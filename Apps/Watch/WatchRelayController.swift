import Foundation
import LocalAuthentication
import SwiftUI
import WatchKit
import WidgetKit
import UserNotifications
@preconcurrency import WatchConnectivity
import CodexWatchCore

@MainActor
final class WatchRelayController: NSObject, ObservableObject {
    // Every heartbeat must update freshness, but only visible changes should
    // invalidate a Watch List while the person is scrolling with the crown.
    private(set) var snapshot = DashboardSnapshot.empty {
        willSet {
            if !snapshot.isVisuallyEquivalent(to: newValue) { objectWillChange.send() }
        }
    }
    private(set) var lastReceivedAt: Date?
    private(set) var isReachable = false
    @Published private(set) var pendingDecisionIDs: Set<String> = []
    @Published private(set) var decisionReceipts = CommandReceipts()
    @Published var selectedNotificationRequestID: String?
    private var notifiedInteractionIDs: Set<String> = []
    @Published private(set) var pendingCommandTaskIDs: Set<String> = []
    @Published private(set) var taskHistories: [String: TaskHistoryState] = [:]
    @Published private(set) var commandReceipts = CommandReceipts()
    @Published private(set) var checkingCommandIDs: Set<String> = []
    @Published private(set) var commandStorageAvailable = false
    @Published private(set) var commandStorageRepairNeeded = false
    @Published private(set) var commandStorageRepairReceipt: CommandOutboxRepairReceipt?
    @Published private(set) var pendingCommandTransportError: String?
    @Published private(set) var connectionIssue: String?
    @Published private(set) var shortcutChatTasks: [AgentTask] = []
    @Published var errorMessage: String?
    @Published var usageResetResult: String?

    private static let deviceIDKey = "CodexWatch.watch.deviceID"
    private static let outboxKey = "CodexWatch.watch.outbox"
    private static let commandOutboxKey = "CodexWatch.watch.commandOutbox"
    private static let resetOutboxKey = "CodexWatch.watch.resetOutbox"
    private static let shortcutChatsKey = "CodexWatch.watch.shortcutChats"
    private static let shortcutPendingKey = "CodexWatch.watch.shortcutPending"
    private static let remoteSnapshotFreshness = RelayTimingPolicy.snapshotFreshness

