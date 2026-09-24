import SwiftUI

// Hermes config. Unlike the others, hermes saves through its own endpoint
// (`acp_update_hermes_config`) and its `config_json` is a backend PROJECTION
// (provider/model/baseUrl/apiKey), not a round-trippable file. Key rule (A2):
// apiKey blank or a non-apiKey provider → send `.keep` (null) so the stored
// `~/.hermes/.env` secret is preserved. After save the host rebuilds the draft
// from the fresh projection (A3).

enum HermesProviderKind: Sendable { case apiKey, oauth, aws }

struct HermesProviderOption: Identifiable, Sendable {
    let id: String
    let label: String
    let needsBaseUrl: Bool
    let kind: HermesProviderKind
}

/// Verbatim from the web `HERMES_PROVIDERS` (types.ts).
let hermesProviders: [HermesProviderOption] = [
    // API key
    .init(id: "openrouter", label: "OpenRouter", needsBaseUrl: false, kind: .apiKey),
    .init(id: "openai-api", label: "OpenAI / Compatible", needsBaseUrl: true, kind: .apiKey),
    .init(id: "custom", label: "Custom (OpenAI-compatible)", needsBaseUrl: true, kind: .apiKey),
    .init(id: "anthropic", label: "Anthropic", needsBaseUrl: false, kind: .apiKey),
    .init(id: "gemini", label: "Google AI Studio", needsBaseUrl: false, kind: .apiKey),
    .init(id: "deepseek", label: "DeepSeek", needsBaseUrl: false, kind: .apiKey),
    .init(id: "xai", label: "xAI Grok", needsBaseUrl: false, kind: .apiKey),
    .init(id: "zai", label: "Z.AI / GLM", needsBaseUrl: false, kind: .apiKey),
    .init(id: "minimax", label: "MiniMax", needsBaseUrl: false, kind: .apiKey),
    .init(id: "minimax-cn", label: "MiniMax (China)", needsBaseUrl: false, kind: .apiKey),
    .init(id: "kimi-coding", label: "Kimi / Moonshot", needsBaseUrl: false, kind: .apiKey),
    .init(id: "kimi-coding-cn", label: "Kimi / Moonshot (China)", needsBaseUrl: false, kind: .apiKey),
    .init(id: "nvidia", label: "NVIDIA NIM", needsBaseUrl: false, kind: .apiKey),
    .init(id: "alibaba", label: "Qwen (DashScope)", needsBaseUrl: false, kind: .apiKey),
    .init(id: "alibaba-coding-plan", label: "Alibaba Coding Plan", needsBaseUrl: false, kind: .apiKey),
    .init(id: "copilot", label: "GitHub Copilot", needsBaseUrl: false, kind: .apiKey),
    .init(id: "lmstudio", label: "LM Studio", needsBaseUrl: true, kind: .apiKey),
    .init(id: "azure-foundry", label: "Azure Foundry", needsBaseUrl: true, kind: .apiKey),
    .init(id: "stepfun", label: "StepFun", needsBaseUrl: false, kind: .apiKey),
    .init(id: "arcee", label: "Arcee AI", needsBaseUrl: false, kind: .apiKey),
    .init(id: "gmi", label: "GMI Cloud", needsBaseUrl: false, kind: .apiKey),
    .init(id: "huggingface", label: "Hugging Face", needsBaseUrl: false, kind: .apiKey),
    .init(id: "kilocode", label: "Kilo Code", needsBaseUrl: false, kind: .apiKey),
    .init(id: "opencode-zen", label: "OpenCode Zen", needsBaseUrl: false, kind: .apiKey),
    .init(id: "opencode-go", label: "OpenCode Go", needsBaseUrl: false, kind: .apiKey),
    .init(id: "xiaomi", label: "Xiaomi MiMo", needsBaseUrl: false, kind: .apiKey),
    .init(id: "tencent-tokenhub", label: "Tencent TokenHub", needsBaseUrl: false, kind: .apiKey),
    .init(id: "ollama-cloud", label: "Ollama Cloud", needsBaseUrl: false, kind: .apiKey),
    .init(id: "novita", label: "Novita AI", needsBaseUrl: false, kind: .apiKey),
    // OAuth
    .init(id: "nous", label: "Nous Portal", needsBaseUrl: false, kind: .oauth),
    .init(id: "openai-codex", label: "OpenAI Codex", needsBaseUrl: false, kind: .oauth),
    .init(id: "minimax-oauth", label: "MiniMax", needsBaseUrl: false, kind: .oauth),
    .init(id: "xai-oauth", label: "xAI Grok", needsBaseUrl: false, kind: .oauth),
    .init(id: "qwen-oauth", label: "Qwen", needsBaseUrl: false, kind: .oauth),
    .init(id: "google-gemini-cli", label: "Gemini CLI", needsBaseUrl: false, kind: .oauth),
    .init(id: "copilot-acp", label: "GitHub Copilot ACP", needsBaseUrl: false, kind: .oauth),
    // AWS
    .init(id: "bedrock", label: "AWS Bedrock", needsBaseUrl: false, kind: .aws),
]

