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
/// - it implements `sizeThatFits` so the field hugs its content between one and
///   six lines (the upstream `lineLimit`), scrolling past the cap instead of
///   swallowing the whole composer;
/// - it bridges focus both ways, because `.focused(_:)` does nothing on a
///   `UIViewRepresentable` — without this, the caller's `focused` flag never
///   flips, so the `/`·`@` panel never opens and the resting/focused bar padding
///   flickers.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// Caret as a UTF-16 offset, reported on every selection change.
    @Binding var caret: Int?
    /// Text the field should hold after an external insertion (a picked `/`
    /// command or `@` mention), with the caret placed at `pendingCaret`. Cleared
    /// by the view once applied. Two plain values rather than a tuple binding,
    /// which SwiftUI cannot form from an optional tuple.
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
    /// The field's height, measured from the text view's real content and written
    /// back here. The caller pins the field to this with `.frame(height:)`.
    ///
    /// Height is driven by an explicit state instead of `sizeThatFits` because
    /// SwiftUI measures BEFORE it writes the new text into the view, so a
    /// `sizeThatFits` measurement repeatedly read the previous string and the
    /// height bounced between two line counts every keystroke — the "+"/send
    /// beside it drifted up and down, worst with a Chinese IME whose marked text
    /// changes length per key. Measuring in the delegate (after the text view has
    /// the new content, marked text included) and pinning that value removes the
    /// read-old-text pass entirely.
    @Binding var measuredHeight: CGFloat
    /// Called on every edit / caret move with the text view's live text, caret and
    /// focus together.
    ///
    /// Reporting them as one unit is the fix for the panel lagging a keystroke:
    /// driving it off two `onChange`s read the *captured* binding on the view
    /// struct, so `onChange(of: text)` saw the caret from before the edit and
    /// `/`·`@` were only detected on the next keypress.
    var onEdit: ((_ text: String, _ caret: Int, _ focused: Bool) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Scrolling lives on the text view; SwiftUI height comes from
        // `sizeThatFits`, clamped to `lineLimit`. Internal scrolling only shows
        // once the content exceeds that cap, so it never fights the layout while
        // the field is growing — and toggling `isScrollEnabled` inside layout
        // would risk a measure/re-layout loop.
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.font = font
        view.tintColor = UIColor(Theme.accent)
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Seed the height once the view has a real width (next runloop), so the
        // first frame isn't a zero/one-line guess that then jumps.
        DispatchQueue.main.async {
            let width = view.bounds.width
            guard width > 0 else { return }
            let h = Self.measureHeight(for: view, width: width, font: self.font, lineLimit: self.lineLimit)
            if abs(h - self.measuredHeight) > 0.5 { self.measuredHeight = h }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.font != font { view.font = font }
        // Never overwrite the text view's text while an IME is composing (a pinyin
        // candidate is open). Writing into it mid-composition resets the marked
        // text — the composition jumps, its length changes, and the row's height
        // with it. `markedTextRange` is non-nil exactly while composing.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if let newText = pendingText {
            view.text = newText
            let clamped = max(0, min(pendingCaret ?? 0, newText.utf16.count))
            if let pos = view.position(from: view.beginningOfDocument, offset: clamped) {
                view.selectedTextRange = view.textRange(from: pos, to: pos)
            }
            DispatchQueue.main.async {
                pendingText = nil
                pendingCaret = nil
            }
        }
        // Text set externally (a picked / command or @ mention, or a cleared draft)
        // changes the height too; re-measure after this update lands.
        if view.markedTextRange == nil {
            let width = view.bounds.width
            if width > 0 {
                let h = Self.measureHeight(for: view, width: width, font: font, lineLimit: lineLimit)
                if abs(h - measuredHeight) > 0.5 {
                    DispatchQueue.main.async { if abs(h - self.measuredHeight) > 0.5 { self.measuredHeight = h } }
                }
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

    /// Measure the height the text view needs for its CURRENT content (marked text
    /// included), clamped to `lineLimit` and quantized to whole lines.
    ///
    /// Called from the delegate after the text view already holds the new content,
    /// so it never reads a stale string. Whole-line quantization keeps the field
    /// growing in clean steps rather than creeping by descender sub-pixels.
    static func measureHeight(for textView: UITextView, width: CGFloat,
                              font: UIFont, lineLimit: ClosedRange<Int>) -> CGFloat {
        guard width > 0 else { return 0 }
        let inset = textView.textContainerInset
        let lineHeight = ceil(font.lineHeight)
        let textWidth = max(1, width - inset.left - inset.right - textView.textContainer.lineFragmentPadding * 2)
        // `textView.text` includes any in-progress IME marked text — the string the
        // view is actually laying out, which is what its height must follow.
        let measured = (textView.text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        let usedLines = max(lineLimit.lowerBound, Int(ceil(measured / lineHeight)))
        let lines = min(max(usedLines, lineLimit.lowerBound), lineLimit.upperBound)
        return lineHeight * CGFloat(lines) + inset.top + inset.bottom
    }

    /// Report the pinned height. The real measurement happens in the delegate
    /// (where the text view already has the new content); here we only echo the
    /// value back so SwiftUI lays the field out at exactly that height. Returning
    /// a stored value — never a fresh measurement of possibly-stale text — is what
    /// stops the per-keystroke bounce.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let height = measuredHeight > 0
            ? measuredHeight
            : Self.measureHeight(for: uiView, width: width, font: font, lineLimit: lineLimit)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let offset = liveCaret(textView)
            parent.text = textView.text
            if parent.caret != offset { parent.caret = offset }
            updateMeasuredHeight(textView)
            parent.onEdit?(textView.text, offset, parent.isFocused)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let offset = liveCaret(textView)
            if parent.caret != offset { parent.caret = offset }
            // Selection alone never changes the wrapped line count, but an IME can
            // finalize marked text on a selection change, which can — measure then.
            updateMeasuredHeight(textView)
            parent.onEdit?(textView.text, offset, parent.isFocused)
        }

        /// Re-measure and publish the field height. Deferred to the next runloop
        /// tick so it runs after the text view has settled its layout for the new
        /// content (including marked text), and so writing the binding does not
        /// mutate SwiftUI state inside the delegate callback that triggered it.
        private func updateMeasuredHeight(_ textView: UITextView) {
            let width = textView.bounds.width
            let font = parent.font
            let lineLimit = parent.lineLimit
            guard width > 0 else { return }
            let target = ComposerTextView.measureHeight(for: textView, width: width, font: font, lineLimit: lineLimit)
            guard abs(target - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async {
                if abs(target - self.parent.measuredHeight) > 0.5 {
                    self.parent.measuredHeight = target
                }
            }
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
