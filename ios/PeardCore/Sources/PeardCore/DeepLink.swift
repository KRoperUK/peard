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

    /// Returns `nil` for any URL that matches no known route
    /// (Requirement 19.5).
    public static func parse(_ url: URL) -> DeepLink? {
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
