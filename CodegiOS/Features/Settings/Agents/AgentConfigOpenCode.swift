import SwiftUI

// OpenCode structured editor: main/small model + a list of providers, each with
// name / npm / base URL / API key and a nested model map. The API key dual-writes
// to config `provider.<id>.options.apiKey` AND `auth.json.<id> = {type:"api",key}`
// (web A7). Provider/model ids are fixed at creation (rename via delete+add) to
// keep stable SwiftUI identity. Held as parsed [String:Any] in @State and written
// back to the draft on every edit; unknown keys/providers are preserved.
struct OpenCodeConfigSection: View {
    @Binding var draft: AgentDraft

    @State private var config: [String: Any]
    @State private var auth: [String: Any]
    @State private var showAddProvider = false
    @State private var newProviderId = ""
    @State private var addModelTo: String?
    @State private var newModelId = ""

    init(draft: Binding<AgentDraft>) {
        _draft = draft
        _config = State(initialValue: JSONConfig.parse(draft.wrappedValue.configText).config)
        _auth = State(initialValue: JSONConfig.parse(draft.wrappedValue.openCodeAuthJsonText).config)
    }

    var body: some View {
        VStack(spacing: 16) {
            EditorSection(title: "Models") {
                FieldRow(label: "Main Model") {
                    TextField("provider/model-id", text: topBind("model")).ocField()
                }
                Divider().overlay(Theme.hairline)
                FieldRow(label: "Small Model") {
                    TextField("provider/model-id", text: topBind("small_model")).ocField()
                }
            }

            EditorSection(title: "Providers · \(providerIds.count)") {
                if providerIds.isEmpty {
                    Text("No providers yet.").font(.subheadline).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 11)
                }
                ForEach(providerIds, id: \.self) { pid in
                    providerCard(pid)
                }
                Button { newProviderId = ""; showAddProvider = true } label: {
                    Label("Add Provider", systemImage: "plus").font(.subheadline)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .alert("New provider", isPresented: $showAddProvider) {
            TextField("provider id (e.g. openrouter)", text: $newProviderId)
                .textInputAutocapitalization(.never).autocorrectionDisabled(true)
            Button("Add") { addProvider() }.disabled(newProviderId.trimmed.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("New model", isPresented: Binding(get: { addModelTo != nil }, set: { if !$0 { addModelTo = nil } })) {
            TextField("model id", text: $newModelId)
                .textInputAutocapitalization(.never).autocorrectionDisabled(true)
            Button("Add") { addModel() }.disabled(newModelId.trimmed.isEmpty)
            Button("Cancel", role: .cancel) { addModelTo = nil }
        }
    }

    // MARK: Provider card

    private func providerCard(_ pid: String) -> some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(pid).font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button(role: .destructive) { deleteProvider(pid) } label: {
                        Image(systemName: "trash").foregroundStyle(Theme.danger)
                    }.buttonStyle(.plain)
                }
                labeled("Name") { TextField("Display name", text: providerBind(pid, "name")).ocField() }
                labeled("Package") {
                    SelectField(selection: providerBind(pid, "npm"),
                                options: openCodeNpmOptions.map { SelectOption(value: $0, label: $0) })
                }
                labeled("Base URL") { TextField("https://…", text: optionBind(pid, "baseURL")).ocField() }
                labeled("API Key") { SecretField(placeholder: "sk-…", text: apiKeyBind(pid)) }

                let mids = modelIds(pid)
                Divider().overlay(Theme.hairline)
                Text("MODELS · \(mids.count)").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary).tracking(0.5)
                ForEach(mids, id: \.self) { mid in
                    HStack(spacing: 8) {
                        Text(mid).font(.mono(11)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                        TextField("name", text: modelNameBind(pid, mid)).ocField()
                        Button { deleteModel(pid, mid) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger.opacity(0.8))
                        }.buttonStyle(.plain)
                    }
                }
                Button { newModelId = ""; addModelTo = pid } label: {
                    Label("Add Model", systemImage: "plus").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    // MARK: Derived

    private var providerDict: [String: Any] { config["provider"] as? [String: Any] ?? [:] }
    private var providerIds: [String] { providerDict.keys.sorted() }
    private func provider(_ id: String) -> [String: Any] { providerDict[id] as? [String: Any] ?? [:] }
    private func modelIds(_ pid: String) -> [String] { (provider(pid)["models"] as? [String: Any])?.keys.sorted() ?? [] }

    private func writeBack() {
        draft.configText = JSONConfig.serialize(config)
        draft.openCodeAuthJsonText = JSONConfig.serialize(auth)
    }

    // MARK: Bindings

    private func topBind(_ key: String) -> Binding<String> {
        Binding(
            get: { config[key] as? String ?? "" },
            set: { v in
                let t = v.trimmed
                if t.isEmpty { config.removeValue(forKey: key) } else { config[key] = v }
                writeBack()
            })
    }

    private func providerBind(_ pid: String, _ key: String) -> Binding<String> {
        Binding(
            get: { provider(pid)[key] as? String ?? "" },
            set: { v in
                var p = provider(pid)
                if v.trimmed.isEmpty { p.removeValue(forKey: key) } else { p[key] = v }
                setProvider(pid, p)
            })
    }

    private func optionBind(_ pid: String, _ key: String) -> Binding<String> {
        Binding(
            get: { (provider(pid)["options"] as? [String: Any])?[key] as? String ?? "" },
            set: { v in
                var p = provider(pid)
                var opts = p["options"] as? [String: Any] ?? [:]
                if v.trimmed.isEmpty { opts.removeValue(forKey: key) } else { opts[key] = v }
                if opts.isEmpty { p.removeValue(forKey: "options") } else { p["options"] = opts }
                setProvider(pid, p)
            })
    }

    /// Dual-write: config `options.apiKey` + auth.json `{type:"api", key}`; clearing
    /// removes the key, the `type:"api"` marker, and the entry if it becomes empty.
    private func apiKeyBind(_ pid: String) -> Binding<String> {
        Binding(
            get: { (provider(pid)["options"] as? [String: Any])?["apiKey"] as? String ?? "" },
            set: { v in
                var p = provider(pid)
                var opts = p["options"] as? [String: Any] ?? [:]
                let trimmed = v.trimmed
                if trimmed.isEmpty { opts.removeValue(forKey: "apiKey") } else { opts["apiKey"] = v }
                if opts.isEmpty { p.removeValue(forKey: "options") } else { p["options"] = opts }
                var pd = providerDict; pd[pid] = p; config["provider"] = pd

                if trimmed.isEmpty {
                    if var entry = auth[pid] as? [String: Any] {
                        entry.removeValue(forKey: "key")
                        if (entry["type"] as? String) == "api" { entry.removeValue(forKey: "type") }
                        if entry.isEmpty { auth.removeValue(forKey: pid) } else { auth[pid] = entry }
                    }
                } else {
                    var entry = auth[pid] as? [String: Any] ?? [:]
                    entry["type"] = "api"; entry["key"] = v
                    auth[pid] = entry
                }
                writeBack()
            })
    }

    private func modelNameBind(_ pid: String, _ mid: String) -> Binding<String> {
        Binding(
            get: { ((provider(pid)["models"] as? [String: Any])?[mid] as? [String: Any])?["name"] as? String ?? "" },
            set: { v in
                var p = provider(pid)
                var models = p["models"] as? [String: Any] ?? [:]
                var m = models[mid] as? [String: Any] ?? [:]
                if v.trimmed.isEmpty { m.removeValue(forKey: "name") } else { m["name"] = v }
                models[mid] = m
                p["models"] = models
                setProvider(pid, p)
            })
    }

    // MARK: Mutations

    private func setProvider(_ id: String, _ p: [String: Any]) {
        var pd = providerDict; pd[id] = p; config["provider"] = pd; writeBack()
    }

    private func addProvider() {
        let id = newProviderId.trimmed
        guard !id.isEmpty else { return }
        var pd = providerDict
        if pd[id] == nil {
            pd[id] = ["npm": openCodeNpmOptions[0], "options": [String: Any](), "models": [String: Any]()]
            config["provider"] = pd
            writeBack()
        }
        newProviderId = ""
    }

    private func deleteProvider(_ id: String) {
        var pd = providerDict; pd.removeValue(forKey: id)
        if pd.isEmpty { config.removeValue(forKey: "provider") } else { config["provider"] = pd }
        auth.removeValue(forKey: id)
        writeBack()
    }

    private func addModel() {
        guard let pid = addModelTo else { return }
        let mid = newModelId.trimmed
        guard !mid.isEmpty else { return }
        var p = provider(pid)
        var models = p["models"] as? [String: Any] ?? [:]
        if models[mid] == nil { models[mid] = ["name": mid] }
        p["models"] = models
        setProvider(pid, p)
        addModelTo = nil; newModelId = ""
    }

    private func deleteModel(_ pid: String, _ mid: String) {
        var p = provider(pid)
        var models = p["models"] as? [String: Any] ?? [:]
        models.removeValue(forKey: mid)
        if models.isEmpty { p.removeValue(forKey: "models") } else { p["models"] = models }
        setProvider(pid, p)
    }
}

private extension View {
    func ocField() -> some View {
        self.font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
