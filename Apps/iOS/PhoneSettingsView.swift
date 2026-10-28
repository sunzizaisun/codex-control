import SwiftUI
import ActivityKit
import CodexWatchCore

struct PhoneSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                // Form owns an opaque platform background on iOS.  Keeping
                // the backdrop behind it is not enough, so explicitly hide
                // the scroll background; otherwise the in-app Dark setting
                // changes the value but the Settings screen remains white.
                CodexBackdrop()
                Form {
                    Section(t("显示")) {
                        Picker(t("语言"), selection: $languageRaw) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option == .system ? t("跟随系统") : option.nativeDisplayName)
                                    .tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("settings.language")

                        Picker(t("外观"), selection: $appearanceRaw) {
                            Text(t("跟随系统")).tag(AppAppearance.system.rawValue)
                            Text(t("浅色")).tag(AppAppearance.light.rawValue)
                            Text(t("深色")).tag(AppAppearance.dark.rawValue)
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("settings.appearance")
                    }

                    Section {
                        Label(t("自动重连与离线队列始终开启"), systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.secondary)
                    }

                    Section(t("审批同步")) {
                        Text(t("ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(t("实时活动")) {
                        if ActivityAuthorizationInfo().areActivitiesEnabled {
                            Label(
                                t("系统允许实时活动"),
                                systemImage: "applewatch.radiowaves.left.and.right"
                            )
                            .foregroundStyle(.green)
                        } else {
                            Label(t("实时活动已关闭"), systemImage: "applewatch.slash")
                                .foregroundStyle(.orange)
                        }
                        Text(t("活动显示与后台刷新由系统管理，信息可能暂时滞后。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Codex Control · \(AppBuildInfo.displayValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
                .environment(\.colorScheme, effectiveColorScheme)
                // Native Form cells can retain their old mirroring transform
                // across an RTL/LTR change. Recreate only this settings Form;
                // keep the surrounding navigation and relay session intact.
                .id(layoutDirection == .rightToLeft)
            }
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
            .environment(\.colorScheme, effectiveColorScheme)
            .navigationTitle(t("设置"))
            .toolbar {
                Button(t("完成")) { dismiss() }
            }
        }
    }

    private func t(_ key: String) -> String {
        AppLocalizer.text(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }

    private var effectiveColorScheme: ColorScheme {
        switch AppAppearance(rawValue: appearanceRaw) ?? .system {
        case .light: .light
        case .dark: .dark
        case .system: systemColorScheme
        }
    }
}