    let deviceID: String
    private var session: WCSession?
    private var remoteClient: RemoteRelayClient?
    private var browserGatewayEnabled = false
    private var browserChatSnapshot = DashboardSnapshot.empty
    private var remotePollTask: Task<Void, Never>?
    private var remoteWaitTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var remoteRefreshID: UUID?
    private var foregroundActive = true
    private var phoneSnapshotRetryGate = RelayRetryGate()
    private var phoneSnapshotRequestID: UUID?
    private var phoneSnapshotTimeoutTask: Task<Void, Never>?
    private var phoneSnapshotResult = "not-requested"
    private var lastPhoneSnapshotAt: Date?
    private var presenceExpiryTask: Task<Void, Never>?
    private var urgentRemotePollingUntil = Date.distantPast
    private var remoteRetryGate = RelayRetryGate()
    private var outbox: [String: PendingRecord] = [:]
    /// Wrist detection is a system confirmation sheet. Do not allow rapid
    /// taps to start a second sheet for the same request before the first one
    /// has returned.
    private var authenticatingApprovalIDs: Set<String> = []
    private var commandOutbox: [String: PendingCommandRecord] = [:]
    private var commandStorageReadFailed = false
    #if CONTROLLER_FAULT_TESTS
    private let commandFaultEnvironment = ControllerCommandFaultEnvironment.current
    #endif
    private var commandStorageQASessionID: UUID? {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard isUIPreview, let index = args.firstIndex(of: "-CommandStorageQASession"), args.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: args[index + 1])
        #else
        return nil
        #endif
    }
    private var commandStore: CommandOutboxFileStore {
        #if CONTROLLER_FAULT_TESTS
        return commandFaultEnvironment!.store
        #else
        let base = CommandOutboxFileStore.applicationURL()
        if let id = commandStorageQASessionID {
            return .init(fileURL: base.deletingLastPathComponent().appendingPathComponent("QA", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("commands.plist"))
        }
        return .init(fileURL: base)
        #endif
    }
    private var commandStatusQueries = CommandStatusQueries()
    private var historyRequests: [String: TaskHistoryRequest] = [:]
    private var resetOutbox: [String: PendingResetRecord] = [:]
    private var pendingResetRequestIDs: Set<String> = []
    private var shortcutPending: [String: ShortcutChatBridge.PendingRequest] = [:]
    private var started = false
    private var lastWidgetSignature = ""
    private var lastWidgetApprovalIDs: Set<String> = []
    private var lastWidgetReloadAt = Date.distantPast
    private var lastBackgroundRefreshRequestAt = Date.distantPast
    private let isUIPreview = ProcessInfo.processInfo.arguments.contains("-UIPreview")
    /// Developer-only simulator hook: keep the preview snapshot but exercise
    /// the real wrist-detection policy instead of short-circuiting the decision.
    private let isAuthPreview = ProcessInfo.processInfo.arguments.contains("-PreviewApprovalAuth")
    private let diagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("-RelayDiagnostics")
    private var lastRelayDiagnosticSuccess: Date?
    private var lastDirectSnapshotAt: Date?

    override init() {
        #if CONTROLLER_FAULT_TESTS
        guard let environment = commandFaultEnvironment else { fatalError("Isolated controller environment required") }
        deviceID = environment.deviceID
        super.init()
        remoteClient = environment.client
        snapshot = environment.snapshot
        loadCommandOutbox()
        #else
        let stored = UserDefaults.standard.string(forKey: Self.deviceIDKey)
        let resolved = stored ?? UUID().uuidString
        if stored == nil { UserDefaults.standard.set(resolved, forKey: Self.deviceIDKey) }
        deviceID = resolved
        super.init()
        if isUIPreview {
            commandStorageAvailable = true
            snapshot = .uiPreview(
                english: ProcessInfo.processInfo.arguments.contains {
                    $0 == AppLanguage.english.rawValue || $0 == "-\(AppLanguage.english.rawValue)"
                },
                longHistory: ProcessInfo.processInfo.arguments.contains("-PreviewLongHistory"),
                unknownUsage: ProcessInfo.processInfo.arguments.contains("-PreviewUnknownUsage"),
                questions: ProcessInfo.processInfo.arguments.contains("-PreviewQuestions")
            )
            lastReceivedAt = Date()
            isReachable = true
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-PreviewUnconfirmedCommand") {
                let target = ProcessInfo.processInfo.arguments.contains("-PreviewTaskDetail") ? "preview-recent" : TaskCommand.newChatTaskID
                let envelope = BridgeEnvelope.taskCommand(.init(taskID: target, prompt: "  原文水獭🦦  ", deviceID: deviceID), sender: deviceID)
                if let bytes = try? CodexWatchCoding.makeEncoder().encode(envelope) {
                    let id = ProcessInfo.processInfo.arguments.contains("-PreviewMismatchedOriginal") ? "qa-wrong-index" : envelope.messageID
                    commandOutbox[id] = .init(messageID: id, taskID: target, data: bytes, stopped: true)
                }
                if ProcessInfo.processInfo.arguments.contains("-PreviewMultipleUnconfirmedCommands") {
                    commandOutbox.removeAll()
                    for (offset, prompt) in ["  原文水獭🦦  ", "  后续枫叶🍁  "].enumerated() {
                        var original = BridgeEnvelope.taskCommand(.init(taskID: target, prompt: prompt, deviceID: deviceID), sender: deviceID)
                        original.messageID = offset == 0 ? "z-older" : "a-newer"
                        original.sentAt = Date().addingTimeInterval(Double(offset - 2) * 30)
                        if let bytes = try? CodexWatchCoding.makeEncoder().encode(original) {
                            commandOutbox[original.messageID] = .init(messageID: original.messageID, taskID: target, data: bytes, stopped: true)
                        }
                    }
                }
            }
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if commandStorageQASessionID != nil {
                if ProcessInfo.processInfo.arguments.contains("-SeedCorruptCommandStorageQA") {
                    do {
                        try commandStore.save([])
                        try Data("QA_CORRUPT_QUEUE".utf8).write(to: commandStore.fileURL, options: .atomic)
                    } catch { commandStorageReadFailed = true; markCommandStorageUnavailable() }
                } else if ProcessInfo.processInfo.arguments.contains("-SeedCommandStorageQA") {
                    do { try commandStore.save(commandOutbox.values.map { record in
                        var active = record; active.stopped = false; return active
                    }) } catch { commandStorageReadFailed = true; markCommandStorageUnavailable() }
                }
                if !commandStorageReadFailed { loadCommandOutbox() }
            }
            #endif
        }
        if !isUIPreview, let configuration = RemoteRelayConfiguration.fromMainBundle() {
            remoteClient = RemoteRelayClient(configuration: configuration, waitsForConnectivity: true)
            browserGatewayEnabled = configuration.browserGatewayEnabled
        }
        // Preview runs must be deterministic. Never hydrate production
        // outboxes or shortcut history into a simulator preview: a previous
        // approval attempt would otherwise make a fresh request appear to be
        // "sending reliably" before the current authentication path runs.
        if !isUIPreview {
            loadOutbox()
            loadCommandOutbox()
            loadResetOutbox()
            loadShortcutState()
            pruneExpiredOutboxes()
        }
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        if isUIPreview { return }
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        presenceExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                self.pruneExpiredOutboxes()
                self.expireMacPresence()
            }
        }
        guard WCSession.isSupported() else {
            errorMessage = AppLocalizer.text("此 Apple Watch 不支持连接")
            return
        }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        recordRelayDiagnostic(stage: "starting", snapshotError: nil, mailboxError: nil)
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexWatchStatus")
        startRemotePolling()
        scheduleBackgroundRefresh()
    }

    func refresh() {
        guard !isUIPreview else { return }
        pruneExpiredOutboxes()
        expireMacPresence()
        guard foregroundActive else { return }
        beginUrgentRemotePolling()
        requestPhoneSnapshot()
        flushOutbox()
        Task { await refreshRemoteNow() }
    }

    func setForegroundActive(_ active: Bool) {
        guard !isUIPreview else { return }
        foregroundActive = active
        if active {
            refresh()
        } else {
            // Default URLSession requests cannot continue reliably once the
            // Watch becomes inactive. Do not leave a suspended refresh ahead
            // of the next user action; system background windows are handled
            // separately by performBackgroundRefresh.
            remotePollTask?.cancel()
            remotePollTask = nil
            remoteWaitTask?.cancel()
            remoteWaitTask = nil
            remoteRefreshTask?.cancel()
            finishPhoneSnapshotRequest(phoneSnapshotRequestID, result: "inactive")
        }
    }

    private func requestPhoneSnapshot() {
        guard foregroundActive, let session, session.activationState == .activated,
              let data = try? CodexWatchCoding.makeEncoder().encode(
                BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: deviceID)
              ), phoneSnapshotRetryGate.begin("snapshot", interval: 15) else { return }
        let id = UUID()
        phoneSnapshotRequestID = id
        phoneSnapshotResult = "pending"
        // On Watch, sendMessageData can wake the iPhone companion in the
        // background. isReachable is not a requirement for attempting this
        // wake-up; an unavailable companion reports through errorHandler.
        session.sendMessageData(
            data,
            replyHandler: phoneSnapshotReplyHandler(for: id),
            errorHandler: phoneSnapshotErrorHandler(for: id)
        )
        phoneSnapshotTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.finishPhoneSnapshotRequest(id, result: "timeout")
        }
    }

    // Construct callbacks outside MainActor: WCSession invokes them on its
    // utility queue. Decode value data there, then explicitly hop to the UI.
    nonisolated private func phoneSnapshotReplyHandler(for id: UUID) -> (Data) -> Void {
        { [weak self] data in
            let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
            Task { @MainActor [weak self] in
                guard let self, self.phoneSnapshotRequestID == id else { return }
                if let envelope, let incoming = envelope.snapshot,
                   envelope.kind == .snapshot, RelayTimingPolicy.isFresh(envelope.sentAt),
                   RelayTimingPolicy.isFresh(incoming.capturedAt) {
                    self.lastPhoneSnapshotAt = incoming.capturedAt
                    self.handle(envelope)
                    self.finishPhoneSnapshotRequest(id, result: "ok")
                } else {
                    self.finishPhoneSnapshotRequest(id, result: "stale-or-invalid")
                }
            }
        }
    }

    nonisolated private func phoneSnapshotErrorHandler(for id: UUID) -> (Error) -> Void {
        { [weak self] error in
            let value = error as NSError
            let code = "\(value.domain):\(value.code)"
            Task { @MainActor [weak self] in
                self?.finishPhoneSnapshotRequest(id, result: code)
            }
        }
    }

    private func finishPhoneSnapshotRequest(_ id: UUID?, result: String) {
        guard let id, phoneSnapshotRequestID == id else { return }
        phoneSnapshotRequestID = nil
        phoneSnapshotTimeoutTask?.cancel()
        phoneSnapshotTimeoutTask = nil
        phoneSnapshotRetryGate.finish("snapshot")
        phoneSnapshotResult = result
    }

    /// Called by watchOS while the app is not on screen.  WatchConnectivity can
    /// still deliver queued context/user-info updates; this also fetches the
    /// encrypted relay once during the system-provided background window.
    func performBackgroundRefresh(_ task: WKRefreshBackgroundTask) {
        if let snapshotTask = task as? WKSnapshotRefreshBackgroundTask {
            // A UI snapshot has only a few seconds of runtime. It is not a
            // scheduled network refresh; render the current state and finish.
            snapshotTask.setTaskCompleted(
                restoredDefaultState: false,
                estimatedSnapshotExpiration: nil,
                userInfo: nil
            )
            return
        }
        Task { [weak self] in
            guard let self else {
                task.setTaskCompletedWithSnapshot(false)
                return
            }
            defer {
                task.setTaskCompletedWithSnapshot(self.snapshot.bridgeConnected)
                self.scheduleBackgroundRefresh()
            }
            await self.refreshRemoteNow()
            self.flushOutbox()
        }
    }

    func decide(_ choice: ApprovalChoice, request: ApprovalRequest, answers: [String: [String]]? = nil) {
        guard choice == .allowOnce || choice == .deny else { return }
        if let questions = request.questions {
            guard let answers, (try? UserInputValidation.validate(answers, questions: questions)) != nil else { return }
        } else if answers != nil { return }
        if isUIPreview && !isAuthPreview {
            acceptPreviewDecision(request, choice: choice)
            return
        }
        guard !pendingDecisionIDs.contains(request.id),
              authenticatingApprovalIDs.insert(request.id).inserted else { return }
        Task {
            defer { authenticatingApprovalIDs.remove(request.id) }
            do {
                _ = try ApprovalReviewValidation.current(
                    reviewed: request, pending: snapshot.pendingApprovals
                )
                if choice == .allowOnce {
                    let context = LAContext()
                    // This policy otherwise permits a fresh passcode entry
                    // while the Watch is off the wrist. Accept only the
                    // system's existing wrist-authenticated state; never
                    // present a passcode sheet as a substitute for wearing it.
                    context.interactionNotAllowed = true
                    var policyError: NSError?
                    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, error: &policyError) else {
                        throw policyError ?? LAError(.authenticationFailed)
                    }
                    let authenticated = try await context.evaluatePolicy(
                        .deviceOwnerAuthenticationWithWristDetection,
                        localizedReason: AppLocalizer.format(
                            "批准 Codex：%@",
                            AppLocalizer.localizedRemote(request.title)
                        )
                    )
                    guard authenticated else { return }
                }

                let current = try ApprovalReviewValidation.current(
                    reviewed: request, pending: snapshot.pendingApprovals
                )
                // Exercise wrist authentication without transmitting the
                // synthetic preview request to the production relay.
                if isUIPreview {
                    acceptPreviewDecision(current, choice: choice)
                    return
                }
                let decision = ApprovalDecision(
                    requestID: current.id,
                    requestDigest: current.requestDigest,
                    choice: choice,
                    decidedAt: Date(),
                    deviceID: deviceID,
                    nonce: current.nonce,
                    origin: .watch,
                    answers: answers
                )
                let envelope = BridgeEnvelope.decision(
                    decision,
                    sender: deviceID,
                    replyMailbox: RemoteRelayMailbox.watch.rawValue
                )
                let data = try CodexWatchCoding.makeEncoder().encode(envelope)
                outbox[envelope.messageID] = PendingRecord(
                    messageID: envelope.messageID,
                    decisionID: decision.id,
                    data: data
                )
                pendingDecisionIDs.insert(request.id)
                persistOutbox()
                // This confirms the tap, not remote execution. Success is
                // played only when an acknowledgement returns from the Mac.
                WKInterfaceDevice.current().play(.click)
                send(envelope, queueIfUnreachable: true)
                enqueueForRemoteDelivery(envelope, urgent: true)
            } catch {
                if let authenticationError = error as? LAError,
                   authenticationError.code == .notInteractive {
                    errorMessage = AppLocalizer.text("请佩戴并解锁手表，开启腕部检测后重试")
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func acceptPreviewDecision(_ request: ApprovalRequest, choice: ApprovalChoice) {
        decisionReceipts.record(.accepted, for: request.id)
        var preview = snapshot
        preview.pendingApprovals.removeAll { $0.id == request.id }
        snapshot = preview
        WKInterfaceDevice.current().play(choice == .allowOnce ? .success : .click)
    }

    @discardableResult
    func sendCommand(_ prompt: String, to task: AgentTask, options: CodexExecutionOptions? = nil) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUIPreview else { return nil }
        guard !task.isChat && !task.isNativeChat else {
            errorMessage = AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务")
            return nil
        }
        if ShortcutChatBridge.isShortcutChat(task.id) {
            // Legacy Shortcut chats are intentionally read-only.  They could
            // target Gemini or inject text into whichever app owns the old
            // shortcut, so never allow a follow-up to leave this app through
            // that route again.
            errorMessage = AppLocalizer.text("旧版快捷指令对话已停用，请新建 Chat")
            return nil
        }
        let command = TaskCommand(
            taskID: task.id,
            prompt: prompt,
            activeTurnID: task.activeTurnID,
            deviceID: deviceID,
            executionTarget: nil,
            options: options
        )
        return queueCommand(command)
    }

    @discardableResult
    func startCodexChat(_ prompt: String, options: CodexExecutionOptions? = nil) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUIPreview else { return nil }
        return queueCommand(TaskCommand(taskID: TaskCommand.newChatTaskID, prompt: prompt, deviceID: deviceID, options: options))
    }

    func task(id: String) -> AgentTask? {
        snapshot.tasks.first { $0.id == id }
    }

    func recoverableCommand(for taskID: String) -> RecoverableCommandDraft? {
        CommandRecovery.earliest(commandOutbox.values
            .filter { $0.taskID == taskID && $0.stopped == true }
            .map { .init(messageID: $0.messageID, originalData: $0.data, taskID: $0.taskID) })
    }

    func commandReviewState(for id: String) -> CommandReviewState {
        .init(receipt: commandReceipts.result(for: id), isPending: commandOutbox[id]?.stopped == true,
            isChecking: checkingCommandIDs.contains(id))
    }

    func initialCommandDraft(for taskID: String) -> MessageDraft {
        var draft = MessageDraft()
        if let saved = recoverableCommand(for: taskID) { draft.restore(saved) }
        #if DEBUG && targetEnvironment(simulator)
        if isUIPreview {
            if ProcessInfo.processInfo.arguments.contains("-PreviewRejectedDraft") {
                draft.discardLocalSubmission(); draft.text = "  被拒绝的草稿🦊  "
                draft.submitted("qa-definite-rejection"); draft.apply(.failed(AppLocalizer.text("远程数据校验失败")))
            } else if ProcessInfo.processInfo.arguments.contains("-PreviewEditedDraft") {
                draft.text = "  新草稿海狸🦫  "
            }
        }
        #endif
        return draft
    }

    private func commandMaySend(_ envelope: BridgeEnvelope) -> Bool {
        guard envelope.kind == .taskCommand else { return true }
        guard commandStorageAvailable else { return false }
        guard let record = commandOutbox[envelope.messageID], record.stopped != true else { return false }
        guard !CommandRecovery.shouldPause(record.data),
              let original = CommandRecovery.original(record.data),
              original.messageID == record.messageID, original.taskCommand?.taskID == record.taskID else {
            commandOutbox[record.messageID]?.stopped = true
            cancelQueuedPhoneDelivery(record.messageID)
            commandReceipts.record(.unconfirmed(CommandRecovery.unconfirmedText), for: record.messageID)
            persistCommandOutbox(); refreshPendingCommandTaskIDs()
            return false
        }
        return true
    }

    func checkCommandStatus(_ id: String?) {
        guard let id, let record = commandOutbox[id], record.stopped == true, !isUIPreview else { return }
        guard let original = CommandRecovery.original(record.data), original.messageID == record.messageID,
              original.taskCommand?.taskID == record.taskID,
              let query = commandStatusQueries.begin(originalData: record.data, replyMailbox: RemoteRelayMailbox.watch.rawValue) else {
            commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: id)
            return
        }
        checkingCommandIDs = commandStatusQueries.checkingIDs
        send(query, queueIfUnreachable: false)
        enqueueForRemoteDelivery(query, urgent: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let originalID = self.commandStatusQueries.fail(query.messageID) else { return }
            self.checkingCommandIDs = self.commandStatusQueries.checkingIDs
            self.commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: originalID)
        }
    }

    /// Explicit local storage retry only. Never resumes a stopped command.
    func retryCommandStorage() {
        guard !isUIPreview || commandStorageQASessionID != nil else { return }
        if commandStorageReadFailed {
            commandStorageReadFailed = false
            loadCommandOutbox()
        } else { _ = persistCommandOutbox() }
        refreshPendingCommandTaskIDs()
    }

    @discardableResult
    func repairCommandStorage() -> Bool {
        guard commandStorageRepairNeeded, !isUIPreview || commandStorageQASessionID != nil else { return false }
        do {
            let receipt = try commandStore.quarantineAndRebuild(legacyData: isUIPreview ? nil : UserDefaults.standard.data(forKey: Self.commandOutboxKey))
            commandStorageReadFailed = false
            commandStorageRepairNeeded = false
            commandStorageRepairReceipt = receipt
            loadCommandOutbox()
            return commandStorageAvailable
        } catch {
            errorMessage = AppLocalizer.text("无法确认修复结果。请保留应用并重试。")
            return false
        }
    }

    @discardableResult
    func discardUnconfirmedCommand(_ id: String?) -> Bool {
        guard let id, let record = commandOutbox[id], record.stopped == true else { return false }
        commandOutbox.removeValue(forKey: id)
        guard persistCommandOutbox() else {
            commandOutbox[id] = record
            refreshPendingCommandTaskIDs()
            return false
        }
        cancelQueuedPhoneDelivery(id)
        commandStatusQueries.cancel(originalMessageID: id)
        checkingCommandIDs = commandStatusQueries.checkingIDs
        refreshPendingCommandTaskIDs()
        return true
    }

    private func applyCommandStatus(_ resolution: CommandStatusQueries.Resolution) {
        guard commandOutbox[resolution.originalMessageID] != nil else { return }
        cancelQueuedPhoneDelivery(resolution.originalMessageID)
        switch resolution.receipt {
        case .accepted, .failed:
            commandOutbox.removeValue(forKey: resolution.originalMessageID)
        case .unconfirmed:
            commandOutbox[resolution.originalMessageID]?.stopped = true
        }
        commandReceipts.record(resolution.receipt, for: resolution.originalMessageID)
        persistCommandOutbox(); refreshPendingCommandTaskIDs()
    }

    func loadHistory(for taskID: String, older: Bool = false, refresh: Bool = false) {
        var state = taskHistories[taskID] ?? TaskHistoryState()
        state.applyLive(task(id: taskID)?.messages ?? [])
        guard !state.isLoading, refresh || older || !state.hasLoaded else { return }
        guard !older || state.hasMore else { return }
        let request = TaskHistoryRequest(taskID: taskID, beforeMessageID: older ? state.nextBeforeMessageID : nil,
            continuation: older ? state.nextContinuation : nil)
        state.beginLoading()
        taskHistories[taskID] = state
        if isUIPreview {
            if let page = try? TaskHistoryPaging.page(messages: task(id: taskID)?.messages ?? [], request: request) {
                taskHistories[taskID]?.apply(page)
            }
            return
        }
        let envelope = BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: deviceID,
            replyMailbox: RemoteRelayMailbox.watch.rawValue, taskHistoryRequest: request)
        historyRequests[envelope.messageID] = request
        send(envelope, queueIfUnreachable: false)
        enqueueForRemoteDelivery(envelope, urgent: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let pending = self.historyRequests.removeValue(forKey: envelope.messageID) else { return }
            self.taskHistories[pending.taskID]?.fail(AppLocalizer.text("无法加载聊天记录，请重试"))
        }
    }

    func handleShortcutCallback(_ url: URL) {
        guard let callback = ShortcutChatBridge.parseCallback(url),
              let pending = shortcutPending.removeValue(forKey: callback.requestID),
              pending.chatID == callback.chatID,
              let index = shortcutChatTasks.firstIndex(where: { $0.id == callback.chatID }) else {
            return
        }
        let current = shortcutChatTasks[index]
        switch callback.outcome {
        case .success:
            let response = callback.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            shortcutChatTasks[index] = response.isEmpty
                ? ShortcutChatBridge.failing(current, message: AppLocalizer.text("ChatGPT 没有返回文字回复"))
                : ShortcutChatBridge.completing(current, response: response)
            if !response.isEmpty { WKInterfaceDevice.current().play(.success) }
        case .cancel:
            shortcutChatTasks[index] = ShortcutChatBridge.failing(
                current,
                message: AppLocalizer.text("已取消 ChatGPT 快捷指令")
            )
        case .error:
            shortcutChatTasks[index] = ShortcutChatBridge.failing(
                current,
                message: callback.errorMessage ?? AppLocalizer.text("ChatGPT 快捷指令运行失败")
            )
        }
        persistShortcutState()
        refreshPendingCommandTaskIDs()
    }

    private var hasFreshMacChatRoute: Bool {
        guard snapshot.bridgeConnected, let lastReceivedAt else { return false }
        return Date().timeIntervalSince(lastReceivedAt) <= Self.remoteSnapshotFreshness
    }

    private func startShortcutChat(_ prompt: String) -> String {
        let chatID = ShortcutChatBridge.chatID()
        shortcutChatTasks.insert(
            ShortcutChatBridge.newTask(chatID: chatID, prompt: prompt),
            at: 0
        )
        launchShortcutChat(prompt: prompt, chatID: chatID, context: [])
        return chatID
    }

    private func continueShortcutChat(_ prompt: String, taskID: String) {
        guard let index = shortcutChatTasks.firstIndex(where: { $0.id == taskID }) else { return }
        let context = shortcutChatTasks[index].messages
        shortcutChatTasks[index] = ShortcutChatBridge.appendingUserMessage(
            prompt,
            to: shortcutChatTasks[index]
        )
        launchShortcutChat(prompt: prompt, chatID: taskID, context: context)
    }

    private func launchShortcutChat(
        prompt: String,
        chatID: String,
        context: [ChatMessage]
    ) {
        let requestID = UUID().uuidString
        let input = ShortcutChatBridge.contextualPrompt(newMessage: prompt, messages: context)
        guard let url = ShortcutChatBridge.runURL(
            prompt: input,
            requestID: requestID,
            chatID: chatID
        ) else {
            markShortcutLaunchFailed(requestID: requestID, chatID: chatID)
            return
        }
        shortcutPending[requestID] = .init(requestID: requestID, chatID: chatID)
        persistShortcutState()
        refreshPendingCommandTaskIDs()
        WKApplication.shared().openSystemURL(url)
        WKInterfaceDevice.current().play(.click)
    }

    private func markShortcutLaunchFailed(requestID: String, chatID: String) {
        shortcutPending.removeValue(forKey: requestID)
        if let index = shortcutChatTasks.firstIndex(where: { $0.id == chatID }) {
            shortcutChatTasks[index] = ShortcutChatBridge.failing(
                shortcutChatTasks[index],
                message: AppLocalizer.text("请先安装 Codex Control Chat 快捷指令")
            )
        }
        persistShortcutState()
        refreshPendingCommandTaskIDs()
    }

    func consumeResetCredit(_ creditID: String) {
        guard !isUIPreview else { return }
        guard snapshot.usage?.resetCredits?.contains(where: {
            $0.id == creditID && $0.status == .available && ($0.expiresAt.map { $0 > Date() } ?? true)
        }) == true else {
            usageResetResult = "noCredit"
            return
        }
        guard !resetOutbox.values.contains(where: {
            (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: $0.data))?.usageReset?.creditID == creditID
        }) else {
            usageResetResult = AppLocalizer.text("正在发送…")
            return
        }
        usageResetResult = nil
        let envelope = BridgeEnvelope.usageReset(
            UsageResetRequest(creditID: creditID, deviceID: deviceID),
            sender: deviceID,
            replyMailbox: RemoteRelayMailbox.watch.rawValue
        )
        guard let data = try? CodexWatchCoding.makeEncoder().encode(envelope) else {
            errorMessage = AppLocalizer.text("无法创建重置请求")
            return
        }
        resetOutbox[envelope.messageID] = PendingResetRecord(
            messageID: envelope.messageID,
            requestID: envelope.usageReset?.id ?? envelope.messageID,
            data: data
        )
        pendingResetRequestIDs.insert(envelope.messageID)
        persistResetOutbox()
        WKInterfaceDevice.current().play(.click)
        send(envelope, queueIfUnreachable: true)
        enqueueForRemoteDelivery(envelope, urgent: true)
    }

    private func queueCommand(_ command: TaskCommand) -> String? {
        guard commandStorageAvailable else {
            errorMessage = AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。")
            return nil
        }
        guard !command.targetsBrowserChat else {
            errorMessage = AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务")
            return nil
        }
        guard commandOutbox.count < 64,
              !commandOutbox.values.contains(where: { $0.taskID == command.taskID && $0.stopped == true }) else {
            errorMessage = CommandRecovery.unconfirmedText
            return nil
        }
        let envelope = BridgeEnvelope.taskCommand(
            command,
            sender: deviceID,
            replyMailbox: RemoteRelayMailbox.watch.rawValue
        )
        guard let data = try? CodexWatchCoding.makeEncoder().encode(envelope) else { return nil }
        guard data.count <= CommandRecovery.maximumStoredBytes else {
            errorMessage = AppLocalizer.text("指令内容过长，请缩短后重试。")
            return nil
        }
        guard CommandRecovery.original(data) != nil else {
            errorMessage = AppLocalizer.text("远程数据校验失败")
            return nil
        }
        commandOutbox[envelope.messageID] = PendingCommandRecord(
            messageID: envelope.messageID,
            taskID: command.taskID,
            data: data
        )
        guard persistCommandOutbox() else {
            refreshPendingCommandTaskIDs()
            return envelope.messageID
        }
        refreshPendingCommandTaskIDs()
        WKInterfaceDevice.current().play(.click)
        send(envelope, queueIfUnreachable: true)
        enqueueForRemoteDelivery(envelope, urgent: true)
        return envelope.messageID
    }

    private func handle(_ envelope: BridgeEnvelope) {
        guard envelope.version <= BridgeEnvelope.currentVersion else {
            errorMessage = AppLocalizer.text("请更新 Apple Watch App")
            return
        }
        switch envelope.kind {
        case .snapshot:
            if envelope.commandStatusReceipt != nil {
                if let resolution = commandStatusQueries.receive(envelope) { applyCommandStatus(resolution) }
                checkingCommandIDs = commandStatusQueries.checkingIDs
                return
            }
            if let page = envelope.taskHistoryPage {
                guard let id = envelope.acknowledgedMessageID, let request = historyRequests[id], page.isValid(for: request) else { return }
                historyRequests.removeValue(forKey: id)
                var state = taskHistories[page.taskID] ?? TaskHistoryState()
                state.apply(page)
                taskHistories[page.taskID] = state
                return
            }
            guard let snapshot = envelope.snapshot,
                  snapshot.capturedAt >= self.snapshot.capturedAt else { return }
            let merged = mergedSnapshot(snapshot.reconcilingMacPresence())
            notifyForNewInteractions(in: merged)
            let contentChanged = hasVisibleChange(from: self.snapshot, to: merged)
            self.snapshot = merged
            if contentChanged {
                for task in merged.tasks where taskHistories[task.id] != nil {
                    taskHistories[task.id]?.applyLive(task.messages)
                }
            }
            lastReceivedAt = snapshot.capturedAt
            // A fresh snapshot is authoritative: it also clears any old
            // transport failure that WatchConnectivity delivered late while
            // the paired Mac Bridge was being upgraded.
            if errorMessage != nil { errorMessage = nil }
            if connectionIssue != nil { connectionIssue = nil }
            if contentChanged {
                reloadWidgetIfNeeded(for: merged)
            }
        case .acknowledgement:
            guard let messageID = envelope.acknowledgedMessageID else { return }
            cancelQueuedPhoneDelivery(messageID)
            if let record = outbox.removeValue(forKey: messageID) {
                if let decoded = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: record.data),
                   let requestID = decoded.decision?.requestID {
                    pendingDecisionIDs.remove(requestID)
                    decisionReceipts.record(.accepted, for: requestID)
                    WKInterfaceDevice.current().play(.success)
                }
                persistOutbox()
            }
            if commandOutbox.removeValue(forKey: messageID) != nil {
                commandStatusQueries.cancel(originalMessageID: messageID)
                checkingCommandIDs = commandStatusQueries.checkingIDs
                if commandOutbox.isEmpty { pendingCommandTransportError = nil }
                commandReceipts.record(.accepted, for: messageID)
                persistCommandOutbox()
                refreshPendingCommandTaskIDs()
                // Receipt acknowledgement arrives before the Mac has
                // necessarily published the assistant turn. Keep the Watch
                // relay poller in its fast response window so the reply is
                // delivered without waiting for the 60-second idle cadence.
                beginUrgentRemotePolling(for: 60)
                WKInterfaceDevice.current().play(.success)
            }
            if resetOutbox.removeValue(forKey: messageID) != nil {
                pendingResetRequestIDs.remove(messageID)
                persistResetOutbox()
                usageResetResult = UsageResetOutcome.confirmedResponse(envelope.message)
                if envelope.message.flatMap(UsageResetOutcome.init(rawValue:))?.confirmsConsumption == true {
                    WKInterfaceDevice.current().play(.success)
                }
            }
        case .error:
            let acknowledgedID = envelope.acknowledgedMessageID
            if let id = acknowledgedID, let originalID = commandStatusQueries.fail(id) {
                checkingCommandIDs = commandStatusQueries.checkingIDs
                commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: originalID)
                return
            }
            if let acknowledgedID { cancelQueuedPhoneDelivery(acknowledgedID) }
            if let id = acknowledgedID, let request = historyRequests.removeValue(forKey: id) {
                taskHistories[request.taskID]?.fail(AppLocalizer.text("无法加载聊天记录，请重试"))
                return
            }
            var matchedDecision: PendingRecord?
            if let acknowledgedID,
               let record = outbox.removeValue(forKey: acknowledgedID) {
                if let decoded = try? CodexWatchCoding.makeDecoder().decode(
                    BridgeEnvelope.self,
                    from: record.data
                ), let requestID = decoded.decision?.requestID {
                    pendingDecisionIDs.remove(requestID)
                    decisionReceipts.record(.failed(envelope.message ?? AppLocalizer.text("审批失败")), for: requestID)
                }
                persistOutbox()
                matchedDecision = record
            }
            let matchedCommand = acknowledgedID.flatMap { commandOutbox[$0] }
            let matchedReset = acknowledgedID.flatMap { resetOutbox.removeValue(forKey: $0) }
            if let matchedCommand {
                if let id = acknowledgedID {
                    let receipt = CommandRecovery.errorReceipt(envelope, originalData: matchedCommand.data)
                    if case .failed = receipt { commandOutbox.removeValue(forKey: id) }
                    else { commandOutbox[id]?.stopped = true }
                    commandReceipts.record(receipt, for: id)
                }
                persistCommandOutbox(); refreshPendingCommandTaskIDs()
            }
            if let messageID = envelope.acknowledgedMessageID,
               matchedReset != nil {
                pendingResetRequestIDs.remove(messageID)
                persistResetOutbox()
            }
            // A removed request is not proof that this decision took effect.
            // Retain the failed receipt, avoid recurring modal alerts, and
            // refresh the owner's queue. Never turn this error into success.
            if isTerminalApprovalRace(envelope) {
                errorMessage = nil
                refresh()
                return
            }
            // Accessibility status is a Mac-local setup issue. It must never
            // turn into a repeating full-screen Watch alert while a stale
            // command is being retried by another companion.
            if isAccessibilitySetupMessage(envelope.message) {
                errorMessage = nil
                return
            }
            // Ignore a delayed reply to an action this Watch no longer has in
            // its queue. Otherwise a stale desktop-permission error can be
            // re-presented every time watchOS wakes the app.
            guard matchedDecision != nil || matchedCommand != nil || matchedReset != nil else {
                return
            }
            if matchedCommand != nil { errorMessage = nil; return }
            errorMessage = envelope.message ?? AppLocalizer.text("审批失败")
        case .hello:
            refresh()
        case .requestSnapshot, .approvalDecision, .taskCommand, .usageReset:
            break
        }
    }

    /// Send every user action by both paths.  The Mac de-duplicates by the
    /// stable message ID, so this gives a Watch action the local low-latency
    /// route and the public relay fallback without ever running it twice.
    private func enqueueForRemoteDelivery(_ envelope: BridgeEnvelope, urgent: Bool) {
        guard RelayOutboxPolicy.isDeliverable(envelope), let remoteClient else { return }
        guard commandMaySend(envelope) else { return }
        guard remoteRetryGate.begin(envelope.messageID) else { return }
        if urgent { beginUrgentRemotePolling() }
        let destination: RemoteRelayMailbox = routesToBrowserGateway(envelope)
            ? .browser
            : .mac
        Task {
            defer { remoteRetryGate.finish(envelope.messageID) }
            guard commandMaySend(envelope) else { return }
            do {
                if destination == .browser {
                    try await remoteClient.enqueueBrowser(envelope)
                } else {
                    try await remoteClient.enqueue(envelope, to: destination)
                }
                if envelope.taskCommand != nil, pendingCommandTransportError != nil { pendingCommandTransportError = nil }
            } catch {
                guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
                // Keep the durable outbox and draft. Surface a compact inline
                // status, not a repeating full-screen alert on every retry.
                if envelope.taskCommand != nil {
                    pendingCommandTransportError = AppLocalizer.text("中继不可用")
                }
            }
        }
    }

    private func routesToBrowserGateway(_ envelope: BridgeEnvelope) -> Bool {
        guard browserGatewayEnabled,
              let command = envelope.taskCommand,
              command.targetsBrowserChat else { return false }
        if command.executionTarget == .browser { return true }
        if command.executionTarget == .mac { return false }
        if browserChatSnapshot.tasks.contains(where: { $0.id == command.taskID }) {
            return true
        }
        let browserIsFresh = browserChatSnapshot.bridgeConnected
            && Date().timeIntervalSince(browserChatSnapshot.capturedAt) <= 90
        if browserIsFresh { return true }
        return !hasFreshMacChatRoute
    }

    private func preferredNewChatExecutionTarget() -> TaskExecutionTarget? {
        guard browserGatewayEnabled else { return nil }
        // watchOS cannot reliably infer whether the Mac is awake from
        // WatchConnectivity reachability. When the independent browser route
        // is enabled, new Watch Chats therefore go to the Oracle queue; only
        // existing conversations remain pinned to their recorded owner.
        return .browser
    }

    private var hasFreshBrowserChatRoute: Bool {
        browserGatewayEnabled
            && browserChatSnapshot.bridgeConnected
            && Date().timeIntervalSince(browserChatSnapshot.capturedAt) <= 90
    }

    private func chatExecutionTarget(for task: AgentTask) -> TaskExecutionTarget? {
        guard browserGatewayEnabled else { return nil }
        return browserChatSnapshot.tasks.contains(where: { $0.id == task.id }) ? .browser : .mac
    }

    /// A compact network snapshot may temporarily omit older recent tasks or
    /// message history. Retaining a small recent window makes navigation and
    /// chat transcripts stable while the Mac is refreshing its task list.
    private func mergedSnapshot(_ incoming: DashboardSnapshot) -> DashboardSnapshot {
        incoming.mergingChatSnapshot(browserChatSnapshot).mergingRecentTasks(from: snapshot)
    }

    /// Heartbeat snapshots differ only in transport timestamps. Publishing
    /// each one invalidates every row of a watchOS List and makes the Digital
    /// Crown feel as if it is fighting the user. Compare only what is actually
    /// rendered, deliberately ignoring transport and message timestamps.
    private func hasVisibleChange(from current: DashboardSnapshot, to candidate: DashboardSnapshot) -> Bool {
        !current.isVisuallyEquivalent(to: candidate)
    }

    private func send(_ envelope: BridgeEnvelope, queueIfUnreachable: Bool) {
        guard commandMaySend(envelope) else { return }
        guard RelayOutboxPolicy.isDeliverable(envelope), let session,
              session.activationState == .activated,
              let data = try? CodexWatchCoding.makeEncoder().encode(envelope) else { return }
        if queueIfUnreachable, RelayOutboxPolicy.isDeliverable(envelope),
           !session.outstandingUserInfoTransfers.contains(where: {
               guard let pending = $0.userInfo["envelope"] as? Data,
                     let queued = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: pending) else { return false }
               return queued.messageID == envelope.messageID
           }) {
            session.transferUserInfo(["envelope": data])
        }
        if session.isReachable {
            // The error callback runs outside the MainActor. The durable
            // transfer and public relay are the authoritative retry paths, so
            // keep this immediate latency path free of actor-unsafe callbacks.
            session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
    }

    private func flushOutbox() {
        pruneExpiredOutboxes()
        for record in outbox.values {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: record.data) else {
                continue
            }
            send(envelope, queueIfUnreachable: true)
            enqueueForRemoteDelivery(envelope, urgent: false)
        }
        for record in commandOutbox.values where record.stopped != true {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.data
            ) else { continue }
            send(envelope, queueIfUnreachable: true)
            enqueueForRemoteDelivery(envelope, urgent: false)
        }
        for record in resetOutbox.values {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.data
            ) else { continue }
            send(envelope, queueIfUnreachable: true)
            enqueueForRemoteDelivery(envelope, urgent: false)
        }
    }

    private func startRemotePolling() {
        #if CONTROLLER_FAULT_TESTS
        return // Explicit single refreshes only; no autonomous test traffic.
        #else
        guard foregroundActive, remoteClient != nil, remotePollTask == nil else { return }
        remotePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // WatchConnectivity can report the paired iPhone as reachable
                // even when its companion app is suspended and no longer
                // forwarding snapshots. Always reconcile with the public
                // relay so Watch remains authoritative on its own network;
                // the adaptive interval below keeps idle traffic bounded.
                await self.refreshRemoteNow()
                guard !Task.isCancelled, self.remoteClient != nil else { return }

                // Normal watchOS apps cannot use WebSockets (TN3135). Keep
                // every Watch request on HTTPS. Only cancel the wait when a
                // user acts; never cancel an in-flight refresh or receipt.
                let waitInterval = self.remotePollingInterval
                let wait = Task<Void, Never> { try? await Task.sleep(for: .seconds(waitInterval)) }
                self.remoteWaitTask = wait
                await wait.value
                self.remoteWaitTask = nil
            }
        }
        #endif
    }

    /// A user action must not remain behind a long idle sleep. Poll quickly
    /// for a brief response window, then return to the battery-friendly rate.
    private func beginUrgentRemotePolling(for duration: TimeInterval = 30) {
        urgentRemotePollingUntil = max(
            urgentRemotePollingUntil,
            Date().addingTimeInterval(duration)
        )
        remoteWaitTask?.cancel()
        startRemotePolling()
    }

    private var remotePollingInterval: Double {
        if Date() < urgentRemotePollingUntil {
            return 2
        }
        let hasUrgentWork = snapshot.activeTaskCount > 0
            || !snapshot.pendingApprovals.filter({ !$0.isExpired }).isEmpty
            || !pendingCommandTaskIDs.isEmpty
            || !pendingDecisionIDs.isEmpty
            || !pendingResetRequestIDs.isEmpty
        return hasUrgentWork && snapshot.isMacOnline() ? 3 : RelayTimingPolicy.idleInterval
    }

    private func scheduleBackgroundRefresh() {
        guard !isUIPreview else { return }
        // Ask for a new system-managed window after 15 minutes.  watchOS owns
        // the actual schedule and may defer it for battery or network reasons.
        guard Date().timeIntervalSince(lastBackgroundRefreshRequestAt) >= 60 else { return }
        lastBackgroundRefreshRequestAt = Date()
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: nil
        ) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func reloadWidgetIfNeeded(for snapshot: DashboardSnapshot) {
        let approvalIDs = Set(snapshot.pendingApprovals
            .filter { !$0.isExpired }
            .map(\.id))
        let approvals = approvalIDs.sorted().joined(separator: ",")
        let tasks = snapshot.tasks.prefix(4).map {
            let progressBucket = Int(((TaskLiveActivityPolicy.progress($0.progress) ?? 0) * 20).rounded())
            return "\($0.id):\($0.state.rawValue):\(progressBucket)"
        }.joined(separator: ",")
        let signature = "\(snapshot.bridgeConnected)|\(approvals)|\(tasks)"
        guard signature != lastWidgetSignature else { return }

        let approvalChanged = approvalIDs != lastWidgetApprovalIDs
        let canReload = approvalChanged || Date().timeIntervalSince(lastWidgetReloadAt) >= 60
        guard canReload else { return }

        lastWidgetSignature = signature
        lastWidgetApprovalIDs = approvalIDs
        lastWidgetReloadAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexWatchStatus")
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refreshRemoteNow() async {
        guard !isUIPreview else { return }
        if let remoteRefreshTask {
            await remoteRefreshTask.value
            return
        }
        let id = UUID()
        let refresh = Task<Void, Never> { [weak self] in await self?.performRemoteRefresh() }
        remoteRefreshID = id
        remoteRefreshTask = refresh
        await refresh.value
        if remoteRefreshID == id {
            remoteRefreshTask = nil
            remoteRefreshID = nil
        }
    }

    private func performRemoteRefresh() async {
        guard let remoteClient, !Task.isCancelled else { return }
        if lastDirectSnapshotAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
            requestPhoneSnapshot()
        }
        expireMacPresence()
        var snapshotError: Error?
        var mailboxError: Error?
        recordRelayDiagnostic(stage: "snapshot", snapshotError: nil, mailboxError: nil)
        do {
            if let envelope = try await remoteClient.latestSnapshot() {
                try Task.checkCancellation()
                if RelayTimingPolicy.isFresh(envelope.sentAt), let incoming = envelope.snapshot,
                   RelayTimingPolicy.isFresh(incoming.capturedAt) {
                    lastDirectSnapshotAt = incoming.capturedAt
                    handle(envelope)
                }
            }
        } catch {
            guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
            snapshotError = error
            requestPhoneSnapshot()
        }

        if browserGatewayEnabled {
            do {
                if let envelope = try await remoteClient.latestChatSnapshot(),
                   let chatSnapshot = envelope.snapshot,
                   Date().timeIntervalSince(envelope.sentAt) <= 5 * 60 {
                    browserChatSnapshot = chatSnapshot
                    let merged = snapshot.mergingChatSnapshot(chatSnapshot)
                    if hasVisibleChange(from: snapshot, to: merged) {
                        snapshot = merged
                        reloadWidgetIfNeeded(for: merged)
                    }
                }
            } catch {
                // Chat gateway health is independent of Mac/Codex status.
            }
        }

        recordRelayDiagnostic(stage: "mailbox", snapshotError: snapshotError, mailboxError: nil)
        do {
            _ = try await drainRemoteMailbox()
            expireMacPresence()
        } catch {
            guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
            mailboxError = error
        }
        // Transport failures are recoverable state, not a blocking alert.
        // A healthy phone route remains usable even if direct HTTPS is down.
        let transportError = snapshotError ?? mailboxError
        let issue = transportError != nil && !isReachable ? AppLocalizer.text("中继不可用") : nil
        if connectionIssue != issue { connectionIssue = issue }
        recordRelayDiagnostic(stage: "complete", snapshotError: snapshotError, mailboxError: mailboxError)
        retryRemoteOutboxes()
    }

    /// Opt-in, bounded diagnostics for real-device validation. No URLs, keys,
    /// prompts, task titles or message contents are recorded.
    private func recordRelayDiagnostic(stage: String, snapshotError: Error?, mailboxError: Error?) {
        #if !DEBUG
        guard diagnosticsEnabled else { return }
        #endif
        if stage == "complete", snapshotError == nil, mailboxError == nil { lastRelayDiagnosticSuccess = Date() }
        func code(_ error: Error?) -> String {
            guard let error else { return stage == "complete" ? "ok" : "pending" }
            let value = error as NSError
            return "\(value.domain):\(value.code)"
        }
        let value: [String: Any] = [
            "checkedAt": Date().timeIntervalSince1970,
            "stage": stage,
            "lastSuccessAt": lastRelayDiagnosticSuccess?.timeIntervalSince1970 ?? 0,
            "snapshot": code(snapshotError),
            "mailbox": code(mailboxError),
            "phoneReachable": isReachable,
            "macOnline": snapshot.isMacOnline(),
            "capturedAt": snapshot.capturedAt.timeIntervalSince1970,
            "directSnapshotAt": lastDirectSnapshotAt?.timeIntervalSince1970 ?? 0,
            "phoneSnapshotAt": lastPhoneSnapshotAt?.timeIntervalSince1970 ?? 0,
            "phoneReply": phoneSnapshotResult,
            "foreground": foregroundActive,
            "tasks": snapshot.tasks.count,
            "usagePresent": snapshot.usage != nil,
            "pendingCommands": commandOutbox.count,
            "transport": "https",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("watch-relay-diagnostics.json"), options: .atomic)
    }

    private func retryRemoteOutboxes() {
        pruneExpiredOutboxes()
        let data = outbox.values.map(\.data) + commandOutbox.values.filter { $0.stopped != true }.map(\.data) + resetOutbox.values.map(\.data)
        let envelopes = data.compactMap { try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: $0) }
        remoteRetryGate.retainOnly(Set(envelopes.map(\.messageID)))
        for envelope in envelopes {
            guard RelayOutboxPolicy.isDeliverable(envelope) else { continue }
            enqueueForRemoteDelivery(envelope, urgent: false)
        }
    }

    var pendingCommandStatus: String {
        if let error = pendingCommandTransportError { return error }
        return AppLocalizer.text(snapshot.isMacOnline() ? "正在可靠发送…" : "Mac 未连接")
    }

    private func expireMacPresence() {
        guard snapshot.bridgeConnected, !snapshot.isMacOnline() else { return }
        snapshot = snapshot.reconcilingMacPresence()
        reloadWidgetIfNeeded(for: snapshot)
    }

    /// Acknowledge every relay packet after it has been applied. This runs even
    /// while WatchConnectivity is healthy, because the Mac mirrors remote
    /// replies to the Watch mailbox for cross-network delivery.
    private func drainRemoteMailbox() async throws -> Bool {
        guard let remoteClient else { return false }
        var receivedRemoteResponse = false
        let responses = try await remoteClient.messages(for: .watch)
        for envelope in responses {
            // Receipt delivery does not prove the sender is still online.
            receivedRemoteResponse = true
            handle(envelope)
            try? await remoteClient.acknowledge(envelope.messageID, in: .watch)
        }
        return receivedRemoteResponse
    }

    private func loadOutbox() {
        guard let data = UserDefaults.standard.data(forKey: Self.outboxKey),
              let records = try? PropertyListDecoder().decode([PendingRecord].self, from: data) else { return }
        outbox = Dictionary(uniqueKeysWithValues: records.map { ($0.messageID, $0) })
        for record in records {
            if let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: record.data),
               let requestID = envelope.decision?.requestID {
                pendingDecisionIDs.insert(requestID)
            }
        }
    }

    private func persistOutbox() {
        if let data = try? PropertyListEncoder().encode(Array(outbox.values)) {
            UserDefaults.standard.set(data, forKey: Self.outboxKey)
        }
    }

    private func loadCommandOutbox() {
        do {
            #if CONTROLLER_FAULT_TESTS
            let records = try commandStore.load()
            #else
            let records = try commandStore.load(legacyData: isUIPreview ? nil : UserDefaults.standard.data(forKey: Self.commandOutboxKey))
            #endif
            commandOutbox = Dictionary(uniqueKeysWithValues: records.map { ($0.messageID, $0) })
            for record in records {
                commandReceipts.record(.unconfirmed(CommandRecovery.unconfirmedText), for: record.messageID)
            }
            commandStorageRepairNeeded = false
            _ = persistCommandOutbox()
        } catch {
            commandStorageReadFailed = true
            commandStorageRepairNeeded = CommandOutboxFileStore.canRepair(error)
            markCommandStorageUnavailable()
        }
        refreshPendingCommandTaskIDs()
    }

    private func loadResetOutbox() {
        guard let data = UserDefaults.standard.data(forKey: Self.resetOutboxKey),
              let records = try? PropertyListDecoder().decode([PendingResetRecord].self, from: data) else { return }
        resetOutbox = Dictionary(uniqueKeysWithValues: records.map { ($0.messageID, $0) })
        pendingResetRequestIDs = Set(records.map(\.messageID))
    }

    private func cancelQueuedPhoneDelivery(_ messageID: String) {
        for transfer in session?.outstandingUserInfoTransfers ?? [] {
            guard let data = transfer.userInfo["envelope"] as? Data,
                  let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data),
                  envelope.messageID == messageID else { continue }
            transfer.cancel()
        }
    }

    /// Stop retrying terminal deliveries even if the app remains open across
    /// their deadline. Expiry is an unconfirmed outcome, never a success.
    private func pruneExpiredOutboxes(now: Date = Date()) {
        let expiredMessage = AppLocalizer.text("发送已过期，执行结果未确认。请查看原任务后再试。")
        func decoded(_ data: Data) -> BridgeEnvelope? {
            try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
        }
        for record in Array(outbox.values) {
            let envelope = decoded(record.data)
            guard envelope.map({ !RelayOutboxPolicy.isDeliverable($0, now: now) }) ?? true else { continue }
            outbox.removeValue(forKey: record.messageID)
            cancelQueuedPhoneDelivery(record.messageID)
            if let requestID = envelope?.decision?.requestID {
                pendingDecisionIDs.remove(requestID)
                decisionReceipts.record(.failed(expiredMessage), for: requestID)
            }
            persistOutbox()
        }
        var removedCommand = false
        for record in Array(commandOutbox.values) {
            guard record.stopped != true, CommandRecovery.shouldPause(record.data, now: now) else { continue }
            commandOutbox[record.messageID]?.stopped = true
            cancelQueuedPhoneDelivery(record.messageID)
            commandReceipts.record(.unconfirmed(CommandRecovery.unconfirmedText), for: record.messageID)
            removedCommand = true
        }
        if removedCommand {
            persistCommandOutbox()
            refreshPendingCommandTaskIDs()
            if commandOutbox.isEmpty, pendingCommandTransportError != nil { pendingCommandTransportError = nil }
        }
        for record in Array(resetOutbox.values) {
            guard decoded(record.data).map({ !RelayOutboxPolicy.isDeliverable($0, now: now) }) ?? true else { continue }
            resetOutbox.removeValue(forKey: record.messageID)
            cancelQueuedPhoneDelivery(record.messageID)
            pendingResetRequestIDs.remove(record.messageID)
            usageResetResult = expiredMessage
            persistResetOutbox()
        }
    }

    private func loadShortcutState() {
        // One-time migration: do not retain legacy Shortcut callbacks that
        // could open Gemini or keep watchOS in a rapid polling state.
        shortcutChatTasks = []
        shortcutPending = [:]
        UserDefaults.standard.removeObject(forKey: Self.shortcutChatsKey)
        UserDefaults.standard.removeObject(forKey: Self.shortcutPendingKey)
        refreshPendingCommandTaskIDs()
    }

    @discardableResult
    private func persistCommandOutbox() -> Bool {
        guard !isUIPreview || commandStorageQASessionID != nil else { return true }
        guard !commandStorageReadFailed else { markCommandStorageUnavailable(); return false }
        do {
            try commandStore.save(Array(commandOutbox.values))
            commandStorageAvailable = true
            return true
        } catch { markCommandStorageUnavailable(); return false }
    }

    private func markCommandStorageUnavailable() {
        commandStorageAvailable = false
        let message = AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。")
        for id in Array(commandOutbox.keys) {
            commandOutbox[id]?.stopped = true
            cancelQueuedPhoneDelivery(id)
            commandReceipts.record(.unconfirmed(message), for: id)
        }
        errorMessage = message
        refreshPendingCommandTaskIDs()
    }

    #if CONTROLLER_FAULT_TESTS
    var faultCommandRecords: [StoredCommandRecord] { Array(commandOutbox.values) }
    func faultReceive(_ envelope: BridgeEnvelope) { handle(envelope) }
    func faultFlush() { flushOutbox() }
    func faultPrune(now: Date) { pruneExpiredOutboxes(now: now) }
    func faultRefresh() async { await refreshRemoteNow() }
    #endif

    private func persistShortcutState() {
        shortcutChatTasks = Array(shortcutChatTasks
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(20))
        if let data = try? PropertyListEncoder().encode(shortcutChatTasks) {
            UserDefaults.standard.set(data, forKey: Self.shortcutChatsKey)
        }
        if let data = try? PropertyListEncoder().encode(Array(shortcutPending.values)) {
            UserDefaults.standard.set(data, forKey: Self.shortcutPendingKey)
        }
    }

    private func refreshPendingCommandTaskIDs() {
        pendingCommandTaskIDs = Set(commandOutbox.values.filter { $0.stopped != true }.flatMap { record in
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.data
            ),
            let projectionID = envelope.taskCommand?.nativeChatProjectionID else {
                return [record.taskID]
            }
            return [projectionID]
        })
            .union(shortcutPending.values.map(\.chatID))
    }

    private func persistResetOutbox() {
        if let data = try? PropertyListEncoder().encode(Array(resetOutbox.values)) {
            UserDefaults.standard.set(data, forKey: Self.resetOutboxKey)
        }
    }

    private func isTerminalApprovalRace(_ envelope: BridgeEnvelope) -> Bool {
        guard envelope.acknowledgedMessageID != nil,
              let message = envelope.message?.lowercased() else { return false }
        return message.contains("no longer pending")
            || message.contains("已不在待处理")
            || message.contains("已不再等待")
    }

    private func isAccessibilitySetupMessage(_ message: String?) -> Bool {
        let normalized = message?.lowercased() ?? ""
        return normalized.contains("allow agent bridge")
            || normalized.contains("辅助功能中允许 agent bridge")
            || normalized.contains("not allowed to send keystrokes")
    }

    private func markChatCommandFailed(
        _ record: PendingCommandRecord,
        message: String?
    ) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
            BridgeEnvelope.self,
            from: record.data
        ),
        let projectionID = envelope.taskCommand?.nativeChatProjectionID,
        let index = snapshot.tasks.firstIndex(where: { $0.id == projectionID }) else {
            return
        }
        var task = snapshot.tasks[index]
        task.state = .failed
        task.detail = message
        task.updatedAt = Date()
        snapshot.tasks[index] = task
        reloadWidgetIfNeeded(for: snapshot)
    }
}

