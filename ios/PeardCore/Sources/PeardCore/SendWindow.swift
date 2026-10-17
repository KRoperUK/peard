import Foundation

/// How long a tapped moment waits before it sends itself, so a note can be added
/// (issue #398).
///
/// Was a hardcoded three seconds. Three is plenty to glance at a note field and
/// tap it, but not long enough to actually write anything — a tester reaching
/// for a full sentence had the field taken away mid-word. Five is the default;
/// the shorter and longer options exist for people who want the tap-and-move-on
/// speed back, or who write slower still.
///
/// The user's, not a connection's: it belongs with appearance and low data, the
/// other things in Settings that are about whoever is holding the phone.
public enum SendWindow: String, CaseIterable, Sendable {
    case three = "3"
    case five = "5"
    case eight = "8"
    case ten = "10"

    public static let `default` = SendWindow.five

    /// Tolerant of a value it does not recognise, like the other preferences: a
    /// setting written by a later build falls back to the default rather than
    /// refusing to start a countdown.
    public init(storedValue: String?) {
        self = SendWindow(rawValue: storedValue ?? "") ?? .default
    }

    /// Seconds the window stays open.
    public var seconds: TimeInterval {
        switch self {
        case .three: return 3
        case .five: return 5
        case .eight: return 8
        case .ten: return 10
        }
    }

    /// Whole seconds, for the copy that counts down and the picker's labels.
    public var wholeSeconds: Int { Int(seconds.rounded()) }

    /// Short form for a segmented picker, where "5 seconds" would not fit four
    /// abreast on a phone.
    public var pickerTitle: String { "\(wholeSeconds)s" }
}
