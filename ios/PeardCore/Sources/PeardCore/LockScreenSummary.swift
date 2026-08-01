import Foundation

/// What the Lock Screen has room to say.
///
/// The home-screen widget can afford a photo, a note over three lines, a row of
/// tallies and five buttons. The accessory families cannot: rectangular is about
/// three short lines, circular is a thumbnail, and inline is a single line
/// sharing the date. So this is not the same content drawn smaller — it is a
/// separate decision about what survives when almost everything has to go.
///
/// Kept here rather than in the widget extension because the extension has no
/// test target of its own: an app-extension bundle cannot host one, which is the
/// same reason the Messages tray's model is compiled into the app's tests.
public struct LockScreenSummary: Equatable, Sendable {
    /// The moment's emoji, or the pear when there is no moment.
    ///
    /// Lock Screen widgets render desaturated, so this reads as a silhouette
    /// rather than a picture. That is survivable for the shapes the app deals in
    /// and is why the text beside it is never purely decorative.
    public let emoji: String
    /// Who, and — in a group — where.
    public let headline: String
    /// What they said, else what they did. One line, and the note wins: it is
    /// the part that could not have been guessed.
    public let detail: String?
    /// Today's counts, pre-joined. Nil when there are none.
    public let talliesText: String?
    /// Everything anybody else logged today, for the circular family, which has
    /// room for one number and nothing else.
    public let todayTotal: Int
    /// When the moment happened, for a relative timestamp.
    public let at: Date?
    /// True when there is no moment to report, only a prompt.
    public let isPrompt: Bool

    /// The single line the inline family gets, next to the clock.
    public let inlineText: String

    public init(
        state: FeedState,
        partnerName: String,
        groupName: String? = nil,
        emoji: String,
        momentLabel: String = "",
        note: String = "",
        tallies: [WidgetFeed.Tally] = [],
        created: Date? = nil
    ) {
        let name = partnerName.isEmpty ? PartnerLabel.fallback : partnerName
        let total = tallies.reduce(0) { $0 + $1.count }
        self.todayTotal = total

        // Three tallies, matching the home-screen widget's own cap. Rectangular
        // is narrower than the small family, so this is the ceiling rather than
        // the target.
        let shown = tallies.prefix(3)
        self.talliesText = shown.isEmpty
            ? nil
            : shown.map { "\($0.emoji) \($0.count)" }.joined(separator: "  ")

        switch state {
        case .unpaired:
            self.emoji = "🍐"
            self.headline = "Pear up"
            self.detail = "Nobody to hear from yet"
            self.at = nil
            self.isPrompt = true
            self.inlineText = "🍐 Pear up to get started"

        case .empty:
            self.emoji = "🍐"
            self.headline = name
            self.detail = "Nothing yet today"
            self.at = nil
            self.isPrompt = true
            self.inlineText = "🍐 Nothing from \(name) yet"

        default:
            let resolvedEmoji = emoji.isEmpty ? MomentCatalogue.fallbackEmoji : emoji
            self.emoji = resolvedEmoji
            // In a group the name alone is ambiguous — two connections can both
            // contain a Sam — so the group is named too when it has a name.
            self.headline = groupName.map { "\(name) · \($0)" } ?? name
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = momentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            self.detail = [trimmedNote, label].first { !$0.isEmpty }
            self.at = created
            self.isPrompt = false
            // No timestamp: inline shares its line with the date, and iOS
            // truncates the middle of an over-long string rather than the end,
            // which would eat the name instead of the tail.
            let tail = [trimmedNote, label].first { !$0.isEmpty }
            self.inlineText = tail.map { "\(resolvedEmoji) \(name) · \($0)" } ?? "\(resolvedEmoji) \(name)"
        }
    }
}
