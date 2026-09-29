import Foundation

// Per-agent-type configuration codec, ported from the web `acp-agent-settings.tsx`.
// The web keeps `configText` (config.json) + `envText` (flat env) as the source of
// truth, patched incrementally as structured fields change; this file mirrors that
// exactly so the iOS structured forms produce byte-equivalent server payloads.
// Codex's TOML codec lives in AgentConfigTOML.swift.
//
// SECURITY: agent config round-trips CLEARTEXT secrets (the server returns them
// unmasked, unlike model providers). Everything here is pure string/JSON
// transformation held in-memory only — nothing is persisted on device.

// MARK: - Enums

enum ClaudeAuthMode: String, CaseIterable, Sendable, Hashable {
    case officialSubscription = "official_subscription"
    case custom
    case modelProvider = "model_provider"
}

enum CodexAuthMode: String, Sendable, Hashable {
    case apiKey = "api_key"
    case chatgptSubscription = "chatgpt_subscription"
    case modelProvider = "model_provider"
}

enum GeminiAuthMode: String, CaseIterable, Sendable, Hashable {
    case custom
    case loginGoogle = "login_google"
    case geminiApiKey = "gemini_api_key"
    case vertexAdc = "vertex_adc"
    case vertexServiceAccount = "vertex_service_account"
    case vertexApiKey = "vertex_api_key"
    case modelProvider = "model_provider"
}

/// `""` is the canonical "default" (server may also send the sentinel `"default"`).
enum ClaudeEffortLevel: String, CaseIterable, Sendable, Hashable {
    case `default` = ""
    case low, medium, high, xhigh
}

enum CodexReasoningEffort: String, CaseIterable, Sendable, Hashable {
    case low, medium, high, xhigh
    static let fallback: CodexReasoningEffort = .high
}

/// CodeBuddy's region/deployment selector. `internal`/`ioa` are written verbatim
/// to `CODEBUDDY_INTERNET_ENVIRONMENT`; `overseas` leaves that key UNSET (the
/// overseas build requires absence, not an empty value); `selfHosted` instead
/// writes `CODEBUDDY_BASE_URL` and clears the region key. Mirrors the web
/// `CodeBuddyEnvironment`.
enum CodeBuddyEnvironment: String, CaseIterable, Sendable, Hashable {
    case overseas
    case `internal`
    case ioa
    case selfHosted = "self_hosted"
}

// MARK: - Constants (env key maps + option lists, verbatim from web)

enum AgentEnvKeys {
    static let claudeMainModel = "ANTHROPIC_MODEL"
    static let claudeReasoningModel = "ANTHROPIC_REASONING_MODEL"
    static let claudeDefaultHaikuModel = "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    static let claudeDefaultSonnetModel = "ANTHROPIC_DEFAULT_SONNET_MODEL"
    static let claudeDefaultOpusModel = "ANTHROPIC_DEFAULT_OPUS_MODEL"
    static let claudeEffortConfigKey = "effortLevel"

    enum Gemini {
        static let baseUrl = "GOOGLE_GEMINI_BASE_URL"
        static let legacyBaseUrl = "GEMINI_BASE_URL"
        static let geminiApiKey = "GEMINI_API_KEY"
        static let legacyGeminiApiKey = "GOOGLE_GEMINI_API_KEY"
        static let googleApiKey = "GOOGLE_API_KEY"
        static let cloudProject = "GOOGLE_CLOUD_PROJECT"
        static let cloudProjectLegacy = "GOOGLE_CLOUD_PROJECT_ID"
        static let cloudLocation = "GOOGLE_CLOUD_LOCATION"
        static let applicationCredentials = "GOOGLE_APPLICATION_CREDENTIALS"
        static let model = "GEMINI_MODEL"
    }

    enum OpenClaw {
        static let gatewayUrl = "OPENCLAW_GATEWAY_URL"
        static let gatewayToken = "OPENCLAW_GATEWAY_TOKEN"
        static let sessionKey = "OPENCLAW_SESSION_KEY"
    }

    enum CodeBuddy {
        static let apiKey = "CODEBUDDY_API_KEY"
        static let environment = "CODEBUDDY_INTERNET_ENVIRONMENT"
        static let baseUrl = "CODEBUDDY_BASE_URL"
    }

