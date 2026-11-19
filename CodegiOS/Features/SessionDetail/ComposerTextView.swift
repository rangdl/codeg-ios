import SwiftUI
import UIKit

/// The composer's text field, backed by `UITextView` so it can report its caret
/// on iOS 16.
///
/// The upstream client uses SwiftUI's `TextField(text:selection:)` (iOS 18+) to
/// drive the inline `/`·`$` command menu and `@` mention panel, which need to
/// know where the caret sits, and it uses `axis: .vertical` + `lineLimit(1...6)`
/// to grow the field up to six lines. iOS 16 has neither a selection binding nor
/// a self-sizing multiline `TextField`, so this wrapper supplies both:
///
/// - it reads `selectedRange` straight off the underlying text view and reports
///   it, so the inline triggers see the caret on the keystroke that opened them;
/// - it sizes itself to its content by overriding `intrinsicContentSize` on the
///   text view and letting `UIViewRepresentable` read it back — no manual height
///   binding, no `sizeThatFits` measurement. That is deliberate: measuring height
///   separately from the view (boundingRect, or a delegate timed against
///   `bounds.width` that lags the SwiftUI layout) repeatedly disagreed with the
///   real layout by a line, so the field bounced between N and N+1 lines every
///   keystroke and the "+"/send pinned to its bottom drifted. Letting the ONE
///   view that lays the text out also report its size removes that mismatch;
/// - it bridges focus both ways, because `.focused(_:)` does nothing on a
///   `UIViewRepresentable`.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// Caret as a UTF-16 offset, reported on every selection change.
    @Binding var caret: Int?
    /// Text the field should hold after an external insertion (a picked `/`
    /// command or `@` mention), with the caret placed at `pendingCaret`. Cleared
    /// by the view once applied.
    @Binding var pendingText: String?
    @Binding var pendingCaret: Int?
    /// Two-way focus bridge. A `UIViewRepresentable` cannot use `@FocusState`, so
    /// the caller keeps a plain `Bool` and this becomes/resigns the responder to
    /// match it, reading the responder back out so a tap on the field updates it.
    @Binding var isFocused: Bool
    /// The typing font, applied to the text view directly (a SwiftUI `.font` on a
    /// representable does not reach the `UITextView`). Scales with Dynamic Type.
    var font: UIFont = .preferredFont(forTextStyle: .body)
    /// Visible line range, matching the upstream `lineLimit(1...2 / 1...6)`.
    var lineLimit: ClosedRange<Int> = 1...6
    /// Called on every edit / caret move with the text view's live text, caret and
    /// focus together.
    ///
    /// Reporting them as one unit is the fix for the panel lagging a keystroke:
    /// driving it off two `onChange`s read the *captured* binding on the view
    /// struct, so `onChange(of: text)` saw the caret from before the edit and
    /// `/`·`@` were only detected on the next keypress.
    var onEdit: ((_ text: String, _ caret: Int, _ focused: Bool) -> Void)? = nil

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = font
        view.tintColor = UIColor(Theme.accent)
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The height clamp lives on the view, so its `intrinsicContentSize` can
        // apply it (see `ComposerUITextView`). Scrolls internally only once the
        // content exceeds the clamp.
        view.lineLimit = lineLimit
        // Scrolling stays off so the text container is free to grow and report its
        // true content height; `updateUIView` turns it on only once the content
        // exceeds `lineLimit`, where the pinned height needs internal scrolling.
        view.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        if view.font != font { view.font = font; view.invalidateIntrinsicContentSize() }
        if view.lineLimit != lineLimit { view.lineLimit = lineLimit; view.invalidateIntrinsicContentSize() }
        // Never overwrite the text view's text while an IME is composing (a pinyin
        // candidate is open). Writing into it mid-composition resets the marked
        // text — the composition jumps and its length changes.
        if view.text != text, view.markedTextRange == nil { view.text = text; view.invalidateIntrinsicContentSize() }
        if let newText = pendingText {
            view.text = newText
            let clamped = max(0, min(pendingCaret ?? 0, newText.utf16.count))
            if let pos = view.position(from: view.beginningOfDocument, offset: clamped) {
                view.selectedTextRange = view.textRange(from: pos, to: pos)
            }
            view.invalidateIntrinsicContentSize()
            DispatchQueue.main.async {
                pendingText = nil
                pendingCaret = nil
            }
        }
        if isFocused, !view.isFirstResponder {
            // Deferred: becoming first responder synchronously here fires the
            // delegate, which writes the focus/text bindings mid-update.
            DispatchQueue.main.async {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// Height for the proposal width, clamped to `lineLimit`.
    ///
    /// Measured with the text view's OWN layout manager at the width SwiftUI will
    /// actually give it — the only measurement guaranteed to match the render, so
    /// the line count (and height) cannot flip between N and N+1 on a keystroke.
    /// Width comes from the proposal (not `bounds`, which lags this pass); that
    /// mismatch is exactly what made the old height bounce.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: uiView.heightClampedToLineLimit(at: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let offset = liveCaret(textView)
            parent.text = textView.text
            if parent.caret != offset { parent.caret = offset }
            // The text changed, so the intrinsic height may have; this is the ONE
            // size signal — the view recounts its own lines.
            textView.invalidateIntrinsicContentSize()
            parent.onEdit?(textView.text, offset, parent.isFocused)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let offset = liveCaret(textView)
            if parent.caret != offset { parent.caret = offset }
            // An IME can finalize marked text on a selection change, which changes
            // the line count.
            textView.invalidateIntrinsicContentSize()
            parent.onEdit?(textView.text, offset, parent.isFocused)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
            parent.onEdit?(textView.text, liveCaret(textView), true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        private func liveCaret(_ textView: UITextView) -> Int {
            let offset = textView.selectedRange.location
            return offset == NSNotFound ? (parent.caret ?? 0) : offset
        }
    }
}

/// A `UITextView` that reports a height clamped to `lineLimit` lines.
///
/// Overriding `intrinsicContentSize` (rather than leaving SwiftUI to measure)
/// is what keeps the composer still: this view IS the one laying the text out,
/// so the size it reports can never disagree with what it draws — the source of
/// the old per-keystroke bounce, where a separate measurement guessed N vs. N+1
/// lines. Width comes from the SwiftUI layout (the text container is resized to
/// it), height is what this returns.
final class ComposerUITextView: UITextView {
    var lineLimit: ClosedRange<Int> = 1...6

    override var intrinsicContentSize: CGSize {
        let width = bounds.width
        guard width > 0 else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight(at: width))
    }

    /// The height for a given layout width, quantized to whole lines and clamped
    /// to `lineLimit`. Uses the layout manager so it reflects exactly what the
    /// view draws — including in-progress IME marked text. Also toggles internal
    /// scrolling: on only when the content exceeds the clamp, where the pinned
    /// height would otherwise clip text. Side-effecting, so `intrinsicContentSize`
    /// (which UIKit can read re-entrantly while laying out) goes through the pure
    /// `measuredHeight` below instead.
    @discardableResult
    func heightClampedToLineLimit(at width: CGFloat) -> CGFloat {
        let height = measuredHeight(at: width)
        guard width > 0 else { return height }
        let used = layoutManager.usedRect(for: textContainer).height
        let needsScroll = used > (height - textContainerInset.top - textContainerInset.bottom) + 0.5
        if isScrollEnabled != needsScroll { isScrollEnabled = needsScroll }
        return height
    }

    /// Pure height computation for a layout width — no side effects.
    func measuredHeight(at width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let lineHeight = ceil(font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight)
        let inset = textContainerInset.top + textContainerInset.bottom
        textContainer.size = CGSize(width: width - textContainer.lineFragmentPadding * 2,
                                    height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let usedLines = max(lineLimit.lowerBound, Int(ceil(used / lineHeight)))
        let lines = min(max(usedLines, lineLimit.lowerBound), lineLimit.upperBound)
        return lineHeight * CGFloat(lines) + inset
    }
}
