import SwiftUI
import CodexWatchCore

struct WatchDashboardView: View {
    @ObservedObject var relay: WatchRelayController
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue

    var body: some View {
        // Reading the stored value makes already-mounted app chrome react to
        // language changes without replacing navigation or conversation state.
        let _ = languageRaw
        NavigationStack {
            List {
                statusSection

                Section {
                    NavigationLink { DotsConversationView(resumeLastConversation: true) } label: {
                        Label("dot", systemImage: "circle.inset.filled")
                    }
                    NavigationLink {
                        WatchNewCodexView(relay: relay)
                    } label: {
                        Label(AppLocalizer.text("新建 Codex"), systemImage: "terminal.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                if !approvals.isEmpty {
                    approvalSection
                }

                if !activeTasks.isEmpty {
                    taskSection("正在进行", tasks: activeTasks, limit: activeTasks.count)
                }

                taskSection("最近任务", tasks: recentTasks, limit: 5)

                Section {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label(AppLocalizer.text("设置"), systemImage: "gearshape")
                            .font(.caption.weight(.medium))
                    }
                }
            }
            .listStyle(.plain)
            .watchScreenBackground()
            .transaction { transaction in
                // Incoming relay heartbeats must never animate a row below a
                // user's finger or Digital Crown position.
                transaction.animation = nil
            }
            .navigationTitle("Codex")
            .refreshable {
                relay.refresh()
                try? await Task.sleep(for: .milliseconds(600))
            }
            .alert(AppLocalizer.text("提示"), isPresented: Binding(
                get: { relay.errorMessage != nil },
                set: { if !$0 { relay.errorMessage = nil } }
            )) {
                Button(AppLocalizer.text("好")) { relay.errorMessage = nil }
            } message: {
                Text(relay.errorMessage ?? "")
            }
        }
        .tint(.cyan)
        .sheet(isPresented: Binding(get: { relay.selectedNotificationRequestID != nil }, set: { if !$0 { relay.selectedNotificationRequestID = nil } })) {
            NavigationStack {
                switch InteractionDestination.resolve(requestID: relay.selectedNotificationRequestID,
                    pending: relay.snapshot.pendingApprovals,
                    receipt: relay.decisionReceipts.result(for: relay.selectedNotificationRequestID)) {
                case .request(let request):
                    WatchApprovalDetail(request: request, relay: relay)
                case .receipt(let receipt):
                    InteractionReceiptView(receipt: receipt, pending: false).padding()
                case .unavailable:
                    Text(AppLocalizer.text("审批请求已不再等待处理。"))
                }
            }
        }
        // Refresh the already-mounted navigation tree when Settings changes
        // the app language.
    }

    private var statusSection: some View {
        Section {
            NavigationLink {
                WatchUsageResetView(relay: relay)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(relay.snapshot.bridgeConnected ? .green : .orange)
                                .frame(width: 7, height: 7)
                            Text(AppLocalizer.text(relay.snapshot.bridgeConnected ? "Mac 在线" : "正在恢复"))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .allowsTightening(true)
                        }
                        if let issue = relay.connectionIssue {
                            Text(issue)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        if let reset = verifiedResetDate {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Label(AppLocalizer.relativeTime(to: reset, from: context.date), systemImage: "arrow.clockwise")
                            }
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(UsagePresentation.remainingText(relay.snapshot.usage?.primary))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.cyan)
                        Text(AppLocalizer.text("Token"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .watchGlassCard(tint: relay.snapshot.bridgeConnected ? .cyan : .orange)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var approvalSection: some View {
        Section {
            NavigationLink {
                WatchApprovalQueueView(relay: relay)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text(AppLocalizer.text("处理审批"))
                        .font(.headline)
                    Spacer()
                    Text("\(approvals.count)")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [AgentTask], limit: Int) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(Array(tasks.prefix(limit))) { task in
                    NavigationLink {
                        WatchTaskDetailView(task: task, relay: relay)
                    } label: {
                        taskRow(task)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("task.row.\(task.id)")
                }
            } header: {
                Text(AppLocalizer.text(title))
            }
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(task.state))
                .foregroundStyle(color(task.state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: task.title)
                    .font(.caption.weight(.medium))
                    // Keep the real ChatGPT title on its own line(s).  The
                    // state badge never competes with it for horizontal room.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(AppLocalizer.text(task.awaitingUserInput == true ? "等待你的回复" : label(task.state)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color(task.state))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color(task.state).opacity(0.16), in: Capsule())
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        // Timestamp-only heartbeats intentionally do not
                        // rebuild the list. Resolve the latest stored task.
                        let updatedAt = relay.task(id: task.id)?.updatedAt ?? task.updatedAt
                        Text(AppLocalizer.relativeTime(to: updatedAt, from: context.date))
                    }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                }
                if let progress = task.progress, task.state.isActive {
                    ProgressView(value: progress)
                        .tint(color(task.state))
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var approvals: [ApprovalRequest] {
        relay.snapshot.pendingApprovals.filter { !$0.isExpired }
    }

    private var activeTasks: [AgentTask] {
        relay.snapshot.tasks.filter { $0.isInProgress && !$0.isChat && !$0.isNativeChat && AgentTaskPresentation.isVisible($0) }
    }

    private var recentTasks: [AgentTask] {
        relay.snapshot.tasks.filter { !$0.isInProgress && !$0.isChat && !$0.isNativeChat && AgentTaskPresentation.isVisible($0) }
    }

    private var verifiedResetDate: Date? {
        guard let usage = relay.snapshot.usage,
              Date().timeIntervalSince(usage.capturedAt) < 15 * 60,
              let reset = usage.primary?.resetsAt,
              reset > Date(),
              reset.timeIntervalSinceNow < 8 * 24 * 60 * 60 else {
            return nil
        }
        return reset
    }

    private func icon(for kind: ApprovalKind) -> String {
        switch kind {
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .permissions: "lock.shield"
        case .userInput: "person.crop.circle.badge.questionmark"
        case .unknown: "questionmark.circle"
        }
    }

    private func symbol(_ state: AgentTask.State) -> String {
        switch state {
        case .running: "play.circle.fill"
        case .waitingForApproval: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle: "pause.circle"
        case .unknown: "circle.dotted"
        }
    }

    private func color(_ state: AgentTask.State) -> Color {
        switch state {
        case .running: .green
        case .waitingForApproval: .orange
        case .failed: .red
        case .completed: .cyan
        case .idle, .unknown: .secondary
        }
    }

    private func label(_ state: AgentTask.State) -> String {
        switch state {
        case .running: "运行中"
        case .waitingForApproval: "等待批准"
        case .idle: "空闲"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "未知"
        }
    }
}

private struct WatchUsageResetView: View {
    @ObservedObject var relay: WatchRelayController
    @State private var selectedCard: ResetCredit?

    private var usage: UsageSnapshot? { relay.snapshot.usage }
    private var resetCards: [ResetCredit] {
        (usage?.resetCredits ?? []).filter { $0.status == .available && ($0.expiresAt.map { $0 > Date() } ?? true) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(AppLocalizer.text("Token 余额"))
                    Spacer()
                    Text(UsagePresentation.remainingText(usage?.primary))
                        .foregroundStyle(.cyan)
                        .font(.headline.monospacedDigit())
                }
                infoRow(AppLocalizer.text("重置日期"), value: usage?.primary?.resetsAt.map(AppLocalizer.dateTime) ?? AppLocalizer.text("用量不可用"))
            }

            if !resetCards.isEmpty {
                Section(AppLocalizer.text("重置卡")) {
                    ForEach(resetCards) { card in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.title ?? AppLocalizer.text("重置卡"))
                                .font(.caption.weight(.semibold))
                            Text(card.expiresAt.map { AppLocalizer.format("到期 %@", AppLocalizer.dateTime($0)) } ?? AppLocalizer.text("无到期日"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(AppLocalizer.text("使用")) { selectedCard = card }
                                .watchPrimaryButton()
                                .tint(.cyan)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(AppLocalizer.text("额度与重置"))
        .confirmationDialog(
            AppLocalizer.text("确认使用重置卡？"),
            isPresented: Binding(get: { selectedCard != nil }, set: { if !$0 { selectedCard = nil } })
        ) {
            Button(AppLocalizer.text("确认"), role: .destructive) {
                if let selectedCard { relay.consumeResetCredit(selectedCard.id) }
                selectedCard = nil
            }
            Button(AppLocalizer.text("取消"), role: .cancel) { selectedCard = nil }
        } message: {
            Text(AppLocalizer.text("这会消耗一张重置卡，并立即重置符合条件的额度窗口。"))
        }
        .alert(AppLocalizer.text("提示"), isPresented: Binding(
            get: { relay.usageResetResult != nil },
            set: { if !$0 { relay.usageResetResult = nil } }
        )) {
            Button(AppLocalizer.text("好")) { relay.usageResetResult = nil }
        } message: {
            Text(resultText(relay.usageResetResult))
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption2).multilineTextAlignment(.trailing)
        }
    }

    private func resultText(_ result: String?) -> String {
        switch result {
        case "reset": AppLocalizer.text("重置完成")
        case "nothingToReset": AppLocalizer.text("当前没有可重置的额度窗口")
        case "noCredit": AppLocalizer.text("没有可用重置卡")
        case "alreadyRedeemed": AppLocalizer.text("此重置请求已完成")
        default: result ?? ""
        }
    }
}

struct WatchTaskDetailView: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    let task: AgentTask
    @ObservedObject var relay: WatchRelayController
    @State private var draft = MessageDraft()
    @State private var modelSelection = CodexModelSelection()
    @State private var reviewedOriginal: RecoverableCommandDraft?

    private var currentTask: AgentTask { relay.task(id: task.id) ?? task }
    private var history: TaskHistoryState? { relay.taskHistories[task.id] }
    private var messages: [ChatMessage] { history?.hasLoaded == true ? history!.messages : currentTask.messages }

    init(task: AgentTask, relay: WatchRelayController) {
        self.task = task; self.relay = relay
        _draft = State(initialValue: relay.initialCommandDraft(for: task.id))
    }

    var body: some View {
        let recoverable = relay.recoverableCommand(for: task.id)
        let separateReview = recoverable.map(draft.needsSeparateReview) ?? false
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(verbatim: currentTask.title)
                    } icon: {
                        Image(systemName: stateSymbol)
                    }
                        .font(.headline)
                        .foregroundStyle(stateColor)
                    Text(AppLocalizer.text(stateLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(AppLocalizer.relativeTime(to: currentTask.updatedAt, from: context.date))
                    }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let detail = AgentTaskPresentation.detail(currentTask.detail) {
                Section(AppLocalizer.text("当前进度")) {
                    Text(verbatim: detail)
                        .font(.caption)
                }
            }

            Section {
                if history?.isLoading == true {
                    ProgressView(AppLocalizer.text("正在加载…"))
                } else if let error = history?.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                    Button(AppLocalizer.text("重试")) { relay.loadHistory(for: task.id, refresh: true) }
                } else if history?.hasMore == true {
                    Button(AppLocalizer.text("加载较早的消息")) { relay.loadHistory(for: task.id, older: true) }
                }
            }

            if !messages.isEmpty {
                Section(AppLocalizer.text("对话")) {
                    ForEach(messages) { message in
                        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                            Text(AppLocalizer.text(message.role == .user ? "你" : "GPT"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(message.role == .user ? .cyan : .secondary)
                            Text(message.text + (message.isStreaming ? " ▍" : ""))
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    }
                }
            }

            Section(AppLocalizer.text("模型")) {
                CodexModelPicker(models: relay.snapshot.models, selection: $modelSelection, preferredModel: currentTask.model, preferredEffort: currentTask.reasoningEffort, preservesCurrentSettings: true, isRunning: currentTask.isInProgress)
            }

            if let workspace = AgentTaskPresentation.workspace(currentTask.workspace) {
                Section(AppLocalizer.text("工作目录")) {
                    Text(workspace)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(3)
                }
            }

            Section(AppLocalizer.text("继续对话")) {
                TextField(text: $draft.text, axis: .vertical) {
                    Text(verbatim: AppLocalizer.text("输入消息"))
                }
                    .lineLimit(2...4)
                    // Keep UI language independent from the system-managed
                    // Watch keyboard, dictation, Scribble, and iPhone input.
                    .environment(\.locale, .autoupdatingCurrent)
                    .accessibilityIdentifier("task.messageInput")

                if relay.pendingCommandTaskIDs.contains(currentTask.id) {
                    Label(relay.pendingCommandStatus, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    compactSendButton {
                        draft.submitted(relay.sendCommand(draft.text, to: currentTask, options: currentTask.isInProgress ? nil : modelSelection.options(in: relay.snapshot.models, onlyWhenSelected: true)))
                    }
                    .disabled(!relay.commandStorageAvailable || recoverable != nil || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.submissionID != nil)
                    .accessibilityIdentifier("task.send")
                    .listRowBackground(Color.clear)
                }
                if let error = draft.displayedError(language: AppLanguage(rawValue: languageRaw) ?? .system) {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable, draft.errorMessage == nil {
                    Text(AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable {
                    Button(AppLocalizer.text("重试")) { relay.retryCommandStorage() }
                        .frame(minHeight: 44).accessibilityIdentifier("command.storage.retry")
                        .listRowBackground(Color.clear)
                }
                CommandStorageRepairControls(canRepair: relay.commandStorageRepairNeeded,
                    recoveredCommands: relay.commandStorageRepairReceipt?.recoveredCommands, repair: { relay.repairCommandStorage() })
                    .listRowBackground(Color.clear)
                if let recoverable, separateReview {
                    CommandRecoveryReviewButton { reviewedOriginal = recoverable }.listRowBackground(Color.clear)
                }
                if draft.isUnconfirmed && !separateReview {
                    CommandRecoveryControls(isChecking: draft.submissionID.map(relay.checkingCommandIDs.contains) ?? false,
                        check: { relay.checkCommandStatus(draft.submissionID) },
                        discard: {
                            guard relay.discardUnconfirmedCommand(draft.submissionID) else { return }
                            draft.discardPendingOriginal()
                            if let next = relay.recoverableCommand(for: task.id) { draft.restore(next) }
                        })
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(AppLocalizer.text("任务详情"))
        .sheet(item: $reviewedOriginal) { original in
            CommandRecoveryReviewView(source: relay, original: original,
                status: { $0.commandReviewState(for: $1) }, check: { $0.checkCommandStatus($1) },
                discard: { source, id in
                    guard source.discardUnconfirmedCommand(id) else { return false }
                    if draft.submissionID == id { draft.discardPendingOriginal() }
                    return true
                })
        }
        .task {
            if let saved = relay.recoverableCommand(for: task.id) { draft.restore(saved) }
            relay.loadHistory(for: task.id)
        }
        .refreshable { relay.loadHistory(for: task.id, refresh: true) }
        .onChange(of: currentTask.state) { _, state in
            if !state.isActive { relay.loadHistory(for: task.id, refresh: true) }
        }
        .onChange(of: relay.commandReceipts.result(for: draft.submissionID)) { _, receipt in
            draft.apply(receipt)
            if receipt == .accepted {
                if let next = relay.recoverableCommand(for: task.id) { draft.restore(next) }
                relay.loadHistory(for: task.id, refresh: true)
            }
        }
        .onChange(of: relay.recoverableCommand(for: task.id)) { _, next in
            if draft.errorMessage == nil, let next { draft.restore(next) }
        }
    }

    private var stateSymbol: String {
        switch currentTask.state {
        case .running: "play.circle.fill"
        case .waitingForApproval: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle: "pause.circle"
        case .unknown: "circle.dotted"
        }
    }

    private var stateColor: Color {
        switch currentTask.state {
        case .running: .green
        case .waitingForApproval: .orange
        case .failed: .red
        case .completed: .cyan
        case .idle, .unknown: .secondary
        }
    }

    private var stateLabel: String {
        if currentTask.awaitingUserInput == true { return "等待你的回复" }
        return switch currentTask.state {
        case .running: "运行中"
        case .waitingForApproval: "等待批准"
        case .idle: "空闲"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "未知"
        }
    }
}

struct WatchNewCodexView: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: WatchRelayController
    @State private var draft = MessageDraft()
    @State private var modelSelection = CodexModelSelection()
    @State private var reviewedOriginal: RecoverableCommandDraft?

    init(relay: WatchRelayController) {
        self.relay = relay
        _draft = State(initialValue: relay.initialCommandDraft(for: TaskCommand.newChatTaskID))
    }

    var body: some View {
        let recoverable = relay.recoverableCommand(for: TaskCommand.newChatTaskID)
        let separateReview = recoverable.map(draft.needsSeparateReview) ?? false
        List {
            Section {
                CodexModelPicker(models: relay.snapshot.models, selection: $modelSelection)
            }
            Section {
                TextField(AppLocalizer.text("输入消息"), text: $draft.text, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("codex.messageInput")
                    .environment(\.locale, .autoupdatingCurrent)
                if draft.submissionID != nil && !draft.isUnconfirmed {
                    ProgressView(AppLocalizer.text("正在发送…"))
                }
                compactSendButton {
                    draft.submitted(relay.startCodexChat(draft.text, options: modelSelection.options(in: relay.snapshot.models)))
                }
                .disabled(!relay.commandStorageAvailable || recoverable != nil || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.submissionID != nil)
                .accessibilityIdentifier("codex.send")
                .listRowBackground(Color.clear)
                if let error = draft.displayedError(language: AppLanguage(rawValue: languageRaw) ?? .system) {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable, draft.errorMessage == nil {
                    Text(AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable {
                    Button(AppLocalizer.text("重试")) { relay.retryCommandStorage() }
                        .frame(minHeight: 44).accessibilityIdentifier("command.storage.retry")
                        .listRowBackground(Color.clear)
                }
                CommandStorageRepairControls(canRepair: relay.commandStorageRepairNeeded,
                    recoveredCommands: relay.commandStorageRepairReceipt?.recoveredCommands, repair: { relay.repairCommandStorage() })
                    .listRowBackground(Color.clear)
                if let recoverable, separateReview {
                    CommandRecoveryReviewButton { reviewedOriginal = recoverable }.listRowBackground(Color.clear)
                }
                if draft.isUnconfirmed && !separateReview {
                    CommandRecoveryControls(isChecking: draft.submissionID.map(relay.checkingCommandIDs.contains) ?? false,
                        check: { relay.checkCommandStatus(draft.submissionID) },
                        discard: {
                            guard relay.discardUnconfirmedCommand(draft.submissionID) else { return }
                            draft.discardPendingOriginal()
                            if let next = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(next) }
                        })
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(AppLocalizer.text("新建 Codex"))
        .sheet(item: $reviewedOriginal) { original in
            CommandRecoveryReviewView(source: relay, original: original,
                status: { $0.commandReviewState(for: $1) }, check: { $0.checkCommandStatus($1) },
                discard: { source, id in
                    guard source.discardUnconfirmedCommand(id) else { return false }
                    if draft.submissionID == id { draft.discardPendingOriginal() }
                    return true
                })
        }
        .task {
            if let saved = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(saved) }
        }
        .onChange(of: relay.commandReceipts.result(for: draft.submissionID)) { _, receipt in
            draft.apply(receipt)
            if receipt == .accepted {
                if let next = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(next) }
                else if draft.text.isEmpty { dismiss() }
            }
        }
        .onChange(of: relay.recoverableCommand(for: TaskCommand.newChatTaskID)) { _, next in
            if draft.errorMessage == nil, let next { draft.restore(next) }
        }
    }
}

@MainActor
@ViewBuilder
private func compactSendButton(action: @escaping () -> Void) -> some View {
    HStack {
        Spacer(minLength: 0)
        Button(action: action) {
            Label(AppLocalizer.text("发送"), systemImage: "arrow.up.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .watchPrimaryButton()
        .fixedSize()
        Spacer(minLength: 0)
    }
}

private struct WatchApprovalQueueView: View {
    @ObservedObject var relay: WatchRelayController

    private var approvals: [ApprovalRequest] {
        relay.snapshot.pendingApprovals.filter { !$0.isExpired }
    }

    var body: some View {
        List(approvals) { request in
            NavigationLink {
                WatchApprovalDetail(request: request, relay: relay)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalizer.localizedRemote(request.title))
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(AppLocalizer.localizedRemote(request.summary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(AppLocalizer.text("待审批"))
    }
}

struct WatchApprovalDetail: View {
    let request: ApprovalRequest
    @ObservedObject var relay: WatchRelayController

    var body: some View {
        Group {
            if request.questions != nil { questionContent }
            else { approvalContent }
        }
        .listStyle(.plain)
        .watchScreenBackground()
        .navigationTitle(AppLocalizer.text(request.kind == .userInput ? "回答" : "审批"))
        .alert(AppLocalizer.text("提示"), isPresented: Binding(
            get: { relay.errorMessage != nil },
            set: { if !$0 { relay.errorMessage = nil } }
        )) {
            Button(AppLocalizer.text("好")) { relay.errorMessage = nil }
        } message: {
            Text(relay.errorMessage ?? "")
        }
    }

    private var approvalContent: some View {
        List {
            Section {
                Label {
                    Text(AppLocalizer.localizedRemote(request.title))
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                }
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(AppLocalizer.localizedRemote(request.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let command = request.command {
                Section(AppLocalizer.text("命令")) {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                }
            }

            if let directory = request.workingDirectory, !directory.isEmpty {
                Section(AppLocalizer.text("工作目录")) {
                    Text(directory)
                        .font(.system(.caption2, design: .monospaced))
                }
            }

            if request.requestsNetwork || !request.requestedPaths.isEmpty {
                Section(AppLocalizer.text("访问范围")) {
                    if request.requestsNetwork {
                        Label(AppLocalizer.text("网络访问"), systemImage: "network")
                    }
                    ForEach(Array(request.requestedPaths.enumerated()), id: \.offset) { _, path in
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }

            Section {
                InteractionReceiptView(receipt: relay.decisionReceipts.result(for: request.id), pending: relay.pendingDecisionIDs.contains(request.id))
                if relay.decisionReceipts.result(for: request.id) != .accepted,
                   !relay.pendingDecisionIDs.contains(request.id) {
                    Button(role: .destructive) {
                        relay.decide(.deny, request: request)
                    } label: {
                        Label(AppLocalizer.text("拒绝"), systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .watchGlassButton()
                    .disabled(request.isExpired)

                    if #available(watchOS 11.0, *) {
                        approvalButton
                            .handGestureShortcut(.primaryAction)
                    } else {
                        approvalButton
                    }
                    Text(AppLocalizer.text("佩戴并解锁手表，启用腕部检测后批准"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var questionContent: some View {
        // A multi-control form inside one watchOS List row snaps between its
        // edges. A continuous scroll surface keeps every option reachable.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The question itself is the primary heading. Repeating the
                // generic request title/summary pushes all options off-screen.
                InteractionReceiptView(receipt: relay.decisionReceipts.result(for: request.id),
                    pending: relay.pendingDecisionIDs.contains(request.id))
                if relay.decisionReceipts.result(for: request.id) != .accepted {
                    UserInputResponseForm(request: request, isSending: relay.pendingDecisionIDs.contains(request.id)) {
                        relay.decide(.allowOnce, request: request, answers: $0)
                    }.id(request.id)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var approvalButton: some View {
        Button {
            relay.decide(.allowOnce, request: request)
        } label: {
            Label(AppLocalizer.text("批准一次"), systemImage: "checkmark.shield.fill")
                .frame(maxWidth: .infinity)
        }
        .watchPrimaryButton()
        .tint(.green)
        .disabled(request.isExpired)
    }
}
