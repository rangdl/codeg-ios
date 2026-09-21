import SwiftUI
import UIKit

/// Live scroll metrics, mirroring the fields of SwiftUI's `ScrollGeometry` that
/// the transcript needs. iOS 16 has no `.onScrollGeometryChange`, so we read the
/// enclosing `UIScrollView` (SwiftUI's `List` is UICollectionView-backed) directly.
struct CodegScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
}

/// A zero-size, non-interactive view that finds the `UIScrollView` it is placed
/// inside and reports its metrics on every offset/size change.
private struct CodegScrollMetricsReader: UIViewRepresentable {
    let onChange: (CodegScrollMetrics, UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        private let onChange: (CodegScrollMetrics, UIScrollView) -> Void
        private weak var scrollView: UIScrollView?

        init(onChange: @escaping (CodegScrollMetrics, UIScrollView) -> Void) {
            self.onChange = onChange
        }

        func attach(from view: UIView) {
            guard let sv = view.codegEnclosingScrollView() else { return }
            guard sv !== scrollView else {
                report()
                return
            }
            detach()
            scrollView = sv
            sv.addObserver(self, forKeyPath: "contentOffset", options: [.new], context: nil)
            sv.addObserver(self, forKeyPath: "contentSize", options: [.new], context: nil)
            report()
        }

        private func detach() {
            scrollView?.removeObserver(self, forKeyPath: "contentOffset")
            scrollView?.removeObserver(self, forKeyPath: "contentSize")
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            report()
        }

        private func report() {
            guard let sv = scrollView else { return }
            let metrics = CodegScrollMetrics(
                offsetY: sv.contentOffset.y,
                contentHeight: sv.contentSize.height,
                containerHeight: sv.bounds.height,
                topInset: sv.adjustedContentInset.top,
                bottomInset: sv.adjustedContentInset.bottom
            )
            DispatchQueue.main.async { self.onChange(metrics, sv) }
        }

        deinit { detach() }
    }
}

extension UIView {
    func codegEnclosingScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}

extension View {
    /// iOS 16 stand-in for `.onScrollGeometryChange`: reports the enclosing
    /// scroll view's metrics whenever they change, and hands back the scroll
    /// view itself so callers can drive it directly.
    ///
    /// `ScrollViewProxy.scrollTo` traps inside SwiftUI on iOS 16 for this `List`
    /// (the target anchor row may not be instantiated under lazy loading), so
    /// scroll-to-bottom goes through the `UIScrollView` instead.
    func codegOnScrollMetricsChange(
        _ action: @escaping (CodegScrollMetrics, UIScrollView) -> Void
    ) -> some View {
        self.background(CodegScrollMetricsReader(onChange: action))
    }
}
