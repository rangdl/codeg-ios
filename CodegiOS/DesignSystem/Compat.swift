import SwiftUI
import UIKit


// MARK: - iOS 17 / 18 shims (v1.1.0 upstream merge)
//
// The upstream client targets iOS 26. These keep its call sites compiling on
// iOS 16 without forking whole views.

/// The haptic kinds the app asks for, named after SwiftUI's `SensoryFeedback`
/// cases (iOS 17+). Declaring our own keeps the call sites readable on iOS 16,
/// where that type does not exist.
enum CodegHaptic {
    case selection
    case success
    case warning
    case lightImpact
    case softImpact
}

extension View {
    /// `sensoryFeedback` is iOS 17+. These are equivalent UIKit generators on
    /// every version we support, so the trigger fires the same haptic either way
    /// and there is no behaviour fork to reason about.
    func codegSensoryFeedback<T: Equatable>(_ haptic: CodegHaptic, trigger: T) -> some View {
        modifier(CodegHapticTrigger(haptic: haptic, trigger: trigger))
    }

    func codegSensoryFeedback<T: Equatable>(_ haptic: CodegHaptic, trigger: T,
                                            condition: @escaping (T, T) -> Bool) -> some View {
        modifier(CodegHapticTrigger(haptic: haptic, trigger: trigger, condition: condition))
    }
}

extension View {
    /// Upstream's value-driven form: the closure returns which haptic (or none)
    /// a transition deserves. Same semantics on 16, played through UIKit.
    func codegSensoryFeedback<T: Equatable>(trigger: T,
                                            _ decide: @escaping (T, T) -> CodegHaptic?) -> some View {
        modifier(CodegHapticDecision(trigger: trigger, decide: decide))
    }
}

private struct CodegHapticDecision<T: Equatable>: ViewModifier {
    let trigger: T
    let decide: (T, T) -> CodegHaptic?
    @State private var previous: T?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = trigger }
            .onChange(of: trigger) { new in
                if let old = previous, let haptic = decide(old, new) {
                    CodegHaptics.play(haptic)
                }
                previous = new
            }
    }
}

private struct CodegHapticTrigger<T: Equatable>: ViewModifier {
    let haptic: CodegHaptic
    let trigger: T
    var condition: ((T, T) -> Bool)? = nil

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { new in
            guard condition == nil || condition!(trigger, new) else { return }
            CodegHaptics.play(haptic)
        }
    }
}

@MainActor
enum CodegHaptics {
    static func play(_ haptic: CodegHaptic) {
        switch haptic {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .softImpact:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}

extension View {
    /// `onGeometryChange` is iOS 18+. These two cover the only shapes the app
    /// uses: a view's measured width, and its measured height.
    func codegOnWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size.width) }
                    .onChange(of: proxy.size.width) { action($0) }
            }
        )
    }

    func codegOnHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size.height) }
                    .onChange(of: proxy.size.height) { action($0) }
            }
        )
    }
}

extension View {
    /// `presentationCompactAdaptation` is iOS 16.4+.
    @ViewBuilder
    func codegPresentationCompactAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}
