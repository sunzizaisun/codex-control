import Foundation
import LocalAuthentication
import MultipeerConnectivity
import SwiftUI
import UIKit
import UserNotifications
@preconcurrency import WatchConnectivity
import CodexWatchCore

@MainActor
final class PhoneRelayController: NSObject, ObservableObject {
    enum MacConnectionState: Equatable {
        case browsing
        case inviting(String)
        case connected(String)
        case disconnected

        var title: String {
            switch self {
            case .browsing:
                return AppLocalizer.text("正在寻找 Mac")
            case .inviting(let name):
                return AppLocalizer.format("正在连接 %@", name)
            case .connected(let name):
                return AppLocalizer.format("已连接 %@", name)
            case .disconnected:
                return AppLocalizer.text("Mac 未连接")
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // Preserve every authenticated heartbeat for freshness without making
    // the entire task list redraw when only transport timestamps changed.
    private(set) var snapshot = DashboardSnapshot.empty {
        willSet {
            if !snapshot.isVisuallyEquivalent(to: newValue) { objectWillChange.send() }
        }
    }
    private(set) var lastSnapshotReceivedAt: Date?
    @Published private(set) var macConnectionState: MacConnectionState = .disconnected
    @Published private(set) var remoteAvailable = false
    private(set) var remoteLastSyncAt: Date?
    @Published private(set) var watchReachable = false
    @Published private(set) var discoveredMacNames: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var pendingDecisionCount = 0
    @Published private(set) var decisionReceipts = CommandReceipts()
    @Published var selectedNotificationRequestID: String?
    @Published private(set) var pendingCommandTaskIDs: Set<String> = []
    @Published private(set) var taskHistories: [String: TaskHistoryState] = [:]
    @Published private(set) var commandReceipts = CommandReceipts()
    @Published private(set) var checkingCommandIDs: Set<String> = []
    @Published private(set) var commandStorageAvailable = false
    @Published private(set) var commandStorageRepairNeeded = false
    @Published private(set) var commandStorageRepairReceipt: CommandOutboxRepairReceipt?
    @Published private(set) var shortcutChatTasks: [AgentTask] = []
    @Published var usageResetResult: String?
    @Published var selectedMacName = ""
    @Published var pairingCode = ""

    let deviceID: String

    private static let serviceType = "codexrelay"
    private static let deviceIDKey = "CodexWatch.iOS.deviceID"
    private static let preferredMacNameKey = "CodexWatch.iOS.preferredMacName"
    private static let outboxKey = "CodexWatch.iOS.decisionOutbox"
    private static let completedDecisionIDsKey = "CodexWatch.iOS.completedDecisionIDs"
    private static let commandOutboxKey = "CodexWatch.iOS.commandOutbox"
    private static let resetOutboxKey = "CodexWatch.iOS.resetOutbox"
    private static let notifiedApprovalIDsKey = "CodexWatch.iOS.notifiedApprovalIDs"
    private static let shortcutChatsKey = "CodexWatch.iOS.shortcutChats"
    private static let shortcutPendingKey = "CodexWatch.iOS.shortcutPending"
    private static let maximumSeenMessageCount = 256
    private static let remoteSnapshotFreshness = RelayTimingPolicy.snapshotFreshness
    /// Chat/task commands can wait for a sleeping Mac for up to one day. The
    /// encrypted relay packet carries the same deadline, so the durable local
    /// outbox and the internet mailbox expire together.
    /// Keep below WatchConnectivity's practical per-message/context ceiling.
    /// The envelope itself adds a small amount of JSON overhead.
    private static let maximumWatchEnvelopeBytes = 48_000

    private var localPeerID: MCPeerID!
    private var multipeerSession: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var watchSession: WCSession?
    private var discoveredPeers: [String: MCPeerID] = [:]
    private var seenMacMessageIDs: [String] = []
    private var seenMacMessageIDSet: Set<String> = []
    private var seenWatchMessageIDs: [String] = []
    private var seenWatchMessageIDSet: Set<String> = []
    private var completedDecisionIDs: [String] = []
    private var completedDecisionIDSet: Set<String> = []
    private var decisionOutbox: [String: PendingDecisionRecord] = [:]
    private var historyRequests: [String: TaskHistoryRequest] = [:]
    /// Prevent rapid taps from opening multiple Face ID prompts for one
    /// approval while the first biometric evaluation is still in progress.
    private var authenticatingApprovalIDs: Set<String> = []
    private var commandOutbox: [String: PendingCommandRecord] = [:]
    private var commandStorageReadFailed = false
    #if CONTROLLER_FAULT_TESTS
    // Compiled only by the separate simulator unit-test project. No launch
    // argument can enable this in a production or normal QA application.
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
    private var resetOutbox: [String: PendingResetRecord] = [:]
    private var notifiedApprovalIDs: [String] = []
    private var notifiedApprovalIDSet: Set<String> = []
    private var shortcutPending: [String: ShortcutChatBridge.PendingRequest] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var pairingAttemptTask: Task<Void, Never>?
    /// A rejected invite is not a transient network failure. Retrying it
    /// every two seconds creates a stream of prompts on the Mac and keeps
    /// Bonjour active even though the user still needs to enter a new code.
    /// Back off automatic invites until the user explicitly starts pairing.
    private var autoConnectBlockedUntil = Date.distantPast
    /// MultipeerConnectivity can trap inside CoreFoundation when a browser is
    /// stopped and started again during the same run-loop turn. In particular,
    /// iOS 26 may crash in `BrowserCancel` while the session delegate reports
    /// a disconnect. Keep a single browser alive for the controller lifetime;
    /// recovery is lazy (start only when it is not already running) instead of
    /// repeatedly cancelling and recreating the CoreFoundation browser.
    private var browserTransitionTask: Task<Void, Never>?
    private var browserRunning = false
    /// `MCNearbyServiceBrowser` may report a transient start failure even
    /// while its Bonjour session is still alive. Do not issue a second start
    /// for that callback: on iOS 26 a duplicate start implicitly cancels the
    /// active browser, then immediately starts it again, which can trap in
    /// CoreFoundation's BrowserCancel path.
    private var browserStartIssued = false
    private var remotePollTask: Task<Void, Never>?
    private var remoteWaitTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var remoteRefreshID: UUID?
    private var presenceExpiryTask: Task<Void, Never>?
    private var remoteClient: RemoteRelayClient?
    private var remoteDeliveryRetryGate = RelayRetryGate()
    private var browserGatewayEnabled = false
    private var browserChatSnapshot = DashboardSnapshot.empty
    private var urgentRemotePollingUntil = Date.distantPast
    /// Manual pairing must never race the automatic trusted-device reconnect.
    /// Otherwise browsing can invite the Mac without the newly entered code
    /// before the user has a chance to press Connect Now.
    private var isManualPairing = false
    private var scannedMacName: String?
    private var started = false
    private let isUIPreview = ProcessInfo.processInfo.arguments.contains("-UIPreview")
    /// Simulator-only relay regression mode. It leaves the real public-relay
    /// polling and outbox active while skipping Multipeer discovery, so a
    /// developer Mac running beside Xcode cannot accidentally win the route
    /// and hide the encrypted remote snapshot under test.
    private let isRelayOnlyPreview = ProcessInfo.processInfo.arguments.contains("-RelayOnlyPreview")
    /// Developer-only simulator hook: keep the preview snapshot but exercise
    /// the real Face ID policy instead of short-circuiting the decision.
    private let isAuthPreview = ProcessInfo.processInfo.arguments.contains("-PreviewApprovalAuth")

    override init() {
        #if CONTROLLER_FAULT_TESTS
        guard let environment = commandFaultEnvironment else { fatalError("Isolated controller environment required") }
        deviceID = environment.deviceID
        super.init()
        remoteClient = environment.client
        snapshot = environment.snapshot
        loadCommandOutbox()
        #else
        let storedID = UserDefaults.standard.string(forKey: Self.deviceIDKey)
        let resolvedID = storedID ?? UUID().uuidString
        if storedID == nil {
            UserDefaults.standard.set(resolvedID, forKey: Self.deviceIDKey)
        }
        deviceID = resolvedID
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
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityQA") {
                let english = ProcessInfo.processInfo.arguments.contains("-english")
                snapshot.tasks[0].title = english
                    ? "Apple Watch GPT Control · A long title for the system activity layout regression"
                    : "控制 Apple Watch GPT · 长标题实时活动排版回归检查"
                snapshot.tasks[0].progress = ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityProgress") ? 0.68 : nil
                if ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityApproval") {
                    snapshot.tasks[0].state = .waitingForApproval
                } else {
                    snapshot.pendingApprovals = []
                }
                if ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityOffline") {
                    snapshot.bridgeConnected = false
                }
            }
            #endif
            remoteAvailable = true
            lastSnapshotReceivedAt = Date()
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-PreviewUnconfirmedCommand") {
                let target = ProcessInfo.processInfo.arguments.contains("-PreviewTaskDetail") ? "preview-recent" : TaskCommand.newChatTaskID
                let envelope = BridgeEnvelope.taskCommand(.init(taskID: target, prompt: "  原文水獭🦦  ", deviceID: deviceID), sender: deviceID)
                if let bytes = try? CodexWatchCoding.makeEncoder().encode(envelope) {
                    let id = ProcessInfo.processInfo.arguments.contains("-PreviewMismatchedOriginal") ? "qa-wrong-index" : envelope.messageID
                    commandOutbox[id] = .init(messageID: id, taskID: target, envelopeData: bytes, stopped: true)
                }
                if ProcessInfo.processInfo.arguments.contains("-PreviewMultipleUnconfirmedCommands") {
                    commandOutbox.removeAll()
                    for (offset, prompt) in ["  原文水獭🦦  ", "  后续枫叶🍁  "].enumerated() {
                        var original = BridgeEnvelope.taskCommand(.init(taskID: target, prompt: prompt, deviceID: deviceID), sender: deviceID)
                        original.messageID = offset == 0 ? "z-older" : "a-newer"
                        original.sentAt = Date().addingTimeInterval(Double(offset - 2) * 30)
                        if let bytes = try? CodexWatchCoding.makeEncoder().encode(original) {
                            commandOutbox[original.messageID] = .init(messageID: original.messageID, taskID: target, envelopeData: bytes, stopped: true)
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

        selectedMacName = UserDefaults.standard.string(forKey: Self.preferredMacNameKey) ?? ""
        if !isUIPreview, let configuration = RemoteRelayConfiguration.fromMainBundle() {
            remoteClient = RemoteRelayClient(configuration: configuration)
            browserGatewayEnabled = configuration.browserGatewayEnabled
        }

        let suffix = resolvedID.prefix(6)
        localPeerID = MCPeerID(displayName: "\(UIDevice.current.name)-\(suffix)")
        multipeerSession = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        if !isUIPreview { loadPersistentState() }
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        if isUIPreview {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityQA") {
                Task {
                    await LiveActivityManager.shared.seedLayoutRegressionActivities()
                    LiveActivityManager.shared.update(from: snapshot)
                }
                return
            }
            #endif
            LiveActivityManager.shared.update(from: snapshot)
            return
        }

        presenceExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                self.pruneExpiredOutboxes()
                self.expireMacPresence()
            }
        }

