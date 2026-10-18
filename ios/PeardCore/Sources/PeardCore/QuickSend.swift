import Foundation

/// A moment that has been tapped but not yet written to the server.
///
/// Tapping a moment is the common case and should cost one tap, so the send is
/// committed automatically after `window`. The window exists only so a note can
/// be added; typing one puts the send on hold, because somebody mid-sentence has
/// not finished saying what they meant.
public struct QuickSend: Hashable, Sendable {
    /// How long the undo/annotate window stays open when nothing has been
    /// configured (issue #398). Only a fallback now: the app passes the user's
    /// chosen `SendWindow` in, and keeps this for a caller with no setting to
    /// hand — the VoiceOver hint, chiefly.
    public static let defaultDelay: TimeInterval = SendWindow.default.seconds

    public let moment: Moment
    public let startedAt: Date
    /// How long this window stays open, in seconds. Captured when the moment is
    /// tapped, so changing the setting mid-countdown cannot move a send that is
    /// already running.
    public let window: TimeInterval
    /// The daily-progress metric this moment counts toward, when it is one —
    /// water, steps, exercise, or a connection's own kind resolved by the
    /// catalogue (#390). Nil for a moment that carries no amount.
    ///
    /// Derived from the kind by default, so callers need not pass it; the
    /// parameter exists for a connection's custom metric, whose definition the
    /// catalogue cannot know without its label and emoji.
    public let metric: MetricDefinition?
    /// Set once the note field has content: the countdown stops and the send
    /// waits for an explicit tap.
    public var isHeld: Bool
    /// An earlier time somebody picked for the moment, or `nil` for now.
    public private(set) var happenedAt: Date?
    /// How much, in millilitres, for a moment that takes an amount; `nil` until
    /// somebody picks one, and always `nil` for any other moment.
    public private(set) var amount: Int?

    public init(
        moment: Moment,
        startedAt: Date = Date(),
        isHeld: Bool = false,
        happenedAt: Date? = nil,
        amount: Int? = nil,
        metric: MetricDefinition? = nil,
        window: TimeInterval = QuickSend.defaultDelay
    ) {
        self.moment = moment
        self.startedAt = startedAt
        self.isHeld = isHeld
        self.happenedAt = happenedAt
        self.metric = metric ?? MetricCatalogue.builtin(moment.kind)
        self.amount = Self.normalised(amount, to: self.metric)
        // A window of zero or less would send the instant it was tapped, which
        // is not a send window at all; one second is the floor.
        self.window = max(1, window)
    }

    /// Whether this moment asks how much: it counts toward a daily metric (#390).
    public var takesAmount: Bool { metric != nil }

    /// Sets how much, or clears it with `nil`. Holds the send either way, like
    /// typing a note: somebody choosing an amount has not finished saying what
    /// they meant. Ignored for a moment that takes no amount, and for one that is
    /// not a sensible size for its metric.
    public mutating func setAmount(_ newAmount: Int?) {
        guard let metric else { return }
        isHeld = true
        amount = Self.normalised(newAmount, to: metric)
    }

    /// A positive amount within the metric's own ceiling, or nil. Water keeps its
    /// five litres through its definition; steps and exercise use their own, so a
    /// count in the thousands is not mistaken for a typo.
    private static func normalised(_ amount: Int?, to metric: MetricDefinition?) -> Int? {
        guard let metric, let amount, amount > 0, amount <= metric.maximum else { return nil }
        return amount
    }

    /// Sets when the moment happened, or clears it with `nil`. Holds the send
    /// either way, like typing a note: somebody picking a time has not finished
    /// saying what they meant. A time too close to now to count as a rewind is
    /// dropped rather than kept, so the send stays an ordinary live one.
    public mutating func rewind(to date: Date?, now: Date = Date()) {
        isHeld = true
        guard let date, Rewind.isRewound(date, loggedAt: now) else {
            happenedAt = nil
            return
        }
        happenedAt = max(date, now.addingTimeInterval(-Rewind.window))
    }

    /// Whole seconds left, rounded up, so a fresh countdown reads its full window.
    public func secondsRemaining(now: Date = Date()) -> Int {
        guard !isHeld else { return Int(window.rounded(.up)) }
        let elapsed = now.timeIntervalSince(startedAt)
        let remaining = window - elapsed
        if remaining <= 0 { return 0 }
        return min(Int(window.rounded(.up)), Int(remaining.rounded(.up)))
    }

    /// Fraction of the window still to run, for the countdown ring.
    public func progressRemaining(now: Date = Date()) -> Double {
        guard !isHeld else { return 1 }
        let elapsed = now.timeIntervalSince(startedAt)
        return min(1, max(0, (window - elapsed) / window))
    }

    /// True once the window has run out and nothing is holding the send.
    public func shouldSend(now: Date = Date()) -> Bool {
        guard !isHeld else { return false }
        return now.timeIntervalSince(startedAt) >= window
    }

    /// The countdown caption, e.g. "Sending in 2…" or "Tap send when ready".
    public func caption(now: Date = Date()) -> String {
        if isHeld { return "Tap send when ready" }
        let remaining = secondsRemaining(now: now)
        return remaining > 0 ? "Sending in \(remaining)…" : "Sending…"
    }
}
