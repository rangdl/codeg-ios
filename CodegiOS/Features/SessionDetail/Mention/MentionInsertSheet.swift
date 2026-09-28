import SwiftUI

/// The "+" menu's **References** picker: a searchable, grouped list of the
/// workspace files, agents, sessions and commits a draft can point at.
///
/// Picking a row emits the reference; the compose bar inserts its Markdown at the
/// top of the draft (see `ComposeBar`). A reference already present in the draft
/// is marked and can't be inserted again — a reference is context, and pointing
/// at the same file twice adds nothing.
struct MentionInsertSheet: View {
    @ObservedObject var model: MentionInsertModel
    /// The live draft, used to mark the references it already contains.
    let draft: String
    /// Emits the picked reference; the owner applies it to the draft.
    let onInsert: (MentionReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle("References")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search files, agents, sessions, commits"
            )
        }
        .presentationDetents([.medium, .large])
        .codegPresentationBackground(Theme.bg)
        .task { model.load() }
    }

    // MARK: - State routing

    @ViewBuilder
    private var content: some View {
        let groups = model.groups(matching: search)
        if model.phase == .loading, model.references.isEmpty {
            centered { ProgressView().tint(Theme.accent) }
        } else if groups.allSatisfy({ $0.items.isEmpty }) {
            emptyState
        } else {
            list(groups)
        }
    }

    private func list(_ groups: [MentionGroup]) -> some View {
        List {
            ForEach(groups) { group in
                // Empty groups keep their slot in `groups` (so the order never
                // shifts while filtering) but render nothing.
                if !group.items.isEmpty {
                    Section {
                        ForEach(group.items) { reference in
                            row(reference)
                        }
                    } header: {
                        Label(group.kind.title, systemImage: group.kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ reference: MentionReference) -> some View {
        // Matched against the serialized Markdown, which is exactly what the
        // draft stores — no separate bookkeeping to drift out of sync.
        let inserted = draft.contains(reference.markdown)
        Button {
            guard !inserted else { return }
            onInsert(reference)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: reference.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(inserted ? Theme.textTertiary : Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reference.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(inserted ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                    if let detail = reference.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if inserted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Already added")
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inserted)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.hairline)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        let hasQuery = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return centered {
            VStack(spacing: 8) {
                Image(systemName: hasQuery ? "magnifyingglass" : "at")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text(hasQuery
                     ? LocalizedStringKey("No matches")
                     : LocalizedStringKey("Nothing to reference here yet. Files come from this folder, plus its agents, sessions and commits."))
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
