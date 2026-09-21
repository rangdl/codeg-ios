import SwiftUI

/// iOS 16 compatibility shims for SwiftUI APIs introduced in 16.4 / 17 / 18.
extension View {
    /// `presentationBackground` is iOS 16.4+. On 16.0–16.3 fall back to a plain
    /// background that fills the presented sheet.
    @ViewBuilder
    func codegPresentationBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(color)
        } else {
            self.background(color.ignoresSafeArea())
        }
    }
}

/// Reports a view's measured height. Stand-in for
/// `.onGeometryChange(for: CGFloat.self) { $0.size.height }` (iOS 18).
private struct CodegHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// iOS 16 stand-in for `.onGeometryChange(for: CGFloat.self) { $0.size.height }`.
    func codegOnHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(key: CodegHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(CodegHeightPreferenceKey.self) { action($0) }
    }
}
