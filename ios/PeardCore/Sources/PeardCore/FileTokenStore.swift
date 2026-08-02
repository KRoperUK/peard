import Foundation

/// Holds the short-lived token that protected files are fetched with.
///
/// `posts.media` is a protected file field, so its bytes need `?token=` — a
/// file token minted from the signed-in account, which PocketBase then checks
/// against `posts.ViewRule` before serving anything. Without one the image is a
/// 404, which is the entire point: it used to be a 200 for anybody at all.
///
/// One token serves every image on screen, so this exists to fetch it once
/// rather than per photo, and to keep the same one until it is nearly spent.
/// That matters more than it sounds: the token is part of the URL, and
/// `AsyncImage` keys its cache on the URL — a token that changed per image, or
/// per minute, would re-download the whole timeline each time.
public actor FileTokenStore {
    private let api: APIClient
    private var token: String?
    private var expiresAt: Date?
    /// The in-flight fetch, so a screenful of images that all miss at once
    /// produces one request rather than twenty.
    private var inFlight: Task<String?, Never>?

    /// Renewed this long before the server would stop accepting it. The server
    /// issues 30-minute tokens (see 1786147200_peard_protect_media.go); the
    /// margin covers a slow request and a clock that disagrees a little.
    private static let renewMargin: TimeInterval = 120
    /// Believed lifetime of a freshly-minted token. The response does not say,
    /// so this is the server's configured duration less the margin — and it is
    /// deliberately shorter than the truth. Expiring early costs one request;
    /// expiring late shows broken images.
    private static let assumedLifetime: TimeInterval = 30 * 60

    public init(api: APIClient) {
        self.api = api
    }

    /// A usable token, or nil when one cannot be had.
    ///
    /// Nil rather than throwing: every caller is decorating an image URL, and
    /// none of them can do anything useful with an error. A URL without a token
    /// fails as a missing image, which is the same outcome and less code.
    public func current() async -> String? {
        if let token, let expiresAt, Date() < expiresAt {
            return token
        }
        if let inFlight {
            return await inFlight.value
        }

        let task = Task<String?, Never> { [api] in
            guard let issued = try? await api.issueFileToken() else { return nil }
            return issued.token
        }
        inFlight = task
        let fetched = await task.value
        inFlight = nil

        guard let fetched else { return nil }
        token = fetched
        expiresAt = Date().addingTimeInterval(Self.assumedLifetime - Self.renewMargin)
        return fetched
    }

    /// Forgets the current token, so the next image asks for a fresh one.
    ///
    /// Called on sign-out: a token outlives the session that made it, and
    /// leaving one in memory for the next account to reuse would be a small
    /// version of the bug this whole file exists to fix.
    public func clear() {
        token = nil
        expiresAt = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Appends the token to a path that already may carry a query.
    ///
    /// Static and pure so the query-joining rule is testable without a network:
    /// `?thumb=512x512` needs `&token=`, a bare path needs `?token=`, and
    /// getting that wrong produces a URL the server answers 404 to.
    public static func decorate(_ path: String, token: String) -> String {
        guard !token.isEmpty else { return path }
        let separator = path.contains("?") ? "&" : "?"
        return path + separator + "token=" + escape(token)
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set.
    ///
    /// Not `.urlQueryAllowed`, which permits `+`, `/` and `=` — and a `+` in a
    /// query value is decoded as a space by a great many servers, which would
    /// turn a valid token into a rejected one for no visible reason. A JWT is
    /// base64url and contains none of those, so in practice this passes the
    /// token through untouched; it is the anything-else case that is worth
    /// being exact about.
    private static func escape(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
