import SwiftUI

/// Renders a string as inline Markdown, gracefully degrading to plain text when
/// the string is not valid Markdown. Used for user bubbles and assistant text
/// blocks. Whitespace is preserved between paragraphs (`.inlineOnlyPreservingWhitespace`
/// keeps newlines that the default parser would otherwise collapse).
struct MarkdownText: View {
    let raw: String
    var color: Color = Theme.textPrimary
    var font: Font = Theme.Typography.messageBody
    /// When true, render the raw string verbatim and skip Markdown parsing. Used
    /// for live-streaming text so each token delta doesn't re-parse the entire
    /// accumulated reply (O(n²) main-actor work on long replies); the turn
    /// re-renders once with full Markdown when it finalizes.
    var plain: Bool = false

    var body: some View {
        // Live-streaming text (`plain`) renders verbatim and is skipped by the
        // cache — each token delta is a distinct string, so caching would only
        // churn. Finalized turns go through the cache so a `List` row recycled
        // back into view re-uses its parse instead of re-running it.
        Text(plain ? AttributedString(raw) : Self.cachedAttributed(raw))
            .font(font)
            .lineSpacing(Theme.Typography.messageLineSpacing)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Parse Markdown into an `AttributedString`, falling back to a verbatim
    /// string when parsing fails. Newlines are preserved so streamed multi-line
    /// replies keep their shape.
    static func attributed(from raw: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }

    // MARK: - Parse cache

    /// Markdown parsing is the per-turn rendering cost that dominates a long
    /// transcript. With a recycling `List`, a row that scrolls off and back on
    /// would otherwise re-parse every time. This bounded, main-thread-only cache
    /// keeps each distinct string's parse around so re-display is free.
    ///
    /// Accessed exclusively from `body` (SwiftUI rendering is on the main
    /// thread), so a plain static store is safe without extra synchronization.
    private static var cache: [String: AttributedString] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 500

    private static func cachedAttributed(_ raw: String) -> AttributedString {
        if let hit = cache[raw] { return hit }
        let parsed = attributed(from: raw)
        cache[raw] = parsed
        cacheOrder.append(raw)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }

    // MARK: - Block-parser inline cache

    /// Memoized `attributed(from:)` for the **block parser**, which calls the
    /// inline parse once per block (`MarkdownContent.parseBlocks`: paragraphs,
    /// headings, list items, quotes, table cells).
    ///
    /// While a reply streams, only the *trailing* block changes between flushes —
    /// every earlier block's source string is byte-identical — so without this
    /// each ~50–140 ms flush re-ran Apple's Markdown parser over the whole
    /// accumulated reply. That is the O(n) per flush / O(n²) per reply cost the
    /// `LiveTextRun` coalescing window exists to blunt; with this it collapses to
    /// the handful of blocks that actually changed.
    ///
    /// A miss behaves exactly like `attributed(from:)`, so the worst case (a cache
    /// too small to hold the reply's blocks) is simply today's behaviour: the
    /// stable blocks that fall out are re-parsed once and re-inserted at the tail,
    /// so at most a couple of blocks are re-parsed per flush rather than all of
    /// them. The trailing block misses on every flush while it grows, and its
    /// ever-new keys churn the tail — hence a limit in the same order as `cache`
    /// above rather than something huge.
    ///
    /// Main-thread-only, like `cache` above: it is only reached from `body`.
    static func inlineAttributed(from raw: String) -> AttributedString {
        if let hit = inlineCache[raw] { return hit }
        let parsed = attributed(from: raw)
        inlineCache[raw] = parsed
        inlineOrder.append(raw)
        if inlineOrder.count > inlineCacheLimit {
            let evicted = inlineOrder.removeFirst()
            inlineCache.removeValue(forKey: evicted)
        }
        return parsed
    }

    private static var inlineCache: [String: AttributedString] = [:]
    private static var inlineOrder: [String] = []
    private static let inlineCacheLimit = 600
}
