import Foundation
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The moments in the app that are felt as well as seen (issue #274).
///
/// Named for what happened rather than for the feedback it gets, so every
/// call site that means "a moment went" feels the same, and a change of mind
/// about how that should feel is one line here.
public enum Haptic: Equatable, Sendable {
    /// A moment was tapped and its countdown started.
    case momentTapped
    /// A moment or photo was recorded to go — queued, not necessarily
    /// delivered, which is the same promise the toast makes.
    case sent
    /// A pending send was dismissed before it went.
    case cancelled
    /// Something the person asked for could not be done.
    case failed
    /// The pending moment was moved to an earlier time.
    case rewound
    /// A reaction was added or taken back.
    case reacted
    /// Another connection was chosen on the rail.
    case switchedConnection
    /// The tallies were switched to another period.
    case changedPeriod

    enum Feedback: Equatable {
        case impact(Weight)
        case notification(Outcome)
        case selection

        enum Weight: Equatable { case light, medium }
        enum Outcome: Equatable { case success, warning, error }
    }

    /// Kept subtle and distinct: a light tap to start, a success at the end,
    /// and the stronger patterns only for things that did not go.
    var feedback: Feedback {
        switch self {
        case .momentTapped: return .impact(.light)
        case .sent: return .notification(.success)
        case .cancelled: return .notification(.warning)
        case .failed: return .notification(.error)
        case .rewound: return .impact(.medium)
        case .reacted, .switchedConnection, .changedPeriod: return .selection
        }
    }
}

public enum Haptics {
    /// Plays the feedback for `haptic`. Does nothing where there is no
    /// Taptic Engine to play it on.
    @MainActor
    public static func play(_ haptic: Haptic) {
        #if os(watchOS)
        // The watch has its own vocabulary, closest match for each.
        let type: WKHapticType
        switch haptic.feedback {
        case .impact(.light), .selection: type = .click
        case .impact(.medium): type = .directionDown
        case .notification(.success): type = .success
        case .notification(.warning): type = .retry
        case .notification(.error): type = .failure
        }
        WKInterfaceDevice.current().play(type)
        #elseif canImport(UIKit)
        switch haptic.feedback {
        case .impact(.light): UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .impact(.medium): UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .notification(.success): UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .notification(.warning): UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .notification(.error): UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
        #endif
    }
}
