import SwiftUI

/// Shared native option/text UI. The original labels, IDs, and text are
/// retained on the wire; language preferences affect only app-owned chrome.
public struct UserInputResponseForm: View {
    public let request: ApprovalRequest
    public let isSending: Bool
    public let submit: ([String: [String]]) -> Void
    @State private var draft = UserInputFormState()
    public init(request: ApprovalRequest, isSending: Bool, submit: @escaping ([String: [String]]) -> Void) {
        self.request = request; self.isSending = isSending; self.submit = submit
    }
    private var answers: [String: [String]] {
        draft.answers(for: request.questions ?? [])
    }
    private var valid: Bool { (try? UserInputValidation.validate(answers, questions: request.questions ?? [])) != nil }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(request.questions ?? []) { q in
                VStack(alignment: .leading, spacing: 9) {
                    if !q.header.isEmpty { Text(verbatim: q.header).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(verbatim: q.question).font(.headline)
                    ForEach(Array((q.options ?? []).enumerated()), id: \.offset) { _, option in
                        Button {
                            draft.select(option.label, for: q.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: draft.selected[q.id] == option.label ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.selected[q.id] == option.label ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: option.label).font(.body.weight(.medium))
                                    if !option.description.isEmpty {
                                        Text(verbatim: option.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(isSending || request.isExpired)
                    }
                    if q.permitsFreeText {
                        let binding = Binding(get: { draft.typed[q.id] ?? "" }, set: { draft.type($0, for: q.id) })
                        Group {
                            if q.isSecret {
                                SecureField(AppLocalizer.text("填写回答"), text: binding)
                            } else {
                                #if os(watchOS)
                                TextField(AppLocalizer.text("填写回答"), text: binding)
                                    .lineLimit(1)
                                #else
                                TextField(AppLocalizer.text("填写回答"), text: binding, axis: .vertical).lineLimit(1...4)
                                #endif
                            }
                        }
                        .disabled(isSending || request.isExpired)
                    }
                }
            }
            Button { submit(answers) } label: {
                Label(AppLocalizer.text(isSending ? "等待电脑确认" : "提交回答"), systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!valid || isSending || request.isExpired)
            .buttonStyle(.borderedProminent)
        }
    }
}

public struct InteractionReceiptView: View {
    public let receipt: CommandReceipt?
    public let pending: Bool
    public init(receipt: CommandReceipt?, pending: Bool) { self.receipt = receipt; self.pending = pending }
    public var body: some View {
        if pending {
            Label(AppLocalizer.text("等待电脑确认"), systemImage: "clock").font(.caption).foregroundStyle(.orange)
        } else if let receipt {
            switch receipt {
            case .accepted:
                Label(AppLocalizer.text("电脑已接收决定"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            case .failed(let message), .unconfirmed(let message):
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

public struct CommandRecoveryControls: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    public let isChecking: Bool
    public let canCheck: Bool
    public let check: () -> Void
    public let discard: () -> Void
    @State private var confirmingDiscard = false
    public init(isChecking: Bool, canCheck: Bool = true, check: @escaping () -> Void, discard: @escaping () -> Void) {
        self.isChecking = isChecking; self.canCheck = canCheck; self.check = check; self.discard = discard
    }
    public var body: some View {
        let _ = languageRaw
        VStack(alignment: .leading, spacing: 10) {
            Button(action: check) {
                Label(AppLocalizer.text(isChecking ? "正在查询…" : "查询发送结果"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.disabled(isChecking || !canCheck).accessibilityIdentifier("command.recovery.query")
            Button(role: .destructive) { confirmingDiscard = true } label: {
                Text(AppLocalizer.text("丢弃本机草稿"))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.accessibilityIdentifier("command.recovery.discard")
        }
        .font(.caption)
        .buttonStyle(.plain)
        .alert(AppLocalizer.text("丢弃本机草稿"), isPresented: $confirmingDiscard) {
            Button(AppLocalizer.text("丢弃本机草稿"), role: .destructive, action: discard)
                .accessibilityIdentifier("command.recovery.confirm")
            Button(AppLocalizer.text("取消"), role: .cancel) {}
                .accessibilityIdentifier("command.recovery.cancel")
        } message: { Text(AppLocalizer.text("这只移除本机草稿，不会取消已提交的操作，也不会重新发送。")) }
    }
}
