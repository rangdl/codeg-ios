import SwiftUI

/// The server's agents: a reorderable list (drag in edit mode → `acp_reorder_agents`)
/// where each row carries an instant enable toggle and taps through to a detail
/// for env / model-provider / preflight. The toggle flips enabled immediately
/// (the row content, not the toggle, owns the tap that navigates).
struct AgentsSettingsView: View {
    let client: CodegClient?
    @StateObject private var model: AgentsSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        self.client = client
        _model = StateObject(wrappedValue: AgentsSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (matches Experts / Skills): big at the top on
        // compact, collapsing to a centered inline title as the list scrolls.
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.agents.count > 1 { EditButton().tint(Theme.accent) }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.agents.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading agents…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(icon: "cpu", title: "No Agents", message: "This server has no registered agents.")
            }
        } else {
            List {
                if let error = model.refreshError {
                    RefreshErrorBanner(
                        message: error,
                        retry: { Task { await model.load() } },
                        dismiss: { model.refreshError = nil }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Layout.screenHMargin, bottom: 8, trailing: Theme.Layout.screenHMargin))
                }
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent, model: model, client: client)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: Theme.Layout.screenHMargin, bottom: 5, trailing: Theme.Layout.screenHMargin))
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3.5))
                    // Don't clear a newer toast: if this task was cancelled by a
                    // toast change, the replacement task owns the dismissal.
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
}

/// One agent row: brand avatar, name + install-status pill, description, and an
/// instant enable toggle. Tapping the content (not the toggle) opens the detail.
private struct AgentRow: View {
    let agent: AcpAgentInfo
    let model: AgentsSettingsModel
    let client: CodegClient?

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
            HStack(spacing: 12) {
                // The row content is the push, and the trailing Toggle sits beside
                // this label rather than inside it, so the toggle still owns its own
                // taps. `navigationDestination(item:)` — the item-driven form
                // upstream uses — is iOS 17+; the `isPresented` stand-in this screen
                // used instead made iOS 16's navigation authority re-register the
                // destination on every frame ("Update NavigationAuthority bound path
                // tried to update multiple times per frame"), re-rendering the body
                // at display rate until the scene-update watchdog killed the app.
                // The detail reads the LIVE agent from the model, so a save/install
                // reload is reflected without a stale snapshot.
                NavigationLink {
                    AgentDetailView(model: model, agentType: agent.agentType, client: client)
                } label: {
                    HStack(spacing: 12) {
                        AgentAvatar(
                            agent: agent.agentType,
                            size: 40,
                            remoteURL: agent.iconUrl.flatMap(URL.init(string:))
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(agent.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                AgentStatusPill(agent: agent)
                            }
                            if !agent.description.isEmpty {
                                Text(agent.description)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: .changes(
                    get: { agent.enabled },
                    set: { on in Task { _ = await model.setEnabled(agent, on) } }
                ))
                .labelsHidden()
                .tint(Theme.accent)
                // The agent name sits in the adjacent button, so label the switch
                // explicitly for VoiceOver.
                .accessibilityLabel("\(agent.name) enabled")
                .disabled(!agent.available || model.togglingEnabled.contains(agent.agentType))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small status pill reflecting an agent's install state: its version when
/// installed (accent), "Not installed" when available but absent (neutral), or
/// "Unavailable" when the platform can't run it (danger).
struct AgentStatusPill: View {
    let agent: AcpAgentInfo

    private var label: LocalizedStringKey {
        if !agent.available { return "Unavailable" }
        if let v = agent.installedVersion { return "v\(v)" }
        return "Not installed"
    }

    private var tint: Color {
        if !agent.available { return Theme.danger }
        return agent.installedVersion != nil ? Theme.accent : Theme.textTertiary
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}
