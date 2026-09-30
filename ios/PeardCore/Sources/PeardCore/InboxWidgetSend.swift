import Foundation

public extension MomentInbox {
    /// Sends what is waiting through the widget route, oldest first, for a
    /// device whose only credential is the widget token — the watch (issue
    /// #286). The phone drains the same inbox through its send queue instead.
    ///
    /// Each keeps its own id as `client_id`, so one that did arrive before the
    /// answer was lost is refused as a duplicate rather than logged twice, and
    /// its tap time as `happened_at`. Stops at the first failure worth retrying:
    /// if one cannot get through, the rest will not either. One the server
    /// refuses outright is dropped, since retrying cannot help.
    ///
    /// Only plain moments: photos and notes go through the phone.
    ///
    /// - Returns: how many are still waiting.
    @discardableResult
    func sendThroughWidgetRoute(using api: APIClient, token: String) async -> Int {
        for moment in load() where moment.isPlainMoment {
            do {
                try await api.logWidgetMoment(
                    token: token,
                    kind: moment.kind,
                    pairID: moment.pairID,
                    clientID: moment.id,
                    happenedAt: moment.queuedAt
                )
                remove(ids: [moment.id])
            } catch {
                guard case .permanent = SendFailure.classify(error) else { break }
                remove(ids: [moment.id])
            }
        }
        return load().filter(\.isPlainMoment).count
    }
}

extension InboxedMoment {
    var isPlainMoment: Bool {
        !hasPhoto && note.isEmpty && (postType == nil || postType == .event)
    }
}
