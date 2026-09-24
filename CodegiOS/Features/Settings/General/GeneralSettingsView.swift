import SwiftUI

/// General settings: multi-agent delegation (enable + depth + completed-result
/// cache budget) and the conversation tools (live feedback, ask-user questions).
/// Every control persists on change — delegation scalars are coalesced by the
/// model, the toggles each run their own serial sender.
///
/// Each setting carries a one-line hint beneath its title (mirroring the web
/// settings page) so the screen explains itself; rows are fully padded inside
/// the glass cards and separated by inset hairlines.
struct GeneralSettingsView: View {
    @StateObject private var model: GeneralSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        _model = StateObject(wrappedValue: GeneralSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("General", compact: horizontalSizeClass == .compact)
        .task { await model.load() }
        .alert("Couldn’t Save", isPresented: .presenting($model.saveError)) {
            Button("OK", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(label: "Loading…")
        case .failed(let message):
            InlineErrorView(message: message) { Task { await model.load() } }
        case .loaded:
            ScrollView {
                VStack(spacing: 22) {
                    delegationSection
                    toolsSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.snappy(duration: 0.28), value: model.delegationEnabled)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Sections

    private var delegationSection: some View {
        EditorSection(
            title: "Delegation",
            footer: "Allow active agents to delegate sub-tasks to other agents and run them in parallel."
        ) {
            settingRow(
                "Enable delegation",
                hint: "When off, the delegate_to_agent tool is hidden from the agent’s catalog."
            ) {
                toggle(get: { model.delegationEnabled },
                       set: { model.delegationEnabled = $0; model.scheduleDelegationSave() })
            }
            if model.delegationEnabled {
                rowDivider
                settingRow(
                    "Maximum depth",
                    hint: "How deep a chain (root → child → grandchild …) can recurse."
                ) {
                    depthControl
                }
                rowDivider
                settingRow(
                    "Completed-result cache",
                    hint: "In-memory cache of finished sub-agent results, cleared when the session ends. Unlimited keeps them all."
                ) {
                    cacheControl
                }
            }
        }
    }

    private var toolsSection: some View {
        EditorSection(
            title: "Conversation Tools",
            footer: "Extra tools agents can use mid-conversation. Each takes effect for agents started after you turn it on."
        ) {
            settingRow(
                "Live feedback",
                hint: "Send notes and corrections to an agent while it’s working."
            ) {
                toggle(get: { model.feedbackEnabled }, set: { model.setFeedback($0) })
            }
            rowDivider
            settingRow(
                "Ask-user questions",
                hint: "Let agents pause to ask you a multiple-choice question and wait for an answer."
            ) {
                toggle(get: { model.questionEnabled }, set: { model.setQuestion($0) })
            }
        }
    }

    // MARK: - Row scaffold
    //
    // A fully-padded row: title + wrapping hint on the left, a control on the
    // right. The vertical/horizontal padding matches `FieldRow` so the content no
    // longer collides with the glass card's edges.

    @ViewBuilder
    private func settingRow<Trailing: View>(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inset hairline so the separator starts at the title, not the card edge.
    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }

    // MARK: - Controls
    //
    // Get/set bindings (NOT `$model.x` + `.onChange`): the set-binding fires only
    // on user interaction, so a programmatic rollback/reload that updates the
    // property can't re-trigger a save.

    private func toggle(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: .changes(get: get, set: set))
            .labelsHidden()
            .tint(Theme.accent)
    }

    private var depthControl: some View {
        HStack(spacing: 12) {
            Text("\(model.depthLimit)")
                .font(.body.monospacedDigit().weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 16, alignment: .trailing)
            Stepper(
                "",
                value: .changes(
                    get: { model.depthLimit },
                    set: { model.depthLimit = $0; model.scheduleDelegationSave() }
                ),
                in: 1...8
            )
            .labelsHidden()
        }
    }

    /// A native menu picker of sensible cache budgets — far more usable than a
    /// step-64 stepper across the 0–4 GB range. The current server value is kept
    /// in the list even when it isn't a preset, so a custom value isn't lost.
    private var cacheControl: some View {
        Menu {
            ForEach(cacheOptions, id: \.self) { mb in
                Button {
                    guard mb != model.completedCacheMaxMb else { return }
                    model.completedCacheMaxMb = mb
                    model.scheduleDelegationSave()
                } label: {
                    if mb == model.completedCacheMaxMb {
                        Label(LocalizedStringKey(stringLiteral: cacheLabel(mb)), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(stringLiteral: cacheLabel(mb)))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(stringLiteral: cacheLabel(model.completedCacheMaxMb)))
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private static let cachePresets = [0, 256, 512, 1024, 2048, 4096]

    private var cacheOptions: [Int] {
        var opts = Self.cachePresets
        if !opts.contains(model.completedCacheMaxMb) {
            opts.append(model.completedCacheMaxMb)
            opts.sort()
        }
        return opts
    }

    private func cacheLabel(_ mb: Int) -> String {
        if mb == 0 { return "Unlimited" }
        if mb >= 1024 && mb % 1024 == 0 { return "\(mb / 1024) GB" }
        return "\(mb) MB"
    }
}
