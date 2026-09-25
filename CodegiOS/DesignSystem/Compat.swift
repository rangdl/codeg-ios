import SwiftUI

// MARK: - Availability shims
//
// Every iOS 16 downgrade in this app lives here (or in `Haptics.swift` /
// `ScrollMetrics.swift` / `GlassComponents.swift`), and each one is a *branch*:
// iOS 17/18/26 keep the API the app was written against, and only iOS 16 takes the
// fallback. Call sites use the shim, so they differ from upstream by one line
// instead of losing the API outright.
//
// When adding one: put the branch here, keep the call site to a single shim call,
// and never fork a whole view. See `docs/ios16-compat.md` for the inventory and for
// the APIs that are deliberately *not* gated.

// MARK: - Sheets

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

// MARK: - Geometry

/// Reports a view's measured height. Stand-in for
/// `.onGeometryChange(for: CGFloat.self) { $0.size.height }` (iOS 18).
private struct CodegHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Reports the view's height whenever it changes. iOS 18+ uses the native
    /// `onGeometryChange`; iOS 16/17 measures through a `GeometryReader` preference.
    @ViewBuilder
    func codegOnHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { action($0) }
        } else {
            self.background(
                GeometryReader { proxy in
                    Color.clear.preference(key: CodegHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(CodegHeightPreferenceKey.self) { action($0) }
        }
    }
}

// MARK: - Zoom navigation transition

extension View {
    /// Pairs a card with the fullscreen it zooms into. iOS 18+ only: the modifier
    /// is a no-op below that, where the cover just presents normally.
    @ViewBuilder
    func codegZoomSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The other half of `codegZoomSource`.
    @ViewBuilder
    func codegZoomTransition<ID: Hashable>(sourceID: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}
