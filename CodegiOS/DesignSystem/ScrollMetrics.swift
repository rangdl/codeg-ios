import SwiftUI
import UIKit

/// Live scroll metrics, mirroring the fields of SwiftUI's `ScrollGeometry` that
/// the transcript needs. iOS 16 has no `.onScrollGeometryChange`, so we read the
/// enclosing `UIScrollView` directly.
struct CodegScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// Whether the *user* is driving the scroll right now — a finger down
    /// (`isTracking`, true before it has even moved), a drag (`isDragging`), or
    /// momentum after release (`isDecelerating`).
    ///
    /// Captured at report time on purpose: the callback is dispatched one tick
    /// later, by which time a short drag may already have ended. Callers use it to
    /// tell "the user scrolled away" from "the content grew / the keyboard moved
    /// the bottom", which is the distinction the transcript's bottom-pin depends
    /// on.
    var isUserInteracting: Bool
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

        func attach(from view: UIView, attempt: Int = 0) {
            guard let sv = view.codegTranscriptScrollView() else {
                // The probe may not be in the hierarchy yet — retry briefly.
                guard attempt < 12 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(from: view, attempt: attempt + 1)
                }
                return
            }
            guard sv !== scrollView else {
                report()
                return
            }
            detach()
            scrollView = sv
            sv.addObserver(self, forKeyPath: "contentOffset", options: [.new], context: nil)
            sv.addObserver(self, forKeyPath: "contentSize", options: [.new], context: nil)
            // Keyboard show/hide changes the content inset (and thus where "the
            // bottom" is) without necessarily changing offset/size — observe it so
            // the transcript re-snaps and the pinned state stays correct.
            sv.addObserver(self, forKeyPath: "contentInset", options: [.new], context: nil)
            // The frame too: the keyboard can resize the scroll view instead of (or
            // as well as) insetting it, and `bounds.height` is what turns a content
            // height into an offset. Without this, a resize produced no report at
            // all, so a snap taken mid-transition — with the pre-transition height —
            // was never corrected, leaving the viewport parked a whole keyboard
            // height past the end of the content.
            sv.addObserver(self, forKeyPath: "bounds", options: [.new], context: nil)
            report()
        }

        private func detach() {
            scrollView?.removeObserver(self, forKeyPath: "contentOffset")
            scrollView?.removeObserver(self, forKeyPath: "contentSize")
            scrollView?.removeObserver(self, forKeyPath: "contentInset")
            scrollView?.removeObserver(self, forKeyPath: "bounds")
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
                bottomInset: sv.adjustedContentInset.bottom,
                isUserInteracting: sv.isTracking || sv.isDragging || sv.isDecelerating
            )
            DispatchQueue.main.async { self.onChange(metrics, sv) }
        }

        deinit { detach() }
    }
}

extension UIScrollView {
    /// TEMPORARY (with `CodegiOS/Diagnostics/ScrollTrace.swift`): the deepest
    /// realized content subview — its bottom in *content* coordinates, its alpha, and
    /// its bottom in window coordinates.
    ///
    /// A `LazyVStack` reports a `contentSize` that is an *estimate* (unrealized rows
    /// contribute a guess), so "the viewport sits at the reported bottom" does not
    /// prove there is anything to draw there. This says where the drawn content
    /// really ends, which is what separates "the estimate overshoots" (a large gap
    /// below `end`) from "the rows exist but are invisible" (`end` reaches the
    /// viewport while `alpha` is 0).
    func codegDeepestRealizedView() -> (bottom: CGFloat, alpha: CGFloat, winBottom: CGFloat)? {
        let contentHeight = contentSize.height
        var best: (bottom: CGFloat, alpha: CGFloat, winBottom: CGFloat)?
        func walk(_ view: UIView, depth: Int) {
            guard depth < 40 else { return }
            for sub in view.subviews {
                if sub.isHidden || sub.bounds.height <= 0 { continue }
                // The scroll indicators live in the scroll view itself.
                if String(describing: type(of: sub)).contains("ScrollIndicator") { continue }
                let inContent = sub.convert(sub.bounds, to: self)
                // The content *container* spans the whole content — which for a lazy
                // stack is the estimate — so it always reaches the bottom and says
                // nothing. Skip it as a candidate (but walk through it: the rows are
                // inside).
                if abs(inContent.height - contentHeight) >= 2,
                   best == nil || inContent.maxY > best!.bottom {
                    best = (inContent.maxY, sub.alpha, sub.convert(sub.bounds, to: nil).maxY)
                }
                walk(sub, depth: depth + 1)
            }
        }
        walk(self, depth: 0)
        return best
    }
}

extension UIView {
    /// Finds the transcript's `UIScrollView` from an introspection view.
    ///
    /// Tries, in order: (1) walking up the superview chain (works when the probe
    /// is placed *inside* the scroll view), (2) the largest scroll view among the
    /// parent's descendants (covers a `.background` sibling), and (3) the largest
    /// scroll view in the window (last-resort fallback).
    func codegTranscriptScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        var ancestor: UIView? = self.superview
        while let current = ancestor {
            if let scrollView = current.codegLargestDescendantScrollView() { return scrollView }
            ancestor = current.superview
        }
        return self.window?.codegLargestDescendantScrollView()
    }

    fileprivate func codegLargestDescendantScrollView() -> UIScrollView? {
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        func walk(_ view: UIView) {
            if let scrollView = view as? UIScrollView {
                let area = scrollView.bounds.width * scrollView.bounds.height
                if area > bestArea {
                    bestArea = area
                    best = scrollView
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(self)
        return best
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
