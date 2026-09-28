import SwiftUI

/// The "+" menu's **References** picker: the workspace files, agents, sessions
/// and commits a draft can point at — one tab per kind, each with a live count
/// badge, listing only the active tab's rows.
///
/// The layout mirrors the web's `@` panel (`suggestion-popup.tsx`): agents are
/// pinned to the first tab as a product decision there, every tab carries the
/// number of matches, and the tab strip scrolls sideways rather than squeezing
/// four labels into the width. The trigger and the insert position still differ
/// from the web — see ``MentionInsertModel`` and `ComposeBar`.
///
/// Picking a row emits the reference, which the composer stages as a chip. One
/// already staged is marked and can't be picked twice — a reference is context,
/// and pointing at the same file twice adds nothing.
struct MentionInsertSheet: View {
    @ObservedObject var model: MentionInsertModel
    /// Uris of the references already staged in the composer. Those rows are
    /// marked and can't be picked again.
    let insertedURIs: Set<String>
    /// Emits the picked reference; the owner stages it.
    let onInsert: (MentionReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// The tab the user explicitly picked, or nil to auto-follow the first
    /// non-empty tab (the web's `pinnedTab`), so the panel never opens on an
    /// empty tab while another one has matches.
    @State private var pinnedKind: MentionReference.Kind?

    var body: some View {
        // Computed once per update rather than inside each subview: a full
        // workspace can push thousands of entries through the four groups, and
        // both the tab strip and the list need the same result.
        let groups = model.groups(matching: search)
        let active = activeGroup(in: groups)

        NavigationStack {
            ZStack {
                CodegBackground()
                content(groups: groups, active: active)
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
    private func content(groups: [MentionGroup], active: MentionGroup?) -> some View {
        if model.phase == .loading, model.references.isEmpty {
            centered { ProgressView().tint(Theme.accent) }
        } else {
            VStack(spacing: 0) {
                tabStrip(groups, active: active)
                Divider().overlay(Theme.hairline)
                list(active)
            }
        }
    }

    /// The tab to show: the pinned one, else the first with content, else the
    /// first. Mirrors the web's `pinnedTab ?? first non-empty`.
    private func activeGroup(in groups: [MentionGroup]) -> MentionGroup? {
        if let pinnedKind, let pinned = groups.first(where: { $0.kind == pinnedKind }) {
            return pinned
        }
        return groups.first(where: { !$0.items.isEmpty }) ?? groups.first
    }

    // MARK: - Tab strip

    private func tabStrip(_ groups: [MentionGroup], active: MentionGroup?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    tab(group, isActive: group.kind == active?.kind)
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.vertical, 10)
        }
    }

    private func tab(_ group: MentionGroup, isActive: Bool) -> some View {
        Button {
            pinnedKind = group.kind
        } label: {
            HStack(spacing: 6) {
                Text(group.kind.title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                // The count is the true match total, not the capped row count —
                // the list below says when it is showing only the first slice.
                if group.total > 0 {
                    Text("\(group.total)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isActive ? Theme.onAccent.opacity(0.22) : Theme.hairline)
                        )
                }
            }
            .foregroundStyle(isActive ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(isActive ? Theme.accent : Theme.bgElevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ group: MentionGroup?) -> some View {
        if let group, !group.items.isEmpty {
            List {
                ForEach(group.items) { reference in
                    row(reference)
                }
                if group.isTruncated {
                    truncatedNotice
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            emptyState(kind: group?.kind)
        }
    }

    private var truncatedNotice: some View {
        Text("Showing the first \(MentionInsertModel.maxPerGroup) matches — keep typing to narrow it down.")
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ reference: MentionReference) -> some View {
        let inserted = insertedURIs.contains(reference.uri)
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

    private func emptyState(kind: MentionReference.Kind?) -> some View {
        let hasQuery = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return centered {
            VStack(spacing: 8) {
                Image(systemName: hasQuery ? "magnifyingglass" : (kind?.systemImage ?? "at"))
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text(hasQuery
                     ? LocalizedStringKey("No matches")
                     : (kind?.emptyMessage ?? LocalizedStringKey("Nothing to reference here yet.")))
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
