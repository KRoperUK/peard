import Foundation

/// Compact elapsed-time labels (Requirement 11.10).
public enum ElapsedTime {
    /// "now" below a minute, then `m`, `h`, `d` — always whole units, floored.
    public static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// Partner display-name rules (Requirement 11.7, 11.8).
public enum PartnerLabel {
    public static let fallback = "Partner"

    /// Used where "Partner" would be wrong: an author who is not a current
    /// member of the connection, which happens once somebody leaves but their
    /// moments stay in the shared timeline. Mirrors the server's own fallback in
    /// `internal/pairs`, and reads correctly in a group, where there is no
    /// single "partner" to speak of.
    public static let unknown = "Someone"

    /// `display_name`, else the local part of the email, else "Partner".
    public static func resolve(displayName: String?, email: String?) -> String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, let separator = email.firstIndex(of: "@") {
            let localPart = email[email.startIndex..<separator]
            if !localPart.isEmpty { return String(localPart) }
        }
        return fallback
    }

    public static func resolve(user: UserRecord?) -> String {
        resolve(displayName: user?.displayName, email: user?.email)
    }

    /// Truncates to 7 characters plus an ellipsis beyond 8 characters.
    public static func short(_ name: String) -> String {
        guard name.count > 8 else { return name }
        return String(name.prefix(7)) + "…"
    }
}