        if isRelayOnlyPreview {
            macConnectionState = .disconnected
            startRemotePolling()
            configureApprovalNotifications()
            return
        }

        multipeerSession.delegate = self
        browser.delegate = self
        macConnectionState = .browsing
        startBrowserIfNeeded()
        startRemotePolling()
        configureApprovalNotifications()

        guard WCSession.isSupported() else {
            lastError = AppLocalizer.text("此 iPhone 不支持 Apple Watch 连接")
            return
        }
        let session = WCSession.default
        watchSession = session
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func connectToSelectedMac() -> Bool {
        autoConnectBlockedUntil = .distantPast
        let peer = discoveredPeers[selectedMacName]
            ?? discoveredPeers.values.sorted { $0.displayName < $1.displayName }.first
        guard let peer else {
            lastError = AppLocalizer.text("请先选择一台可用的 Mac")
            macConnectionState = .disconnected
            return false
        }
        selectedMacName = peer.displayName
        invite(peer)
        return true
    }

    func resumeConnectivity() {
        guard started else { return }
        guard !isUIPreview else { return }
        pruneExpiredOutboxes()
        expireMacPresence()
        isManualPairing = false
        if isRelayOnlyPreview {
            Task { await refreshRemoteNow() }
            return
        }
        if !macConnectionState.isConnected {
            restartBrowser()
            attemptAutoConnect()
        }
        Task { await refreshRemoteNow() }
    }

    /// Opens a deliberate re-pairing flow even when a stale remote snapshot
    /// still makes the dashboard look connected. This does not touch tasks or
    /// relay data; it only renews the nearby encrypted Mac session.
    func beginPairing() {
        guard started, !isUIPreview else { return }
        isManualPairing = true
        autoConnectBlockedUntil = .distantPast
        pairingCode = ""
        lastError = nil
        multipeerSession.disconnect()
        macConnectionState = .disconnected
        restartBrowser()
    }

    func applyPairingQRCode(_ payload: String) {
        let decoded: PairingQRCodePayload
        do {
            decoded = try PairingQRCodePayload.parse(payload)
        } catch PairingQRCodePayload.Failure.expired {
            lastError = AppLocalizer.text("配对二维码已过期，请在 Mac 上更新")
            return
        } catch {
            lastError = AppLocalizer.text("无法读取配对二维码")
            return
        }
        pairingCode = decoded.code
        autoConnectBlockedUntil = .distantPast
        if let macName = decoded.macName {
            scannedMacName = macName
            if discoveredPeers[macName] != nil {
                selectedMacName = macName
            }
        }
        lastError = nil
    }

    func requestLatestSnapshot() {
        guard !isUIPreview else { return }
        if macConnectionState.isConnected {
            let request = BridgeEnvelope(
                kind: .requestSnapshot,
                senderDeviceID: deviceID
            )
            sendToMac(request)
        }
        if remoteClient != nil {
            Task { await refreshRemoteNow() }
        } else if !macConnectionState.isConnected {
            lastError = AppLocalizer.text("Mac 未连接，暂时无法刷新")
        }
    }

    /// Approvals initiated on iPhone must be authenticated locally.  We use
    /// the biometric-only policy deliberately: a device passcode fallback
    /// would make the iPhone path weaker than the Watch wrist-detection path.
    func isDecisionPending(for requestID: String) -> Bool {
        decisionOutbox.values.contains {
            (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: $0.envelopeData))?.decision?.requestID == requestID
        }
    }
    func decide(_ choice: ApprovalChoice, request: ApprovalRequest, answers: [String: [String]]? = nil) {
        guard choice == .allowOnce || choice == .deny else { return }
        if let questions = request.questions {
            guard let answers, (try? UserInputValidation.validate(answers, questions: questions)) != nil else { return }
        } else if answers != nil { return }
        guard !(isUIPreview && !isAuthPreview) else {
            acceptPreviewDecision(request)
            return
        }
        guard !decisionOutbox.values.contains(where: {
            (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: $0.envelopeData))?.decision?.requestID == request.id
        }), authenticatingApprovalIDs.insert(request.id).inserted else { return }

        Task {
            defer { authenticatingApprovalIDs.remove(request.id) }
            do {
                _ = try ApprovalReviewValidation.current(
                    reviewed: request, pending: snapshot.pendingApprovals
                )

                // Both outcomes change the desktop task's authorization state;
                // require Face ID before either decision leaves the phone.
                let context = LAContext()
                context.localizedCancelTitle = AppLocalizer.text("取消")
                var evaluationError: NSError?
                guard context.canEvaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    error: &evaluationError
                ) else {
                    throw evaluationError ?? PhoneApprovalError.faceIDRequired
                }
                guard context.biometryType == .faceID else {
                    throw PhoneApprovalError.faceIDRequired
                }

                let authenticated = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: AppLocalizer.format(
                        "在 iPhone 上确认 Codex：%@",
                        AppLocalizer.localizedRemote(request.title)
                    )
                )
                guard authenticated else { return }

                let current = try ApprovalReviewValidation.current(
                    reviewed: request, pending: snapshot.pendingApprovals
                )
                // Authentication QA must never put a synthetic decision in
                // the user's real cloud mailbox or persistent outbox.
                if isUIPreview {
                    acceptPreviewDecision(current)
                    return
                }

