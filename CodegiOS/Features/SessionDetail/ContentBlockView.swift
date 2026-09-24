import SwiftUI

/// Renders a single `ContentBlock` in isolation. The assistant transcript no
/// longer uses this directly — it is flattened into timeline nodes (`NodeBody`),
/// which pair tool calls and group runs — but the user node body still falls back
/// to it for the rare non-text/image block, so it stays a complete,
/// self-contained renderer.
struct ContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownContent(raw: text)
            }
        case .thinking(let text):
            ReasoningBlock(text: text)
        case .image(let image):
            InlineImageView(image: image, caption: nil)
        case .imageGeneration(let revisedPrompt, let image):
            if let image {
                InlineImageView(image: image, caption: revisedPrompt)
            } else if let revisedPrompt {
                MarkdownContent(raw: revisedPrompt)
            }
        case .toolUse(let id, let name, let inputPreview, let meta):
            ToolCallCard(vm: ToolCallVM(
                id: id ?? "tool", rawName: name, kind: "", state: .done,
                input: inputPreview, output: nil, content: nil, isError: false, meta: meta))
        case .toolResult(let id, let outputPreview, let isError):
            ToolCallCard(vm: ToolCallVM(
                id: id ?? "result", rawName: "result", kind: "", state: isError ? .error : .done,
                input: nil, output: outputPreview, content: nil, isError: isError))
        case .unknown(let type):
            UnsupportedBlock(type: type)
        }
    }
}

// MARK: - Reasoning (thinking)

/// A dim "Reasoning" disclosure for `.thinking` content. Auto-expands while the
/// model is streaming its thoughts (so they're visible as they arrive) and
/// auto-collapses a beat after streaming ends; finalized reasoning starts
/// collapsed. The body renders as Markdown once finalized, verbatim while
/// streaming (to avoid re-parsing every token).
struct ReasoningBlock: View {
    let text: String
    var streaming: Bool = false

    @State private var expanded = false
    @State private var didAutoCollapse = false
    /// Paragraphs that can no longer change, and the still-growing tail after them.
    ///
    /// Streaming reasoning used to be one `Text` of the whole accumulated string,
    /// re-laid-out on every ~50–140 ms publish: cost grows with length, so a long
    /// chain-of-thought got slower and slower (and, once a publish cost more than
    /// the interval between them, the UI fell permanently behind the stream). Frozen
    /// paragraphs are stable `Text` values that SwiftUI skips, so each publish only
    /// lays out the tail — bounded by one paragraph.
    @State private var frozen: [String] = []
    @State private var tail: String = ""
    /// How many characters of `text` `frozen` + `tail` already account for.
    @State private var consumed = 0

    /// Upper bound on what the live tail hands to `Text`. A single paragraph with no
    /// blank line would otherwise grow without limit; the finalized block still
    /// renders the full text.
    private let tailLimit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                    (streaming ? Text("Thinking…") : Text("Reasoning"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    if streaming {
                        streamingBody
                    } else {
                        MarkdownContent(raw: text)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
        .onAppear { if streaming { expanded = true } }
        .onChange(of: streaming) { nowStreaming in
            if nowStreaming {
                expanded = true
            } else if !didAutoCollapse {
                didAutoCollapse = true
                Task { @MainActor in
                    // One beat after the model moved on, so the fold reads as a
                    // settle rather than a snap. Deferred folds land in the turn-end
                    // rebuild instead, which is the one window where a height change
                    // is amplified by the lazy stack's re-estimate — folding here
                    // lets the transcript's follow-snap absorb it while the estimate
                    // is still anchored to laid-out content.
                    try? await Task.sleep(for: .seconds(1.0))
                    // TEMPORARY scroll trace (CodegiOS/Diagnostics/ScrollTrace.swift).
                    ScrollTrace.note("reasoning collapse begin")
                    withAnimation(.snappy(duration: 0.25)) { expanded = false }
                    ScrollTrace.note("reasoning collapse set")
                    try? await Task.sleep(for: .milliseconds(500))
                    ScrollTrace.note("reasoning collapse settle")
                }
            }
        }
    }

    private var streamingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(frozen.enumerated()), id: \.offset) { _, paragraph in
                MarkdownText(raw: paragraph, color: Theme.textSecondary, plain: true)
            }
            if !tail.isEmpty {
                MarkdownText(raw: tailForDisplay, color: Theme.textSecondary, plain: true)
            }
        }
        .onAppear { syncParagraphs() }
        .onChange(of: text) { _ in syncParagraphs() }
    }

    private var tailForDisplay: String {
        guard tail.count > tailLimit else { return tail }
        return "…" + String(tail.suffix(tailLimit))
    }

    /// Move every paragraph that has been closed off by a blank line into `frozen`,
    /// leaving only the trailing paragraph live. Called as `text` grows.
    private func syncParagraphs() {
        guard streaming else { return }
        // A rebuilt live turn can hand back a shorter (or different) string: start
        // over instead of appending to a stale tail.
        if text.count < consumed {
            frozen = []
            tail = ""
            consumed = 0
        }
        guard text.count != consumed else { return }
        let fresh = String(text.dropFirst(consumed))
        consumed = text.count
        tail += fresh
        while let blank = tail.range(of: "\n\n") {
            frozen.append(String(tail[tail.startIndex..<blank.lowerBound]))
            tail = String(tail[blank.upperBound...])
        }
    }
}

// MARK: - Inline image

/// Decodes a base64 `ImageData` payload and renders it rounded, with an optional
/// caption (e.g. a revised generation prompt). The base64 → image decode runs once
/// off the main thread in a `.task` (not in `body`, where it re-ran on every
/// render — costly while the transcript invalidates during streaming) and is held
/// in a memory-pressure-evicting `NSCache`, so scrolling a decoded image back on
/// screen is free.
struct InlineImageView: View {
    let image: ImageData
    let caption: String?

    @State private var decoded: UIImage?
    @State private var failed = false

    /// Thread-safe, auto-evicting under memory pressure — the right store for a
    /// handful of potentially large transcript images.
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .hairlineBorder(Theme.Radius.md)
                    .transition(.opacity)
            } else {
                placeholder
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Theme.Motion.content, value: decoded == nil)
        .task(id: image.data) { await decode() }
    }

    /// A calm decoding box (or a decode-failure note) shown until the image lands.
    private var placeholder: some View {
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "photo")
                Text("Image could not be decoded")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, minHeight: failed ? 56 : 120)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
    }

    private func decode() async {
        let key = image.data as NSString
        if let hit = Self.cache.object(forKey: key) { decoded = hit; failed = false; return }
        let raw = image.data
        // Heavy base64 decode off the main thread; `Data` is Sendable so it crosses
        // the boundary cleanly (UIImage(data:) defers the pixel decode to draw time).
        let data = await Task.detached(priority: .userInitiated) {
            Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
        }.value
        guard let data, let img = UIImage(data: data) else { failed = true; return }
        Self.cache.setObject(img, forKey: key)
        decoded = img
        failed = false
    }
}

// MARK: - Unknown

/// A small dim note for content variants this client version does not render.
struct UnsupportedBlock: View {
    let type: String

    var body: some View {
        Text("unsupported block: \(type)")
            .font(.mono(11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03), in: Capsule())
    }
}
