import CoreImage.CIFilterBuiltins
import SwiftUI
import CodexWatchCore

struct MacSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacBridgeViewModel
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section(t("显示")) {
                    Picker(t("语言"), selection: $languageRaw) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option == .system ? t("跟随系统") : option.nativeDisplayName)
                                .tag(option.rawValue)
                        }
                    }

                    Picker(t("外观"), selection: $appearanceRaw) {
                        Text(t("跟随系统")).tag(AppAppearance.system.rawValue)
                        Text(t("浅色")).tag(AppAppearance.light.rawValue)
                        Text(t("深色")).tag(AppAppearance.dark.rawValue)
                    }
                }

                Section(t("设备")) {
                    NavigationLink {
                        MacPairingSettingsView(model: model, onClose: { dismiss() })
                    } label: {
                        Label(t("设备连接"), systemImage: "qrcode.viewfinder")
                    }
                }

                Section(t("审批同步")) {
                    Text(t("ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Codex Control · \(AppBuildInfo.displayValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(t("设置"))
            .toolbar {
                Button(t("完成")) { dismiss() }
            }
        }
        .frame(width: 460, height: 620)
    }

    private func t(_ key: String) -> String {
        AppLocalizer.text(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }
}

private struct MacPairingSettingsView: View {
    @ObservedObject var model: MacBridgeViewModel
    @State private var pairingVisibilityID = UUID()
    let onClose: () -> Void

    var body: some View {
        ZStack {
            CodexBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalizer.text("动态配对二维码"))
                                .font(.title3.weight(.semibold))
                            Text(AppLocalizer.text("在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Label(
                            AppLocalizer.text(model.isPhonePaired ? "已配对" : "等待配对"),
                            systemImage: model.isPhonePaired ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.isPhonePaired ? .green : .secondary)
                    }

                    VStack(spacing: 14) {
                        if let image = PairingQRCode.image(for: model.pairingQRPayload) {
                            image
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 216, height: 216)
                                .padding(14)
                                .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                        }

                        Divider().overlay(.primary.opacity(0.10))

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(AppLocalizer.text("Mac 动态配对码（首次连接）"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.pairingCode)
                                    .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                                    .tracking(5)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(AppLocalizer.format("有效期 %@", model.pairingCodeRemaining))
                                    .font(.caption.weight(.medium).monospacedDigit())
                                Text(AppLocalizer.text("自动更新"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .codexGlassCard(tint: .purple)

                    VStack(spacing: 10) {
                        Button(AppLocalizer.text("更新验证码")) { model.rotatePairingCode() }
                            .frame(maxWidth: .infinity)
                            .codexPrimaryButton()
                            .tint(.cyan)

                        Button(AppLocalizer.text("重置 iPhone 配对"), role: .destructive) {
                            model.resetPhonePairing()
                        }
                        .font(.caption.weight(.medium))
                    }

                    Text(AppLocalizer.text("重置后，下一台 iPhone 扫码或输入验证码即可配对。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
        }
        .navigationTitle(AppLocalizer.text("设备连接"))
        .onAppear { model.setPairingVisible(true, observerID: pairingVisibilityID) }
        .onDisappear { model.setPairingVisible(false, observerID: pairingVisibilityID) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.text("完成")) { onClose() }
            }
        }
    }
}

private enum PairingQRCode {
    static func image(for payload: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
