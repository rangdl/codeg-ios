import SwiftUI

/// What a full-screen rich-block viewer shows.
struct RichBlockViewerInput: Identifiable {
    enum Content {
        case mermaid(MermaidViewerContent)
        case html(HtmlViewerContent)
    }

    let id = UUID()
    let content: Content
}

/// The open viewer, owned by the screen rather than the block: a transcript
/// row can be recycled — or replaced, when a streaming reply settles — while
/// its diagram is open, and a cover presented from the row would close with it
/// (the same arrangement as `MarkdownImageViewerState`).
@MainActor
final class RichBlockViewerState: ObservableObject {
    @Published var input: RichBlockViewerInput?
}

private struct RichBlockViewerKey: EnvironmentKey {
    static let defaultValue: RichBlockViewerState? = nil
}

extension EnvironmentValues {
    var richBlockViewer: RichBlockViewerState? {
        get { self[RichBlockViewerKey.self] }
        set { self[RichBlockViewerKey.self] = newValue }
    }
}

private struct RichBlockViewerHost: ViewModifier {
    @StateObject private var state = RichBlockViewerState()

    @ViewBuilder
    func body(content: Content) -> some View {
        @ObservedObject var presented = state
        content
            .environment(\.richBlockViewer, state)
            .fullScreenCover(item: $presented.input) { input in
                RichBlockViewer(input: input)
            }
    }
}

extension View {
    /// Diagrams (and HTML previews) under this view open full screen from here.
    func richBlockViewers() -> some View {
        modifier(RichBlockViewerHost())
    }

    /// Opens `input` from the screen's viewer when there is one, else from this
    /// view — Markdown outside a transcript (a skill body, an expert's notes).
    func richBlockViewerFallback(_ input: Binding<RichBlockViewerInput?>) -> some View {
        fullScreenCover(item: input) { RichBlockViewer(input: $0) }
    }
}

/// Dispatches to the viewer for the content.
struct RichBlockViewer: View {
    let input: RichBlockViewerInput

    var body: some View {
        switch input.content {
        case .mermaid(let content):
            MermaidViewer(content: content)
        case .html(let content):
            HtmlPreviewViewer(content: content)
        }
    }
}

/// The accent, resolved from the store rather than through `Theme.accent`:
/// the bridged accent trait does not reach a separately presented hosting
/// controller (a sheet or cover), and these viewers are one.
struct ResolvedAccent: ViewModifier {
    @EnvironmentObject private var appearance
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let accent = appearance?.accent ?? .neutral
        content.tint(accent.fill(dark: colorScheme == .dark))
    }
}