                let decision = ApprovalDecision(
                    requestID: current.id,
                    requestDigest: current.requestDigest,
                    choice: choice,
                    decidedAt: Date(),
                    deviceID: deviceID,
                    nonce: current.nonce,
                    origin: .phone,
                    answers: answers
                )
                let envelope = BridgeEnvelope.decision(
                    decision,
                    sender: deviceID,
                    replyMailbox: RemoteRelayMailbox.phone.rawValue
                )
                let data = try CodexWatchCoding.makeEncoder().encode(envelope)
                decisionOutbox[envelope.messageID] = PendingDecisionRecord(
                    messageID: envelope.messageID,
                    decisionID: decision.id,
                    envelopeData: data
                )
                persistDecisionOutbox()
                pendingDecisionCount = decisionOutbox.count
                sendToMac(envelope, urgent: true)
                forwardSnapshotToWatch(snapshot)
            } catch {
                lastError = error.localizedDescription
                decisionReceipts.record(.failed(error.localizedDescription), for: request.id)
            }
        }
    }

    private func acceptPreviewDecision(_ request: ApprovalRequest) {
        decisionReceipts.record(.accepted, for: request.id)
        snapshot.pendingApprovals.removeAll { $0.id == request.id }
    }

    @discardableResult
    func sendCommand(_ prompt: String, to task: AgentTask, options: CodexExecutionOptions? = nil) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUIPreview else { return nil }
        guard !task.isChat && !task.isNativeChat else {
            lastError = AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务")
            return nil
        }
        if ShortcutChatBridge.isShortcutChat(task.id) {
            // Legacy Shortcut chats are intentionally read-only.  They could
            // target Gemini or inject text into whichever app owns the old
            // shortcut, so never allow a follow-up to leave this app through
            // that route again.
            lastError = AppLocalizer.text("旧版快捷指令对话已停用，请新建 Chat")
            return nil
        }
        let envelope = BridgeEnvelope.taskCommand(
                    TaskCommand(
                        taskID: task.id,
                        prompt: prompt,
                        activeTurnID: task.activeTurnID,
                        deviceID: deviceID,
                        options: options
                    ),
                sender: deviceID,
                replyMailbox: RemoteRelayMailbox.phone.rawValue
            )
        acceptCommand(envelope)
        return commandOutbox[envelope.messageID] != nil ? envelope.messageID : nil
    }

    @discardableResult
    func startCodexChat(_ prompt: String, options: CodexExecutionOptions? = nil) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUIPreview else { return nil }
        let envelope = BridgeEnvelope.taskCommand(
                TaskCommand(taskID: TaskCommand.newChatTaskID, prompt: prompt, deviceID: deviceID, options: options),
                sender: deviceID,
                replyMailbox: RemoteRelayMailbox.phone.rawValue
            )
        acceptCommand(envelope)
        return commandOutbox[envelope.messageID] != nil ? envelope.messageID : nil
    }

    func task(id: String) -> AgentTask? {
        snapshot.tasks.first { $0.id == id }
    }

    func recoverableCommand(for taskID: String) -> RecoverableCommandDraft? {
        CommandRecovery.earliest(commandOutbox.values
            .filter { $0.taskID == taskID && $0.stopped == true }
            .map { .init(messageID: $0.messageID, originalData: $0.envelopeData, taskID: $0.taskID) })
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
        guard !CommandRecovery.shouldPause(record.envelopeData),
              let original = CommandRecovery.original(record.envelopeData),
              original.messageID == record.messageID, original.taskCommand?.taskID == record.taskID else {
            commandOutbox[record.messageID]?.stopped = true
            commandReceipts.record(.unconfirmed(CommandRecovery.unconfirmedText), for: record.messageID)
            persistCommandOutbox(); refreshPendingCommandTaskIDs()
            return false
        }
        return true
    }

    func checkCommandStatus(_ id: String?) {
        guard let id, let record = commandOutbox[id], record.stopped == true else { return }
        guard !isUIPreview else { return }
        guard let original = CommandRecovery.original(record.envelopeData), original.messageID == record.messageID,
              original.taskCommand?.taskID == record.taskID,
              let query = commandStatusQueries.begin(originalData: record.envelopeData,
            replyMailbox: RemoteRelayMailbox.phone.rawValue) else {
            commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: id)
            return
        }
        checkingCommandIDs = commandStatusQueries.checkingIDs
        sendToMac(query, urgent: true)
        armCommandQueryTimeout(query)
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
            lastError = AppLocalizer.text("无法确认修复结果。请保留应用并重试。")
            return false
        }
    }

    private func armCommandQueryTimeout(_ query: BridgeEnvelope) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let originalID = self.commandStatusQueries.fail(query.messageID) else { return }
            self.checkingCommandIDs = self.commandStatusQueries.checkingIDs
            self.commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: originalID)
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
        commandStatusQueries.cancel(originalMessageID: id)
        checkingCommandIDs = commandStatusQueries.checkingIDs
        refreshPendingCommandTaskIDs()
        return true
    }

    private func applyCommandStatus(_ resolution: CommandStatusQueries.Resolution) {
        guard commandOutbox[resolution.originalMessageID] != nil else { return }
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
            let messages = task(id: taskID)?.messages ?? []
            if let page = try? TaskHistoryPaging.page(messages: messages, request: request) {
                taskHistories[taskID]?.apply(page)
            }
            return
        }
        let envelope = BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: deviceID,
            replyMailbox: RemoteRelayMailbox.phone.rawValue, taskHistoryRequest: request)
        trackHistoryRequest(envelope)
        sendToMac(envelope, urgent: true)
    }

    private func trackHistoryRequest(_ envelope: BridgeEnvelope) {
        guard let request = envelope.taskHistoryRequest else { return }
        historyRequests[envelope.messageID] = request
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let pending = self.historyRequests.removeValue(forKey: envelope.messageID) else { return }
            self.taskHistories[pending.taskID]?.fail(AppLocalizer.text("无法加载聊天记录，请重试"))
            if envelope.replyMailbox == RemoteRelayMailbox.watch.rawValue {
                self.sendWatchError(AppLocalizer.text("无法加载聊天记录，请重试"), acknowledging: envelope.messageID)
            }
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
        let input = ShortcutChatBridge.contextualPrompt(
            newMessage: prompt,
            messages: context
        )
        guard let url = ShortcutChatBridge.runURL(
            prompt: input,
            requestID: requestID,
            chatID: chatID
        ) else {
            markShortcutLaunchFailed(
                requestID: requestID,
                chatID: chatID,
                message: AppLocalizer.text("无法创建 ChatGPT 快捷指令")
            )
            return
        }
        shortcutPending[requestID] = .init(requestID: requestID, chatID: chatID)
        persistShortcutState()
        refreshPendingCommandTaskIDs()
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.markShortcutLaunchFailed(
                    requestID: requestID,
                    chatID: chatID,
                    message: AppLocalizer.text("请先安装 Codex Control Chat 快捷指令")
                )
            }
        }
    }

    private func markShortcutLaunchFailed(
        requestID: String,
        chatID: String,
        message: String
    ) {
        shortcutPending.removeValue(forKey: requestID)
        if let index = shortcutChatTasks.firstIndex(where: { $0.id == chatID }) {
            shortcutChatTasks[index] = ShortcutChatBridge.failing(
                shortcutChatTasks[index],
                message: message
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
            (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: $0.envelopeData))?.usageReset?.creditID == creditID
        }) else {
            usageResetResult = AppLocalizer.text("正在发送…")
            return
        }
        usageResetResult = nil
        let request = UsageResetRequest(creditID: creditID, deviceID: deviceID)
        acceptReset(.usageReset(
            request,
            sender: deviceID,
            replyMailbox: RemoteRelayMailbox.phone.rawValue
        ))
    }

    var isMacConnected: Bool {
        snapshot.isMacOnline()
    }

    var connectionTitle: String {
        if isMacConnected && macConnectionState.isConnected { return macConnectionState.title }
        if isMacConnected && remoteAvailable { return AppLocalizer.text("远程在线") }
        if remoteClient != nil { return AppLocalizer.text("远程正在恢复") }
        return macConnectionState.title
    }

    var activeTasks: [AgentTask] {
        snapshot.tasks
            .filter { $0.isInProgress }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var unexpiredApprovals: [ApprovalRequest] {
        snapshot.pendingApprovals
            .filter { !$0.isExpired }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var isSnapshotStale: Bool {
        guard let lastSnapshotReceivedAt else { return true }
        return Date().timeIntervalSince(lastSnapshotReceivedAt) > 90
    }

    private func didConnect(to name: String) {
        // A delayed reconnect may still be sleeping when the encrypted
        // session reports connected. Cancel it so it cannot create a
        // reconnect storm behind the live session. The browser stays alive;
        // stopping it here is unsafe on iOS 26 (see browser lifecycle note).
        browserTransitionTask?.cancel()
        browserTransitionTask = nil
        isManualPairing = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pairingAttemptTask?.cancel()
        pairingAttemptTask = nil
        macConnectionState = .connected(name)
        selectedMacName = name
        UserDefaults.standard.set(name, forKey: Self.preferredMacNameKey)
        lastError = nil
        // A nearby session is a transport, not proof that Codex is ready.

        let hello = BridgeEnvelope(
            kind: .hello,
            senderDeviceID: deviceID,
            message: "ios-relay"
        )
        sendToMac(hello)
        requestLatestSnapshot()
        flushDecisionOutbox()
        flushCommandOutbox()
        flushResetOutbox()
    }

    private func invite(_ peer: MCPeerID) {
        guard !macConnectionState.isConnected else { return }
        if case .inviting = macConnectionState { return }
        lastError = nil
        selectedMacName = peer.displayName
        UserDefaults.standard.set(peer.displayName, forKey: Self.preferredMacNameKey)
        macConnectionState = .inviting(peer.displayName)
        let code = pairingCode.filter { $0.isNumber }
        let invitation = PairingInvitation(
            phoneDeviceID: deviceID,
            code: code.isEmpty ? nil : code
        )
        guard let context = try? CodexWatchCoding.makeEncoder().encode(invitation) else {
            lastError = AppLocalizer.text("无法创建配对请求")
            macConnectionState = .disconnected
            return
        }
        browser.invitePeer(
            peer,
            to: multipeerSession,
            withContext: context,
            timeout: 20
        )
        pairingAttemptTask?.cancel()
        let invitedName = peer.displayName
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  let self,
                  case .inviting(let currentName) = self.macConnectionState,
                  currentName == invitedName else { return }
            self.autoConnectBlockedUntil = Date().addingTimeInterval(30)
            self.macConnectionState = .disconnected
            self.lastError = AppLocalizer.text("Mac 没有接受配对请求，请确认最新六码和本地网络权限")
        }
    }

    private func attemptAutoConnect() {
        guard !macConnectionState.isConnected else { return }
        if case .inviting = macConnectionState { return }
        guard isManualPairing || Date() >= autoConnectBlockedUntil else { return }
        let preferred = UserDefaults.standard.string(forKey: Self.preferredMacNameKey)
        if let preferred, let peer = discoveredPeers[preferred] {
            invite(peer)
        } else if let peer = discoveredPeers.values.sorted(by: { $0.displayName < $1.displayName }).first {
            invite(peer)
        }
    }

    private func scheduleReconnect(after delay: Duration = .seconds(2)) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.restartBrowser()
            self.attemptAutoConnect()
        }
    }

    private func startBrowserIfNeeded() {
        guard !browserRunning, !browserStartIssued else { return }
        browserStartIssued = true
        browser.startBrowsingForPeers()
        browserRunning = true
    }

    private func restartBrowser(after delay: Duration = .milliseconds(250)) {
        browserTransitionTask?.cancel()
        browserTransitionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.started, !self.macConnectionState.isConnected else { return }
            self.startBrowserIfNeeded()
        }
    }

    private func markMacDisconnected() {
        if case .connected = macConnectionState {
            macConnectionState = .disconnected
        } else if case .inviting = macConnectionState {
            macConnectionState = .disconnected
        }
        let disconnectedSnapshot = snapshot.reconcilingMacPresence()
        snapshot = disconnectedSnapshot
        forwardSnapshotToWatch(disconnectedSnapshot)
    }

    private func handleMacEnvelope(_ envelope: BridgeEnvelope) {
        guard envelope.version <= BridgeEnvelope.currentVersion else {
            lastError = AppLocalizer.text("Mac 使用了较新的协议版本，请更新 iPhone App")
            return
        }
        guard Self.remember(
            envelope.messageID,
            order: &seenMacMessageIDs,
            set: &seenMacMessageIDSet
        ) else {
            return
        }

        switch envelope.kind {
        case .snapshot:
            if envelope.commandStatusReceipt != nil {
                if let resolution = commandStatusQueries.receive(envelope) { applyCommandStatus(resolution) }
                checkingCommandIDs = commandStatusQueries.checkingIDs
                forwardReliablyToWatch(envelope)
                return
            }
            if let page = envelope.taskHistoryPage {
                if let id = envelope.acknowledgedMessageID, let request = historyRequests[id], page.isValid(for: request) {
                    historyRequests.removeValue(forKey: id)
                    var state = taskHistories[page.taskID] ?? TaskHistoryState()
                    state.apply(page)
                    taskHistories[page.taskID] = state
                }
                forwardReliablyToWatch(envelope)
                return
            }
            guard var incoming = envelope.snapshot else {
                lastError = AppLocalizer.text("Mac 发来的任务快照为空")
                return
            }
            guard incoming.capturedAt >= snapshot.capturedAt else { return }
            incoming = incoming.reconcilingMacPresence()
            incoming = incoming.mergingRecentTasks(from: snapshot)
            incoming = incoming.mergingChatSnapshot(browserChatSnapshot)
            incoming = preservingQueuedNativeChats(incoming)
            notifyForNewApprovals(in: incoming)
            let visibleChange = !snapshot.isVisuallyEquivalent(to: incoming)
            snapshot = incoming
            if visibleChange {
                for task in incoming.tasks where taskHistories[task.id] != nil {
                    taskHistories[task.id]?.applyLive(task.messages)
                }
            }
            lastSnapshotReceivedAt = incoming.capturedAt
            if lastError != nil { lastError = nil }
            LiveActivityManager.shared.update(from: incoming)
            // A newly reconnected Watch may need this snapshot even when the
            // iPhone already has the same visible data. The Watch performs its
            // own visual-equivalence check, so forwarding is cheap and does
            // not reanimate its list.
            forwardSnapshotToWatch(incoming)

        case .acknowledgement:
            guard let acknowledgedID = envelope.acknowledgedMessageID else { return }
            if let record = decisionOutbox.removeValue(forKey: acknowledgedID) {
                rememberCompletedDecision(record.decisionID)
                if let id = (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: record.envelopeData))?.decision?.requestID {
                    decisionReceipts.record(.accepted, for: id)
                }
                persistDecisionOutbox()
            }
            if commandOutbox.removeValue(forKey: acknowledgedID) != nil {
                commandStatusQueries.cancel(originalMessageID: acknowledgedID)
                checkingCommandIDs = commandStatusQueries.checkingIDs
                commandReceipts.record(.accepted, for: acknowledgedID)
                persistCommandOutbox()
                refreshPendingCommandTaskIDs()
                // The Mac acknowledges receipt before ChatGPT finishes
                // generating the assistant turn. Keep the relay in its
                // fast response window after that acknowledgement; otherwise
                // removing the pending command immediately drops the adaptive
                // poller back to its 60-second idle cadence and can hide the
                // reply until the next reconciliation.
                beginUrgentRemotePolling(for: 60)
            }
            if resetOutbox.removeValue(forKey: acknowledgedID) != nil {
                persistResetOutbox()
                usageResetResult = UsageResetOutcome.confirmedResponse(envelope.message)
            }
            pendingDecisionCount = decisionOutbox.count
            forwardReliablyToWatch(envelope)

        case .error:
            let acknowledgedID = envelope.acknowledgedMessageID
            if let id = acknowledgedID, let originalID = commandStatusQueries.fail(id) {
                checkingCommandIDs = commandStatusQueries.checkingIDs
                commandReceipts.record(.unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。")), for: originalID)
                forwardReliablyToWatch(envelope)
                return
            }
            if let id = acknowledgedID, let request = historyRequests.removeValue(forKey: id) {
                taskHistories[request.taskID]?.fail(AppLocalizer.text("无法加载聊天记录，请重试"))
                forwardReliablyToWatch(envelope)
                return
            }
            let matchedDecision = acknowledgedID.flatMap { decisionOutbox.removeValue(forKey: $0) }
            if let record = matchedDecision,
               let id = (try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: record.envelopeData))?.decision?.requestID {
                decisionReceipts.record(.failed(envelope.message ?? AppLocalizer.text("审批失败")), for: id)
            }
            if matchedDecision != nil {
                persistDecisionOutbox()
                pendingDecisionCount = decisionOutbox.count
            }
            let matchedCommand = acknowledgedID.flatMap { commandOutbox[$0] }
            let matchedReset = acknowledgedID.flatMap { resetOutbox.removeValue(forKey: $0) }
            if let matchedCommand {
                if let id = acknowledgedID {
                    let receipt = CommandRecovery.errorReceipt(envelope, originalData: matchedCommand.envelopeData)
                    if case .failed = receipt { commandOutbox.removeValue(forKey: id) }
                    else { commandOutbox[id]?.stopped = true }
                    commandReceipts.record(receipt, for: id)
                }
                persistCommandOutbox(); refreshPendingCommandTaskIDs()
            }
            if acknowledgedID != nil, matchedReset != nil {
                persistResetOutbox()
            }
            // A response can outlive the command that caused it (for example
            // after the WatchConnectivity durable queue has already replayed
            // it). Do not surface an unrelated old error as a modal alert on
            // the Watch every time the companion app reconnects.
            guard matchedDecision != nil || matchedCommand != nil || matchedReset != nil else {
                return
            }
            if matchedCommand != nil {
                lastError = nil
                forwardReliablyToWatch(envelope)
                return
            }
            lastError = envelope.message ?? AppLocalizer.text("Mac 返回了未知错误")
            forwardReliablyToWatch(envelope)

        case .hello:
            requestLatestSnapshot()

        case .requestSnapshot:
            forwardSnapshotToWatch(snapshot)

        case .approvalDecision:
            // Decisions only travel Watch -> iPhone -> Mac.
            break
        case .taskCommand:
            break
        case .usageReset:
            break
        }
    }

    private func handleWatchEnvelope(_ envelope: BridgeEnvelope) {
        guard envelope.version <= BridgeEnvelope.currentVersion else {
            sendWatchError(
                AppLocalizer.text("iPhone App 无法读取这个协议版本"),
                acknowledging: envelope.messageID
            )
            return
        }
        if envelope.kind == .approvalDecision || envelope.kind == .taskCommand || envelope.kind == .usageReset {
            guard RelayOutboxPolicy.isDeliverable(envelope) else {
                sendWatchError(AppLocalizer.text("发送已过期，执行结果未确认。请查看原任务后再试。"), acknowledging: envelope.messageID)
                return
            }
        }

        switch envelope.kind {
        case .hello, .requestSnapshot:
            if envelope.commandStatusQuery != nil {
                guard let original = envelope.commandStatusQuery?.validatedOriginal(for: envelope) else { return }
                if let known = commandOutbox[original.messageID],
                   commandStatusQueries.trackForwarded(envelope, expectedOriginalData: known.envelopeData) {
                    checkingCommandIDs = commandStatusQueries.checkingIDs
                    armCommandQueryTimeout(envelope)
                }
                sendToMac(envelope, urgent: true)
                return
            }
            if envelope.taskHistoryRequest != nil {
                guard historyRequests[envelope.messageID] == nil else { return }
                trackHistoryRequest(envelope)
                sendToMac(envelope, urgent: true)
                return
            }
            forwardSnapshotToWatch(snapshot)
            requestLatestSnapshot()

        case .approvalDecision:
            guard Self.remember(
                envelope.messageID,
                order: &seenWatchMessageIDs,
                set: &seenWatchMessageIDSet
            ) else {
                if let decision = envelope.decision,
                   completedDecisionIDSet.contains(decision.id) {
                    let ack = BridgeEnvelope.acknowledgement(
                        for: envelope.messageID,
                        sender: deviceID
                    )
                    forwardReliablyToWatch(ack)
                }
                return
            }
            acceptDecisionFromWatch(envelope)

        case .taskCommand:
            acceptCommand(envelope)

        case .usageReset:
            // WatchConnectivity may deliver the same user action through its
            // immediate and durable channels. Forward the stable request once;
            // the Mac also uses this request UUID as its server idempotency key.
            guard Self.remember(
                envelope.messageID,
                order: &seenWatchMessageIDs,
                set: &seenWatchMessageIDSet
            ) else { return }
            acceptReset(envelope)

        case .snapshot, .acknowledgement, .error:
            break
        }
    }

    private func acceptCommand(_ envelope: BridgeEnvelope) {
        guard commandStorageAvailable else {
            lastError = AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。")
            sendWatchError(lastError ?? CommandRecovery.unconfirmedText, acknowledging: envelope.messageID)
            return
        }
        guard let command = envelope.taskCommand,
              !command.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendWatchError(AppLocalizer.text("指令内容为空"), acknowledging: envelope.messageID)
            return
        }
        guard !command.targetsBrowserChat else {
            sendWatchError(AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务"), acknowledging: envelope.messageID)
            return
        }
        guard let encoded = try? CodexWatchCoding.makeEncoder().encode(envelope),
              encoded.count <= CommandRecovery.maximumStoredBytes else {
            lastError = AppLocalizer.text("指令内容过长，请缩短后重试。")
            sendWatchError(lastError ?? CommandRecovery.unconfirmedText, acknowledging: envelope.messageID)
            return
        }
        guard CommandRecovery.original(encoded) != nil else {
            sendWatchError(AppLocalizer.text("远程数据校验失败"), acknowledging: envelope.messageID)
            return
        }
        if let existing = commandOutbox[envelope.messageID],
           let decoded = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: existing.envelopeData
           ) {
            guard existing.stopped != true else {
                sendWatchError(CommandRecovery.unconfirmedText, acknowledging: envelope.messageID)
                return
            }
            sendToMac(decoded)
            return
        }
        guard commandOutbox.count < 64,
              !CommandRecovery.requiresLocalReview(senderDeviceID: envelope.senderDeviceID, localDeviceID: deviceID,
                hasStoppedTask: commandOutbox.values.contains(where: { $0.taskID == command.taskID && $0.stopped == true })) else {
            lastError = CommandRecovery.unconfirmedText
            sendWatchError(CommandRecovery.unconfirmedText, acknowledging: envelope.messageID)
            return
        }
        guard command.startsNewCodexChat
            || snapshot.tasks.contains(where: { $0.id == command.taskID }) else {
            sendWatchError(AppLocalizer.text("找不到这个任务"), acknowledging: envelope.messageID)
            return
        }
        commandOutbox[envelope.messageID] = PendingCommandRecord(
            messageID: envelope.messageID,
            taskID: command.taskID,
            envelopeData: encoded
        )
        guard persistCommandOutbox() else {
            refreshPendingCommandTaskIDs()
            return
        }
        refreshPendingCommandTaskIDs()
        sendToMac(envelope, urgent: true)
    }

    private func acceptDecisionFromWatch(_ envelope: BridgeEnvelope) {
        guard let decision = envelope.decision else {
            sendWatchError(AppLocalizer.text("审批决定为空"), acknowledging: envelope.messageID)
            return
        }
        guard decision.choice == .allowOnce || decision.choice == .deny else {
            sendWatchError(AppLocalizer.text("手表只允许单次批准或拒绝"), acknowledging: envelope.messageID)
            return
        }
        let action: ApprovalReviewValidation.RelayAction
        do {
            action = try ApprovalReviewValidation.forwardingAction(decision: decision,
                cached: snapshot.pendingApprovals.first(where: { $0.id == decision.requestID }),
                macConfirmed: completedDecisionIDSet.contains(decision.id))
        } catch {
            sendWatchError(error.localizedDescription, acknowledging: envelope.messageID)
            return
        }
        if action == .replayConfirmed {
            let ack = BridgeEnvelope.acknowledgement(for: envelope.messageID, sender: deviceID)
            forwardReliablyToWatch(ack)
            return
        }

        // A missing phone cache entry is neither approval nor rejection.
        // The Watch already authenticated its reviewed request; forward its
        // exact digest/nonce to the authoritative Mac broker. Only an actual
        // Mac acknowledgement may populate completedDecisionIDSet.

        if let existing = decisionOutbox.values.first(where: { $0.decisionID == decision.id }) {
            if let existingEnvelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: existing.envelopeData
            ) {
                sendToMac(existingEnvelope)
            }
            return
        }

        guard let encoded = try? CodexWatchCoding.makeEncoder().encode(envelope) else {
            sendWatchError(AppLocalizer.text("无法编码审批决定"), acknowledging: envelope.messageID)
            return
        }
        decisionOutbox[envelope.messageID] = PendingDecisionRecord(
            messageID: envelope.messageID,
            decisionID: decision.id,
            envelopeData: encoded
        )
        persistDecisionOutbox()
        pendingDecisionCount = decisionOutbox.count
        sendToMac(envelope, urgent: true)
    }

    private func acceptReset(_ envelope: BridgeEnvelope) {
        guard envelope.usageReset != nil else {
            return
        }
        if let existing = resetOutbox[envelope.messageID],
           let decoded = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: existing.envelopeData
           ) {
            sendToMac(decoded)
            return
        }
        guard let encoded = try? CodexWatchCoding.makeEncoder().encode(envelope) else {
            return
        }
        resetOutbox[envelope.messageID] = PendingResetRecord(
            messageID: envelope.messageID,
            envelopeData: encoded
        )
        persistResetOutbox()
        sendToMac(envelope, urgent: true)
    }

    private func sendToMac(_ envelope: BridgeEnvelope, urgent: Bool = false) {
        guard RelayOutboxPolicy.isDeliverable(envelope) else { return }
        guard commandMaySend(envelope) else { return }
        // A Multipeer session can briefly report a connected peer after the
        // old Mac process has quit. Returning immediately in that window
        // silently stranded a command on the stale local session. Actions are
        // already idempotent by envelope ID on the Mac, so mirror them to the
        // encrypted internet relay as a durable path. This is intentionally
        // limited to user actions, never the frequent dashboard snapshots.
        let targetsBrowserGateway = routesToBrowserGateway(envelope)
        if !targetsBrowserGateway, let multipeerSession, !multipeerSession.connectedPeers.isEmpty {
            do {
                let data = try CodexWatchCoding.makeEncoder().encode(envelope)
                try multipeerSession.send(
                    data,
                    toPeers: multipeerSession.connectedPeers,
                    with: .reliable
                )
            } catch {
                lastError = AppLocalizer.format("发送到 Mac 失败：%@", error.localizedDescription)
            }
        }

        guard envelope.kind == .approvalDecision || envelope.kind == .taskCommand || envelope.kind == .usageReset
                || envelope.taskHistoryRequest != nil || envelope.commandStatusQuery != nil,
              let remoteClient,
              remoteDeliveryRetryGate.begin(envelope.messageID) else { return }
        // Only a newly initiated action may extend the short fast-poll window.
        // Durable retries must not keep an offline Mac in a two-second loop.
        if urgent { beginUrgentRemotePolling() }
        Task {
            defer { remoteDeliveryRetryGate.finish(envelope.messageID) }
            guard commandMaySend(envelope) else { return }
            do {
                if targetsBrowserGateway {
                    try await remoteClient.enqueueBrowser(envelope)
                } else {
                    try await remoteClient.enqueue(envelope, to: .mac)
                }
                // Queued at Cloudflare is not received or executed by Mac.
                if lastError != nil { lastError = nil }
            } catch {
                remoteAvailable = false
                lastError = AppLocalizer.format("远程发送失败：%@", error.localizedDescription)
            }
        }
    }

    /// Existing browser-owned conversations must stay on the host that owns
    /// their real ChatGPT thread ID. For a brand-new Chat, prefer a healthy
    /// gateway, but fall back to the current Mac route when that is the only
    /// verified live path so enabling the feature never removes old behavior.
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
        return !macConnectionState.isConnected && !remoteAvailable
    }

    private func preferredNewChatExecutionTarget() -> TaskExecutionTarget? {
        guard browserGatewayEnabled else { return nil }
        // With the cloud Chat gateway enabled, new Chats always go to the
        // cloud (DeepSeek executor). The Mac Chrome bridge is no longer used
        // for Chat, so a stale browser heartbeat must not pin a new Chat to a
        // sleeping Mac.
        return .browser
    }

    private var hasFreshMacChatRoute: Bool {
        macConnectionState.isConnected || remoteAvailable
    }

    private var hasFreshBrowserChatRoute: Bool {
        browserGatewayEnabled
            && browserChatSnapshot.bridgeConnected
            && Date().timeIntervalSince(browserChatSnapshot.capturedAt) <= 90
    }

    private func chatExecutionTarget(for task: AgentTask) -> TaskExecutionTarget? {
        guard browserGatewayEnabled else { return nil }
        // Existing conversations also use the cloud Chat executor when the
        // gateway is enabled; continuing them starts a fresh cloud thread
        // instead of failing on an unavailable Mac Chrome bridge.
        return .browser
    }

    private func flushDecisionOutbox() {
        pruneExpiredOutboxes()
        // A queued decision is exactly the case where the dashboard may not
        // yet have a fresh snapshot.  `sendToMac` mirrors actions to the
        // remote relay, so do not wait for a connection indicator here.
        for record in decisionOutbox.values {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.envelopeData
            ) else { continue }
            sendToMac(envelope, urgent: false)
        }
    }

    private func flushCommandOutbox() {
        // Do not make durable command recovery depend on a snapshot arriving
        // first.  After an app relaunch or a stale Multipeer session, that
        // creates a circular wait: the phone waits to send the command until
        // the Mac has published a snapshot, while the Mac is waiting for the
        // command.  `sendToMac` is idempotent and selects the available path.
        for record in commandOutbox.values where record.stopped != true {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.envelopeData
            ) else { continue }
            sendToMac(envelope, urgent: false)
        }
    }

    private func flushResetOutbox() {
        // Reset requests are idempotent by their message ID as well, and must
        // be retried through the remote relay even before dashboard recovery.
        for record in resetOutbox.values {
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.envelopeData
            ) else { continue }
            sendToMac(envelope, urgent: false)
        }
    }

    private func startRemotePolling() {
        #if CONTROLLER_FAULT_TESTS
        return // Explicit single refreshes only; no autonomous test traffic.
        #else
        guard remoteClient != nil, remotePollTask == nil else { return }
        remotePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A local encrypted Multipeer session is cheaper and faster;
                // do not duplicate that traffic through the public relay.
                // `remoteAvailable` means the public relay has a fresh
                // snapshot; it does not mean a nearby Multipeer session is
                // active. Treating that status as a local connection makes
                // this loop sleep for 60 seconds immediately after the first
                // remote refresh, so later Chat replies and follow-ups are
                // stranded until the next reconciliation. Only the actual
                // local session may suppress relay polling.
                // The cloud Chat gateway is authoritative for native Chat even
                // while a local Multipeer session is up, so the relay snapshot
                // must still be polled. Only suppress relay traffic when the
                // Mac is connected AND the cloud gateway is not in use.
                if self.macConnectionState.isConnected && !self.browserGatewayEnabled {
                    let wait = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
                    self.remoteWaitTask = wait
                    await wait.value
                    self.remoteWaitTask = nil
                    continue
                }
                await self.refreshRemoteNow()
                guard !Task.isCancelled, let client = self.remoteClient else { return }

                // Keep the public relay connection hibernating instead of
                // waking the phone on a fixed timer. The mailbox remains the
                // source of truth, so a WebSocket reconnect or timeout cannot
                // lose a command; a timeout simply performs the next
                // low-frequency snapshot reconciliation.
                let waitInterval = self.remotePollingInterval
                let wait = Task<Void, Never> {
                    do {
                        try await client.waitForMailboxActivity(.phone, timeout: waitInterval)
                    } catch {
                        guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
                        // Bounded fallback when a network rejects WebSockets.
                        try? await Task.sleep(for: .seconds(min(waitInterval, 15)))
                    }
                }
                self.remoteWaitTask = wait
                await wait.value
                self.remoteWaitTask = nil
            }
        }
        #endif
    }

    /// After a remote action, temporarily use a fast heartbeat. This wakes a
    /// controller that was previously in its low-power idle wait, while the
    /// short window avoids permanently spending relay requests.
    private func beginUrgentRemotePolling(for duration: TimeInterval = 30) {
        urgentRemotePollingUntil = max(
            urgentRemotePollingUntil,
            Date().addingTimeInterval(duration)
        )
        // Only interrupt the idle wait, not snapshot/receipt delivery.
        remoteWaitTask?.cancel()
        startRemotePolling()
    }

    private var remotePollingInterval: Double {
        if Date() < urgentRemotePollingUntil {
            return 2
        }
        let hasUrgentWork = snapshot.activeTaskCount > 0
            || !unexpiredApprovals.isEmpty
            || !pendingCommandTaskIDs.isEmpty
            || pendingDecisionCount > 0
            || !resetOutbox.isEmpty
        // ChatGPT may legitimately take longer than the initial fast window.
        // Keep pending replies and approvals near-real-time without paying the
        // two-second idle polling cost all day.
        return hasUrgentWork && snapshot.isMacOnline() ? 3 : RelayTimingPolicy.idleInterval
    }

    private func refreshRemoteNow() async {
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
        guard let remoteClient else { return }
        var hasFreshMacSnapshot = false
        var macSnapshotDate: Date?
        var relayError: Error?
        do {
            if let envelope = try await remoteClient.latestSnapshot() {
                if RelayTimingPolicy.isFresh(envelope.sentAt), let incoming = envelope.snapshot,
                   RelayTimingPolicy.isFresh(incoming.capturedAt) {
                    handleMacEnvelope(envelope)
                    hasFreshMacSnapshot = incoming.bridgeConnected
                    macSnapshotDate = incoming.capturedAt
                }
            }
        } catch {
            guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
            relayError = error
        }

        if browserGatewayEnabled {
            do {
                if let envelope = try await remoteClient.latestChatSnapshot(),
                   let chatSnapshot = envelope.snapshot,
                   Date().timeIntervalSince(envelope.sentAt) <= 5 * 60 {
                    browserChatSnapshot = chatSnapshot
                    let merged = snapshot.mergingChatSnapshot(chatSnapshot)
                    if !snapshot.isVisuallyEquivalent(to: merged) {
                        snapshot = merged
                        LiveActivityManager.shared.update(from: merged)
                        forwardSnapshotToWatch(merged)
                    }
                }
            } catch {
                // The browser gateway is an independent Chat-only route. A
                // temporary failure must not mark the Mac/Codex relay offline.
            }
        }

        do {
            let responses = try await remoteClient.messages(for: .phone)
            for envelope in responses {
                // A persisted receipt can outlive the Mac. Apply it to the
                // matching action, but never use it as a presence heartbeat.
                handleMacEnvelope(envelope)
                try? await remoteClient.acknowledge(envelope.messageID, in: .phone)
            }
            if remoteAvailable != hasFreshMacSnapshot { remoteAvailable = hasFreshMacSnapshot }
            remoteLastSyncAt = macSnapshotDate
            expireMacPresence()
            forwardSnapshotToWatch(snapshot)
            flushDecisionOutbox()
            flushCommandOutbox()
            flushResetOutbox()
            if let relayError {
                lastError = AppLocalizer.format("远程快照正在恢复：%@", relayError.localizedDescription)
            }
        } catch {
            guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else { return }
            remoteAvailable = false
            expireMacPresence()
            lastError = AppLocalizer.format("远程连接正在恢复：%@", error.localizedDescription)
        }
    }

    private func expireMacPresence() {
        guard snapshot.bridgeConnected, !snapshot.isMacOnline() else { return }
        snapshot = snapshot.reconcilingMacPresence()
        remoteAvailable = false
        forwardSnapshotToWatch(snapshot)
        LiveActivityManager.shared.update(from: snapshot)
    }

    private func forwardSnapshotToWatch(_ value: DashboardSnapshot) {
        guard let data = watchSnapshotData(from: value),
              let session = watchSession,
              session.activationState == .activated else { return }

        do {
            try session.updateApplicationContext(["envelope": data])
        } catch {
            lastError = AppLocalizer.format("无法同步到 Apple Watch：%@", error.localizedDescription)
        }

        guard session.isReachable, data.count <= Self.maximumWatchEnvelopeBytes else { return }
        // WCSession invokes its error handler on a private utility queue. Keep
        // this latency-only path handler-free; any user-visible error is
        // handled by the durable context/relay path above, and no callback may
        // mutate this @MainActor controller off the main executor.
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    /// Choose the richest snapshot that is still safe to send through
    /// WatchConnectivity. The watch can always fetch the full encrypted relay
    /// snapshot when it needs more history, so losing a few old messages is a
    /// much better failure mode than losing every update.
    private func watchSnapshotData(from value: DashboardSnapshot) -> Data? {
        let policies = [
            (tasks: 30, messages: 4, text: 600),
            (tasks: 30, messages: 2, text: 300),
            (tasks: 30, messages: 0, text: 240),
            (tasks: 8, messages: 0, text: 240),
        ]

        for policy in policies {
            let compact = value.compactForWatch(
                maximumTasks: policy.tasks,
                messagesPerTask: policy.messages,
                maximumTextLength: policy.text,
                maximumApprovals: value.pendingApprovals.count
            )
            let envelope = BridgeEnvelope.snapshot(compact, sender: deviceID)
            if let data = try? CodexWatchCoding.makeEncoder().encode(envelope),
               data.count <= Self.maximumWatchEnvelopeBytes {
                return data
            }
        }

        // Do not overwrite a richer Watch snapshot with a truncated approval
        // or an incomplete queue. The Watch's independent relay can fetch it.
        lastError = AppLocalizer.text("Apple Watch 同步内容过大，正在改用公网中继")
        return nil
    }

    private func forwardReliablyToWatch(_ envelope: BridgeEnvelope) {
        guard let data = try? CodexWatchCoding.makeEncoder().encode(envelope),
              let session = watchSession,
              session.activationState == .activated else { return }

        guard data.count <= Self.maximumWatchEnvelopeBytes else {
            lastError = AppLocalizer.text("Apple Watch 指令内容过大，正在改用公网中继")
            return
        }

        // Queue first so delivery continues even when iOS suspends the app.
        // The immediate message is only a latency optimization; duplicate
        // envelopes are rejected by their stable message ID.
        if !session.outstandingUserInfoTransfers.contains(where: {
            guard let pending = $0.userInfo["envelope"] as? Data,
                  let queued = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: pending) else { return false }
            return queued.messageID == envelope.messageID
        }) {
            session.transferUserInfo(["envelope": data])
        }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
    }

    private func sendWatchError(_ message: String, acknowledging messageID: String) {
        let envelope = BridgeEnvelope(
            kind: .error,
            senderDeviceID: deviceID,
            acknowledgedMessageID: messageID,
            message: message
        )
        forwardReliablyToWatch(envelope)
    }

    private func loadPersistentState() {
        if let data = UserDefaults.standard.data(forKey: Self.outboxKey),
           let records = try? PropertyListDecoder().decode([PendingDecisionRecord].self, from: data) {
            decisionOutbox = Dictionary(uniqueKeysWithValues: records.map { ($0.messageID, $0) })
        }
        pendingDecisionCount = decisionOutbox.count

        completedDecisionIDs = UserDefaults.standard.stringArray(
            forKey: Self.completedDecisionIDsKey
        ) ?? []
        completedDecisionIDSet = Set(completedDecisionIDs)

        loadCommandOutbox()

        // One-time migration: old Shortcut chats could target Gemini and their
        // pending callbacks kept the phone in a needless fast-poll loop. The
        // current Chat route is relay/Mac-only, so discard only those legacy
        // caches; command, approval and reset outboxes remain untouched.
        shortcutChatTasks = []
        shortcutPending = [:]
        UserDefaults.standard.removeObject(forKey: Self.shortcutChatsKey)
        UserDefaults.standard.removeObject(forKey: Self.shortcutPendingKey)
        refreshPendingCommandTaskIDs()

        if let data = UserDefaults.standard.data(forKey: Self.resetOutboxKey),
           let records = try? PropertyListDecoder().decode([PendingResetRecord].self, from: data) {
            resetOutbox = Dictionary(uniqueKeysWithValues: records.map { ($0.messageID, $0) })
        }

        notifiedApprovalIDs = UserDefaults.standard.stringArray(
            forKey: Self.notifiedApprovalIDsKey
        ) ?? []
        notifiedApprovalIDSet = Set(notifiedApprovalIDs)
        pruneExpiredOutboxes()
    }

    /// Persistent queues can outlive both their network packet and the app
    /// session. Never replay expired actions or keep them marked as pending.
    private func pruneExpiredOutboxes(now: Date = Date()) {
        let expiredMessage = AppLocalizer.text("发送已过期，执行结果未确认。请查看原任务后再试。")
        func decoded(_ data: Data) -> BridgeEnvelope? {
            try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
        }
        var decisionsChanged = false
        for record in Array(decisionOutbox.values) {
            let envelope = decoded(record.envelopeData)
            guard envelope.map({ !RelayOutboxPolicy.isDeliverable($0, now: now) }) ?? true else { continue }
            decisionOutbox.removeValue(forKey: record.messageID)
            if let requestID = envelope?.decision?.requestID {
                decisionReceipts.record(.failed(expiredMessage), for: requestID)
            }
            decisionsChanged = true
        }
        if decisionsChanged {
            persistDecisionOutbox()
            pendingDecisionCount = decisionOutbox.count
        }
        var commandsChanged = false
        for record in Array(commandOutbox.values) {
            guard record.stopped != true, CommandRecovery.shouldPause(record.envelopeData, now: now) else { continue }
            commandOutbox[record.messageID]?.stopped = true
            commandReceipts.record(.unconfirmed(CommandRecovery.unconfirmedText), for: record.messageID)
            commandsChanged = true
        }
        if commandsChanged {
            persistCommandOutbox()
            refreshPendingCommandTaskIDs()
        }
        var resetsChanged = false
        for record in Array(resetOutbox.values) {
            guard decoded(record.envelopeData).map({ !RelayOutboxPolicy.isDeliverable($0, now: now) }) ?? true else { continue }
            resetOutbox.removeValue(forKey: record.messageID)
            usageResetResult = expiredMessage
            resetsChanged = true
        }
        if resetsChanged { persistResetOutbox() }
        remoteDeliveryRetryGate.retainOnly(Set(decisionOutbox.keys)
            .union(commandOutbox.keys).union(resetOutbox.keys).union(historyRequests.keys))
    }

    private func configureApprovalNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func notifyForNewApprovals(in incoming: DashboardSnapshot) {
        let valid = incoming.pendingApprovals.filter { !$0.isExpired }
        let newRequests = valid.filter { notifiedApprovalIDSet.insert($0.id).inserted }

        for request in newRequests {
            notifiedApprovalIDs.append(request.id)
            let content = UNMutableNotificationContent()
            content.title = AppLocalizer.text(request.kind == .userInput ? "Codex 等待回答" : "Codex 等待审批")
            // Lock-screen reminders contain no task body or secret question.
            content.body = AppLocalizer.text(
                request.kind == .userInput ? "打开软件查看并回答" : "打开 Codex 控制，在 iPhone 或 Apple Watch 上查看并确认。"
            )
            content.sound = .default
            content.badge = NSNumber(value: valid.count)
            content.userInfo = ["approvalRequestID": request.id]
            let notification = UNNotificationRequest(
                identifier: "codex-approval-\(request.id)",
                content: content,
                trigger: nil
            )
            Task { try? await UNUserNotificationCenter.current().add(notification) }
        }

        if notifiedApprovalIDs.count > Self.maximumSeenMessageCount {
            let overflow = notifiedApprovalIDs.count - Self.maximumSeenMessageCount
            for removed in notifiedApprovalIDs.prefix(overflow) {
                notifiedApprovalIDSet.remove(removed)
            }
            notifiedApprovalIDs.removeFirst(overflow)
        }
        if !newRequests.isEmpty {
            UserDefaults.standard.set(
                notifiedApprovalIDs,
                forKey: Self.notifiedApprovalIDsKey
            )
        }
        if valid.isEmpty {
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        }
    }

    private func persistDecisionOutbox() {
        let values = Array(decisionOutbox.values)
        guard let data = try? PropertyListEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: Self.outboxKey)
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
            // Keep legacy preferences intact. An existing empty v1 file is
            // authoritative and cannot re-import a previously discarded item.
            _ = persistCommandOutbox()
        } catch {
            commandStorageReadFailed = true
            commandStorageRepairNeeded = CommandOutboxFileStore.canRepair(error)
            markCommandStorageUnavailable()
        }
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
            commandReceipts.record(.unconfirmed(message), for: id)
        }
        lastError = message
        refreshPendingCommandTaskIDs()
    }

    #if CONTROLLER_FAULT_TESTS
    var faultCommandRecords: [StoredCommandRecord] { Array(commandOutbox.values) }
    func faultReceive(_ envelope: BridgeEnvelope) { handleMacEnvelope(envelope) }
    func faultFlush() { pruneExpiredOutboxes(); flushCommandOutbox() }
    func faultPrune(now: Date) { pruneExpiredOutboxes(now: now) }
    func faultRefresh() async { await refreshRemoteNow() }
    #endif

    private func persistShortcutState() {
        shortcutChatTasks = Array(shortcutChatTasks
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(30))
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
                from: record.envelopeData
            ),
            let projectionID = envelope.taskCommand?.nativeChatProjectionID else {
                return [record.taskID]
            }
            return [projectionID]
        })
            .union(shortcutPending.values.map(\.chatID))
    }

    private func persistResetOutbox() {
        let values = Array(resetOutbox.values)
        guard let data = try? PropertyListEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: Self.resetOutboxKey)
    }

    private func markChatCommandFailed(
        _ record: PendingCommandRecord,
        message: String?
    ) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
            BridgeEnvelope.self,
            from: record.envelopeData
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
        forwardSnapshotToWatch(snapshot)
    }

    /// A Mac heartbeat can legitimately predate a newly queued Chat command.
    /// Keep that local draft until the owner publishes the matching transcript;
    /// otherwise the row would disappear every time the relay refreshes.
    private func preservingQueuedNativeChats(
        _ incoming: DashboardSnapshot
    ) -> DashboardSnapshot {
        let pendingProjectionIDs: Set<String> = Set(commandOutbox.values.compactMap { record in
            guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
                BridgeEnvelope.self,
                from: record.envelopeData
            ),
            let command = envelope.taskCommand else { return nil }
            return command.nativeChatProjectionID
        })
        guard !pendingProjectionIDs.isEmpty else { return incoming }

        var result = incoming
        for draft in snapshot.tasks where pendingProjectionIDs.contains(draft.id) {
            if let index = result.tasks.firstIndex(where: { $0.id == draft.id }) {
                if result.tasks[index].messages.isEmpty {
                    result.tasks[index] = draft
                }
            } else {
                result.tasks.append(draft)
            }
        }
        result.tasks.sort {
            if $0.state.isActive != $1.state.isActive { return $0.state.isActive }
            return $0.updatedAt > $1.updatedAt
        }
        return result
    }

    private func rememberCompletedDecision(_ id: String) {
        guard completedDecisionIDSet.insert(id).inserted else { return }
        completedDecisionIDs.append(id)
        if completedDecisionIDs.count > Self.maximumSeenMessageCount {
            let removed = completedDecisionIDs.removeFirst()
            completedDecisionIDSet.remove(removed)
        }
        UserDefaults.standard.set(completedDecisionIDs, forKey: Self.completedDecisionIDsKey)
    }

    @discardableResult
    private static func remember(
        _ id: String,
        order: inout [String],
        set: inout Set<String>
    ) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > Self.maximumSeenMessageCount {
            let removed = order.removeFirst()
            set.remove(removed)
        }
        return true
    }
}

