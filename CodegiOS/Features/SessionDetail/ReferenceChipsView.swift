import SwiftUI

/// The staged references above the compose field: one removable chip each.
///
/// A reference's Markdown — `[@Codex CLI](codeg://agent/codex)` — is far too long
/// to sit in the text field, and deleting it a character at a time leaves a
/// half-link behind. So the composer keeps references out of the draft entirely
/// and shows what they *mean*: an icon and a label, with an × to drop one.
/// `SessionDetailViewModel.send` serializes them back to Markdown.
///
/// This is the iOS answer to the web's inline `ReferenceBadge`. The web can render
/// that inline because its composer is a ProseMirror document; a SwiftUI
/// `TextField` has no rich-text support on iOS 16, and swapping it for a
/// `UITextView` would mean re-deriving the keyboard avoidance this screen
/// deliberately does not touch (see `docs/ios16-compat.md`).
struct ReferenceChipsView: View {
    let references: [MentionReference]
    let onRemove: (MentionReference) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(references) { reference in
                    chip(reference)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ reference: MentionReference) -> some View {
        HStack(spacing: 6) {
            Image(systemName: reference.kind.systemImage)
                .font(.caption2.weight(.semibold))
            Text(reference.label)
                .font(.caption)
                .lineLimit(1)
            Button {
                onRemove(reference)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.leading, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(reference.label)")
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.accent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.28)))
        .accessibilityElement(children: .combine)
    }
}
