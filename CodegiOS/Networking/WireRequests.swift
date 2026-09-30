import Foundation

/// A block of a prompt sent to an agent (Rust `PromptInputBlock`, tagged by
/// `type`). Encode-only. The request encoder does NOT convert keys, so the
/// snake_case wire keys (`mime_type`) are spelled explicitly here.
enum PromptInputBlock: Encodable, Sendable {
    case text(String)
    case image(data: String, mimeType: String, uri: String?)

    private enum CodingKeys: String, CodingKey {
        case type, text, data
        case mimeType = "mime_type"
        case uri
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let data, let mimeType, let uri):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(uri, forKey: .uri)
        }
    }
}

// MARK: - Request bodies (camelCase keys; nil optionals are omitted)

struct EmptyBody: Encodable, Sendable {}

struct ListConversationsBody: Encodable, Sendable {
    var folderIds: [Int]?
    var agentType: String?
    var search: String?
    var sortBy: String?
    var status: String?
    var includeChildren: Bool?
}

struct ConversationIdBody: Encodable, Sendable {
    let conversationId: Int
}

/// Body for `create_conversation` — creates a server-side conversation row in
/// `folderId` for `agentType` (optional `title`) BEFORE the first prompt, so the
/// server broadcasts a `conversation_upsert` to every client (the desktop/web
/// sidebars then show it immediately). Mirrors the web client's new-tab flow.
/// Returns the new conversation id. camelCase keys, encoded as-is.
struct CreateConversationBody: Encodable, Sendable {
    let folderId: Int
    let agentType: AgentType
    var title: String?
}

/// Body for `acp_find_connection_for_conversation`. The server requires
/// `agentType` (no default) and accepts an optional `sessionId` (`external_id`)
/// used to match a connection in the pre-first-prompt window.
struct FindConnectionBody: Encodable, Sendable {
    let conversationId: Int
    var sessionId: String?
    let agentType: AgentType
}

struct ConnectBody: Encodable, Sendable {
    let agentType: AgentType
    var workingDir: String?
    var sessionId: String?
    /// Last-used mode/config to start the session with (server applies before
    /// reporting state). Omitted when nil. See `SelectorPrefsStore`.
    var preferredModeId: String?
    var preferredConfigValues: [String: String]?
}

struct PromptBody: Encodable, Sendable {
    let connectionId: String
    let blocks: [PromptInputBlock]
    var folderId: Int?
    var conversationId: Int?
    var clientMessageId: String?
}

struct ConnectionIdBody: Encodable, Sendable {
    let connectionId: String
}

/// Body for `acp_respond_permission` — resolves a `permission_request` (and
/// ExitPlanMode) by selecting one of the offered options. `optionId` is the
/// chosen `PermissionOption.optionId`; a `reject*`-kind option denies.
struct RespondPermissionBody: Encodable, Sendable {
    let connectionId: String
    let requestId: String
    let optionId: String
}

/// Body for `acp_answer_question` — answers an `ask_user_question`. `answer`
/// carries one `QuestionAnswerItem` per question (selected option labels), or
/// `declined: true` with no answers to dismiss.
struct AnswerQuestionBody: Encodable, Sendable {
    let connectionId: String
    let questionId: String
    let answer: QuestionAnswer
}

/// Body for `acp_answer_plan_approval` — resolves Grok's blocked
/// `exit_plan_mode`. `feedback` carries the revision notes for a
/// `request_changes` decision (ignored by the other two).
struct AnswerPlanApprovalBody: Encodable, Sendable {
    let connectionId: String
    let approvalId: String
    let answer: PlanApprovalAnswer
}

struct PlanApprovalAnswer: Encodable, Sendable {
    let decision: PlanApprovalDecision
    var feedback: String?
}

/// Body for `acp_describe_agent_options`. Takes the agent type + an optional
/// working dir — NOT a connection id (the server spawns a throwaway probe agent
/// to enumerate options). camelCase keys, encoded as-is.
struct DescribeAgentOptionsBody: Encodable, Sendable {
    let agentType: AgentType
    var workingDir: String?
}

/// Body carrying a single agent type (`acp_clear_binary_cache`,
/// `acp_detect_agent_local_version`). camelCase key (`agentType`), encoded as-is.
struct AgentTypeBody: Encodable, Sendable {
    let agentType: AgentType
}

/// Body for `acp_set_mode` — applies to a live chat `connectionId`.
struct SetModeBody: Encodable, Sendable {
    let connectionId: String
    let modeId: String
}

/// Body for `acp_fork` — forks a live session at a rendered turn. All three
/// linkages are optional and pass-through: the backend adopts them only when
/// the connection isn't yet bound to the conversation row (a fork from a
/// history-opened conversation fires no prompt, so nothing else would bind
/// it), and a turn the agent cannot name silently forks at the tail instead
/// of failing (`resolve_fork_point`). camelCase keys, encoded as-is.
struct ForkBody: Encodable, Sendable {
    let connectionId: String
    var conversationId: Int?
    var folderId: Int?
    var forkFromTurnId: String?
}

