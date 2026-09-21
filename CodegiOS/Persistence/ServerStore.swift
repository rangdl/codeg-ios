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
        }
        servers[index] = profile
        persist()
        return true
    }

    func delete(_ profile: ServerProfile) {
        servers.removeAll { $0.id == profile.id }
        Keychain.deleteToken(for: profile.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            Keychain.deleteToken(for: servers[index].id)
        }
        servers.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Access

    func token(for profile: ServerProfile) -> String? {
        Keychain.token(for: profile.id)
    }

    /// Build an HTTP client for a profile, or nil if the URL/token is missing.
    func client(for profile: ServerProfile) -> CodegClient? {
        guard let baseURL = profile.baseURL, let token = token(for: profile) else { return nil }
        return CodegClient(baseURL: baseURL, token: token)
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
