import SwiftUI

/// Version Control settings: git availability + a custom git path override, and
/// the GitHub accounts list (full-replace metadata + per-account keyring token).
@MainActor
final class VersionControlSettingsModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var git: GitDetectResult?
    @Published var customPath = ""
    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var testResult: GitDetectResult?
    @Published var testing = false
    @Published var refreshError: String?
    @Published var toast: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            async let detect = client.detectGit()
            async let settings = client.gitSettings()
            async let accts = client.githubAccounts()
            git = try await detect
            customPath = (try await settings).customPath ?? ""
            accounts = try await accts
            phase = .loaded
            refreshError = nil
        } catch {
            if case .loaded = phase { refreshError = error.localizedDescription }
            else { phase = .failed(error.localizedDescription) }
        }
    }

    // MARK: - Git path

    func testCustomPath() async {
        guard let client else { return }
        let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        testing = true
        defer { testing = false }
        testResult = try? await client.testGitPath(path)
    }

    func saveCustomPath() async {
        guard let client else { return }
        let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.updateGitSettings(customPath: path.isEmpty ? nil : path)
            git = try await client.detectGit()   // re-detect with the new path
            toast = "Git path saved."
        } catch {
            toast = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    // MARK: - GitHub accounts

    /// Add or update an account (full-replace metadata + token). A stable `id`
    /// (held by the editor) makes a retry after a token failure replace rather
    /// than duplicate.
    func upsert(_ account: GitHubAccount, token: String?) async throws {
        guard let client else { return }
        var list = accounts
        if account.isDefault { list = list.map { $0.with(isDefault: false) } }
        if let idx = list.firstIndex(where: { $0.id == account.id }) {
            list[idx] = account
        } else {
            list.append(account)
        }
        try await client.updateGithubAccounts(list)
        if let token, !token.isEmpty {
            try await client.saveAccountToken(accountId: account.id, token: token)
        }
        await load()
    }

    func setDefault(_ account: GitHubAccount) async {
        guard let client else { return }
        let list = accounts.map { $0.with(isDefault: $0.id == account.id) }
        do {
            try await client.updateGithubAccounts(list)
            await load()
        } catch {
            toast = "Couldn’t set default: \(error.localizedDescription)"
        }
    }

    func delete(_ account: GitHubAccount) async {
        guard let client else { return }
        // Delete the keyring token FIRST: if it fails the account stays intact and
        // the user can retry, rather than orphaning a server-side secret with no
        // way to clean it up.
        do {
            try await client.deleteAccountToken(accountId: account.id)
        } catch {
            toast = "Couldn’t remove token: \(error.localizedDescription)"
            return
        }
        let previous = accounts
        accounts.removeAll { $0.id == account.id }
        do {
            try await client.updateGithubAccounts(accounts)
            toast = "Removed \(account.username)."
        } catch {
            accounts = previous
            toast = "Couldn’t delete: \(error.localizedDescription)"
        }
    }
}
