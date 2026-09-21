import SwiftUI

/// App display-language picker: System / English / 中文. The choice is a purely
/// local (device-scoped) preference held in `LanguageStore`, injected by
/// `RootView`. Picking a language overrides `\.environment(\.locale)` at the root,
/// which re-resolves every `LocalizedStringKey` live — so this screen and the
/// whole app switch language without a relaunch.
///
/// Mirrors ``AppearanceSettingsView``'s theme section. This is the **app UI**
/// language; it is separate from the *server-side* reply language in System
/// settings.
struct LanguageSettingsView: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    languageSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .screenTitle("Language", compact: horizontalSizeClass == .compact)
    }

    private var languageSection: some View {
        EditorSection(
            title: "Display Language",
            footer: "Sets the language of the app's interface. “System” follows your device's language."
        ) {
            ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { index, lang in
                if index > 0 { InsetDivider(leading: 16) }
                SelectableRow(symbol: lang.symbol, title: lang.titleKey, isSelected: language.language == lang) {
                    language.language = lang
                }
            }
        }
    }
}
