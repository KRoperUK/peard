import PeardCore
import SwiftUI

/// What the Messages tray knows.
///
/// It used to know nothing: three hard-coded moments, logged into whichever
/// connection the server judged liveliest, with no way to see or change either.
/// That is defensible for a widget button pressed in passing; it is not for a
/// tray opened inside a conversation with a specific person, where the whole
/// question is *who this is for*. Nothing in Messages tells an extension who the
/// other participants are — Apple gives opaque per-conversation identifiers and
/// nothing else — so it cannot be guessed. It can be asked.
///
/// The moments are the connection's own too, not the three built-ins, so a
/// group that invented "dog walk" can log one from a chat.
@MainActor
@Observable
final class MomentTrayModel {
    enum Phase: Equatable {
        case loading
        /// No widget token in the App Group: the app has never been signed in.
        case signedOut
        case ready
        case failed(String)
    }

    /// What a tap is doing, so it is visibly acknowledged.
    ///
    /// The widget solves this with `pendingWidgetLog`, and says why in its own
    /// doc comment: without an immediate acknowledgement the only sign of life
    /// is the tallies changing after a round trip, which on a slow connection
    /// reads as a button that does nothing.
    enum Status: Equatable {
        case idle
        case logging(String)
        case logged(moment: String, connection: String)
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var connections: [WidgetConnection] = []
    private(set) var moments: [WidgetFeed.AvailableMoment] = MomentTrayModel.builtin
    private(set) var status: Status = .idle
    private(set) var selectedID: String?

    /// The three every connection has without any setup. Used before the
    /// connection's own catalogue arrives, and as the fallback when it cannot
    /// be fetched — a tray that can still log a beer beats one that cannot log
    /// anything because a secondary request failed.
    static let builtin: [WidgetFeed.AvailableMoment] = [
        .init(kind: .beer, emoji: "🍺", label: "Beer"),
        .init(kind: .loo, emoji: "💩", label: "Loo"),
        .init(kind: .coffee, emoji: "☕", label: "Coffee"),
    ]

    private let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    var selectedConnection: WidgetConnection? {
        connections.first { $0.id == selectedID }
    }

    /// Only worth offering a choice when there is one to make.
    var canChooseConnection: Bool { connections.count > 1 }

    var isBusy: Bool {
        if case .logging = status { return true }
        return false
    }

    // MARK: Loading

    func load() async {
        guard let token = store.widgetToken, !token.isEmpty, let baseURL = store.apiBaseURL else {
            phase = .signedOut
            return
        }
        let api = APIClient(baseURL: baseURL)
        do {
            connections = try await api.widgetConnections(token: token)
        } catch let error as APIError where error.isCancellation {
            // Messages tears the extension's task down when the tray is
            // collapsed. Nothing went wrong and nothing should be said.
            return
        } catch {
            phase = .failed("Couldn't reach Pear'd.")
            return
        }

        guard !connections.isEmpty else {
            phase = .failed("Pear up with somebody first.")
            return
        }

        // Last used from here, then whatever the app is showing, then the first.
        // The app's choice is a decent guess for somebody who has only ever had
        // one connection; it is only a guess, which is why the picker exists.
        selectedID = [store.messagesConnectionID, store.selectedConnectionID]
            .compactMap { $0 }
            .first { id in connections.contains { $0.id == id } }
            ?? connections[0].id

        phase = .ready
        await loadMoments()
    }

    func select(_ id: String) async {
        guard id != selectedID else { return }
        selectedID = id
        store.messagesConnectionID = id
        status = .idle
        await loadMoments()
    }

    /// The chosen connection's own catalogue.
    ///
    /// A failure leaves the built-ins in place rather than emptying the tray:
    /// the three of them work in every connection, and a tray with no buttons is
    /// worse than a tray missing the custom ones.
    private func loadMoments() async {
        guard let token = store.widgetToken, let baseURL = store.apiBaseURL, let selectedID else { return }
        let api = APIClient(baseURL: baseURL)
        guard let feed = try? await api.widgetFeed(token: token, pairID: selectedID) else {
            moments = Self.builtin
            return
        }
        let published = feed.moments ?? []
        moments = published.isEmpty ? Self.builtin : published
    }

    // MARK: Logging

    /// Logs the moment and reports whether the server took it, so the caller
    /// knows whether it may put a bubble in somebody's conversation saying so.
    func log(_ moment: WidgetFeed.AvailableMoment) async -> Bool {
        guard case .idle = status else { return false }
        status = .logging(moment.id)

        let logged = await MomentLogging.perform(
            kind: moment.kind,
            // Always explicit now. The old nil meant "whichever the server
            // thinks is liveliest", which is a guess the tray then could not
            // report — you tapped, something was logged, and nowhere on screen
            // said where it went.
            pairID: selectedID,
            emoji: moment.emoji,
            label: moment.label,
            store: store
        )

        guard logged else {
            status = .failed
            return false
        }
        status = .logged(moment: moment.label, connection: selectedConnection?.title ?? "")
        return true
    }
}
