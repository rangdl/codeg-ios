import SwiftUI

/// One rendered group of the References panel. A named struct rather than a
/// tuple because `ForEach` keys on a key path and tuples don't have them.
struct MentionGroup: Identifiable {
    let kind: MentionReference.Kind
    let items: [MentionReference]
    var id: MentionReference.Kind { kind }
}

/// Backs the compose bar's **References** picker: the same references the web
/// composer offers from its `@` mention panel — workspace files, agents,
/// sessions and commits (web `composer/use-reference-search.ts`).
///
/// The *trigger* differs on purpose. Web opens the panel by typing `@`, which
/// requires the caret position; the iOS composer is a plain `TextField` and iOS 16
/// offers no caret access, so this picker is opened from the "+" menu instead and
/// the chosen reference is inserted at the top of the draft (see `ComposeBar`).
/// Everything else — the four groups, their order, the per-group cap, the
/// in-memory filtering and the Markdown each row serializes to — is the web's.
@MainActor
final class MentionInsertModel: ObservableObject {

    enum Phase: Equatable { case idle, loading, loaded }

    /// Rows surfaced per group; the web's `MAX_PER_GROUP`.
    static let maxPerGroup = 50
    /// Commits pulled before filtering client-side; the web's `GIT_LOG_LIMIT`.
    static let commitFetchLimit = 100

    // Loaders injected by the owner (wired to the client + this conversation).
    @Published var loadFilesAction: (() async throws -> [WorkspaceFileEntry])?
    @Published var loadAgentsAction: (() async throws -> [AcpAgentInfo])?
    @Published var loadSessionsAction: (() async throws -> [ConversationSummary])?
    @Published var loadCommitsAction: (() async throws -> [GitLogEntry])?

    /// Resolves the absolute workspace root when loading. A closure rather than a
    /// stored string because the folder is loaded asynchronously and the picker
    /// can be opened before it lands. The root doubles as the commit uri's
    /// `repoKey` (the web passes the repository path) and as the base for file
    /// uris; while it resolves to nil those two groups stay empty, exactly as the
    /// web omits them.
    @Published var resolveWorkspaceRoot: (() -> String?)?

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var references: [MentionReference] = []

    private var task: Task<Void, Never>?

    /// Load every group. Called from the sheet's `.task`, which re-runs whenever
    /// the sheet is presented, so re-opening refreshes the lists (the web's
    /// focus-refetch equivalent).
    func load() {
        if case .loading = phase { return }
        phase = .loading
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            // Each source is awaited on its own so a failing group drops only
            // itself instead of blanking the picker — the web fails open the same
            // way (`useEnabledSkillIds`/`useFileTree` keep their last snapshot).
            let root = self.resolveWorkspaceRoot?()
            async let files = self.loadFiles(root: root)
            async let agents = self.loadAgents()
            async let sessions = self.loadSessions()
            async let commits = self.loadCommits(root: root)
            let (f, a, s, c) = await (files, agents, sessions, commits)
            guard !Task.isCancelled else { return }
            self.references = f + a + s + c
            self.phase = .loaded
        }
    }

    func teardown() {
        task?.cancel()
        task = nil
    }

    /// The panel's groups for `query`, in the fixed render order
    /// (files → agents → sessions → commits). Empty groups are kept so the order
    /// never shifts; the sheet skips them.
    func groups(matching query: String) -> [MentionGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MentionReference.Kind.allCases.map { kind in
            // `lazy` + `prefix` stops scanning a group once its cap is reached,
            // which matters for the file list (the whole workspace, thousands of
            // entries) — the web's `truncated` optimization.
            let items = references.lazy
                .filter { $0.kind == kind && (needle.isEmpty || $0.matches(needle)) }
                .prefix(Self.maxPerGroup)
            return MentionGroup(kind: kind, items: Array(items))
        }
    }

    /// Total rows across all groups — drives the panel's empty state.
    func matchCount(matching query: String) -> Int {
        groups(matching: query).reduce(0) { $0 + $1.items.count }
    }

    // MARK: - Per-group loads

    private func loadFiles(root: String?) async -> [MentionReference] {
        guard let action = loadFilesAction, let root else { return [] }
        guard let entries = try? await action() else { return [] }
        return entries.map { MentionReference.file(root: root, path: $0.path, name: $0.name) }
    }

    private func loadAgents() async -> [MentionReference] {
        guard let action = loadAgentsAction else { return [] }
        guard let agents = try? await action() else { return [] }
        // Only enabled agents are mentionable — a disabled agent can't be
        // referenced, so it never reaches the panel (web parity).
        return agents
            .filter(\.enabled)
            .map { MentionReference.agent(type: $0.agentType, name: $0.name, description: $0.description) }
    }

    private func loadSessions() async -> [MentionReference] {
        guard let action = loadSessionsAction else { return [] }
        guard let sessions = try? await action() else { return [] }
        return sessions.map { MentionReference.session(id: $0.id, title: $0.title ?? "") }
    }

    private func loadCommits(root: String?) async -> [MentionReference] {
        guard let action = loadCommitsAction, let repoKey = root else { return [] }
        guard let entries = try? await action() else { return [] }
        return entries.map {
            MentionReference.commit(
                repoKey: repoKey,
                fullHash: $0.fullHash,
                shortHash: $0.hash,
                subject: $0.subject
            )
        }
    }
}

extension MentionReference {
    /// Case-insensitive match against the label, the uri and the detail line —
    /// the web matches the label, the id, extra keywords and the detail.
    func matches(_ lowercasedQuery: String) -> Bool {
        if label.lowercased().contains(lowercasedQuery) { return true }
        if uri.lowercased().contains(lowercasedQuery) { return true }
        if let detail, detail.lowercased().contains(lowercasedQuery) { return true }
        return false
    }
}
