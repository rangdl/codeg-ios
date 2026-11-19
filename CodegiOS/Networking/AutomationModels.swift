import Foundation

// MARK: - Automations (scheduled tasks)

/// Wire shape of a scheduled automation (Rust `Automation`, camelCase wire).
struct AutomationInfo: Decodable, Sendable, Identifiable {
    let id: Int
    var name: String
    var enabled: Bool
    let triggerKind: String
    let cron: String?
    let timezone: String
    let nextRunAt: Date?
    let agentType: AgentType
    let rootFolderId: Int?
    let isolation: String
    var branch: String?
    var isRemoteBranch: Bool?
    let lastRunAt: Date?
    let lastRunStatus: String?
    let lastRunConversationId: Int?
    let unseenFailures: Int?
    let createdAt: Date
    let updatedAt: Date
}

/// One historical run of an automation.
struct AutomationRunInfo: Decodable, Sendable, Identifiable {
    let id: Int
    let automationId: Int
    let status: String
    let trigger: String
    let scheduledFor: Date?
    let startedAt: Date?
    let endedAt: Date?
    let conversationId: Int?
    let stopReason: String?
    let error: String?
    let summary: String?
    let createdAt: Date
}

/// Captured composer payload the automation runs with (`AutomationConfig`).
/// The draft is sent snake_case (the server deserializes it with the Rust
/// field names verbatim — the outer envelope is camelCase but the draft is
/// not; confirmed against the live server: a camelCase draft 422s with
/// "missing field `trigger_kind`").
struct AutomationConfigBody: Encodable, Sendable {
    var action: String?
    var promptBlocks: [PromptInputBlock]
    var displayText: String
    var modeId: String?
    var configValues: [String: String]

    private enum CodingKeys: String, CodingKey {
        case action
        case promptBlocks = "prompt_blocks"
        case displayText = "display_text"
        case modeId = "mode_id"
        case configValues = "config_values"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encode(promptBlocks, forKey: .promptBlocks)
        try c.encode(displayText, forKey: .displayText)
        // mode_id is nullable-but-required: the server wants the key present
        // even when null. Same for every draft Option below.
        try c.encode(modeId, forKey: .modeId)
        try c.encode(configValues, forKey: .configValues)
    }
}

/// Create/update payload (`AutomationDraft`), snake_case keys — see
/// `AutomationConfigBody`.
struct AutomationDraftBody: Encodable, Sendable {
    var name: String
    var enabled: Bool
    var triggerKind: String
    var cron: String?
    var timezone: String
    var agentType: String
    var rootFolderId: Int?
    var isolation: String
    var branch: String?
    var isRemoteBranch: Bool?
    var config: AutomationConfigBody

    private enum CodingKeys: String, CodingKey {
        case name, enabled
        case triggerKind = "trigger_kind"
        case cron, timezone
        case agentType = "agent_type"
        case rootFolderId = "root_folder_id"
        case isolation
        case branch
        case isRemoteBranch = "is_remote_branch"
        case config
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(triggerKind, forKey: .triggerKind)
        try c.encode(cron, forKey: .cron)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(agentType, forKey: .agentType)
        try c.encode(rootFolderId, forKey: .rootFolderId)
        try c.encode(isolation, forKey: .isolation)
        try c.encode(branch, forKey: .branch)
        // Required-but-nullable: omitting the key 422s ("missing field
        // `is_remote_branch`"), so every Option encodes as null.
        try c.encode(isRemoteBranch, forKey: .isRemoteBranch)
        try c.encode(config, forKey: .config)
    }
}

struct AutomationIdBody: Encodable, Sendable {
    let id: Int
}

struct AutomationSetEnabledBody: Encodable, Sendable {
    let id: Int
    let enabled: Bool
}

struct AutomationRunsBody: Encodable, Sendable {
    let automationId: Int
    var limit: Int?
}

struct AutomationRunNowBody: Encodable, Sendable {
    let automationId: Int
}

struct AutomationCreateBody: Encodable, Sendable {
    let draft: AutomationDraftBody
}

struct AutomationUpdateBody: Encodable, Sendable {
    let id: Int
    let draft: AutomationDraftBody
}