private extension WatchRelayController {
    struct PendingRecord: Codable {
        let messageID: String
        let decisionID: String
        let data: Data
    }

    typealias PendingCommandRecord = StoredCommandRecord

    struct PendingResetRecord: Codable {
        let messageID: String
        let requestID: String
        let data: Data
    }
}

extension WatchRelayController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReachable = reachable
            if let error {
                errorMessage = error.localizedDescription
            } else if activationState == .activated {
                refresh()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = reachable
            if reachable {
                self.refresh()
            } else {
                // Do not wait behind the previous low-power timer when the
                // iPhone app backgrounds or is out of range. The Watch has
                // its own encrypted relay path and should take over now.
                self.beginUrgentRemotePolling()
                Task { await self.refreshRemoteNow() }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        receive(messageData)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext["envelope"] as? Data else { return }
        receive(data)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo["envelope"] as? Data else { return }
        receive(data)
    }

    nonisolated private func receive(_ data: Data) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data) else {
            return
        }
        Task { @MainActor [weak self] in self?.handle(envelope) }
    }
}

private extension WatchRelayController {
    func notifyForNewInteractions(in snapshot: DashboardSnapshot) {
        let key = "CodexWatch.watch.notifiedInteractions"
        if notifiedInteractionIDs.isEmpty {
            notifiedInteractionIDs = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }
        var changed = false
        for request in snapshot.pendingApprovals where !request.isExpired {
            guard notifiedInteractionIDs.insert(request.id).inserted else { continue }
            changed = true
            let content = UNMutableNotificationContent()
            content.title = AppLocalizer.text(request.kind == .userInput ? "Codex 等待回答" : "Codex 等待审批")
            // Never disclose the question or a secret answer on a lock screen.
            content.body = AppLocalizer.text("打开软件查看并回答")
            content.sound = .default
            content.userInfo = ["approvalRequestID": request.id]
            Task { try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "codex-approval-\(request.id)", content: content, trigger: nil)) }
        }
        if notifiedInteractionIDs.count > 512 {
            notifiedInteractionIDs = Set(snapshot.pendingApprovals.map(\.id))
        }
        if changed { UserDefaults.standard.set(Array(notifiedInteractionIDs), forKey: key) }
    }
}

extension WatchRelayController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["approvalRequestID"] as? String else { return }
        await MainActor.run { self.selectedNotificationRequestID = id; self.refresh() }
    }
}
