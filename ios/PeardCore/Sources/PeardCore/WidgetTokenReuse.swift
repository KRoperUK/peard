import Foundation

/// The widget-token endpoints `WidgetSync` needs, as a protocol so the
/// reuse-versus-mint decision can be unit-tested without a live `APIClient` or a
/// simulator (#381). `APIClient` conforms via its `PeardAPI` extension.
public protocol WidgetTokenService: Sendable {
    /// `POST /api/peard/widget/token` — mints a fresh token row and returns its
    /// id and secret.
    func issueWidgetToken() async throws -> WidgetTokenIssue
    /// `GET /api/peard/widget/tokens` — the caller's live token rows (never the
    /// secrets). `currentTokenID` only marks `isCurrentDevice`; it does not
    /// filter.
    func widgetTokens(currentTokenID: String?) async throws -> [WidgetTokenInfo]
}

extension APIClient: WidgetTokenService {}

/// The pure decision behind `WidgetSync.sync()`: reuse the token this device
/// already holds when it is still live server-side, and mint only when there is
/// nothing to reuse (#375). Lifted out of `WidgetSync` — which lives in the app
/// target and depends on `WatchSync`/`WidgetCenter` — so the branching is
/// testable in the fast PeardCore loop (#381).
public enum WidgetTokenReuse {
    /// What `resolve` decided. `.reused` means the held credentials stand as-is;
    /// `.minted` carries the fresh id and secret the caller must persist.
    public enum Outcome: Equatable, Sendable {
        case reused
        case minted(id: String, token: String)
    }

    /// Decide whether to reuse the held token or mint a new one.
    ///
    /// - `heldToken` / `heldID`: what this device currently has stored.
    /// - Reuse when both are present and the id is in the caller's live token
    ///   list. A liveness-check failure while a token is held reuses it, so a
    ///   transient network blip does not mint a redundant row — the pile-up
    ///   #375 fixes. With nothing held, or the held id absent from the live
    ///   list (revoked/expired), mint.
    /// - A mint failure rethrows, matching the opportunistic caller that
    ///   swallows it.
    public static func resolve(
        heldToken: String?,
        heldID: String?,
        service: WidgetTokenService
    ) async throws -> Outcome {
        if let token = heldToken, !token.isEmpty, let id = heldID, !id.isEmpty {
            if await storedTokenIsLive(id: id, service: service) {
                return .reused
            }
        }
        let issue = try await service.issueWidgetToken()
        return .minted(id: issue.id ?? "", token: issue.token)
    }

    /// Whether the row this device minted is still in the caller's live token
    /// list. A failure returns `true` so a transient blip reuses rather than
    /// mints; a dead token is absent and returns `false`, driving a mint.
    private static func storedTokenIsLive(id: String, service: WidgetTokenService) async -> Bool {
        do {
            return try await service.widgetTokens(currentTokenID: nil).contains { $0.id == id }
        } catch {
            return true
        }
    }
}
