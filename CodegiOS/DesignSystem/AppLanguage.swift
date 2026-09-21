import SwiftUI

/// The app's display language. `.system` follows the device's language; the other
/// cases override it in-app via `.environment(\.locale, …)` (see `RootView`).
///
/// This is the **app UI** language and is purely device-local. It is unrelated to
/// the *server-side* reply language in System settings (`AppLocaleCatalog`), which
/// is sent to the backend.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, chinese

    var id: String { rawValue }

    /// Display name. Concrete languages are shown in their own name (iOS
    /// convention), so they read the same regardless of the current UI language;
    /// only "System" is localized.
    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .english: "English"
        case .chinese: "中文"
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .english: "character"
        case .chinese: "character.book.closed"
        }
    }

    /// BCP-47 identifier handed to `.environment(\.locale)`. `.system` → `nil`
    /// (defer to the device), so the caller leaves the environment locale alone.
    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .chinese: "zh-Hans"
        }
    }
}

/// User-chosen app display language. Persists to `UserDefaults` and survives
/// relaunch. Owned at the app root (`RootView`) and injected into the environment
/// so the Settings screen can read and mutate it; `language` drives
/// `.environment(\.locale)`, applied once in `RootView`, which re-resolves every
/// `LocalizedStringKey` live (no view-identity teardown).
///
/// Mirrors ``AppearanceStore``.
@MainActor
final class LanguageStore: ObservableObject {
    private static let languageKey = "codeg.appLanguage"

    var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.language = defaults.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The locale to hand `.environment(\.locale)`. For `.system` we hand back the
    /// device's auto-updating locale (equivalent to not overriding it).
    var locale: Locale {
        guard let id = language.localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: id)
    }
}
