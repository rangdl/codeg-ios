import Foundation

// Automations (scheduled agent runs): the settings screen's whole backend.
//
// Kept in its own file rather than in `CodegClient.swift`: this feature is one
// of the ones this fork carries and upstream does not, so isolating it keeps
// future merges from upstream honest.

extension CodegClient {
    func automationList() async throws -> [AutomationInfo] {
        let data = try await send("automation_list", body: EmptyBody())
        do { return try CodegJSON.decoder.decode([AutomationInfo].self, from: data) }
        catch { throw APIError.decoding("automation_list did not decode: \(String(describing: error))") }
    }

    func automationCreate(draft: AutomationDraftBody) async throws -> AutomationInfo {
        let data = try await send("automation_create", body: AutomationCreateBody(draft: draft))
        do { return try CodegJSON.decoder.decode(AutomationInfo.self, from: data) }
        catch { throw APIError.decoding("automation_create did not decode: \(String(describing: error))") }
    }

    func automationUpdate(id: Int, draft: AutomationDraftBody) async throws -> AutomationInfo {
        let data = try await send("automation_update", body: AutomationUpdateBody(id: id, draft: draft))
        do { return try CodegJSON.decoder.decode(AutomationInfo.self, from: data) }
        catch { throw APIError.decoding("automation_update did not decode: \(String(describing: error))") }
    }

    func automationSetEnabled(id: Int, enabled: Bool) async throws {
        _ = try await send("automation_set_enabled", body: AutomationSetEnabledBody(id: id, enabled: enabled))
    }

    func automationDelete(id: Int) async throws {
        _ = try await send("automation_delete", body: AutomationIdBody(id: id))
    }

    func automationRunNow(id: Int) async throws {
        _ = try await send("automation_run_now", body: AutomationRunNowBody(automationId: id))
    }

    func automationRuns(automationId: Int, limit: Int = 20) async throws -> [AutomationRunInfo] {
        let data = try await send("automation_runs", body: AutomationRunsBody(automationId: automationId, limit: limit))
        do { return try CodegJSON.decoder.decode([AutomationRunInfo].self, from: data) }
        catch { throw APIError.decoding("automation_runs did not decode: \(String(describing: error))") }
    }
}
