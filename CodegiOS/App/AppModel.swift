import SwiftUI

/// Top-level navigation + selection state shared by both shells. Owns the
/// server store, the compact shell's per-tab navigation paths, the regular
/// shell's sidebar/content/detail selection, and the app-wide activity poller
/// that feeds the Activity tab and its badge.
@MainActor
final class AppModel: ObservableObject {
    let serverStore: ServerStore

    /// App-wide pulse of the selected server (running sessions, recents,
    /// folders) — the poll-based stand-in for the future persistent event hub.
    let activity = ActivityModel()

    // MARK: - Server selection

    private static let lastServerKey = "codeg.lastSelectedServerID"

    @Published var selectedServerID: ServerProfile.ID? {
        didSet {
            guard oldValue != selectedServerID else { return }
            resetServerScopedState()
            UserDefaults.standard.set(selectedServerID?.uuidString, forKey: Self.lastServerKey)
        }
    }

    // MARK: - Regular-width (iPad) selection

    /// Detail-column selection. Mutually exclusive with `pendingNewSession`.
    @Published var selectedConversationID: Int?
    /// A "new task" occupying the detail column before its conversation exists.
    @Published var pendingNewSession: NewSessionRequest?
    @Published var sidebarSection: SidebarSection? = .chats
    /// Pushes within the content column (currently: project detail).
    @Published var contentPath: [Route] = []

    // MARK: - Compact-width (iPhone) navigation

    // Typed route stacks (not opaque `NavigationPath`s) so navigation stays
    // inspectable — `open(_:)` can no-op when the destination is already on
    // top (e.g. tapping the running bar inside that very conversation).
    @Published var selectedTab: AppTab = .chats
    @Published var paths: [AppTab: [Route]] = [:]

    // Settings deliberately has NO navigation path here. Its stack is unbound so
    // iOS 16's navigation authority has no path to re-sync — see
    // `RootView.settingsTab` for what that sync cost.

    /// Width class mirrored in by RootView so `open(_:)` can decide between a
    /// push (compact) and a column selection (regular).
    @Published var isCompact = false

    // MARK: - Presentation

    @Published var serversSheetPresented = false
    @Published var settingsSheetPresented = false

    init(serverStore: ServerStore? = nil) {
        let store = serverStore ?? ServerStore()
        self.serverStore = store
        // Restore the last-used server, falling back to the first. With servers
        // demoted out of the tab bar there is no "pick a server" landing screen
        // anymore — the app must come up already pointed at a server.
        let persisted = UserDefaults.standard.string(forKey: Self.lastServerKey).flatMap(UUID.init)
        self.selectedServerID = store.servers.first { $0.id == persisted }?.id ?? store.servers.first?.id
    }

    var selectedServer: ServerProfile? {
        guard let id = selectedServerID else { return nil }
        return serverStore.servers.first { $0.id == id }
    }

    /// HTTP client for the selected server, if its token resolves.
    func selectedClient() -> CodegClient? {
        guard let server = selectedServer else { return nil }
        return serverStore.client(for: server)
    }

    // MARK: - Routing

    /// Open a destination from any entry point. Compact pushes onto the current
    /// tab's stack; regular routes to the appropriate column.
    func open(_ route: Route) {
        if isCompact {
            push(route, on: selectedTab)
            return
        }
        switch route {
        case .conversation(let id):
            pendingNewSession = nil
            selectedConversationID = id
        case .newSession(let request):
            selectedConversationID = nil
            pendingNewSession = request
        case .project:
            sidebarSection = .projects
            if contentPath.last != route { contentPath.append(route) }
        }
    }

    private func push(_ route: Route, on tab: AppTab) {
        var path = paths[tab, default: []]
        // Already there (e.g. the running bar tapped inside that conversation).
        guard path.last != route else { return }
        path.append(route)
        paths[tab] = path
    }

    /// Handle a `codeg://` URL. `codeg://tab/<name>` switches tabs;
    /// `codeg://conversation/<id>` / `codeg://project/<id>` land on the owning
    /// tab with a fresh, predictable stack (so Back always returns to that
    /// tab's root, not to wherever the user happened to be).
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "codeg" else { return }
        if url.host?.lowercased() == "tab",
           url.pathComponents.count > 1,
           let tab = AppTab(rawValue: url.pathComponents[1].lowercased()) {
            select(tab: tab)
            return
        }
        // `codeg://settings/<slug>` opens Settings (used for screenshot
        // verification, and harmless in production). It no longer pushes straight
        // to the pane: the Settings stack is deliberately unbound, because a bound
        // path plus any `NavigationLink { destination }` push makes iOS 16's
        // navigation authority retry a path sync it can never satisfy, every frame
        // (see `RootView.settingsTab`). The slug is still parsed so an unknown one
        // is rejected rather than falling through to the route table.
        if url.host?.lowercased() == "settings",
           url.pathComponents.count > 1,
           SettingsLeaf(slug: url.pathComponents[1]) != nil {
            if isCompact {
                selectedTab = .settings
            } else {
                settingsSheetPresented = true
            }
            return
        }
        guard let route = Route.from(url: url) else { return }
        if isCompact {
            let owner: AppTab = if case .project = route { .projects } else { .chats }
            selectedTab = owner
            paths[owner] = [route]
        } else {
            if case .project = route { contentPath = [] }
            open(route)
        }
    }

    private func select(tab: AppTab) {
        if isCompact {
            selectedTab = tab
            return
        }
        switch tab {
        case .chats, .search: sidebarSection = .chats
        case .projects: sidebarSection = .projects
        case .activity: sidebarSection = .activity
        // Open Settings at its root.
        case .settings: settingsSheetPresented = true
        }
    }

    // MARK: - Server-scoped resets

    /// Conversation, folder, and route identities are all endpoint-local.
    /// Dropped when the selected server changes…
    private func resetServerScopedState() {
        selectedConversationID = nil
        pendingNewSession = nil
        paths = [:]
        contentPath = []
        activity.reset()
    }

    /// …and when the selected server is edited in place (same UUID, new
    /// URL/token) — the old endpoint's IDs may not exist on the new one.
    func selectedServerEndpointChanged() {
        resetServerScopedState()
    }
}
