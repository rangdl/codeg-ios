import SwiftUI

/// Settings root — a tab on iPhone, a sheet on iPad. An iOS-Settings-style
/// grouped list: the twelve entries are gathered into four labeled sections
/// (Personalization · AI & Agents · Integrations · System), each a single glass
/// card whose whole-row entries are split by inset hairlines. Every category
/// pushes a dedicated leaf screen — value-based throughout: the ten `SettingsLeaf`
/// panes (one `.navigationDestination(for:)`) plus Appearance / Language / About
/// over their own `SettingsPushDestination` enum. Server management lives in the
/// Chats / sidebar title menu's "Manage Servers…", not here.
struct SettingsView: View {
    @ObservedObject var store: ServerStore
    @Binding var selectedServerID: ServerProfile.ID?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var language: LanguageStore

    /// Live server version, fetched from `health`, pre-loaded here so the pushed
    /// About screen has it ready.
    @StateObject private var versionModel = ServerVersionModel()

    private var selectedServer: ServerProfile? {
        store.servers.first { $0.id == selectedServerID }
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    personalizationSection
                    aiSection
                    integrationsSection
                    systemSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .screenTitle("Settings", compact: horizontalSizeClass == .compact)
        .navigationDestination(for: SettingsLeaf.self) { leaf in
            leaf.destination(store: store, selectedServerID: selectedServerID)
        }
        // Appearance / Language / About also push by value (see
        // `SettingsPushDestination`), so code-driven `settingsPath = []` pops
        // them like every other leaf instead of stranding them above the stack.
        .navigationDestination(for: SettingsPushDestination.self) { dest in
            switch dest {
            case .appearance: AppearanceSettingsView()
            case .language: LanguageSettingsView()
            case .about: AboutView(versionModel: versionModel, serverName: selectedServer?.name)
            }
        }
        .task(id: selectedServerID) {
            await versionModel.load(selectedServer.flatMap { store.client(for: $0) })
        }
    }

    // MARK: - Sections

    /// Appearance + the personal app preferences.
    private var personalizationSection: some View {
        EditorSection(title: "Personalization") {
            appearanceRow
            SettingsRowDivider()
            languageRow
            SettingsRowDivider()
            leafRow(.general)
            SettingsRowDivider()
            leafRow(.quickMessages)
        }
    }

    /// The core AI configuration: agents and what they run with.
    private var aiSection: some View {
        EditorSection(title: "AI & Agents") {
            leafRows([.agents, .modelProviders, .experts, .skills, .mcp])
        }
    }

    /// Outbound hooks: source control and notification channels.
    private var integrationsSection: some View {
        EditorSection(title: "Integrations") {
            leafRows([.versionControl, .chatChannels, .automations, .tokenUsage])
        }
    }

    /// System-level configuration, then About (last) carrying the version.
    private var systemSection: some View {
        EditorSection(title: "System") {
            leafRow(.system)
            SettingsRowDivider()
            aboutRow
        }
    }

    // MARK: - Leaf rows

    /// One value-based leaf row using the leaf's own title + icon.
    private func leafRow(_ leaf: SettingsLeaf) -> some View {
        SettingsGroupedNavRow(icon: leaf.icon, title: leaf.title, value: leaf)
    }

    /// A run of leaf rows with inset dividers between them (no leading or
    /// trailing divider, so it drops straight into a section card).
    @ViewBuilder
    private func leafRows(_ leaves: [SettingsLeaf]) -> some View {
        ForEach(Array(leaves.enumerated()), id: \.element) { index, leaf in
            if index > 0 { SettingsRowDivider() }
            leafRow(leaf)
        }
    }

    // MARK: - Destination-based rows
    //
    // Appearance, Language, and About push concrete screens (not `SettingsLeaf`
    // values) — but they still push BY VALUE: `SettingsGroupedNavRow` over the
    // `SettingsPushDestination` enum registered above. A destination-based
    // `NavigationLink { … }` wouldn't enter `settingsPath`, so a code-driven
    // `settingsPath = []` (server change / deep link) would strand these screens
    // above an emptied stack.

    /// Appearance pushes the theme/accent screen. The leading glyph mirrors the
    /// current mode, and the detail shows the live selection (e.g. "System · Mint").
    private var appearanceRow: some View {
        SettingsGroupedNavRow(
            icon: appearance.mode.symbol,
            title: "Appearance",
            // Compose from the localized enum keys via `Text` interpolation so
            // each piece re-resolves live with the app language.
            detail: "\(Text(appearance.mode.titleKey)) · \(Text(appearance.accent.titleKey))",
            value: SettingsPushDestination.appearance
        )
    }

    /// Language pushes the app display-language picker; the detail shows the
    /// current choice (e.g. "中文"), re-resolved live with the app language.
    private var languageRow: some View {
        SettingsGroupedNavRow(
            icon: "globe",
            title: "Language",
            detail: language.language.titleKey,
            value: SettingsPushDestination.language
        )
    }

    /// About (last): pushes the detail screen carrying the app + server version.
    /// `versionModel` is pre-loaded by the `.task` above so it's ready on arrival.
    private var aboutRow: some View {
        SettingsGroupedNavRow(
            icon: "info.circle.fill",
            title: "About",
            value: SettingsPushDestination.about
        )
    }
}

/// Value-routing for the Settings screens that don't fit the `SettingsLeaf`
/// enum: Appearance, Language, and About push concrete views with per-row
/// labels/details of their own, but must still enter the `settingsPath` stack
/// (see the note in ``SettingsView``). Private on purpose — only `SettingsView`
/// registers a destination for it.
private enum SettingsPushDestination: Hashable {
    case appearance
    case language
    case about
}
