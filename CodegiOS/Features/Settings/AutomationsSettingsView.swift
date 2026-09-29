import SwiftUI

/// Scheduled automations (web `automations` parity, mobile shape): the list
/// with enable toggles, run-now, delete, and a create sheet covering the core
/// fields — name, cron, agent, folder, isolation, prompt. Runs history opens
/// per row.
struct AutomationsSettingsView: View {
    let client: CodegClient?

    @State private var automations: [AutomationInfo] = []
    @State private var folders: [FolderDetail] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreate = false
    @State private var deleteTarget: AutomationInfo?
    @State private var runsFor: AutomationInfo?
    @State private var busyIds = Set<Int>()

    var body: some View {
        Group {
            if client == nil {
                EmptyStateView(icon: "server.rack", title: "No Server Selected",
                               message: "Pick a server to see its automations.")
            } else if isLoading, automations.isEmpty {
                LoadingView(label: "Loading automations…")
            } else if let error, automations.isEmpty {
                InlineErrorView(message: error) { Task { await load() } }
            } else if automations.isEmpty {
                EmptyStateView(icon: "clock.badge.checkmark", title: "No Automations",
                               message: "Schedule a prompt to run on a cron.")
            } else {
                list
            }
        }
        .background(CodegBackground())
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .disabled(client == nil)
                    .accessibilityLabel("New Automation")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showCreate) {
            AutomationEditSheet(client: client, folders: folders) { draft in
                Task {
                    await create(draft)
                    showCreate = false
                }
            }
        }
        .sheet(item: $runsFor) { automation in
            AutomationRunsSheet(client: client, automation: automation)
        }
        .confirmationDialog(
            "Delete this automation?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { Task { await delete(target) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its schedule and history are removed. Conversations it already ran stay.")
        }
    }

    private var list: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(automations) { automation in
                row(automation)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ automation: AutomationInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AgentAvatar(agent: automation.agentType, size: 24)
                Text(verbatim: automation.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { automation.enabled },
                    set: { Task { await setEnabled(automation, $0) } }
                ))
                .labelsHidden()
                .disabled(busyIds.contains(automation.id))
            }
            HStack(spacing: 12) {
                Label(scheduleLabel(automation), systemImage: "clock")
                if let next = automation.nextRunAt {
                    Label("Next \(next.formatted(.relative(presentation: .named)))", systemImage: "forward")
                }
                if let last = automation.lastRunAt {
                    Label("Last \(last.formatted(.relative(presentation: .named)))", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 14) {
                Button { runsFor = automation } label: {
                    Label("Runs", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                Button { deleteTarget = automation } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                if automation.enabled {
                    Button { Task { await runNow(automation) } } label: {
                        Label("Run Now", systemImage: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(busyIds.contains(automation.id))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func scheduleLabel(_ automation: AutomationInfo) -> String {
        automation.triggerKind == "manual"
            ? "Manual"
            : (automation.cron ?? "Scheduled")
    }

    // MARK: - Actions

    private func load() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            automations = try await client.automationList()
            folders = (try? await client.listFolders()) ?? []
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setEnabled(_ automation: AutomationInfo, _ enabled: Bool) async {
        guard let client else { return }
        busyIds.insert(automation.id)
        defer { busyIds.remove(automation.id) }
        if let idx = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[idx].enabled = enabled
        }
        do {
            try await client.automationSetEnabled(id: automation.id, enabled: enabled)
        } catch {
            if let i = automations.firstIndex(where: { $0.id == automation.id }) {
                automations[i].enabled = !enabled
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ automation: AutomationInfo) async {
        guard let client else { return }
        do {
            try await client.automationDelete(id: automation.id)
            automations.removeAll { $0.id == automation.id }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runNow(_ automation: AutomationInfo) async {
        guard let client else { return }
        busyIds.insert(automation.id)
        defer { busyIds.remove(automation.id) }
        do {
            try await client.automationRunNow(id: automation.id)
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func create(_ draft: AutomationDraftBody) async {
        guard let client else { return }
        do {
            let created = try await client.automationCreate(draft: draft)
            automations.append(created)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Create sheet — the fields a mobile user realistically sets. Advanced knobs
/// (mode/config values, labels) stay editable on the web.
private struct AutomationEditSheet: View {
    let client: CodegClient?
    let folders: [FolderDetail]
    let onCreate: (AutomationDraftBody) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cron = "0 9 * * *"
    @State private var agentType: AgentType = .claudeCode
    @State private var folderId: Int?
    @State private var isolation = "shared_in_root"
    @State private var prompt = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Automation") {
                    TextField("Name", text: $name)
                    TextField("Cron (min hour day month weekday)", text: $cron)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Agent") {
                    Picker("Agent", selection: $agentType) {
                        ForEach(AgentType.allCases) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    Picker("Folder", selection: $folderId) {
                        Text("None").tag(Int?.none)
                        ForEach(folders) { folder in
                            Text(verbatim: FolderVisibility.label(name: folder.name, alias: folder.alias))
                                .tag(Int?.some(folder.id))
                        }
                    }
                    Picker("Isolation", selection: $isolation) {
                        Text("Shared in root").tag("shared_in_root")
                        Text("Worktree per run").tag("worktree_per_run")
                    }
                }
                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 90)
                }
            }
            .navigationTitle("New Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Create") {
                            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            saving = true
                            let draft = AutomationDraftBody(
                                name: name.trimmingCharacters(in: .whitespaces),
                                enabled: true,
                                triggerKind: "schedule",
                                cron: cron.isEmpty ? nil : cron,
                                timezone: TimeZone.current.identifier,
                                agentType: agentType.wireValue,
                                rootFolderId: folderId,
                                isolation: isolation,
                                branch: nil,
                                isRemoteBranch: false,
                                config: AutomationConfigBody(
                                    action: "launch_session",
                                    promptBlocks: prompt.isEmpty ? [] : [.text(prompt)],
                                    displayText: prompt,
                                    modeId: nil,
                                    configValues: [:]))
                            Task {
                                await onCreate(draft)
                                saving = false
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Recent runs of one automation (last 20), newest first.
private struct AutomationRunsSheet: View {
    let client: CodegClient?
    let automation: AutomationInfo
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [AutomationRunInfo] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    LoadingView(label: "Loading runs…")
                } else if runs.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", title: "No Runs Yet",
                                   message: "This automation hasn't run.")
                } else {
                    List(runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: run.status)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(run.status == "success" ? Theme.accent : .red)
                                Spacer()
                                if let started = run.startedAt {
                                    Text(started.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            if let summary = run.summary, !summary.isEmpty {
                                Text(verbatim: summary)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(3)
                            }
                            if let error = run.error, !error.isEmpty {
                                Text(verbatim: error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CodegBackground())
            .navigationTitle("Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let client {
                    runs = (try? await client.automationRuns(automationId: automation.id)) ?? []
                }
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }
}
