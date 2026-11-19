import SwiftUI
import UIKit

/// The composer's text field, backed by `UITextView` so it can report its caret
/// on iOS 16.
///
/// The upstream client uses SwiftUI's `TextField(text:selection:)` (iOS 18+) to
/// drive the inline `/`·`$` command menu and `@` mention panel, which need to
/// know where the caret sits, and `axis: .vertical` + `lineLimit` to grow the
/// field. iOS 16 has neither a selection binding nor a self-sizing multiline
/// `TextField`, so this wrapper supplies both:
///
/// - it reads `selectedRange` straight off the underlying text view and reports
///   it, so the inline triggers see the caret on the keystroke that opened them;
/// - it sizes itself in `sizeThatFits`, clamped to `lineLimit` lines, scrolling
///   inside past the cap;
/// - it bridges focus both ways, because `.focused(_:)` does nothing on a
///   `UIViewRepresentable`.
///
/// Deliberately simple on sizing: `sizeThatFits` is the only place the height is
/// decided, measured from the text view at the width SwiftUI proposes. Earlier
/// attempts (a `measuredHeight` binding refilled from the delegate, or overriding
/// `intrinsicContentSize`) each disagreed with the real layout on some pass — the
/// latter even returned the full-content height while `bounds.width` was still 0
/// on first layout, pushing the bar's neighbours off screen. One measurement
/// source, at a real width, avoids both.
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
    /// representable does not reach the `UITextView`).
    var font: UIFont = .preferredFont(forTextStyle: .body)
    /// Visible line range, matching the upstream `lineLimit(1...2 / 1...6)`.
    var lineLimit: ClosedRange<Int> = 1...6
    /// Called on every edit / caret move with the text view's live text, caret and
    /// focus together, so the `/`·`@` trigger sees them consistent on the very
    /// keystroke that typed the character.
    var onEdit: ((_ text: String, _ caret: Int, _ focused: Bool) -> Void)? = nil
    /// While false the field refuses to become first responder.
    ///
    /// `updateUIView` re-asserts focus from `isFocused`, and during a pop that
    /// binding is still `true` for a moment — so resigning once was immediately
    /// undone and the keyboard rode into the list behind ("返回后键盘还留在列表
    /// 上"). The owner clears this before it resigns, which makes the re-assert
    /// impossible instead of racing it.
    var allowsFocus: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = font
        view.tintColor = UIColor(Theme.accent)
        view.text = text
        // No internal scrolling: `sizeThatFits` grows the field to its content,
        // clamped to `lineLimit` (see there). A non-scrolling text view reports
        // its full content height, which is what we clamp.
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.font != font { view.font = font }
        // Never overwrite the text view's text while an IME is composing (a pinyin
        // candidate is open): writing into it mid-composition resets the marked
        // text.
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
        if allowsFocus, isFocused, !view.isFirstResponder {
            DispatchQueue.main.async {
                // Re-check: the owner may have refused focus in the meantime.
                guard allowsFocus, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        } else if view.isFirstResponder, !allowsFocus || !isFocused {
            view.resignFirstResponder()
        }
    }

    /// Resign on teardown as well: the last line of defence for a screen that
    /// goes away without its owner ever getting a chance to clear focus.
    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        if uiView.isFirstResponder { uiView.resignFirstResponder() }
    }

    /// The one place the height is decided: the text view's content height at the
    /// proposed width, quantized to whole lines and clamped to `lineLimit`.
    ///
    /// Quantizing to whole lines is what keeps the field (and the "+"/send pinned
    /// to its bottom) from creeping: a sub-line measurement difference would
    /// otherwise change the row height on every keystroke.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let fontLine = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let lineHeight = ceil(fontLine)
        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let minHeight = lineHeight + inset
        let maxHeight = lineHeight * CGFloat(lineLimit.upperBound) + inset

        // Before the first real width is known, report a stable single line — never
        // the text view's whole-content height, which would shove neighbours away.
        guard let width = proposal.width, width > 0 else {
            return CGSize(width: proposal.width ?? 0, height: minHeight)
        }
        // Lay the text container out at the proposed width, then read the used
        // height. `lineFragmentPadding` is 0, so no horizontal slack to subtract.
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer).height
        let usedLines = max(lineLimit.lowerBound, Int(ceil(used / lineHeight)))
        let lines = min(max(usedLines, lineLimit.lowerBound), lineLimit.upperBound)
        let height = min(max(lineHeight * CGFloat(lines) + inset, minHeight), maxHeight)
        // Past the clamp the text no longer fits the reported height; turn on
        // internal scrolling so the hidden lines are reachable instead of clipped.
        // (Only meaningful once the field is pinned to `maxHeight`.)
        let needsScroll = used > height - inset + 0.5
        if uiView.isScrollEnabled != needsScroll { uiView.isScrollEnabled = needsScroll }
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
            parent.onEdit?(textView.text, offset, parent.isFocused)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let offset = liveCaret(textView)
            if parent.caret != offset { parent.caret = offset }
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