extension AgentConfig {
    struct HermesValues { var provider = "openrouter"; var model = ""; var baseUrl = ""; var apiKey = "" }

    /// Parse the hermes projection carried in `config_json` (camelCase keys).
    static func parseHermes(_ configText: String) -> HermesValues {
        let c = JSONConfig.parse(configText).config
        return HermesValues(
            provider: (c["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "openrouter",
            model: c["model"] as? String ?? "",
            baseUrl: c["baseUrl"] as? String ?? "",
            apiKey: c["apiKey"] as? String ?? "")
    }

    /// Build the structured `acp_update_hermes_config` body. apiKey is `.keep`
    /// (null) when blank or the provider isn't apiKey-kind (so the stored secret
    /// survives); baseUrl is sent only for needsBaseUrl providers.
    static func hermesStructuredBody(_ draft: AgentDraft) -> UpdateHermesConfigBody {
        let opt = hermesProviders.first { $0.id == draft.hermesProvider }
        var body = UpdateHermesConfigBody(provider: draft.hermesProvider)
        body.model = draft.model
        if opt?.kind == .apiKey, !draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            body.apiKey = .set(draft.apiKey)
        } else {
            // Explicit null — the backend reads a null hermes apiKey as "keep the
            // stored ~/.hermes/.env secret" (web parity), so a blank field can't wipe it.
            body.apiKey = .clear
        }
        body.baseUrl = (opt?.needsBaseUrl == true) ? .set(draft.apiBaseUrl) : .clear
        return body
    }
}

struct HermesConfigSection: View {
    @Binding var draft: AgentDraft

    private var option: HermesProviderOption? { hermesProviders.first { $0.id == draft.hermesProvider } }
    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var keyProviders: [HermesProviderOption] { hermesProviders.filter { $0.kind == .apiKey } }
    private var oauthProviders: [HermesProviderOption] { hermesProviders.filter { $0.kind == .oauth } }
    private var awsProviders: [HermesProviderOption] { hermesProviders.filter { $0.kind == .aws } }

    var body: some View {
        EditorSection(title: "Config", footer: footer) {
            FieldRow(label: "Provider") {
                SelectBox(display: option?.label ?? "") {
                    Picker("", selection: Binding(get: { draft.hermesProvider }, set: setProvider)) {
                        Section("API Key") { ForEach(keyProviders) { Text($0.label).tag($0.id) } }
                        Section("OAuth") { ForEach(oauthProviders) { Text($0.label).tag($0.id) } }
                        Section("AWS") { ForEach(awsProviders) { Text($0.label).tag($0.id) } }
                    }
                    .pickerStyle(.inline)
                }
            }
            if option?.kind == .apiKey {
                divider
                FieldRow(label: "API Key") {
                    SecretField(placeholder: "Leave blank to keep current", text: $draft.apiKey)
                }
            }
            if option?.needsBaseUrl == true {
                divider
                FieldRow(label: "API URL") {
                    TextField("https://…", text: $draft.apiBaseUrl)
                        .font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            divider
            FieldRow(label: "Model") {
                TextField("moonshotai/kimi-k2", text: $draft.model)
                    .font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: LocalizedStringKey {
        switch option?.kind {
        case .oauth: return "This provider uses OAuth — run hermes setup on the desktop to sign in."
        case .aws: return "Uses the AWS credential chain on the server."
        default: return "API key is saved to ~/.hermes/.env. Leave blank to keep the stored key."
        }
    }

    /// On provider switch, restore the key/url only when returning to the
    /// configured provider; otherwise clear so one provider's secret never leaks
    /// into another's env var (mirrors the web handler).
    private func setProvider(_ value: String) {
        let projected = AgentConfig.parseHermes(draft.configText)
        let same = value == projected.provider
        draft.hermesProvider = value
        draft.apiKey = same ? projected.apiKey : ""
        draft.apiBaseUrl = same ? projected.baseUrl : ""
    }
}