private enum PhoneApprovalError: LocalizedError {
    case faceIDRequired

    var errorDescription: String? {
        switch self {
        case .faceIDRequired:
            AppLocalizer.text("需要 Face ID 才能批准此请求")
        }
    }
}

private extension PhoneRelayController {
    struct PendingDecisionRecord: Codable {
        let messageID: String
        let decisionID: String
        let envelopeData: Data
    }

    typealias PendingCommandRecord = StoredCommandRecord

    struct PendingResetRecord: Codable {
        let messageID: String
        let envelopeData: Data
    }

    final class PeerReference: @unchecked Sendable {
        let peer: MCPeerID

        init(_ peer: MCPeerID) {
            self.peer = peer
        }
    }
}

extension PhoneRelayController: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        if let role = info?["role"], role != "mac" { return }
        let reference = PeerReference(peerID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            discoveredPeers[reference.peer.displayName] = reference.peer
            discoveredMacNames = discoveredPeers.keys.sorted()
            if scannedMacName == reference.peer.displayName {
                selectedMacName = reference.peer.displayName
            } else if selectedMacName.isEmpty {
                selectedMacName = reference.peer.displayName
            }
            if !isManualPairing, !macConnectionState.isConnected {
                macConnectionState = .browsing
                attemptAutoConnect()
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        let name = peerID.displayName
        Task { @MainActor [weak self] in
            guard let self else { return }
            discoveredPeers.removeValue(forKey: name)
            discoveredMacNames = discoveredPeers.keys.sorted()
            if selectedMacName == name {
                selectedMacName = discoveredMacNames.first ?? ""
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.lastError = AppLocalizer.format("无法搜索 Mac：%@", error.localizedDescription)
            self?.macConnectionState = .disconnected
        }
    }
}

extension PhoneRelayController: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let name = peerID.displayName
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                didConnect(to: name)
            case .notConnected:
                let wasInviting: Bool
                if case .inviting = macConnectionState { wasInviting = true } else { wasInviting = false }
                markMacDisconnected()
                if wasInviting {
                    pairingAttemptTask?.cancel()
                    pairingAttemptTask = nil
                    autoConnectBlockedUntil = Date().addingTimeInterval(30)
                    lastError = AppLocalizer.text("Mac 拒绝了配对请求，请确认最新六码和本地网络权限")
                }
                if started, !isManualPairing {
                    // The browser remains active across session changes. This
                    // is intentionally an idempotent lazy start; calling
                    // stopBrowsingForPeers followed by startBrowsingForPeers
                    // here can crash CoreFoundation on iOS 26.
                    startBrowserIfNeeded()
                    scheduleReconnect()
                }
            case .connecting:
                macConnectionState = .inviting(name)
            @unknown default:
                markMacDisconnected()
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
            BridgeEnvelope.self,
            from: data
        ) else { return }
        Task { @MainActor [weak self] in
            self?.handleMacEnvelope(envelope)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

extension PhoneRelayController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            watchReachable = reachable
            if let error {
                lastError = AppLocalizer.format("Apple Watch 连接失败：%@", error.localizedDescription)
            } else if activationState == .activated {
                forwardSnapshotToWatch(snapshot)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.watchReachable = reachable
            if reachable, let self {
                self.forwardSnapshotToWatch(self.snapshot)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data
    ) {
        receiveWatchData(messageData)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let reply = RelayDataReply(replyHandler)
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: messageData) else {
            reply.send(Data())
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { reply.send(Data()); return }
            guard envelope.version <= BridgeEnvelope.currentVersion,
                  envelope.kind == .requestSnapshot || envelope.kind == .hello,
                  envelope.taskHistoryRequest == nil, envelope.commandStatusQuery == nil else {
                self.handleWatchEnvelope(envelope)
                reply.send(Data())
                return
            }
            // A foreground Watch request wakes this companion in the
            // background. Fetch fresh data before replying, instead of merely
            // re-sending cached data. Keep the original Mac capturedAt so a
            // failed fetch cannot make an offline Mac look online.
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                let data = self.flatMap { $0.watchSnapshotData(from: $0.snapshot.reconcilingMacPresence()) }
                reply.send(data ?? Data())
            }
            defer { deadline.cancel() }
            if self.macConnectionState.isConnected {
                self.sendToMac(BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: self.deviceID))
            }
            // Do not wait behind a mailbox drain that iOS may have suspended
            // earlier. This wake-up reads just the snapshot using the same
            // authenticated client; the normal poller still owns receipts.
            if let client = self.remoteClient {
                do {
                    if let fresh = try await client.latestSnapshot(),
                       RelayTimingPolicy.isFresh(fresh.sentAt),
                       let incoming = fresh.snapshot, RelayTimingPolicy.isFresh(incoming.capturedAt) {
                        self.handleMacEnvelope(fresh)
                    }
                } catch {
                    // Reply with the original timestamped cache below. A
                    // failed fetch must not become a new presence heartbeat.
                }
            }
            let data = self.watchSnapshotData(from: self.snapshot.reconcilingMacPresence())
            reply.send(data ?? Data())
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext["envelope"] as? Data else { return }
        receiveWatchData(data)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo["envelope"] as? Data else { return }
        receiveWatchData(data)
    }

    nonisolated private func receiveWatchData(_ data: Data) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(
            BridgeEnvelope.self,
            from: data
        ) else { return }
        Task { @MainActor [weak self] in
            self?.handleWatchEnvelope(envelope)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.watchReachable = false
            self?.watchSession?.activate()
        }
    }
}

extension PhoneRelayController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["approvalRequestID"] as? String else { return }
        await MainActor.run { self.selectedNotificationRequestID = id; self.requestLatestSnapshot() }
    }
}
