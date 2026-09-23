import Foundation
import Combine

/// Observable store of saved server profiles. Owns persistence (UserDefaults
/// for metadata, Keychain for tokens) and vends `CodegClient`s. Main-actor
/// isolated since it backs SwiftUI state.
@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile]

    private let defaults: UserDefaults
    private let storageKey = "codeg.servers.v1"

    /// In-memory token cache. View bodies call `client(for:)` / `token(for:)` on
    /// every evaluation (e.g. `SettingsLeaf.destination` and a dozen `RootView`
    /// branches), and each miss is a synchronous `SecItemCopyMatching`. Doing that
    /// inside a body wedged the main thread on device — the settings hang sat in
    /// `Keychain.token` (TH_WAIT) for 10s until the scene-update watchdog killed
    /// the app. Reads are served from memory; the Keychain is touched once per
    /// token. Tokens only change through this store, so the cache cannot go stale.
    private var tokens: [UUID: String] = [:]
    /// Profiles whose Keychain lookup already missed, so a genuinely token-less
    /// server isn't re-read from the Keychain on every body evaluation.
    private var missingTokens: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.servers = ServerStore.load(from: defaults, key: storageKey)
    }

    // MARK: - Mutations

    /// Add a new server. Returns the created profile, or `nil` if the token
    /// could not be persisted securely — in which case nothing is added, so the
    /// list never holds a server whose token silently failed to save.
    @discardableResult
    func add(name: String, urlString: String, token: String) -> ServerProfile? {
        let profile = ServerProfile(name: name, urlString: urlString)
        guard Keychain.setToken(token, for: profile.id) else { return nil }
        cacheToken(token, for: profile.id)
        servers.append(profile)
        persist()
        return profile
    }

    /// Update a server's metadata and, if `token` is non-empty, its secret.
    /// A nil/empty `token` means "keep the existing token unchanged" — including
    /// when the endpoint changed, since editing a server's address (e.g. it moved
    /// to a new IP) shouldn't force the user to re-paste a token they want to
    /// reuse. Returns `false` (and leaves the stored profile untouched) when a
    /// provided token fails to persist, so we never bind new host metadata to a
    /// lost token.
    @discardableResult
    func update(_ profile: ServerProfile, token: String?) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return false }
        if let token, !token.isEmpty {
            // Store the new secret first; abort the whole update if it fails.
            guard Keychain.setToken(token, for: profile.id) else { return false }
            cacheToken(token, for: profile.id)
        }
        servers[index] = profile
        persist()
        return true
    }

    func delete(_ profile: ServerProfile) {
        servers.removeAll { $0.id == profile.id }
        Keychain.deleteToken(for: profile.id)
        forgetToken(for: profile.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            Keychain.deleteToken(for: servers[index].id)
            forgetToken(for: servers[index].id)
        }
        servers.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Access

    /// The profile's token, served from the in-memory cache. Only the first lookup
    /// for a profile touches the Keychain (see `tokens`), so callers — including
    /// view bodies — can resolve a client without blocking on `SecItemCopyMatching`.
    func token(for profile: ServerProfile) -> String? {
        if let cached = tokens[profile.id] { return cached }
        if missingTokens.contains(profile.id) { return nil }
        guard let token = Keychain.token(for: profile.id) else {
            missingTokens.insert(profile.id)
            return nil
        }
        tokens[profile.id] = token
        return token
    }

    /// Build an HTTP client for a profile, or nil if the URL/token is missing.
    func client(for profile: ServerProfile) -> CodegClient? {
        guard let baseURL = profile.baseURL, let token = token(for: profile) else { return nil }
        return CodegClient(baseURL: baseURL, token: token)
    }

    private func cacheToken(_ token: String, for id: UUID) {
        tokens[id] = token
        missingTokens.remove(id)
    }

    private func forgetToken(for id: UUID) {
        tokens[id] = nil
        missingTokens.insert(id)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [ServerProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
