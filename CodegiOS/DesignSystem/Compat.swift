import SwiftUI
import UIKit


// MARK: - iOS 17 / 18 shims (v1.1.0 upstream merge)
//
// The upstream client targets iOS 26. These keep its call sites compiling on
// iOS 16 without forking whole views.

extension View {
    /// `sensoryFeedback` is iOS 17+. Haptics are a nicety, so on 16 this is a
    /// no-op rather than a behaviour fork.
    @ViewBuilder
    func codegSensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            self.codegSensoryFeedback(feedback, trigger: trigger)
        } else {
            self
        }
    }

    @ViewBuilder
    func codegSensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T,
                                            condition: @escaping (T, T) -> Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.codegSensoryFeedback(feedback, trigger: trigger, condition: condition)
        } else {
            self
        }
    }

    /// `scrollBounceBehavior` is iOS 16.4+. Below that the default bounce is
    /// close enough; nothing is scroll-critical about it.
    @ViewBuilder
    func codegScrollBounceBehavior() -> some View {
        if #available(iOS 16.4, *) {
            self.codegScrollBounceBehavior()
        } else {
            self
        }
    }

    /// `scrollClipDisabled` is iOS 17+.
    @ViewBuilder
    func codegScrollClipDisabled() -> some View {
        if #available(iOS 17.0, *) {
            self.codegScrollClipDisabled()
        } else {
            self
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
