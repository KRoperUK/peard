import Foundation

/// Resolves incoming `peard://` URLs (Requirement 19).
public enum DeepLink: Equatable, Sendable {
    /// `peard://pair/{code}` — pairing screen with the code pre-filled.
    case pair(code: String)
    /// `peard://home`
    case home
    /// `peard://auth/google` — belongs to the pending authorization session.
    case googleCallback(URL)

    public static let scheme = "peard"

    /// The host whose `/c/{code}` links open the app directly.
    ///
    /// A universal link rather than only `peard://`, because a custom scheme is
    /// nothing at all to somebody who has not installed the app — iOS shows
    /// "Safari cannot open the page", which is the worst possible answer to an
    /// invite. An https link opens the app when it is there and a web page that
    /// explains how to get it when it is not.
    public static let webHost = "peard.kroper.uk"
    /// The path an invite link uses, kept in step with the server's `/c/{code}`
    /// route and the `applinks` component in its site association file.
    public static let invitePath = "c"

    /// Returns `nil` for any URL that matches no known route
    /// (Requirement 19.5).
    public static func parse(_ url: URL) -> DeepLink? {
        if let webInvite = parseWebInvite(url) { return webInvite }
        guard url.scheme?.lowercased() == scheme else { return nil }

        // peard://pair/ABC123 parses with host "pair" and path "/ABC123".
        let segments = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .filter { !$0.isEmpty }

        switch segments.first?.lowercased() {
        case "pair":
            guard segments.count >= 2 else { return nil }
            let code = segments[1].uppercased()
            return code.isEmpty ? nil : .pair(code: code)
        case "home":
            return .home
        case "auth":
            guard segments.count >= 2, segments[1].lowercased() == "google" else { return nil }
            return .googleCallback(url)
        default:
            return nil
        }
    }

    /// `https://peard.kroper.uk/c/ABC123` — the link an invite is shared as.
    ///
    /// Only that one path, and only on that host: an associated domain hands
    /// the app *every* https URL on the domain that matches, and anything this
    /// does not recognise has to fall through to the browser rather than open
    /// an app that has nothing to show for it. The privacy policy at `/privacy`
    /// is on the same host and must keep opening in Safari.
    private static func parseWebInvite(_ url: URL) -> DeepLink? {
        guard
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host?.lowercased() == webHost
        else { return nil }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count == 2, segments[0].lowercased() == invitePath else { return nil }

        let code = segments[1].uppercased()
        return code.isEmpty ? nil : .pair(code: code)
    }

    /// The link to put in an invite message.
    ///
    /// Built here rather than taken from the server's `deep_link` so the app
    /// shares the public https form even when it is pointed at a dev server,
    /// which is what somebody receiving the message needs — a link to
    /// 192.168.x.y is no use to them at all.
    public static func inviteLink(code: String) -> URL {
        URL(string: "https://\(webHost)/\(invitePath)/\(code)")!
    }
}

/// Resolution of the configured server URL (Requirement 3.1, 3.2).
public enum PeardServerURL {
    public static let fallback = URL(string: "http://127.0.0.1:8090")!

    /// Accepts only an absolute URL with a scheme and a host. An empty value,
    /// an unsubstituted `$(...)` placeholder, or a relative string falls back.
    public static func resolve(_ raw: String?, fallback: URL = PeardServerURL.fallback) -> URL {
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            !trimmed.contains("$("),
            let url = URL(string: trimmed),
            let scheme = url.scheme,
            !scheme.isEmpty,
            let host = url.host,
            !host.isEmpty
        else {
            return fallback
        }
        // Strip a trailing slash so path joining stays predictable.
        if trimmed.hasSuffix("/"), let stripped = URL(string: String(trimmed.dropLast())) {
            return stripped
        }
        return url
    }
}
