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

    /// How long ago something last happened, for "when did we last…".
    ///
    /// Separate from `label` rather than an extension of it, because the two
    /// answer different questions over different spans. A timeline row is
    /// minutes-to-days old and "21d" there is fine; a moment nobody has logged
    /// since spring is the interesting case here, and "112d" says less than
    /// "4mo" about whether it is worth doing again.
    ///
    /// Whole units, floored, and deliberately coarse: this sits under an emoji
    /// on a 80-point tile, and the difference between 6 and 7 weeks is not what
    /// anybody is reading it for.
    public static func age(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "now" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if days < 60 { return "\(weeks)w" }
        let months = days / 30
        if months < 12 { return "\(months)mo" }
        return "\(days / 365)y"
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