    /// Priority-ordered env keys per agent for the generic apiBaseUrl/apiKey/model
    /// (the FIRST is the canonical write target). Mirrors `importantEnvKeysByAgent`.
    static func important(_ agent: AgentType) -> (apiBaseUrl: [String], apiKey: [String], model: [String]) {
        switch agent {
        case .claudeCode:
            return (["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "API_BASE_URL"],
                    ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
                    ["ANTHROPIC_MODEL", "OPENAI_MODEL", "MODEL"])
        case .gemini:
            return (["GOOGLE_GEMINI_BASE_URL", "GEMINI_BASE_URL", "API_BASE_URL"],
                    ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GEMINI_API_KEY", "API_KEY"],
                    ["GEMINI_MODEL", "MODEL"])
        case .grok:
            // Grok reads XAI_API_KEY only (the generic API_KEY alias is NOT read by
            // Grok — including it would falsely report "configured"). Model/endpoint
            // have working env overrides but aren't surfaced in the panel.
            return (["GROK_XAI_API_BASE_URL", "XAI_API_BASE_URL", "API_BASE_URL"],
                    ["XAI_API_KEY"],
                    ["GROK_DEFAULT_MODEL", "MODEL"])
        case .cursor:
            // cursor-agent authenticates against Cursor's own backend only: no
            // bring-your-own endpoint (so no base-url keys at all), and the
            // generic API_KEY alias is excluded so auth status can't false-positive.
            return ([],
                    ["CURSOR_API_KEY"],
                    ["CURSOR_MODEL"])
        case .deepSeek:
            // DEEPSEEK_BASE_URL is the endpoint knob; DEEPSEEK_ACP_PROVIDER is a
            // provider ROUTE id, not a URL — it must not feed the base-url slot.
            // Generic OPENAI_*/API_KEY aliases are not read by the harness.
            return (["DEEPSEEK_BASE_URL"],
                    ["DEEPSEEK_API_KEY"],
                    ["DEEPSEEK_ACP_MODEL"])
        case .qoder:
            // Qoder talks only to its own service: no endpoint var at all. The
            // PAT is the only headless credential; QODER_MODEL is -m/--model.
            return ([],
                    ["QODER_PERSONAL_ACCESS_TOKEN"],
                    ["QODER_MODEL"])
        case .antigravity:
            // Credentials vary by auth method; the superset of what any method
            // reads, so the generic "configured" probe stays honest. (The web
            // panel has no generic important-keys entry for Antigravity — its
            // auth panel owns all five keys.)
            return ([],
                    ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
                    [])
        default:
            return (["OPENAI_BASE_URL", "API_BASE_URL"],
                    ["OPENAI_API_KEY", "API_KEY"],
                    ["OPENAI_MODEL", "MODEL"])
        }
    }
}

/// `value`/`label` for the Cline provider picker (verbatim from web).
let clineProviders: [(value: String, label: String)] = [
    ("anthropic", "Anthropic"),
    ("openai-native", "OpenAI"),
    ("openai", "OpenAI Compatible"),
    ("openrouter", "OpenRouter"),
    ("gemini", "Gemini"),
    ("deepseek", "DeepSeek"),
    ("bedrock", "AWS Bedrock"),
    ("vertex", "GCP Vertex"),
    ("ollama", "Ollama"),
]

let codexReasoningEffortOptions: [(value: CodexReasoningEffort, label: String, description: String)] = [
    (.low, "Low", "Fast responses with lighter reasoning"),
    (.medium, "Medium", "Balances speed and reasoning depth for everyday tasks"),
    (.high, "High", "Greater reasoning depth for complex problems"),
    (.xhigh, "Extra High", "Extra-high reasoning depth for the hardest problems"),
]

let codexDefaultModelProvider = "codeg"

/// OpenCode provider npm packages (verbatim from web). The first is the default
/// filled in by ``AgentConfig/ensureOpenCodeProviderNpm(_:)``.
let openCodeNpmOptions: [String] = [
    "@ai-sdk/openai-compatible", "@ai-sdk/cerebras", "@ai-sdk/azure", "@ai-sdk/xai",
    "@ai-sdk/anthropic", "@ai-sdk/amazon-bedrock", "@ai-sdk/google", "@ai-sdk/google-vertex",
    "@ai-sdk/deepseek",
]

// MARK: - JSON primitives

enum JSONConfig {
    /// Parse a config.json string. Returns `([:], nil)` for empty; `([:], error)`
    /// for invalid/non-object; `(dict, nil)` otherwise.
    static func parse(_ text: String) -> (config: [String: Any], error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ([:], nil) }
        guard let data = trimmed.data(using: .utf8) else {
            return ([:], "Native JSON config format error")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                return ([:], "Native JSON config must be an object")
            }
            return (dict, nil)
        } catch {
            return ([:], "Native JSON config format error: \(error.localizedDescription)")
        }
    }

    /// `JSON.stringify(obj, null, 2)` equivalent. Empty object → "". Keys sorted
    /// for deterministic output (the web preserves insertion order; ordering is
    /// cosmetic since the server re-parses — sorting avoids spurious diffs).
    static func serialize(_ obj: [String: Any]) -> String {
        if obj.isEmpty { return "" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Recursive `markRemovedKeysNull`: any key present in `original` but absent in
    /// `current` is set to `NSNull()` so the backend's merge deletes it from disk;
    /// nested objects recurse. Used by claude/gemini/open_claw (merge agents).
    static func markRemovedKeysNull(original: [String: Any], current: [String: Any]) -> [String: Any] {
        var result = current
        for key in original.keys {
            if result[key] == nil {
                result[key] = NSNull()
            } else if let origChild = original[key] as? [String: Any],
                      let curChild = result[key] as? [String: Any] {
                result[key] = markRemovedKeysNull(original: origChild, current: curChild)
            }
        }
        return result
    }

    /// Parse + reserialize (drops to "" when empty). Mirrors `normalizeConfigText`
    /// but on invalid input returns the trimmed original rather than recovering.
    static func normalize(_ text: String) -> String {
        let parsed = parse(text)
        if parsed.error != nil { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parsed.config.isEmpty { return "" }
        return serialize(parsed.config)
    }

    /// Read `config.env` (the nested env object) as a trimmed string map.
    static func envFromConfig(_ config: [String: Any]) -> [String: String] {
        guard let raw = config["env"] as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in raw {
            guard let s = value as? String else { continue }
            let k = key.trimmingCharacters(in: .whitespaces)
            let v = s.trimmingCharacters(in: .whitespaces)
            if k.isEmpty || v.isEmpty { continue }
            map[k] = v
        }
        return map
    }

    static func pickFirstString(_ source: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let s = source[key] as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }
}

// MARK: - Env-text primitives

enum EnvText {
    static func toText(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    static func parse(_ envText: String) -> [String: String] {
        var map: [String: String] = [:]
        for rawLine in envText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let idx = line.firstIndex(of: "="), idx != line.startIndex else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            map[key] = value
        }
        return map
    }

    /// The value of one key in an env-text draft, or "" when absent.
    static func value(of key: String, in envText: String) -> String {
        parse(envText)[key] ?? ""
    }

    /// The env-text draft with one key set (trimmed-empty deletes the line).
    static func setting(_ key: String, to value: String, in envText: String) -> String {
        patch(envText, [key: value])
    }

    /// Apply a patch: trimmed-empty value deletes the key. Mirrors `patchEnvText`.
    static func patch(_ envText: String, _ patch: [String: String?]) -> String {
        var map = parse(envText)
        for (key, value) in patch {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { map.removeValue(forKey: key) }
            else { map[key] = trimmed }
        }
        return toText(map)
    }

    static func find(_ env: [String: String], _ keys: [String]) -> String {
        for key in keys {
            if let v = env[key] {
                let t = v.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }
}

// MARK: - AgentDraft (the editable per-type form state; mirrors web `AgentDraft`)

struct AgentDraft: Equatable, Sendable {
    var enabled: Bool = true
    /// Raw flat env (`acp_update_agent_env`) — the source of truth, kept in lockstep
    /// with structured fields.
    var envText: String = ""
    /// Raw config.json (`acp_update_agent_config`) — source of truth for the
    /// structured fields + the native-config editor.
    var configText: String = ""
    var modelProviderId: Int?

    // Shared important
    var apiBaseUrl = ""
    var apiKey = ""
    var model = ""

    // Claude
    var claudeAuthMode: ClaudeAuthMode = .officialSubscription
    var claudeMainModel = ""
    var claudeReasoningModel = ""
    var claudeDefaultHaikuModel = ""
    var claudeDefaultSonnetModel = ""
    var claudeDefaultOpusModel = ""
    var claudeEffortLevel: ClaudeEffortLevel = .default

    // Codex
    var codexAuthMode: CodexAuthMode = .apiKey
    var codexReasoningEffort: CodexReasoningEffort = .high
    var codexSupportsWebsockets = false
    var codexSkills = false
    var codexServiceTierFast = false
    var codexAuthJsonText = ""
    var codexConfigTomlText = ""

    // Gemini
    var geminiAuthMode: GeminiAuthMode = .loginGoogle
    var geminiApiKey = ""
    var googleApiKey = ""
    var googleCloudProject = ""
    var googleCloudLocation = ""
    var googleApplicationCredentials = ""

    // OpenClaw
    var openClawGatewayUrl = ""
    var openClawGatewayToken = ""
    var openClawSessionKey = ""

    // CodeBuddy (env-only, like OpenClaw). `apiKey` is reused for CODEBUDDY_API_KEY.
    var codeBuddyEnvironment: CodeBuddyEnvironment = .overseas
    var codeBuddyBaseUrl = ""

    // Grok. `apiKey` is reused for XAI_API_KEY (env). The two structured controls
    // (`""` = "use default") + the raw config.toml escape hatch are persisted via
    // `acp_update_agent_config` (grok_structured / grok_config_toml), NOT env.
    var grokPermissionMode = ""
    var grokReasoningEffort = ""
    var grokConfigTomlText = ""

    // Cursor. `apiKey` is reused for CURSOR_API_KEY. The auth method, model and
    // Run Everything knob ride the env; the sandbox mode + permission rules are a
    // structured patch on cli-config.json, and the raw file is the escape hatch —
    // both persisted via `acp_update_agent_config` (cursor_structured /
    // cursor_cli_config_json).
    var cursorAuthMode: CursorConfig.AuthMethod = .subscription
    var cursorModel = ""
    var cursorForce = true
    var cursorSandboxMode = ""
    var cursorAllowRules: [String] = []
    var cursorDenyRules: [String] = []
    var cursorCliConfigText = ""

    // Cline
    var clineProvider = "anthropic"
    var clineApiKey = ""
    var clineModel = ""
    var clineBaseUrl = ""

    // OpenCode / Hermes raw payloads (structured editing lives in B7)
    var openCodeAuthJsonText = ""
    var hermesProvider = "openrouter"
    var hermesConfigYaml = ""
}

extension AgentDraft {
    /// Re-bake the structured fields into `configText`/`envText` (and codex
    /// toml/auth) so the raw editors + the save payload stay in sync. Call after any
    /// structured field edit. Idempotent.
    mutating func reapply(_ agentType: AgentType) {
        let applied = AgentConfig.reapply(agentType, self)
        configText = applied.configText
        envText = applied.envText
        codexConfigTomlText = applied.codexConfigTomlText
        codexAuthJsonText = applied.codexAuthJsonText
    }

    /// Port of `buildAgentDraft`: reconstruct the editable form from a stored agent.
    init(agent: AcpAgentInfo) {
        let configText = (agent.configJson?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (agent.configJson ?? "") : ""
        let env = agent.env ?? [:]

        self.enabled = agent.enabled
        self.configText = configText
        self.envText = EnvText.toText(env)
        self.modelProviderId = agent.modelProviderId
        self.openCodeAuthJsonText = agent.opencodeAuthJson ?? ""
        self.hermesConfigYaml = agent.hermesConfigYaml ?? ""

        // codex config.toml always carries disable_response_storage=true (read-side
        // injection keeps a round-trip stable — see AgentConfigTOML).
        let codexToml = agent.agentType == .codex
            ? AgentTOML.setRootBool(agent.codexConfigToml ?? "", "disable_response_storage", true)
            : (agent.codexConfigToml ?? "")
        self.codexConfigTomlText = codexToml
        self.codexAuthJsonText = agent.codexAuthJson ?? ""

        let important = AgentConfig.extractImportant(agent.agentType, env: env, configText: configText)
        let gemini = AgentConfig.extractGemini(env: env, configText: configText)
        let openClaw = AgentConfig.extractOpenClaw(env: env, configText: configText)
        let cline = AgentConfig.extractCline(configText: configText)
        let codex = AgentTOML.extractCodex(authJsonText: codexAuthJsonText, configTomlText: codexToml)

        // Shared important (per-type source)
        switch agent.agentType {
        case .codex:   self.apiBaseUrl = codex.apiBaseUrl
        case .gemini:  self.apiBaseUrl = gemini.apiBaseUrl
        default:       self.apiBaseUrl = important.apiBaseUrl
        }
        switch agent.agentType {
        case .codex:   self.apiKey = codex.apiKey ?? ""
        case .gemini:  self.apiKey = gemini.geminiApiKey.isEmpty ? gemini.googleApiKey : gemini.geminiApiKey
        default:       self.apiKey = important.apiKey
        }
        switch agent.agentType {
        case .codex:   self.model = codex.model
        case .gemini:  self.model = gemini.model
        default:       self.model = important.model
        }

        // Claude
        if agent.agentType == .claudeCode {
            self.claudeAuthMode = agent.modelProviderId != nil ? .modelProvider
                : (!important.apiBaseUrl.isEmpty || !important.apiKey.isEmpty) ? .custom
                : .officialSubscription
            self.claudeMainModel = important.claudeMainModel
            self.claudeReasoningModel = important.claudeReasoningModel
            self.claudeDefaultHaikuModel = important.claudeDefaultHaikuModel
            self.claudeDefaultSonnetModel = important.claudeDefaultSonnetModel
            self.claudeDefaultOpusModel = important.claudeDefaultOpusModel
            self.claudeEffortLevel = important.claudeEffortLevel
        }

        // Codex
        if agent.agentType == .codex {
            self.codexAuthMode = agent.modelProviderId != nil ? .modelProvider
                : AgentTOML.inferCodexAuthMode(codexAuthJsonText)
            self.codexReasoningEffort = codex.reasoningEffort
            self.codexSupportsWebsockets = codex.supportsWebsockets
            self.codexSkills = codex.skills
            self.codexServiceTierFast = codex.serviceTierFast
        }

        // Gemini
        if agent.agentType == .gemini {
            self.geminiAuthMode = agent.modelProviderId != nil ? .modelProvider : gemini.authMode
            self.geminiApiKey = gemini.geminiApiKey
            self.googleApiKey = gemini.googleApiKey
            self.googleCloudProject = gemini.googleCloudProject
            self.googleCloudLocation = gemini.googleCloudLocation
            self.googleApplicationCredentials = gemini.googleApplicationCredentials
        }

        // OpenClaw
        if agent.agentType == .openClaw {
            self.openClawGatewayUrl = openClaw.gatewayUrl
            self.openClawGatewayToken = openClaw.gatewayToken
            self.openClawSessionKey = openClaw.sessionKey
        }

        // CodeBuddy: API key + region/base-url derive from CODEBUDDY_* env (the
        // shared `apiKey` set above reads the wrong keys for this agent — override).
        if agent.agentType == .codeBuddy {
            let cb = AgentConfig.extractCodeBuddy(env: env)
            self.apiKey = cb.apiKey
            self.codeBuddyEnvironment = cb.environment
            self.codeBuddyBaseUrl = cb.baseUrl
        }

        // Cline
        if agent.agentType == .cline {
            self.clineProvider = cline.provider
            self.clineApiKey = cline.apiKey
            self.clineModel = cline.model
            self.clineBaseUrl = cline.baseUrl
        }

        // Grok: `apiKey` (XAI_API_KEY) is already set via the shared `important`
        // branch above (its key list is Grok-specific); seed the structured
        // controls + raw config.toml from the backend's parsed projection.
        if agent.agentType == .grok {
            self.grokPermissionMode = agent.grokSettings?.permissionMode ?? ""
            self.grokReasoningEffort = agent.grokSettings?.defaultReasoningEffort ?? ""
            self.grokConfigTomlText = agent.grokConfigToml ?? ""
        }

        // Cursor: `apiKey` (CURSOR_API_KEY) comes from the shared `important`
        // branch; the rest is read straight off the env plus the backend's parsed
        // cli-config.json projection.
        if agent.agentType == .cursor {
            let env = agent.env ?? [:]
            self.cursorAuthMode = CursorConfig.inferMode(env)
            self.cursorModel = (env[CursorConfig.modelEnv] ?? "").trimmingCharacters(in: .whitespaces)
            // A fresh Cursor agent defaults to Run Everything; only an explicitly
            // written knob (incl. "0" = "ask before running") overrides that.
            self.cursorForce = CursorConfig.hasForceKnob(env) ? CursorConfig.isForceEnabled(env) : true
            self.cursorSandboxMode = agent.cursorSettings?.sandboxMode ?? ""
            self.cursorAllowRules = agent.cursorSettings?.permissionsAllow ?? []
            self.cursorDenyRules = agent.cursorSettings?.permissionsDeny ?? []
            self.cursorCliConfigText = agent.cursorCliConfigJson ?? ""
        }

        // Hermes: the projection carries provider/model/baseUrl/apiKey.
        if agent.agentType == .hermes {
            let h = AgentConfig.parseHermes(configText)
            self.hermesProvider = h.provider
            self.apiBaseUrl = h.baseUrl
            self.apiKey = h.apiKey
            self.model = h.model
        }
    }
}

// MARK: - Codec (extract = read; reapply = write)

enum AgentConfig {

    /// Agents whose config.json is merged on save (removed keys → null so the
    /// backend deletes them). Everyone else replaces wholesale. Mirrors the web
    /// `usesMerge` set.
    static func usesMerge(_ agent: AgentType) -> Bool {
        agent == .claudeCode || agent == .gemini || agent == .openClaw
    }

    /// True when the agent is in model_provider auth mode but no provider is
    /// selected — the save must be blocked (web `selectedMissingModelProvider`).
    static func missingModelProvider(_ agent: AgentType, _ draft: AgentDraft) -> Bool {
        guard draft.modelProviderId == nil else { return false }
        switch agent {
        case .claudeCode: return draft.claudeAuthMode == .modelProvider
        case .codex: return draft.codexAuthMode == .modelProvider
        case .gemini: return draft.geminiAuthMode == .modelProvider
        default: return false
        }
    }

    /// Fill a default npm package for any open_code provider missing one (web
    /// `ensureOpenCodeProviderNpm`, applied before persist).
    static func ensureOpenCodeProviderNpm(_ configText: String) -> String {
        var config = JSONConfig.parse(configText).config
        guard var providers = config["provider"] as? [String: Any] else { return configText }
        var changed = false
        for (id, raw) in providers {
            guard var p = raw as? [String: Any] else { continue }
            let npm = (p["npm"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if npm.isEmpty {
                p["npm"] = openCodeNpmOptions[0]
                providers[id] = p
                changed = true
            }
        }
        guard changed else { return configText }
        config["provider"] = providers
        return JSONConfig.serialize(config)
    }

    // ---- Extract (read structured fields from stored config/env) ----

    struct ImportantValues {
        var apiBaseUrl = "", apiKey = "", model = ""
        var claudeMainModel = "", claudeReasoningModel = ""
        var claudeDefaultHaikuModel = "", claudeDefaultSonnetModel = "", claudeDefaultOpusModel = ""
        var claudeEffortLevel: ClaudeEffortLevel = .default
    }

    static func extractImportant(_ agent: AgentType, env: [String: String], configText: String) -> ImportantValues {
        let config = JSONConfig.parse(configText).config
        let keys = AgentEnvKeys.important(agent)
        let merged = env.merging(JSONConfig.envFromConfig(config)) { _, new in new }

        var v = ImportantValues()
        v.apiBaseUrl = JSONConfig.pickFirstString(config, ["apiBaseUrl", "api_base_url"]) ?? EnvText.find(merged, keys.apiBaseUrl)
        v.apiKey = JSONConfig.pickFirstString(config, ["apiKey", "api_key"]) ?? EnvText.find(merged, keys.apiKey)
        v.model = JSONConfig.pickFirstString(config, ["model", "model_name"]) ?? EnvText.find(merged, keys.model)
        if agent == .claudeCode {
            v.claudeMainModel = EnvText.find(merged, [AgentEnvKeys.claudeMainModel])
            v.claudeReasoningModel = EnvText.find(merged, [AgentEnvKeys.claudeReasoningModel])
            v.claudeDefaultHaikuModel = EnvText.find(merged, [AgentEnvKeys.claudeDefaultHaikuModel])
            v.claudeDefaultSonnetModel = EnvText.find(merged, [AgentEnvKeys.claudeDefaultSonnetModel])
            v.claudeDefaultOpusModel = EnvText.find(merged, [AgentEnvKeys.claudeDefaultOpusModel])
            v.claudeEffortLevel = normalizeClaudeEffort(config[AgentEnvKeys.claudeEffortConfigKey])
        }
        return v
    }

    private static func normalizeClaudeEffort(_ value: Any?) -> ClaudeEffortLevel {
        guard let s = value as? String else { return .default }
        let n = s.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty || n == "default" { return .default }
        return ClaudeEffortLevel(rawValue: n) ?? .default
    }

    struct GeminiValues {
        var authMode: GeminiAuthMode = .loginGoogle
        var apiBaseUrl = "", geminiApiKey = "", googleApiKey = ""
        var googleCloudProject = "", googleCloudLocation = "", googleApplicationCredentials = ""
        var model = ""
    }

    static func extractGemini(env: [String: String], configText: String) -> GeminiValues {
        let config = JSONConfig.parse(configText).config
        let merged = env.merging(JSONConfig.envFromConfig(config)) { _, new in new }
        let K = AgentEnvKeys.Gemini.self
        var v = GeminiValues()
        v.apiBaseUrl = EnvText.find(merged, [K.baseUrl, K.legacyBaseUrl, "API_BASE_URL"])
        v.geminiApiKey = EnvText.find(merged, [K.geminiApiKey, K.legacyGeminiApiKey])
        v.googleApiKey = EnvText.find(merged, [K.googleApiKey])
        v.googleCloudProject = EnvText.find(merged, [K.cloudProject, K.cloudProjectLegacy])
        v.googleCloudLocation = EnvText.find(merged, [K.cloudLocation])
        v.googleApplicationCredentials = EnvText.find(merged, [K.applicationCredentials])
        v.model = EnvText.find(merged, [K.model, "MODEL"])
        v.authMode = inferGeminiAuthMode(v)
        return v
    }

    static func inferGeminiAuthMode(_ v: GeminiValues) -> GeminiAuthMode {
        if !v.apiBaseUrl.trimmed.isEmpty { return .custom }
        if !v.geminiApiKey.trimmed.isEmpty { return .geminiApiKey }
        if !v.googleApiKey.trimmed.isEmpty { return .vertexApiKey }
        if !v.googleApplicationCredentials.trimmed.isEmpty { return .vertexServiceAccount }
        if !v.googleCloudProject.trimmed.isEmpty || !v.googleCloudLocation.trimmed.isEmpty { return .vertexAdc }
        return .loginGoogle
    }

    struct OpenClawValues { var gatewayUrl = "", gatewayToken = "", sessionKey = "" }

    static func extractOpenClaw(env: [String: String], configText: String) -> OpenClawValues {
        let config = JSONConfig.parse(configText).config
        let merged = env.merging(JSONConfig.envFromConfig(config)) { _, new in new }
        let K = AgentEnvKeys.OpenClaw.self
        return OpenClawValues(
            gatewayUrl: EnvText.find(merged, [K.gatewayUrl]),
            gatewayToken: EnvText.find(merged, [K.gatewayToken]),
            sessionKey: EnvText.find(merged, [K.sessionKey])
        )
    }

    struct CodeBuddyValues {
        var apiKey = ""
        var environment: CodeBuddyEnvironment = .overseas
        var baseUrl = ""
    }

    /// Read CodeBuddy's structured fields from the flat env. A non-empty
    /// `CODEBUDDY_BASE_URL` implies self-hosted; otherwise the region comes from
    /// `CODEBUDDY_INTERNET_ENVIRONMENT` (`internal`/`ioa`), defaulting to overseas.
    /// Mirrors the web `codeBuddyEnvironmentFromEnv`.
    static func extractCodeBuddy(env: [String: String]) -> CodeBuddyValues {
        let K = AgentEnvKeys.CodeBuddy.self
        var v = CodeBuddyValues()
        v.apiKey = EnvText.find(env, [K.apiKey])
        v.baseUrl = EnvText.find(env, [K.baseUrl])
        if !v.baseUrl.trimmed.isEmpty {
            v.environment = .selfHosted
        } else {
            let raw = EnvText.find(env, [K.environment]).lowercased()
            v.environment = CodeBuddyEnvironment(rawValue: raw).map {
                $0 == .selfHosted ? .overseas : $0   // self_hosted is BASE_URL-derived only
            } ?? .overseas
        }
        return v
    }

    struct ClineValues { var provider = "anthropic", apiKey = "", model = "", baseUrl = "" }

    static func extractCline(configText: String) -> ClineValues {
        let config = JSONConfig.parse(configText).config
        return ClineValues(
            provider: (config["apiProvider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "anthropic",
            apiKey: config["apiKey"] as? String ?? "",
            model: config["model"] as? String ?? "",
            baseUrl: config["apiBaseUrl"] as? String ?? ""
        )
    }

    // ---- Reapply (write structured fields back into config/env strings) ----

    /// The recomputed raw payloads for an agent type after a structured edit.
    struct Applied: Equatable, Sendable {
        var configText: String
        var envText: String
        var codexConfigTomlText: String
        var codexAuthJsonText: String
    }

    /// Recompute config/env (and codex toml/auth) from the draft's structured
    /// fields, preserving unknown keys in the existing `configText`. In
    /// model_provider mode the typed url/key are NOT written (the server resolves
    /// the provider link from `modelProviderId`; iOS never has the provider's real
    /// key — it's masked). Idempotent.
    static func reapply(_ agent: AgentType, _ draft: AgentDraft) -> Applied {
        var out = Applied(configText: draft.configText, envText: draft.envText,
                          codexConfigTomlText: draft.codexConfigTomlText,
                          codexAuthJsonText: draft.codexAuthJsonText)
        let linked = draft.modelProviderId != nil
        switch agent {
        case .claudeCode:
            // Linked: the provider supplies endpoint/key/model and iOS only holds the
            // provider's MASKED key — so SCRUB the manual url/key/models so no stale
            // secret is persisted; the server resolves everything from modelProviderId.
            var d = draft
            if linked {
                d.apiBaseUrl = ""; d.apiKey = ""
                d.claudeMainModel = ""; d.claudeReasoningModel = ""
                d.claudeDefaultHaikuModel = ""; d.claudeDefaultSonnetModel = ""; d.claudeDefaultOpusModel = ""
            }
            out.configText = applyClaudeConfig(draft.configText, d)
            out.envText = applyClaudeEnv(draft.envText, d)
            out.configText = applyClaudeEffort(out.configText, draft.claudeEffortLevel)
        case .gemini:
            var d = draft
            if linked {
                d.apiBaseUrl = ""; d.geminiApiKey = ""; d.googleApiKey = ""
                d.googleCloudProject = ""; d.googleCloudLocation = ""; d.googleApplicationCredentials = ""
                d.model = ""
            }
            out.configText = applyGeminiConfig(draft.configText, d)
            out.envText = applyGeminiEnv(draft.envText, d)
        case .openClaw:
            out.envText = applyOpenClawEnv(draft.envText, draft)
        case .codeBuddy:
            out.envText = applyCodeBuddyEnv(draft.envText, draft)
        case .grok:
            // Only XAI_API_KEY rides the env; the structured controls + raw toml
            // are persisted via acp_update_agent_config, not baked into envText.
            out.envText = applyGrokEnv(draft.envText, draft)
        case .cursor:
            // Auth method / credential / model / Run Everything ride the env; the
            // sandbox + permission rules are persisted via acp_update_agent_config.
            out.envText = CursorConfig.applyEnv(draft.envText,
                                                mode: draft.cursorAuthMode,
                                                apiKey: draft.apiKey,
                                                model: draft.cursorModel,
                                                force: draft.cursorForce)
        case .cline:
            out.configText = buildClineConfig(draft)
        case .codex:
            var d = draft
            if linked { d.apiBaseUrl = ""; d.model = "" }   // scrub provider-managed
            out.codexConfigTomlText = AgentTOML.patchCodex(draft.codexConfigTomlText, d)
            // api_key mode owns OPENAI_API_KEY (linked → clear it); a
            // chatgpt-subscription OAuth auth.json is left untouched (A9).
            if linked {
                out.codexAuthJsonText = AgentTOML.patchCodexAuth(draft.codexAuthJsonText, apiKey: "")
            } else if draft.codexAuthMode == .apiKey {
                out.codexAuthJsonText = AgentTOML.patchCodexAuth(draft.codexAuthJsonText, apiKey: draft.apiKey)
            }
        default:
            break
        }
        return out
    }

    // Claude: url/key + 5 models → config.env; effortLevel → config root.
    private static func applyClaudeConfig(_ configText: String, _ d: AgentDraft) -> String {
        var config = JSONConfig.parse(configText).config
        var env = (config["env"] as? [String: Any]) ?? [:]
        func assignEnv(_ key: String, _ value: String) {
            let t = value.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { env.removeValue(forKey: key) } else { env[key] = t }
        }
        // Legacy root cleanup — Claude values belong under config.env, so strip any
        // stale root landing keys that would otherwise shadow them on next read.
        for key in ["apiBaseUrl", "apiKey", "api_base_url", "api_key", "model", "model_name"] {
            config.removeValue(forKey: key)
        }
        assignEnv("ANTHROPIC_BASE_URL", d.apiBaseUrl)
        assignEnv("ANTHROPIC_AUTH_TOKEN", d.apiKey)
        assignEnv("ANTHROPIC_MODEL", d.claudeMainModel)
        assignEnv("ANTHROPIC_REASONING_MODEL", d.claudeReasoningModel)
        assignEnv("ANTHROPIC_DEFAULT_HAIKU_MODEL", d.claudeDefaultHaikuModel)
        assignEnv("ANTHROPIC_DEFAULT_SONNET_MODEL", d.claudeDefaultSonnetModel)
        assignEnv("ANTHROPIC_DEFAULT_OPUS_MODEL", d.claudeDefaultOpusModel)
        if env.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = env }
        return JSONConfig.serialize(config)
    }

    private static func applyClaudeEnv(_ envText: String, _ d: AgentDraft) -> String {
        EnvText.patch(envText, [
            "ANTHROPIC_BASE_URL": d.apiBaseUrl, "ANTHROPIC_AUTH_TOKEN": d.apiKey,
            "ANTHROPIC_MODEL": d.claudeMainModel, "ANTHROPIC_REASONING_MODEL": d.claudeReasoningModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": d.claudeDefaultHaikuModel,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": d.claudeDefaultSonnetModel,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": d.claudeDefaultOpusModel,
        ])
    }

    private static func applyClaudeEffort(_ configText: String, _ level: ClaudeEffortLevel) -> String {
        var config = JSONConfig.parse(configText).config
        if level == .default { config.removeValue(forKey: AgentEnvKeys.claudeEffortConfigKey) }
        else { config[AgentEnvKeys.claudeEffortConfigKey] = level.rawValue }
        return JSONConfig.serialize(config)
    }

    /// Every Claude url/key env alias (not just the canonical pair). Mirrors the web
    /// `handleClaudeAuthModeChange` official-subscription branch's `allEnvKeys`.
    static let claudeCredentialAliasKeys = [
        "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "API_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
    ]

    /// Strip every Claude url/key alias from BOTH the flat env and `config.env`.
    /// `reapply` only clears the canonical `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`,
    /// so switching to the official subscription would otherwise leave a stale alias
    /// (e.g. `OPENAI_BASE_URL`) behind — which `extractImportant` re-reads on the next
    /// load and flips the mode back to "custom". Empty `config.env` is dropped.
    static func clearClaudeCredentialAliases(configText: String, envText: String) -> (config: String, env: String) {
        var envPatch: [String: String?] = [:]
        for key in claudeCredentialAliasKeys { envPatch[key] = "" }
        let env = EnvText.patch(envText, envPatch)

        var config = JSONConfig.parse(configText).config
        if var cfgEnv = config["env"] as? [String: Any] {
            for key in claudeCredentialAliasKeys { cfgEnv.removeValue(forKey: key) }
            if cfgEnv.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = cfgEnv }
        }
        return (JSONConfig.serialize(config), env)
    }

    // Gemini: write into config.env AND flat env (lockstep), clearing legacy keys.
    private static func applyGeminiConfig(_ configText: String, _ d: AgentDraft) -> String {
        var config = JSONConfig.parse(configText).config
        var env = (config["env"] as? [String: Any]) ?? [:]
        let K = AgentEnvKeys.Gemini.self
        func assign(_ key: String, _ value: String) {
            let t = value.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { env.removeValue(forKey: key) } else { env[key] = t }
        }
        config.removeValue(forKey: "model")
        config.removeValue(forKey: "model_name")
        assign(K.model, d.model)
        assign(K.baseUrl, d.apiBaseUrl); env.removeValue(forKey: K.legacyBaseUrl)
        assign(K.geminiApiKey, d.geminiApiKey); env.removeValue(forKey: K.legacyGeminiApiKey)
        assign(K.googleApiKey, d.googleApiKey)
        assign(K.cloudProject, d.googleCloudProject); env.removeValue(forKey: K.cloudProjectLegacy)
        assign(K.cloudLocation, d.googleCloudLocation)
        assign(K.applicationCredentials, d.googleApplicationCredentials)
        if env.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = env }
        return JSONConfig.serialize(config)
    }

    private static func applyGeminiEnv(_ envText: String, _ d: AgentDraft) -> String {
        let K = AgentEnvKeys.Gemini.self
        return EnvText.patch(envText, [
            K.model: d.model,
            K.baseUrl: d.apiBaseUrl, K.legacyBaseUrl: "",
            K.geminiApiKey: d.geminiApiKey, K.legacyGeminiApiKey: "",
            K.googleApiKey: d.googleApiKey,
            K.cloudProject: d.googleCloudProject, K.cloudProjectLegacy: "",
            K.cloudLocation: d.googleCloudLocation,
            K.applicationCredentials: d.googleApplicationCredentials,
        ])
    }

    private static func applyOpenClawEnv(_ envText: String, _ d: AgentDraft) -> String {
        let K = AgentEnvKeys.OpenClaw.self
        return EnvText.patch(envText, [
            K.gatewayUrl: d.openClawGatewayUrl,
            K.gatewayToken: d.openClawGatewayToken,
            K.sessionKey: d.openClawSessionKey,
        ])
    }

    /// CodeBuddy env write (mirrors the web `buildCodeBuddyEnv`): API key set/cleared,
    /// then routed by environment — self-hosted writes a slash-stripped BASE_URL and
    /// clears the region key; overseas clears both region and BASE_URL; internal/ioa
    /// set the region and clear BASE_URL. `EnvText.patch` deletes any empty value.
    private static func applyCodeBuddyEnv(_ envText: String, _ d: AgentDraft) -> String {
        let K = AgentEnvKeys.CodeBuddy.self
        var patch: [String: String?] = [K.apiKey: d.apiKey]
        switch d.codeBuddyEnvironment {
        case .selfHosted:
            patch[K.environment] = ""
            patch[K.baseUrl] = normalizeCodeBuddyBaseUrl(d.codeBuddyBaseUrl)
        case .overseas:
            patch[K.environment] = ""
            patch[K.baseUrl] = ""
        case .internal, .ioa:
            patch[K.environment] = d.codeBuddyEnvironment.rawValue
            patch[K.baseUrl] = ""
        }
        return EnvText.patch(envText, patch)
    }

    /// Grok env write: only XAI_API_KEY (set/cleared). Base URL + model have env
    /// overrides but aren't surfaced in the panel, so they round-trip untouched in
    /// `envText`. `EnvText.patch` deletes the key when the value is empty.
    private static func applyGrokEnv(_ envText: String, _ d: AgentDraft) -> String {
        EnvText.patch(envText, ["XAI_API_KEY": d.apiKey])
    }

    /// Trim + strip trailing slashes (matches the web's `.replace(/\/+$/, "")`).
    private static func normalizeCodeBuddyBaseUrl(_ value: String) -> String {
        var s = value.trimmed
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// http(s)-URL check for the self-hosted endpoint (web `isValidCodeBuddyBaseUrl`).
    static func isValidCodeBuddyBaseUrl(_ value: String) -> Bool {
        let t = value.trimmed
        guard !t.isEmpty, let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Block a self-hosted CodeBuddy save whose Base URL isn't a valid http(s) URL.
    static func missingCodeBuddyBaseUrl(_ agent: AgentType, _ draft: AgentDraft) -> Bool {
        agent == .codeBuddy
            && draft.codeBuddyEnvironment == .selfHosted
            && !isValidCodeBuddyBaseUrl(draft.codeBuddyBaseUrl)
    }

    /// Cursor in API-key mode with nothing typed: saving would write an auth mode
    /// that has no credential to go with it, so the launch would silently fall back
    /// to the browser login. Mirrors the web's `cursor.customApiKeyRequired` guard.
    static func missingCursorApiKey(_ agent: AgentType, _ draft: AgentDraft) -> Bool {
        agent == .cursor
            && draft.cursorAuthMode == .custom
            && draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func buildClineConfig(_ d: AgentDraft) -> String {
        var config: [String: Any] = ["apiProvider": d.clineProvider]
        let key = d.clineApiKey.trimmingCharacters(in: .whitespaces)
        let model = d.clineModel.trimmingCharacters(in: .whitespaces)
        let base = d.clineBaseUrl.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { config["apiKey"] = key }
        if !model.isEmpty { config["model"] = model }
        if !base.isEmpty { config["apiBaseUrl"] = base }
        return JSONConfig.serialize(config)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
