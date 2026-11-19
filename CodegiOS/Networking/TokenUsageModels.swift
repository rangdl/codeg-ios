import Foundation

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

/// Sync mode for `token_usage_sync` (Rust `TokenUsageSyncMode`): incremental
/// re-parses only stale conversations, full rebuilds every fact row.
enum TokenUsageSyncMode: String, Encodable, Sendable {
    case incremental
    case full
}

/// Body for `token_usage_sync` — server takes `{ mode }`.
struct TokenUsageSyncBody: Encodable, Sendable {
    let mode: TokenUsageSyncMode
}

/// Fact-store health from `token_usage_status` (Rust `TokenUsageSyncStatus`).
/// `staleConversations > 0` means the report would omit recent sessions until
/// a sync runs — the web dashboard auto-syncs on that condition.
struct TokenUsageSyncStatus: Decodable, Sendable {
    let totalConversations: Int
    let syncedConversations: Int
    let staleConversations: Int
    let factRows: Int
    let lastSyncedAt: Date?
    let running: Bool
}

/// Outcome of one `token_usage_sync` pass (Rust `TokenUsageSyncResult`).
struct TokenUsageSyncResult: Decodable, Sendable {
    let scanned: Int
    let synced: Int
    let skipped: Int
    /// Real faults — retried on the next pass.
    let failed: Int
    /// Transcripts gone for good: facts kept, stamp settled, never retried.
    let lost: Int
    let turnsWritten: Int
    let tokensWritten: Int
    let prunedConversations: Int
}

