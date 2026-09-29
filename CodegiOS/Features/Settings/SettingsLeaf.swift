import SwiftUI

/// The Settings tab's pushable leaf screens. Navigation is value-driven
/// (`NavigationLink(value:)` + a single `.navigationDestination(for:)` registered
/// inside `SettingsView`): this keeps every row whole-row-tappable and lets the
/// `codeg://settings/<slug>` deep link jump straight to a pane for screenshot
/// verification. These are leaf settings panes, not server-addressable entities,
/// so they deliberately stay out of the global `Route` enum.
///
/// `allCases` is declared in the exact order the rows appear under Appearance.
enum SettingsLeaf: String, Hashable, CaseIterable, Identifiable {
    case general
    case mcp
    case skills
    case experts
    case agents
    case modelProviders
    case quickMessages
    case versionControl
    case chatChannels
    case automations
    case tokenUsage
    case system

    var id: String { rawValue }

    /// Deep-link slug for `codeg://settings/<slug>` (the lowercased raw value,
    /// e.g. `modelproviders`).
    var slug: String { rawValue.lowercased() }

    init?(slug: String) {
        let normalized = slug.lowercased()
        guard let match = Self.allCases.first(where: { $0.slug == normalized }) else { return nil }
        self = match
    }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .mcp: "MCP"
        case .skills: "Skills"
        case .experts: "Experts"
        case .agents: "Agents"
        case .modelProviders: "Model Providers"
        case .quickMessages: "Quick Messages"
        case .versionControl: "Version Control"
        case .chatChannels: "Chat Channels"
        case .automations: "Automations"
        case .tokenUsage: "Token Usage"
        case .system: "System"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .mcp: "puzzlepiece.extension.fill"
        case .skills: "wand.and.stars"
        case .experts: "graduationcap.fill"
        case .agents: "cpu"
        case .modelProviders: "server.rack"
        case .quickMessages: "text.bubble.fill"
        case .versionControl: "arrow.triangle.branch"
        case .chatChannels: "bell.badge.fill"
        case .automations: "clock.badge.checkmark"
        case .tokenUsage: "chart.bar.fill"
        case .system: "gearshape.2.fill"
        }
    }

    /// The screen this leaf pushes. All ten categories are implemented.
    @MainActor @ViewBuilder
    func destination(store: ServerStore, selectedServerID: ServerProfile.ID?) -> some View {
        let client = store.servers.first { $0.id == selectedServerID }.flatMap { store.client(for: $0) }
        switch self {
        case .general:
            GeneralSettingsView(client: client)
        case .quickMessages:
            QuickMessagesSettingsView(client: client)
        case .modelProviders:
            ModelProvidersSettingsView(client: client)
        case .experts:
            ExpertsSettingsView(client: client)
        case .skills:
            SkillsSettingsView(client: client)
        case .mcp:
            McpSettingsView(client: client)
        case .agents:
            AgentsSettingsView(client: client)
        case .chatChannels:
            ChatChannelsSettingsView(client: client)
        case .versionControl:
            VersionControlSettingsView(client: client)
        case .automations:
            AutomationsSettingsView(client: client)
        case .tokenUsage:
            TokenUsageSettingsView(client: client)
        case .system:
            SystemSettingsView(client: client)
        }
    }
}
