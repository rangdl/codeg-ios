import SwiftUI
import UIKit

/// Haptic feedback for iOS 16, where SwiftUI's `.sensoryFeedback` (iOS 17) is
/// unavailable. Covers the subset the app uses and fires via UIKit's feedback
/// generators. On iOS 17+ `codegSensoryFeedback` prefers the native modifier (so
/// the system's haptics settings are honoured); this is the iOS 16 path.
enum CodegHapticFeedback {
    case impact(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium)
    case selection
    case success
    case warning
    case error

    /// The native equivalent, used on iOS 17+.
    @available(iOS 17.0, *)
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .impact(let style):
            switch style {
            case .light: return .impact(weight: .light)
            case .medium: return .impact(weight: .medium)
            case .heavy: return .impact(weight: .heavy)
            case .soft: return .impact(flexibility: .soft)
            case .rigid: return .impact(flexibility: .rigid)
            default: return .impact(weight: .medium)
            }
        case .selection: return .selection
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }

    @MainActor
    static func fire(_ feedback: CodegHapticFeedback) {
        switch feedback {
        case .impact(let style):
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension View {
    /// Fire `feedback` whenever `trigger` changes (not on the initial value).
    ///
    /// iOS 17+ uses the native `.sensoryFeedback`, so it takes part in the system's
    /// haptics settings; iOS 16 drives the feedback generators by hand.
    @ViewBuilder
    func codegSensoryFeedback<T: Equatable>(
        _ feedback: CodegHapticFeedback,
        trigger: T
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(feedback.sensoryFeedback, trigger: trigger)
        } else {
            self.onChange(of: trigger) { _ in
                CodegHapticFeedback.fire(feedback)
            }
        }
    }

    /// Conditional variant: derive the feedback from the new value (return `nil`
    /// to stay silent), matching `.sensoryFeedback(trigger:_:)`'s shape.
    @ViewBuilder
    func codegSensoryFeedback<T: Equatable>(
        trigger: T,
        _ feedback: @escaping (T) -> CodegHapticFeedback?
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(trigger: trigger) { feedback($0)?.sensoryFeedback }
        } else {
            self.onChange(of: trigger) { newValue in
                if let feedback = feedback(newValue) {
                    CodegHapticFeedback.fire(feedback)
                }
            }
        }
    }
}
