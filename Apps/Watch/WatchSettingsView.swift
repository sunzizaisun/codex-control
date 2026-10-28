import SwiftUI
import CodexWatchCore

struct WatchSettingsView: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        List {
            Picker(t("语言"), selection: $languageRaw) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option == .system ? t("跟随系统") : option.nativeDisplayName)
                        .tag(option.rawValue)
                }
            }
            .accessibilityIdentifier("settings.language")
            .listRowBackground(Color.clear)

            Picker(t("外观"), selection: $appearanceRaw) {
                Text(t("跟随系统")).tag(AppAppearance.system.rawValue)
                Text(t("浅色")).tag(AppAppearance.light.rawValue)
                Text(t("深色")).tag(AppAppearance.dark.rawValue)
            }
            .accessibilityIdentifier("settings.appearance")
            .listRowBackground(Color.clear)

            Text("Codex Control · \(AppBuildInfo.displayValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(t("设置"))
    }

    private func t(_ key: String) -> String {
        AppLocalizer.text(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }
}
