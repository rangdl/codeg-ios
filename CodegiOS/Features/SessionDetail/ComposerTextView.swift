import SwiftUI
import UIKit

/// The composer's text field, backed by `UITextView` so it can report its caret
/// on iOS 16.
///
/// The upstream client uses SwiftUI's `TextField(text:selection:)` (iOS 18+) to
/// drive the inline `/`·`$` command menu and `@` mention panel, which need to
/// know where the caret sits. iOS 16 has no selection binding, so this wrapper
/// reads `selectedRange` straight off the underlying text view.
///
/// Deliberately small: it owns text, caret reporting and focus. Everything the
/// upstream field did with view modifiers (fonts, padding, overlay) stays in the
/// SwiftUI caller.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// Caret as a UTF-16 offset, reported on every selection change.
    @Binding var caret: Int?
    /// Text the field should hold after an external insertion (a picked `/`
    /// command or `@` mention), with the caret placed at `caret`. Cleared by the
    /// view once applied.
    /// Text to swap in, and where the caret should land. Nil means "no swap
    /// pending". Two plain values rather than a tuple binding, which SwiftUI
    /// cannot form from an optional tuple.
    @Binding var pendingText: String?
    @Binding var pendingCaret: Int?
    var isFocused: FocusState<Bool>.Binding

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if let newText = pendingText {
            view.text = newText
            let clamped = max(0, min(pendingCaret ?? 0, newText.utf16.count))
            if let pos = view.position(from: view.beginningOfDocument, offset: clamped) {
                view.selectedTextRange = view.textRange(from: pos, to: pos)
            }
            DispatchQueue.main.async { pendingText = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            reportCaret(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            reportCaret(textView)
        }

        private func reportCaret(_ textView: UITextView) {
            let offset = textView.selectedRange.location
            guard offset != NSNotFound else { return }
            if parent.caret != offset { parent.caret = offset }
        }
    }
}
