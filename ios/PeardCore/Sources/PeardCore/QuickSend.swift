import Foundation

/// A moment that has been tapped but not yet written to the server.
///
/// Tapping a moment is the common case and should cost one tap, so the send is
/// committed automatically after `delay`. The window exists only so a note can
/// be added; typing one puts the send on hold, because somebody mid-sentence has
/// not finished saying what they meant.
public struct QuickSend: Hashable, Sendable {
    /// How long the undo/annotate window stays open.
    public static let delay: TimeInterval = 3

    public let moment: Moment
    public let startedAt: Date
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
        amount: Int? = nil
    ) {
        self.moment = moment
        self.startedAt = startedAt
        self.isHeld = isHeld
        self.happenedAt = happenedAt
        self.amount = moment.kind == .water ? WaterAmount.normalised(amount) : nil
    }

    /// Whether this moment asks how much. Only water does.
    public var takesAmount: Bool { moment.kind == .water }

    /// Sets how much, or clears it with `nil`. Holds the send either way, like
    /// typing a note: somebody choosing a size has not finished saying what they
    /// meant. Ignored for a moment that takes no amount, and for one that is not a
    /// sensible size.
    public mutating func setAmount(_ ml: Int?) {
        guard takesAmount else { return }
        isHeld = true
        amount = WaterAmount.normalised(ml)
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

    /// Whole seconds left, rounded up, so a fresh countdown reads "3".
    public func secondsRemaining(now: Date = Date()) -> Int {
        guard !isHeld else { return Int(Self.delay.rounded(.up)) }
        let elapsed = now.timeIntervalSince(startedAt)
        let remaining = Self.delay - elapsed
        if remaining <= 0 { return 0 }
        return min(Int(Self.delay.rounded(.up)), Int(remaining.rounded(.up)))
    }

    /// Fraction of the window still to run, for the countdown ring.
    public func progressRemaining(now: Date = Date()) -> Double {
        guard !isHeld else { return 1 }
        let elapsed = now.timeIntervalSince(startedAt)
        return min(1, max(0, (Self.delay - elapsed) / Self.delay))
    }

    /// True once the window has run out and nothing is holding the send.
    public func shouldSend(now: Date = Date()) -> Bool {
        guard !isHeld else { return false }
        return now.timeIntervalSince(startedAt) >= Self.delay
    }

    /// The countdown caption, e.g. "Sending in 2…" or "Tap send when ready".
    public func caption(now: Date = Date()) -> String {
        if isHeld { return "Tap send when ready" }
        let remaining = secondsRemaining(now: now)
        return remaining > 0 ? "Sending in \(remaining)…" : "Sending…"
    }
}
