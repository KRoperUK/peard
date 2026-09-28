import ActivityKit
import Foundation
import PeardCore

/// Hands the server what it needs to run photo-drop Live Activities.
///
/// Nothing here starts an activity: the server does, by push, with this
/// device's push-to-start token (iOS 17.2+), and then updates it with the
/// activity's own token. So the coordinator's job is the two tokens —
///
///   - the push-to-start token goes on this device's `devices` row, once that
///     row exists (it is made when APNs hands over the device token);
///   - each activity's update token goes in `live_activities`, scoped to its
///     connection, and comes out again when the activity ends —
///
/// and one piece of housekeeping: when a new activity arrives for a connection
/// that already has one (the old one lapsed, and the server started afresh),
/// the old one is ended, so the Lock Screen never shows two.
@MainActor
final class LiveActivityCoordinator {
    private let api: APIClient
    private let session: KeychainSessionStore
    private let store: SharedStore

    private var startToken: String?
    private var observed: Set<String> = []
    /// Activity id → the update token registered for it.
    private var registered: [String: String] = [:]
    private var isRunning = false

    init(api: APIClient, session: KeychainSessionStore, store: SharedStore) {
        self.api = api
        self.session = session
        self.store = store
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await data in Activity<PhotoDropAttributes>.pushToStartTokenUpdates {
                    guard let self else { return }
                    self.startToken = Self.hex(data)
                    await self.uploadStartToken()
                }
            }
        }

        for activity in Activity<PhotoDropAttributes>.activities {
            observe(activity)
        }
        Task { [weak self] in
            for await activity in Activity<PhotoDropAttributes>.activityUpdates {
                guard let self else { return }
                self.endOthers(forPair: activity.attributes.pairID, keeping: activity.id)
                self.observe(activity)
            }
        }
    }

    /// Puts the push-to-start token on this device's registration. Called when
    /// the token arrives and again once push registration has made the row, in
    /// whichever order those happen.
    func uploadStartToken() async {
        guard
            let startToken,
            let deviceToken = store.devicePushToken, !deviceToken.isEmpty,
            let userID = session.userID, !userID.isEmpty
        else { return }
        do {
            guard let device = try await api.first(
                "devices",
                of: Device.self,
                filter: PeardFilter.equals("push_token", deviceToken)
            ) else { return }
            let _: Device = try await api.update("devices", id: device.id, fields: ["activity_start_token": startToken])
        } catch {
            // Retried the next time either token changes or the app registers.
        }
    }

    /// Ends every photo drop at once, for signing out: the next person to sign
    /// in on this phone should not see the last one's connections.
    func endAll() async {
        for activity in Activity<PhotoDropAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        registered.removeAll()
    }

    // MARK: Per activity

    private func observe(_ activity: Activity<PhotoDropAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let pairID = activity.attributes.pairID
        let activityID = activity.id

        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                let token = Self.hex(data)
                self.registered[activityID] = token
                await self.register(token: token, pairID: pairID)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self else { return }
                if let token = self.registered.removeValue(forKey: activityID) {
                    await self.unregister(token: token)
                }
                self.observed.remove(activityID)
                return
            }
        }
    }

    private func endOthers(forPair pairID: String, keeping activityID: String) {
        for other in Activity<PhotoDropAttributes>.activities
        where other.id != activityID && other.attributes.pairID == pairID {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func register(token: String, pairID: String) async {
        guard let userID = session.userID, !userID.isEmpty else { return }
        let fields = ["user": userID, "pair": pairID, "push_token": token]
        do {
            if let existing = try await api.first(
                "live_activities",
                of: Identified.self,
                filter: PeardFilter.equals("push_token", token)
            ) {
                let _: Identified = try await api.update("live_activities", id: existing.id, fields: fields)
            } else {
                let _: Identified = try await api.create("live_activities", fields: fields)
            }
        } catch {
            // Without the row the next photo starts a fresh activity rather than
            // updating this one, which endOthers then tidies up.
        }
    }

    private func unregister(token: String) async {
        do {
            if let existing = try await api.first(
                "live_activities",
                of: Identified.self,
                filter: PeardFilter.equals("push_token", token)
            ) {
                try await api.delete("live_activities", id: existing.id)
            }
        } catch {
            // The server forgets it thirty minutes after its last photo anyway.
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct Identified: Codable, Hashable, Sendable { let id: String }
}
