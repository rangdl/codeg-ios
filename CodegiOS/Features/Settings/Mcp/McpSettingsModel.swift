import SwiftUI

/// Loads + mutates locally-installed MCP servers (`mcp_scan_local`). Add/edit go
/// through `mcp_upsert_local_server` (spec + apps together); delete is optimistic
/// with rollback. Marketplace install is deferred to a later pass.
@MainActor
final class McpSettingsModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var servers: [LocalMcpServer] = []
    /// Agent configs the scan could not read. Kept alongside the servers so one
    /// unreadable file degrades to a warning instead of an empty page — the reason
    /// `mcp_scan_local` returns a wrapper instead of a bare list.
    @Published private(set) var scanWarnings: [LocalMcpSourceWarning] = []
    @Published var refreshError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if servers.isEmpty { phase = .loading }
        do {
            let scan = try await client.mcpScanLocal()
            servers = scan.servers.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            scanWarnings = scan.warnings
            phase = .loaded
            refreshError = nil
        } catch {
            if servers.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }

    func upsert(serverId: String, spec: JSONValue, apps: [McpAppType]) async throws {
        guard let client else { return }
        _ = try await client.mcpUpsertLocalServer(serverId: serverId, spec: spec, apps: apps)
        await load()
    }

    func remove(_ server: LocalMcpServer) async {
        guard let client else { return }
        let previous = servers
        servers.removeAll { $0.id == server.id }
        do {
            try await client.mcpRemoveServer(serverId: server.id)
        } catch {
            servers = previous
            refreshError = error.localizedDescription
        }
    }
}
