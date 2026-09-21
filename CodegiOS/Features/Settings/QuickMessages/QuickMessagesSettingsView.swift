import SwiftUI

/// Reusable message templates the user can insert into the chat composer.
/// Reorderable + deletable (a `List` for `.onMove` / `.onDelete`, styled to the
/// app's glass aesthetic), with an add/edit sheet.
struct QuickMessagesSettingsView: View {
    @StateObject private var model: QuickMessagesSettingsModel
    @State private var editorRoute: EditorRoute?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum EditorRoute: Identifiable {
        case add
        case edit(QuickMessage)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let m): "edit-\(m.id)"
            }
        }
    }

    init(client: CodegClient?) {
        _model = StateObject(wrappedValue: QuickMessagesSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Quick Messages", compact: horizontalSizeClass == .compact)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editorRoute = .add } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Quick Message")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !model.items.isEmpty { EditButton().tint(Theme.accent) }
            }
        }
        .sheet(item: $editorRoute) { editorSheet($0) }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading quick messages…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(
                    icon: "text.bubble",
                    title: "No Quick Messages",
                    message: "Create reusable message templates to drop into the chat composer.",
                    actionTitle: "New Quick Message",
                    action: { editorRoute = .add }
                )
            }
        } else {
            VStack(spacing: 0) {
                if let error = model.refreshError {
                    RefreshErrorBanner(
                        message: error,
                        retry: { Task { await model.load() } },
                        dismiss: { model.refreshError = nil }
                    )
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.bottom, 8)
                }
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.items) { message in
                QuickMessageRow(message: message)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: Theme.Layout.screenHMargin, bottom: 5, trailing: Theme.Layout.screenHMargin))
                    .contentShape(.rect)
                    .onTapGesture { editorRoute = .edit(message) }
            }
            .onDelete { offsets in Task { await model.delete(at: offsets) } }
            .onMove { model.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func editorSheet(_ route: EditorRoute) -> some View {
        switch route {
        case .add:
            QuickMessageEditorSheet { title, content in
                try await model.create(title: title, content: content)
            }
        case .edit(let message):
            QuickMessageEditorSheet(editing: message) { title, content in
                try await model.update(id: message.id, title: title, content: content)
            }
        }
    }
}

/// One quick-message card: title + a two-line content preview.
private struct QuickMessageRow: View {
    let message: QuickMessage

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.title.isEmpty ? "Untitled" : message.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
