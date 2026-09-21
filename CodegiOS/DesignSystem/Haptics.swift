import SwiftUI
import UIKit

/// Haptic feedback for iOS 16, where SwiftUI's `.sensoryFeedback` (iOS 17) is
/// unavailable. Covers the subset the app uses and fires via UIKit's feedback
/// generators. On iOS 17+ this is still correct — it just doesn't participate in
/// the system's haptics-disabled setting the way `.sensoryFeedback` would.
enum CodegHapticFeedback {
    case impact(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium)
    case selection
    case success
    case warning
    case error

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
    func codegSensoryFeedback<T: Equatable>(
        _ feedback: CodegHapticFeedback,
        trigger: T
    ) -> some View {
        onChange(of: trigger) { _ in
            CodegHapticFeedback.fire(feedback)
        }
    }

    /// Conditional variant: derive the feedback from the new value (return `nil`
    /// to stay silent), matching `.sensoryFeedback(trigger:_:)`'s shape.
    func codegSensoryFeedback<T: Equatable>(
        trigger: T,
        _ feedback: @escaping (T) -> CodegHapticFeedback?
    ) -> some View {
        onChange(of: trigger) { newValue in
            if let feedback = feedback(newValue) {
                CodegHapticFeedback.fire(feedback)
            }
        }
    }
}
