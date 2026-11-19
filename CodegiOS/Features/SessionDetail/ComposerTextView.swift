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
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.font != font { view.font = font }
        if view.text != text { view.text = text }
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

    /// Size the field to its content, clamped to the visible line range.
    ///
    /// Measures with the text view's own layout manager rather than
    /// `boundingRect`: only the real layout matches what `UITextView` renders, so
    /// the height cannot flicker between N and N+1 lines on each keystroke (which
    /// showed up as the "+" drifting up and down while typing).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let inset = uiView.textContainerInset
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let textWidth = max(
            1,
            width - inset.left - inset.right - uiView.textContainer.lineFragmentPadding * 2
        )
        // Lay the text container out at the proposed width and read the used height.
        uiView.textContainer.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer)
        let contentHeight = ceil(used.height) + inset.top + inset.bottom
        let minHeight = ceil(lineHeight) + inset.top + inset.bottom
        let maxHeight = ceil(lineHeight * CGFloat(lineLimit.upperBound)) + inset.top + inset.bottom
        let height = min(max(contentHeight, minHeight), maxHeight)
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
            // Text growth changes the field's height; ask SwiftUI to re-measure.
            textView.invalidateIntrinsicContentSize()
            // One callback with the live text + caret together, so the trigger sees
            // them consistent on the very keystroke that typed `/` or `@`.
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
