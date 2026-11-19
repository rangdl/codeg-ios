import Foundation

// Token usage report / status / sync: the usage screen's backend.
//
// In its own file for the same reason as `CodegClient+Automations.swift`: this
// pane is carried by this fork, not upstream.

extension CodegClient {
    /// The usage report for a filter (server `token_usage_report`).
    func tokenUsageReport(filter: TokenUsageFilterBody) async throws -> TokenUsageReport {
        let data = try await send("token_usage_report", body: TokenUsageReportBody(filter: filter))
        do { return try CodegJSON.decoder.decode(TokenUsageReport.self, from: data) }
        catch { throw APIError.decoding("token_usage_report did not decode: \(String(describing: error))") }
    }

    /// How far the usage fact store lags the conversation list (server
    /// `token_usage_status`) — `staleConversations > 0` means the report would
    /// show numbers that don't include recent sessions.
    func tokenUsageStatus() async throws -> TokenUsageSyncStatus {
        let data = try await send("token_usage_status", body: EmptyBody())
        do { return try CodegJSON.decoder.decode(TokenUsageSyncStatus.self, from: data) }
        catch { throw APIError.decoding("token_usage_status did not decode: \(String(describing: error))") }
    }

    /// Re-parse stale conversation transcripts into the usage fact store (server
    /// `token_usage_sync`). The web dashboard runs this incrementally before every
    /// load — without it the report only ever reflects the last full sync.
    func tokenUsageSync(mode: TokenUsageSyncMode = .incremental) async throws -> TokenUsageSyncResult {
        let data = try await send("token_usage_sync", body: TokenUsageSyncBody(mode: mode))
        do { return try CodegJSON.decoder.decode(TokenUsageSyncResult.self, from: data) }
        catch { throw APIError.decoding("token_usage_sync did not decode: \(String(describing: error))") }
    }
}
