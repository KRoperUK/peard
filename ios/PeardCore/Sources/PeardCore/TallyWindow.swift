import Foundation

/// One of the four reporting windows a tally is counted against.
///
/// The four windows already existed as four fields on `TallyPeriods`, which is
/// right for the wire format — they are literally the keys the server sends — but
/// wrong for a UI that lets somebody choose one. Without a value to hold, every
/// view that offers the choice ends up with its own `switch`, and the labels drift
/// apart between screens.
public enum TallyWindow: String, CaseIterable, Codable, Sendable, Identifiable {
    case day
    case week
    case month
    case all

    public var id: String { rawValue }

    /// The picker's segment title. Short because four of them share a row.
    public var shortLabel: String {
        switch self {
        case .day: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    /// Reads as part of a sentence: "3 beers <phrase>".
    public var phrase: String {
        switch self {
        case .day: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .all: return "all time"
        }
    }

    /// How the home screen's compact tally rows abbreviate this window, kept here
    /// so the row and the breakdown cannot disagree about which letter is which.
    public var initial: String {
        switch self {
        case .day: return "T"
        case .week: return "W"
        case .month: return "M"
        case .all: return "All"
        }
    }
}

public extension TallyPeriods {
    /// The count for one window, so a caller holding a `TallyWindow` does not
    /// need to know which field it maps to.
    func count(in window: TallyWindow) -> Int {
        switch window {
        case .day: return day
        case .week: return week
        case .month: return month
        case .all: return all
        }
    }
}
