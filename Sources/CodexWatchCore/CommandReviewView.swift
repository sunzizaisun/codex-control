import SwiftUI

/// Review is deliberately separate from the caller's composer. It can query
/// or discard only this immutable original; it has no send/execute closure.
@MainActor
public struct CommandRecoveryReviewView<Source: ObservableObject>: View {
    @ObservedObject private var source: Source
    private let original: RecoverableCommandDraft
    private let status: @MainActor (Source, String) -> CommandReviewState
    private let check: @MainActor (Source, String) -> Void
    private let discard: @MainActor (Source, String) -> Bool

    public init(source: Source, original: RecoverableCommandDraft,
        status: @escaping @MainActor (Source, String) -> CommandReviewState,
        check: @escaping @MainActor (Source, String) -> Void,
        discard: @escaping @MainActor (Source, String) -> Bool) {
        self.source = source; self.original = original; self.status = status; self.check = check; self.discard = discard
    }
    public var body: some View {
        AppAppearanceRoot {
            CommandRecoveryReviewContent(original: original, state: status(source, original.messageID),
                check: { check(source, original.messageID) }, discard: { discard(source, original.messageID) })
                .id(original.messageID)
        }
    }
}

public struct CommandStorageRepairControls: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    public let canRepair: Bool
    public let recoveredCommands: Int?
    public let repair: () -> Bool
    @State private var confirming = false
    public init(canRepair: Bool, recoveredCommands: Int?, repair: @escaping () -> Bool) {
        self.canRepair = canRepair; self.recoveredCommands = recoveredCommands; self.repair = repair
    }
    public var body: some View {
        let _ = languageRaw
        Group {
            if canRepair {
                Button { confirming = true } label: {
                    Label(AppLocalizer.text("修复本机队列"), systemImage: "externaldrive.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("command.storage.repair")
            }
            if let recoveredCommands {
                Text(AppLocalizer.format("已恢复 %d 项待确认操作；原文件备份已保存。", recoveredCommands))
                    .font(.caption).accessibilityIdentifier("command.storage.repairResult")
            }
        }
        .alert(AppLocalizer.text("修复本机队列"), isPresented: $confirming) {
            Button(AppLocalizer.text("备份并修复")) { _ = repair() }
                .accessibilityIdentifier("command.storage.repairConfirm")
            Button(AppLocalizer.text("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalizer.text("修复前将备份原文件。只恢复可识别的记录，其余仅保留在备份中；不会取消或重新发送已提交的操作。"))
        }
    }
}

private struct CommandRecoveryReviewContent: View {
    let original: RecoverableCommandDraft
    let state: CommandReviewState
    let check: () -> Void
    let discard: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @State private var discardedLocally = false

    var body: some View {
        NavigationStack {
            List {
                Section(AppLocalizer.text("原始指令")) {
                    if let prompt = original.verifiedPrompt {
                        Text(verbatim: prompt).accessibilityIdentifier("command.review.original")
                    } else {
                        Text(AppLocalizer.text("远程数据校验失败"))
                    }
                }
                Section {
                    if let receipt = state.receipt {
                        switch receipt {
                        case .accepted:
                            Label(AppLocalizer.text("电脑已接收指令"), systemImage: "checkmark.circle")
                                .foregroundStyle(.green).accessibilityIdentifier("command.review.accepted")
                        case .failed(let message), .unconfirmed(let message):
                            Text(CommandRecoveryTranslations.relocalizedNotice(message,
                                language: AppLanguage(rawValue: languageRaw) ?? .system))
                                .foregroundStyle(.orange).accessibilityIdentifier("command.review.notice")
                        }
                    } else if !discardedLocally {
                        Text(CommandRecovery.unconfirmedText).foregroundStyle(.orange)
                    }
                    if discardedLocally {
                        Text(AppLocalizer.text("本机草稿已移除"))
                            .accessibilityIdentifier("command.review.discarded")
                    }
                    Text(AppLocalizer.text("这只移除本机草稿，不会取消已提交的操作，也不会重新发送。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.isPending {
                    Section {
                        CommandRecoveryControls(isChecking: state.isChecking, canCheck: original.verifiedPrompt != nil, check: check) {
                            if discard() { discardedLocally = true }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : Color.white)
            .navigationTitle(AppLocalizer.text("待确认操作"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalizer.text("关闭")) { dismiss() }
                        .accessibilityIdentifier("command.review.close")
                }
            }
        }
        .adaptiveWatchNavigationAppearance()
    }
}

public struct CommandRecoveryReviewButton: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    public let open: () -> Void
    public init(open: @escaping () -> Void) { self.open = open }
    public var body: some View {
        let _ = languageRaw
        Button(action: open) {
            Label(AppLocalizer.text("查看待确认操作"), systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("command.review.open")
    }
}
