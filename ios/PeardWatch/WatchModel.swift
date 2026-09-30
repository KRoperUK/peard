import Foundation
import Observation
import PeardCore
import WidgetKit

/// The watch's one job: log a moment to a connection (issue #8).
@MainActor
@Observable
final class WatchModel {
    enum Phase: Equatable {
        /// No credentials from the phone yet.
        case signedOut
        case loading
        case ready
        case failed(String)
    }

    /// What became of the last tap on a moment, shown on its button.
    enum LogState: Equatable {
        case sending
        case logged
        /// No signal: kept, and sent when the watch next can (issue #286).
        case queued
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var connections: [WidgetConnection] = []
    private(set) var logStates: [String: LogState] = [:]
    /// Moments tapped without a connection, still to be sent.
    private(set) var waitingCount = 0

    var selectedID: String? {
        didSet { store.selectedConnectionID = selectedID }
    }

    private let store: SharedStore
    private let inbox: MomentInbox

    init(store: SharedStore = .shared, inbox: MomentInbox = .appGroup()) {
        self.store = store
        self.inbox = inbox
        selectedID = store.selectedConnectionID
        waitingCount = inbox.load().count
    }

    var selected: WidgetConnection? {
        connections.first { $0.id == selectedID } ?? connections.first
    }

    /// The selected connection's moments, or the built-ins before any have
    /// arrived — a watch that can log a beer is better than an empty screen.
    var moments: [WidgetFeed.AvailableMoment] {
        if let moments = selected?.moments, !moments.isEmpty { return moments }
        return MomentCatalogue.builtin.map {
            WidgetFeed.AvailableMoment(kind: $0.kind, emoji: $0.emoji, label: $0.label)
        }
    }

    func load() async {
        guard let credentials = WatchCredentials(store: store) else {
            phase = .signedOut
            return
        }
        if connections.isEmpty { phase = .loading }
        await sendWaiting(credentials)
        do {
            connections = try await APIClient(baseURL: credentials.baseURL)
                .widgetConnections(token: credentials.token, withMoments: true)
            if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) {
                selectedID = connections.first?.id
            }
            phase = .ready
        } catch let error as APIError {
            if case .unauthorized = error {
                phase = .signedOut
            } else if connections.isEmpty {
                phase = .failed(APIError.userMessage(for: error))
            }
        } catch {
            if connections.isEmpty { phase = .failed(APIError.userMessage(for: error)) }
        }
    }

    func log(_ moment: WidgetFeed.AvailableMoment) async {
        guard let credentials = WatchCredentials(store: store) else {
            phase = .signedOut
            return
        }
        let key = moment.kind.rawValue
        guard logStates[key] != .sending else { return }
        Haptics.play(.momentTapped)
        logStates[key] = .sending
        // Chosen here so a queued retry carries the same id, and the server can
        // refuse it as a duplicate if this attempt did land.
        let queued = InboxedMoment(
            pairID: selected?.id,
            kind: moment.kind,
            emoji: moment.emoji,
            label: moment.label
        )
        do {
            try await APIClient(baseURL: credentials.baseURL).logWidgetMoment(
                token: credentials.token,
                kind: moment.kind,
                pairID: queued.pairID,
                clientID: queued.id
            )
            logStates[key] = .logged
            Haptics.play(.sent)
            WidgetCenter.shared.reloadAllTimelines()
            // It got through, so anything waiting probably can too.
            await sendWaiting(credentials)
        } catch {
            if case .retryable = SendFailure.classify(error), inbox.append(queued) {
                // Kept, so it counts as sent: the same promise the phone's toast
                // makes for a moment saved offline.
                logStates[key] = .queued
                waitingCount = inbox.load().count
                Haptics.play(.sent)
            } else {
                logStates[key] = .failed
                Haptics.play(.failed)
            }
        }
        // Long enough to read, then back to the plain button.
        try? await Task.sleep(for: .seconds(2))
        if logStates[key] != .sending { logStates[key] = nil }
    }

    /// Sends what was tapped while offline, oldest first, at the times it was
    /// tapped.
    private func sendWaiting(_ credentials: WatchCredentials) async {
        guard waitingCount > 0 || !inbox.load().isEmpty else { return }
        let before = waitingCount
        waitingCount = await inbox.sendThroughWidgetRoute(
            using: APIClient(baseURL: credentials.baseURL),
            token: credentials.token
        )
        if waitingCount < before { WidgetCenter.shared.reloadAllTimelines() }
    }
}
