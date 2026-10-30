import Foundation

/// `get_system_proxy_settings`. Update is sent raw as `{settings:{enabled,proxy_url}}`.
struct SystemProxySettings: Decodable, Sendable {
    let enabled: Bool
    let proxyUrl: String?
}

/// `get_system_language_settings`. `mode` is "system"|"manual"; `language` is an
/// app-locale code with UNDERSCORES (e.g. "zh_cn", not "zh-cn"). Kept as strings
/// (lenient) so an unexpected value can't fail the decode.
struct SystemLanguageSettings: Decodable, Sendable {
    let mode: String
    let language: String
}

/// `get_system_terminal_settings`. `default_shell` is nil for the system default,
/// otherwise a shell option value or a custom path.
struct SystemTerminalSettings: Decodable, Sendable {
    let defaultShell: String?
}

/// One selectable shell from `get_available_terminal_shells`.
struct TerminalShellOption: Decodable, Identifiable, Sendable {
    let id: String
    let labelKey: String
    let value: String?
    let exists: Bool
    let acceptsCustomPath: Bool
}

struct AvailableTerminalShells: Decodable, Sendable {
    let options: [TerminalShellOption]
    let resolvedShell: String
}

/// `check_app_update` — note this endpoint's response is camelCase on the wire
/// (the shared `.convertFromSnakeCase` decoder is a no-op on already-camelCase
/// keys, so these decode fine). Only the read-only fields the UI shows are kept.
struct AppUpdateInfo: Decodable, Sendable {
    let version: String
    let body: String
    let date: String?
}

struct AppUpdateCheckResult: Decodable, Sendable {
    let currentVersion: String
    let update: AppUpdateInfo?
    let selfUpdateSupported: Bool
    /// Older servers (< the detached update protocol) omit this. They answer
    /// `perform_app_update` with the legacy blocking shape instead of an
    /// `AppUpdateState`, so the in-place flow must stay hidden there.
    let liveProgress: Bool?
}

/// Lifecycle of the server's in-place self-update. Mirrors the backend
/// `AppUpdateLifecycle` (snake_case values on the wire; the status VALUE is not
/// touched by `.convertFromSnakeCase`, so `ready_to_restart` needs its own raw
/// value).
enum AppUpdateLifecycle: String, Decodable, Sendable {
    case idle
    case downloading
    case installing
    case readyToRestart = "ready_to_restart"
    case restarting
    case error
}

/// Full update snapshot from `app_update_state` / `perform_app_update`. Progress
/// is backend-owned, so re-reading this snapshot after leaving the page recovers
/// an in-flight download.
struct AppUpdateState: Decodable, Sendable {
    /// Monotonic; apply only snapshots newer than the one already shown.
    let seq: UInt64
    let status: AppUpdateLifecycle
    let downloaded: UInt64?
    let total: UInt64?
    let version: String?
    let restartDelayMs: Int?
    let trialSeconds: Int?
    let capability: String?
    let error: String?
}

/// `restart_app` response: the server has already scheduled the relaunch, so
/// `needRestart` is false there; the delay/trial drive the client's countdown
/// and post-restart verification.
struct AppUpdateActionResult: Decodable, Sendable {
    let version: String?
    let needRestart: Bool
    let restartDelayMs: Int
    let trialSeconds: Int
    let capability: String
}

/// App-locale options for the System language picker (codes use underscores).
enum AppLocaleCatalog {
    static let options: [(code: String, label: String)] = [
        ("en", "English"), ("zh_cn", "简体中文"), ("zh_tw", "繁體中文"),
        ("ja", "日本語"), ("ko", "한국어"), ("es", "Español"),
        ("de", "Deutsch"), ("fr", "Français"), ("pt", "Português"), ("ar", "العربية"),
    ]

    static func label(for code: String) -> String {
        options.first { $0.code == code.lowercased() }?.label ?? code
    }
}
