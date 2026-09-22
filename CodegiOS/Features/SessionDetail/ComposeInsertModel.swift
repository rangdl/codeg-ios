import SwiftUI

/// Backs the compose-bar "+" menu's three insert sources — Quick Messages,
/// Expert Skills, and Slash Commands — mirroring the web client's add-menu
/// (`message-input.tsx`). Loading is on demand (when a picker sheet opens) via
/// closures the owner wires to `CodegClient`; selecting an item produces a pure
/// draft transform applied by the compose bar.
@MainActor
final class ComposeInsertModel: ObservableObject {

    /// The three text-insert sources in the "+" menu.
    enum Source: String, Identifiable, CaseIterable {
        case quickMessages, experts, slashCommands
        var id: String { rawValue }

        /// Order the "+" menu lists them in. Declared explicitly rather than
        /// derived from `allCases` (or its reverse): the order the user sees is a
        /// product decision, and it must not silently flip when a case is added,
        /// removed, or reordered in the enum above.
        static let displayOrder: [Source] = [.slashCommands, .experts, .quickMessages]

        var title: LocalizedStringKey {
            switch self {
            case .quickMessages: return "Quick Messages"
            case .experts: return "Expert Skills"
            case .slashCommands: return "Slash Commands"
            }
        }
        var systemImage: String {
            switch self {
            case .quickMessages: return "text.bubble"
            case .experts: return "sparkles"
            case .slashCommands: return "slash.circle"
            }
        }
    }

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    /// The agent in context — drives the expert-mention prefix (`$` for Codex,
    /// `/` otherwise) and is the agent whose experts are listed.
    @Published var agentType: AgentType = .claudeCode

    // Loaders injected by the owner (wired to the client + this conversation).
    @Published var loadQuickMessagesAction: (() async throws -> [QuickMessage])?
    @Published var loadExpertsAction: (() async throws -> [ExpertListItem])?
    /// The GLOBAL built-in expert catalog (`experts_list`), used only to build the
    /// known-expert id set for the replace-prefix logic (the web's `expertIdSet`).
    @Published var loadBuiltInExpertsAction: (() async throws -> [ExpertListItem])?
    @Published var loadCommandsAction: (() async throws -> [AvailableCommandInfo])?

    @Published private(set) var quickMessages: [QuickMessage] = []
    @Published private(set) var experts: [ExpertListItem] = []
    @Published private(set) var commands: [AvailableCommandInfo] = []

    /// Ids treated as "known experts" when deciding whether to replace an existing
    /// mention prefix. Mirrors the web's `expertIdSet` (built from the built-in
    /// catalog, of which agent-linked experts are a subset); the agent's own
    /// experts are folded in as a fallback if the catalog read fails.
    @Published private(set) var knownExpertIDs: Set<String> = []

    @Published private(set) var phases: [Source: Phase] = [:]
    @Published private var tasks: [Source: Task<Void, Never>] = [:]
    /// Memoized (on success) global built-in expert ids, used for both the
    /// replace-prefix known set and the slash-command filter.
    @Published private var builtInIDs: Set<String>?

    private let client: CodegClient

    init(client: CodegClient) {
        self.client = client
    }

    func phase(_ source: Source) -> Phase { phases[source] ?? .idle }

    /// True when a source has loaded and produced no items (drives an empty state).
    func isEmpty(_ source: Source) -> Bool {
        switch source {
        case .quickMessages: return quickMessages.isEmpty
        case .experts: return experts.isEmpty
        case .slashCommands: return visibleCommands.isEmpty
        }
    }

    /// Slash commands with expert-backed commands removed (web parity:
    /// `availableCommands.filter(cmd => !expertIdSet.has(cmd.name))`). Reactive —
    /// re-filters when `knownExpertIDs` updates.
    var visibleCommands: [AvailableCommandInfo] {
        commands.filter { !knownExpertIDs.contains($0.name) }
    }

    // MARK: - Load