/// Response of `acp_fork` (Rust `ForkResult`). `forkedSessionId` is the NEW
/// session — the caller adopts it immediately, because the current
/// conversation row now points at it; `originalSessionId` is what the row
/// was bound to before, preserved on the freshly inserted sibling row.
struct ForkResult: Decodable, Sendable {
    let forkedSessionId: String
    let originalSessionId: String
    let siblingConversationId: Int
}

/// Body for `acp_set_config_option` — applies to a live chat `connectionId`.
struct SetConfigOptionBody: Encodable, Sendable {
    let connectionId: String
    let configId: String
    let valueId: String
}

/// Body for `update_conversation_pinned` — pins (`true`) or unpins (`false`) a
/// conversation. The server sets/clears `pinned_at` and leaves `updated_at`
/// untouched.
struct UpdateConversationPinnedBody: Encodable, Sendable {
    let conversationId: Int
    let pinned: Bool
}

/// Body for `update_conversation_title` — renames a conversation. The server
/// stores the new `title`; the response is `null`.
struct UpdateConversationTitleBody: Encodable, Sendable {
    let conversationId: Int
    let title: String
}

/// Body for `update_conversation_status` — sets the lifecycle status. `status`
/// is the raw wire value (`in_progress` / `pending_review` / `completed` /
/// `cancelled`); the response is `null`.
struct UpdateConversationStatusBody: Encodable, Sendable {
    let conversationId: Int
    let status: String
}

/// Body for endpoints that take a single absolute server-side `path`:
/// `open_folder` and `list_directory_entries`.
struct PathBody: Encodable, Sendable {
    let path: String
}

/// Body for `update_folder_alias`. `alias == nil` clears the alias: the key is
/// then omitted (the synthesized encoder uses `encodeIfPresent`), which the
/// server's `Option<String>` param reads as `None`.
struct UpdateFolderAliasBody: Encodable, Sendable {
    let folderId: Int
    let alias: String?
}

/// Git auth for `clone_repository` of a private repo (Rust `GitCredentials`).
/// Omitted entirely for public repos.
struct GitCredentials: Encodable, Sendable {
    let username: String
    let password: String
}

/// Body for `clone_repository` — clone `url` into `targetDir` (the full
/// destination path) on the server. `credentials` is omitted for public repos.
struct CloneRepositoryBody: Encodable, Sendable {
    let url: String
    let targetDir: String
    var credentials: GitCredentials?
}

/// Error envelope returned by the server on non-2xx (`{code, message}`).
struct ServerError: Decodable, Sendable {
    let code: String?
    let message: String?
}

// MARK: - Token usage (mirror of Rust `TokenUsageFilter` / report shapes)

/// Envelope for `token_usage_report` — the server takes `{ filter: {...} }`.
struct TokenUsageReportBody: Encodable, Sendable {
    let filter: TokenUsageFilterBody
}

/// Filter for `token_usage_report`. All buckets are local-time (`tzOffsetMinutes`
/// is `-TimeZone.current.secondsFromGMT()/60`, the web's `-new Date().getTimezoneOffset()`).
struct TokenUsageFilterBody: Encodable, Sendable {
    var start: String?
    var end: String?
    var folderIds: [Int]?
    var agentTypes: [String]?
    var models: [String]?
    let bucket: String
    let tzOffsetMinutes: Int
    var comparePrevious: Bool?
}

/// One bucketed point of the usage series (wire `bucket_key` / `start` / `end`).
struct TokenUsagePoint: Decodable, Sendable {
    let bucketKey: String?
    let start: String?
    let end: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int
    let turnCount: Int
}

/// Aggregate totals over the whole filtered range.
struct TokenUsageTotals: Decodable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int
    let turnCount: Int
    let conversationCount: Int
    let durationMs: Int
    let activeDays: Int
}

/// One row of a `by_*` breakdown.
struct TokenUsageBreakdownItem: Decodable, Sendable {
    let key: String
    let label: String?
    let totalTokens: Int
    let turnCount: Int?
}

/// `token_usage_report` response — only the fields the iOS screen renders.
struct TokenUsageReport: Decodable, Sendable {
    let bucket: String
    let totals: TokenUsageTotals
    let series: [TokenUsagePoint]
    let byFolder: [TokenUsageBreakdownItem]
    let byAgent: [TokenUsageBreakdownItem]
    let byModel: [TokenUsageBreakdownItem]
    let truncated: Bool?
}

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
struct AutomationConfigBody: Encodable, Sendable {
    var action: String?
    var promptBlocks: [PromptInputBlock]
    var displayText: String
    var modeId: String?
    var configValues: [String: String]
}

/// Create/update payload (`AutomationDraft`).
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

/// Body for `submit_session_feedback` — inject a message into the RUNNING turn
/// over the native `_session/steering` channel (Claude Code only, server-gated).
struct SubmitSessionFeedbackBody: Encodable, Sendable {
    let connectionId: String
    let text: String
    var blocks: [PromptInputBlock]?
}
