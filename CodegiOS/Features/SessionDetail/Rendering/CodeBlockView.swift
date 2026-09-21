import SwiftUI
import UIKit

/// A "copy to clipboard" affordance: a doc icon that briefly flips to a
/// checkmark after a tap. Reused by code blocks, diffs, and message context
/// menus — anywhere the user might want the raw text.
struct CopyButton: View {
    let text: String
    /// Optional trailing label ("Copy"). Icon-only when nil.
    var label: LocalizedStringKey? = nil
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.snappy(duration: 0.18)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy(duration: 0.18)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                if let label {
                    Text(copied ? "Copied" : label).font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(copied ? Theme.accent : Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A soft success tick on copy (only on the copy, not the 1.6s auto-reset).
        .codegSensoryFeedback(trigger: copied) { now in now ? .success : nil }
    }
}

/// A fenced code block: a language label + copy button header over a near-black,
/// horizontally scrollable monospaced body. Used by `MarkdownContent` for the
/// ``` fences in an assistant reply, and reused for tool bodies that show a
/// shell command or pretty-printed JSON.
///
/// Deliberately NOT syntax-highlighted — the app ships no highlighter
/// dependency — but it is a *real* block (its own surface, horizontal scroll for
/// long lines, copy) rather than inline text with literal backticks. Very tall
/// blocks expand in place (an inner vertical scroll would fight the transcript's
/// `List`).
struct CodeBlockView: View {
    let code: String
    var language: String? = nil
    /// Collapse to this many lines when the block is longer, with a toggle.
    var collapsedLineLimit: Int = 20

    @State private var expanded = false

    private var lines: [Substring] { trimmedTrailing.split(separator: "\n", omittingEmptySubsequences: false) }
    private var isLong: Bool { lines.count > collapsedLineLimit }
    private var shown: String {
        if !isLong || expanded { return trimmedTrailing }
        return lines.prefix(collapsedLineLimit).joined(separator: "\n")
    }
    private var trimmedTrailing: String {
        var s = code
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown)
                    .font(Theme.Typography.code)
                    .lineSpacing(Theme.Typography.codeLineSpacing)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            if isLong { expandToggle }
        }
        .background(Self.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(stringLiteral: displayLanguage))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            CopyButton(text: trimmedTrailing)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            (expanded ? Text("Show less") : Text("Show \(lines.count - collapsedLineLimit) more lines"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var displayLanguage: String {
        let l = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return l.isEmpty ? "code" : l
    }

    /// Darker than the transcript backdrop so the block reads as an inset panel.
    private static let surface = Theme.codeSurface
}