    /// Load (or refresh) a source. Keeps any previously loaded items visible while
    /// refreshing, so reopening a picker shows instantly then updates.
    func load(_ source: Source) {
        if case .loading = phase(source) { return }
        phases[source] = .loading
        tasks[source]?.cancel()
        tasks[source] = Task { [weak self] in
            guard let self else { return }
            do {
                switch source {
                case .quickMessages:
                    let list = try await (self.loadQuickMessagesAction?() ?? [])
                    if Task.isCancelled { return }
                    self.quickMessages = list.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
                case .experts:
                    // Fetch the agent's experts and the global built-in known set
                    // CONCURRENTLY, then publish the list and the known set TOGETHER
                    // (no await between) so a row can never be tapped while the
                    // known set is still stale — which would stack an existing
                    // built-in prefix instead of replacing it.
                    async let agentList = (self.loadExpertsAction?() ?? [])
                    let builtIn = await self.builtInKnownIDs()
                    let list = try await agentList
                    if Task.isCancelled { return }
                    self.experts = list.sorted {
                        (Self.rank($0.metadata.category), $0.metadata.sortOrder, $0.metadata.id)
                            < (Self.rank($1.metadata.category), $1.metadata.sortOrder, $1.metadata.id)
                    }
                    self.knownExpertIDs = builtIn.union(list.map { $0.metadata.id })
                case .slashCommands:
                    // Resolve the known-expert set too, so the filter (below /
                    // `visibleCommands`) can hide expert-backed commands even when
                    // Expert Skills was never opened (web parity).
                    async let cmds = (self.loadCommandsAction?() ?? [])
                    let known = await self.builtInKnownIDs()
                    let list = try await cmds
                    if Task.isCancelled { return }
                    self.knownExpertIDs.formUnion(known)
                    self.commands = list
                }
                if Task.isCancelled { return }
                self.phases[source] = .loaded
            } catch is CancellationError {
                // superseded / torn down
            } catch {
                if Task.isCancelled { return }
                self.phases[source] = .failed(Self.describe(error))
            }
        }
    }

    /// The global built-in expert ids (the web's `expertIdSet`), memoized on
    /// success. A transient failure returns an empty set without memoizing, so a
    /// later load retries rather than permanently disabling the known set.
    private func builtInKnownIDs() async -> Set<String> {
        if let ids = builtInIDs { return ids }
        guard let action = loadBuiltInExpertsAction else { return [] }
        guard let list = try? await action() else { return [] }
        let ids = Set(list.map { $0.metadata.id })
        builtInIDs = ids
        return ids
    }

    func teardown() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    // MARK: - Insertion (pure draft transforms)

    /// The expert-mention prefix for the current agent (`$` for Codex, `/` else),
    /// matching the web's `expertPrefix`.
    var expertPrefix: String { agentType == .codex ? "$" : "/" }

    /// Append a quick-message template to the draft (a separating space is added
    /// when needed so it doesn't run into existing text).
    func draftAppendingMessage(_ content: String, to draft: String) -> String {
        guard !content.isEmpty else { return draft }
        if draft.isEmpty { return content }
        let needsSpace = !(draft.last?.isWhitespace ?? false)
        return draft + (needsSpace ? " " : "") + content
    }

    /// Append a slash command (`/<name> `) to the draft, mirroring the web's
    /// `handleSlashPopoverSelect` spacing (a leading space when needed).
    func draftAppendingCommand(_ name: String, to draft: String) -> String {
        let needsSpace = !draft.isEmpty && !(draft.last?.isWhitespace ?? false)
        return draft + (needsSpace ? " " : "") + "/\(name) "
    }

    /// Prepend an expert mention (`<prefix><id> `) to the draft, replacing an
    /// existing expert prefix already at the front so they don't stack — mirroring
    /// the web's `handleExpertPopoverSelect`.
    func draftApplyingExpert(_ id: String, to draft: String) -> String {
        let insertion = "\(expertPrefix)\(id) "
        var base = draft
        if let found = firstExpertPrefix(in: draft), knownExpertIDs.contains(found.id) {
            base = String(draft[found.end...])
        }
        return base.isEmpty ? insertion : insertion + base
    }

    /// Find a leading `<prefix><id><whitespace>` token in the draft, returning the
    /// id and the index just past the trailing whitespace (so the caller can strip
    /// the whole token). Matches the web regex `^<prefix>([A-Za-z0-9_-]+)\s`.
    private func firstExpertPrefix(in draft: String) -> (id: String, end: String.Index)? {
        guard draft.hasPrefix(expertPrefix) else { return nil }
        var i = draft.index(draft.startIndex, offsetBy: expertPrefix.count)
        var id = ""
        while i < draft.endIndex {
            let ch = draft[i]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                id.append(ch); i = draft.index(after: i)
            } else { break }
        }
        guard !id.isEmpty, i < draft.endIndex, draft[i].isWhitespace else { return nil }
        return (id, draft.index(after: i))
    }

    // MARK: - Helpers

    /// Web's expert category sort order (`CATEGORY_SORT`); unknown categories sort last.
    private static let categoryOrder = ["discovery", "planning", "execution", "quality", "debugging", "review", "meta"]
    private static func rank(_ category: String) -> Int {
        categoryOrder.firstIndex(of: category) ?? categoryOrder.count
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}
