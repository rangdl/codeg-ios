import SwiftUI

/// The app's theme mode. `.system` follows the device's light/dark setting.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    /// The value to hand `.preferredColorScheme`. `.system` → `nil` (defer to the
    /// device).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-chosen appearance: light/dark/system mode and the accent color scheme.
/// Both persist to `UserDefaults` and survive relaunch. Owned at the app root
/// (`RootView`) and injected into the environment so the Settings screen can read
/// and mutate it; `mode` drives `.preferredColorScheme` and `accent` drives the
/// `\.codegAccent` trait bridge, both applied once in `RootView`.
@MainActor
final class AppearanceStore: ObservableObject {
    private static let modeKey = "codeg.appearance.mode"
    private static let accentKey = "codeg.appearance.accent"

    @Published var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    @Published var accent: AccentPalette {
        didSet {
            guard oldValue != accent else { return }
            UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey)
            codegCurrentAccentPalette = accent
            codegRefreshAccentTrait()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.mode = defaults.string(forKey: Self.modeKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        // Unset reads back as nil here (we use `object(forKey:)`, not
        // `integer(forKey:)`), so a fresh install falls through to the neutral
        // default; an out-of-range stored index also falls back to neutral.
        self.accent = (defaults.object(forKey: Self.accentKey) as? Int)
            .flatMap(AccentPalette.init(rawValue:)) ?? .neutral
        // Seed the global backing `Theme.accent` (didSet doesn't run during init).
        codegCurrentAccentPalette = self.accent
    }
}
