import ApplicationServices
import Foundation
import IOKit.ps
import LocalAuthentication
import SwiftUI
import CodexBridgeKit
import CodexWatchCore

@MainActor
final class MacBridgeViewModel: ObservableObject {
    @Published private(set) var snapshot = DashboardSnapshot.empty
    @Published private var statusKey = "正在启动"
    @Published private var statusSessionKey: String?
    var statusText: String {
        if let statusSessionKey {
            return AppLocalizer.format(statusKey, AppLocalizer.text(statusSessionKey))
        }
        return AppLocalizer.text(statusKey)
    }
    @Published private(set) var bridgeRunning = false
    @Published private(set) var remoteRelayAvailable = false
    @Published private(set) var pendingAnswerIDs: Set<String> = []
    @Published private(set) var pendingCommandTaskIDs: Set<String> = []
    @Published private(set) var isStartingTask = false
    @Published var prompt = ""
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var errorMessage: String?
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairingCodeExpiry = Date.distantPast
    @Published private(set) var pairingCodeRemaining = "0:00"
    @Published private(set) var isPhonePaired = false
    @Published private(set) var pairingMacName = "Mac"
    /// Accessibility is a persistent macOS permission, but the bridge only
    /// asks macOS to grant/bind it while the Mac is on external power. This
    /// avoids waking the user with a permission prompt on battery and keeps
    /// the battery policy explicit in the UI.
    @Published private(set) var isConnectedToExternalPower = false

    private let service: CodexBridgeService
    private let desktopThreadController = ChatGPTDesktopThreadController()
    private let desktopInterfaceController = ChatGPTDesktopInterfaceController()
    private var transport: MacPeerTransport?
    private var remoteTransport: MacRemoteRelayTransport?
    private var started = false
    private var keepAwakeActivity: NSObjectProtocol?
    private var powerSourceMonitorTask: Task<Void, Never>?
    private var activeLocalOperationCount = 0
    /// TCC prompts are user-facing and should be requested at most once per
    /// process. Reconnect/power polling must not present the same sheet again.
    private var didRequestAccessibilityBinding = false
    private var pairingCountdownTask: Task<Void, Never>?
    private var pairingVisibility = PairingVisibility()
    /// The app-server is a child process of the bridge and can disappear
    /// independently (for example after ChatGPT updates or a transient
    /// crash). Keep a small, exponential recovery loop so the companion
    /// transports stay useful instead of polling a permanently dead client.
    private var serviceRecoveryTask: Task<Void, Never>?
    private var serviceHealthTask: Task<Void, Never>?
    /// Watch actions intentionally travel over both nearby peer connectivity
    /// and the internet relay. Both transports must share one gate or the same
    /// envelope can be executed once by each path.
    private let companionActionDeduplicator: BridgeMessageDeduplicator
    private let watchApprovalGate = WatchApprovalGate()
    private let isUIPreview: Bool
    init() {
        let preview = ProcessInfo.processInfo.arguments.contains("-UIPreview")
        isUIPreview = preview
        let journal = BridgeMessageDeduplicator(capacity: 4_096,
            persistenceURL: preview ? nil : BridgeMessageDeduplicator.defaultJournalURL)
        companionActionDeduplicator = journal
        service = CodexBridgeService(ownerBindingRecorder: { command, owner in
            try journal.bindAssignedOwner(command, threadID: owner)
        })
        isConnectedToExternalPower = Self.readExternalPowerState()
        if isUIPreview {
            snapshot = .uiPreview(
                english: ProcessInfo.processInfo.arguments.contains {
                    $0 == AppLanguage.english.rawValue || $0 == "-\(AppLanguage.english.rawValue)"
                },
                questions: ProcessInfo.processInfo.arguments.contains("-PreviewQuestions")
            )
            setStatus("本地与远程桥接已运行")
            bridgeRunning = true
        }
        rotatePairingCode()
    }

    deinit {
        pairingCountdownTask?.cancel()
        powerSourceMonitorTask?.cancel()
        serviceRecoveryTask?.cancel()
        serviceHealthTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        guard !isUIPreview else { return }
        // Companion connectivity must not wait behind a slow local ChatGPT
        // socket. This keeps the relay and Watch surfaces alive while the
        // desktop client reconnects.
        configureCompanionTransports()
        bridgeRunning = true
        setStatus("正在连接 ChatGPT，正在验证远程中继")
        startPowerSourceMonitoring()
        // Primary app-server and desktop IPC do not need Accessibility.
        // Do not prompt at startup or whenever the power source changes.
        Task { [self] in
            do {
                await service.setSnapshotChangedHandler { [weak self] in
                    await self?.publishCurrentSnapshot()
                }
                await service.setServiceLostHandler { [weak self] in
                    guard let self else { return }
                    await MainActor.run {
                        self.startServiceRecoveryLoop()
                    }
                }
                try await service.start(refreshImmediately: false)
                // Establish the owner monitor before any optional history
                // reads. Startup must not parse multi-hundred-MB rollouts.
                await service.refresh(readTranscripts: false)
                await configureDesktopMonitoring()
                let source = await service.connectionSource()
                let sessionStatus = source == .managedDaemon
                    ? "已接入 app-server 会话"
                    : "本地 app-server 会话"
                guard let transport else { return }
                if remoteTransport == nil, let configuration = RemoteRelayConfiguration.fromMainBundle() {
                    let remote = MacRemoteRelayTransport(
                        configuration: configuration,
                        deviceID: transport.deviceID,
                        actionDeduplicator: companionActionDeduplicator
                    )
                    remote.start(
                        snapshotProvider: { [service] in await service.snapshot() },
                        decisionHandler: { [service, watchApprovalGate] decision in
                            try await watchApprovalGate.confirmIfNeeded(decision)
                            try await service.submit(decision)
                        },
                        commandHandler: { [weak self] command in
                            guard let self else { throw AppServerClientError.notRunning }
                            try await self.deliver(command)
                        },
                        usageResetHandler: { [service] request in try await service.consumeResetCredit(request) },
                        historyHandler: { [service] request in try await service.history(request) },
                        commandRecoveryHandler: { [service] command in await service.confirmsAcceptedCommand(command) },
                        reachabilityHandler: { [weak self] isReachable, error in
                            Task { @MainActor in
                                guard let self else { return }
                                self.remoteRelayAvailable = isReachable
                                self.setStatus(
                                    isReachable
                                        ? "%@，远程中继在线"
                                        : "%@，远程中继正在恢复",
                                    session: sessionStatus
                                )
                                // Preserve the actionable error in the debug/UI state without
                                // surfacing a modal alert on every retry.
                                if isReachable { self.errorMessage = nil }
                                _ = error
                            }
                        }
                    )
                    remoteTransport = remote
                    setStatus("%@，正在验证远程中继", session: sessionStatus)
                    bridgeRunning = true
                } else {
                    setStatus(
                        remoteTransport == nil
                            ? "%@已运行"
                            : (remoteRelayAvailable
                                ? "%@，远程中继在线"
                                : "%@，远程中继正在恢复"),
                        session: sessionStatus
                    )
                    bridgeRunning = true
                }
            } catch {
                errorMessage = error.localizedDescription
                setStatus("ChatGPT 桌面接口暂不可用，远程中继保持在线")
                startServiceRecoveryLoop()
            }
            // Reconciliation belongs to the bridge lifetime, not only to a
            // successful first launch. Otherwise recovery can restore the
            // child while quota, tasks and desktop approvals stay frozen.
            await refreshLoop()
        }
        startServiceHealthMonitoring()
    }

    private func startServiceHealthMonitoring() {
        guard serviceHealthTask == nil else { return }
        serviceHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if !(await self.service.isRunning()) {
                    self.startServiceRecoveryLoop()
                }
            }
        }
    }

    private func configureCompanionTransports() {
        guard transport == nil else { return }
        let transport = MacPeerTransport(actionDeduplicator: companionActionDeduplicator)
        pairingMacName = transport.peerDisplayName
        isPhonePaired = transport.hasTrustedPhone
        transport.setPairingCode(pairingCode, expiresAt: pairingCodeExpiry)
        transport.start(
            snapshotProvider: { [service] in await service.snapshot() },
            decisionHandler: { [service, watchApprovalGate] decision in
                try await watchApprovalGate.confirmIfNeeded(decision)
                try await service.submit(decision)
            },
            commandHandler: { [weak self] command in
                guard let self else { throw AppServerClientError.notRunning }
                try await self.deliver(command)
            },
            usageResetHandler: { [service] request in try await service.consumeResetCredit(request) },
            historyHandler: { [service] request in try await service.history(request) },
            commandRecoveryHandler: { [service] command in await service.confirmsAcceptedCommand(command) }
        )
        self.transport = transport

        guard let configuration = RemoteRelayConfiguration.fromMainBundle() else { return }
        let remote = MacRemoteRelayTransport(
            configuration: configuration,
            deviceID: transport.deviceID,
            actionDeduplicator: companionActionDeduplicator
        )
        remote.start(
            snapshotProvider: { [service] in await service.snapshot() },
            decisionHandler: { [service, watchApprovalGate] decision in
                try await watchApprovalGate.confirmIfNeeded(decision)
                try await service.submit(decision)
            },
            commandHandler: { [weak self] command in
                guard let self else { throw AppServerClientError.notRunning }
                try await self.deliver(command)
            },
            usageResetHandler: { [service] request in try await service.consumeResetCredit(request) },
            historyHandler: { [service] request in try await service.history(request) },
            commandRecoveryHandler: { [service] command in await service.confirmsAcceptedCommand(command) },
            reachabilityHandler: { [weak self] isReachable, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.remoteRelayAvailable = isReachable
                    guard self.snapshot.bridgeConnected else { return }
                    self.setStatus(
                        isReachable
                            ? "已接入 app-server 会话，远程中继在线"
                            : "已接入 app-server 会话，远程中继正在恢复"
                    )
                }
            }
        )
        remoteTransport = remote
    }

    func rotatePairingCode() {
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        pairingCodeExpiry = Date().addingTimeInterval(5 * 60)
        transport?.setPairingCode(pairingCode, expiresAt: pairingCodeExpiry)
        refreshPairingCountdown()
    }

    func resetPhonePairing() {
        transport?.forgetTrustedPhone()
        isPhonePaired = false
        rotatePairingCode()
    }

    var pairingQRPayload: String {
        var components = URLComponents()
        components.scheme = "codexcontrol"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "mac", value: pairingMacName),
            URLQueryItem(name: "code", value: pairingCode),
            URLQueryItem(name: "expires", value: String(Int(pairingCodeExpiry.timeIntervalSince1970)))
        ]
        return components.url?.absoluteString ?? "codexcontrol://pair"
    }

    func setPairingVisible(_ visible: Bool, observerID: UUID) {
        guard pairingVisibility.setVisible(visible, observerID: observerID) else { return }
        pairingCountdownTask?.cancel()
        pairingCountdownTask = nil
        guard pairingVisibility.shouldTick else { return }
        refreshPairingCountdown()
        pairingCountdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.pairingVisibility.shouldTick == true else { return }
                self?.refreshPairingCountdown()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshPairingCountdown() {
        if let transport {
            isPhonePaired = transport.hasTrustedPhone
            pairingMacName = transport.peerDisplayName
        }
        if pairingCodeExpiry <= Date() {
            rotatePairingCode()
            return
        }
        let seconds = max(0, Int(pairingCodeExpiry.timeIntervalSinceNow.rounded(.down)))
        pairingCodeRemaining = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func startTask(options: CodexExecutionOptions? = nil) {
        guard !isUIPreview else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isStartingTask else { return }
        isStartingTask = true
        let submittedPrompt = prompt
        Task {
            beginLocalOperation()
            defer { endLocalOperation(); isStartingTask = false }
            do {
                _ = try await service.startTask(prompt: trimmedPrompt, workingDirectory: workingDirectory, options: options)
                if prompt == submittedPrompt { prompt = "" }
                await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func approveWithAppleWatch(_ request: ApprovalRequest) {
        if isUIPreview {
            removePreviewApproval(request)
            return
        }
        Task {
            beginLocalOperation()
            defer { endLocalOperation() }
            do {
                let context = LAContext()
                let policy: LAPolicy
                if #available(macOS 15.0, *) {
                    policy = .deviceOwnerAuthenticationWithCompanion
                } else {
                    policy = .deviceOwnerAuthenticationWithWatch
                }

                var evaluationError: NSError?
                guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
                    throw evaluationError ?? LAError(.authenticationFailed)
                }
                let approved = try await context.evaluatePolicy(
                    policy,
                    localizedReason: AppLocalizer.format("批准 Codex：%@", request.title)
                )
                guard approved else { return }
                try await submit(choice: .allowOnce, request: request, deviceID: "mac-system-watch")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func answer(_ request: ApprovalRequest, answers: [String: [String]]) {
        guard let questions = request.questions,
              (try? UserInputValidation.validate(answers, questions: questions)) != nil,
              pendingAnswerIDs.insert(request.id).inserted else { return }
        if isUIPreview { removePreviewApproval(request); pendingAnswerIDs.remove(request.id); return }
        Task {
            defer { pendingAnswerIDs.remove(request.id) }
            do { try await submit(choice: .allowOnce, request: request, deviceID: "mac", answers: answers) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func deny(_ request: ApprovalRequest) {
        if isUIPreview {
            removePreviewApproval(request)
            return
        }
        Task {
            do {
                try await submit(choice: .deny, request: request, deviceID: "mac")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendCommand(_ prompt: String, to task: AgentTask, options: CodexExecutionOptions? = nil,
                     onSuccess: @escaping @MainActor () -> Void = {}) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isUIPreview else { return }
        guard pendingCommandTaskIDs.insert(task.id).inserted else { return }
        let command = TaskCommand(
            taskID: task.id,
            prompt: trimmed,
            activeTurnID: task.activeTurnID,
            deviceID: "mac",
            options: options
        )
        Task {
            defer { pendingCommandTaskIDs.remove(task.id) }
            do {
                try await deliver(command)
                onSuccess()
                await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deliver(_ command: TaskCommand) async throws {
        beginLocalOperation()
        defer { endLocalOperation() }
        if command.targetsBrowserChat || command.executionTarget == .browser {
            // Chat was removed from the companion UI. Reject stale packets
            // from an older iPhone/Watch build instead of opening a ChatGPT
            // window, invoking Chrome, or consuming a separate Chat quota.
            throw ChatGPTDesktopControlError.chatUnavailable
        }
        try await waitForLocalServiceStartup()
        try await service.validateOptions(command)
        let canContinueDirectly = await service.canContinueDirectly(threadID: command.taskID)
        if command.startsNewCodexChat || canContinueDirectly {
            try await service.send(command)
            return
        }

        let task = await service.task(threadID: command.taskID)
        if task?.isNativeChat == true || task?.isChat == true {
            throw ChatGPTDesktopControlError.chatUnavailable
        }
        do {
            let submittedAt = Date()
            // The structured task-follower IPC does not use Accessibility or
            // keystrokes and does not need a keep-awake assertion on battery.
            // Never fall back to keystrokes or another application's window.
            try await desktopThreadController.send(command, task: task)
            await service.recordExternallySentCommand(command, submittedAt: submittedAt, previousMessageIDs: Set(task?.messages.map(\.id) ?? []))
            return
        } catch let error as ChatGPTDesktopControlError {
            // Only a proven absence of a desktop owner permits another
            // executor to acquire this conversation. A timeout or version
            // error is not proof of non-delivery and must never duplicate it.
            switch error {
            case .noOwningWindow, .desktopNotRunning, .invalidSocket: break
            default: throw error
            }
            // An idle desktop task has no live window owner. The app-server can
            // safely resume it and becomes the owner of the new turn, which
            // also makes future permission requests available to the Watch.
            if task?.isInProgress != true {
                do {
                    try await service.send(command)
                    return
                } catch {
                    throw error
                }
            }
        }

        // No keystrokes or UI injection: preserve an active desktop task's
        // owner rather than silently switching apps or copying the conversation.
        throw ChatGPTDesktopControlError.noOwningWindow
    }

    private func waitForLocalServiceStartup() async throws {
        if await service.isRunning() { return }
        // MacPeerTransport and the encrypted relay start before app-server so
        // that pairing and status recovery do not wait on a slow desktop
        // socket. A queued command arriving in that small window should wait
        // for the same startup instead of being acknowledged as failed.
        for _ in 0..<120 where !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(250))
            if await service.isRunning() { return }
        }
        throw AppServerClientError.notRunning
    }

    private func submit(choice: ApprovalChoice, request: ApprovalRequest, deviceID: String, answers: [String: [String]]? = nil) async throws {
        let decision = ApprovalDecision(
            requestID: request.id,
            requestDigest: request.requestDigest,
            choice: choice,
            decidedAt: Date(),
            deviceID: deviceID,
            nonce: request.nonce,
            origin: .mac,
            answers: answers
        )
        try await service.submit(decision)
        await refreshNow()
    }

    private func removePreviewApproval(_ request: ApprovalRequest) {
        snapshot.pendingApprovals.removeAll { $0.id == request.id }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            if await service.isRunning() {
                await refreshNow()
            } else {
                // A dead app-server must not leave the bridge in a silent
                // polling loop. Route runtime failures through the same
                // bounded, exponential recovery loop used at startup instead
                // of retrying a failed launch every five seconds.
                startServiceRecoveryLoop()
            }
            // Active work stays responsive; an idle bridge refreshes slowly
            // because mailbox delivery is event-driven through WebSocket.
            let hasActiveWork = snapshot.activeTaskCount > 0 || !snapshot.pendingApprovals.isEmpty
            // Owner events publish immediately. This timer only reconciles
            // metadata/quota; it must not keep re-reading giant live rollouts.
            let interval: Double = hasActiveWork
                ? ((await service.activeTasksHaveLiveUpdates()) ? 30 : 5)
                : RelayTimingPolicy.idleInterval
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func startServiceRecoveryLoop() {
        guard serviceRecoveryTask == nil else { return }
        serviceRecoveryTask = Task { @MainActor [weak self] in
            var delay: TimeInterval = 5
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if await self.attemptServiceRecovery() {
                    self.serviceRecoveryTask = nil
                    return
                }
                delay = min(delay * 2, 60)
            }
        }
    }

    @discardableResult
    private func attemptServiceRecovery() async -> Bool {
        guard !(await service.isRunning()) else { return true }
        setStatus("正在恢复 ChatGPT 桌面接口")
        do {
            // The normal startup performs an initial full snapshot refresh.
            // Recovery only needs to re-establish the app-server session;
            // refreshLoop will fetch the snapshot on its next pass. Keeping
            // that expensive read out of the recovery critical section means
            // a second child-process exit cannot hold the backoff task open.
            try await service.start(
                refreshImmediately: false,
                preferManagedDaemon: false
            )
            errorMessage = nil
            setStatus("本地 app-server 会话已运行")
            await publishCurrentSnapshot()
            return true
        } catch {
            errorMessage = error.localizedDescription
            setStatus("ChatGPT 桌面接口暂不可用，远程中继保持在线")
            return false
        }
    }

    private func refreshNow() async {
        await service.refresh(readTranscripts: false)
        if await service.isRunning() { await configureDesktopMonitoring() }
        await publishCurrentSnapshot()
    }

    private func configureDesktopMonitoring() async {
        let desktopApprovals = desktopThreadController
        let existingConversationIDs = Set((await service.snapshot()).tasks.map(\.id))
        // The controller starts only one monitor. Calling this after each
        // successful refresh also covers an initially unavailable app-server.
        await desktopApprovals.startApprovalMonitoring(
            existingConversationIDs: existingConversationIDs,
            onApproval: { [weak self, service, desktopApprovals] approval in
                do {
                    _ = try await service.registerExternalApproval(
                        approval.event, externalKey: approval.externalKey
                    ) { requestID, result in
                        guard requestID == approval.requestID else {
                            throw ChatGPTDesktopControlError.protocolError("desktop approval request changed")
                        }
                        try await desktopApprovals.respond(to: approval, result: result)
                    }
                    await self?.publishCurrentSnapshot()
                } catch { await self?.reportDesktopApprovalError(error) }
            },
            onResolved: { [weak self, service] externalKey in
                await service.resolveExternalApproval(externalKey: externalKey)
                await self?.publishCurrentSnapshot()
            },
            onTranscript: { [weak self, service] conversationID, messages in
                guard !messages.isEmpty else { return }
                await service.applyDesktopTranscript(threadID: conversationID, messages: messages)
                await self?.publishCurrentSnapshot()
            },
            onRuntime: { [service] projection in await service.applyDesktopRuntime(projection) },
            onRuntimeUnavailable: { [service] conversationID in
                await service.desktopRuntimeUnavailable(threadID: conversationID)
            }
        )
    }

    private func publishCurrentSnapshot() async {
        let latest = await service.snapshot()
        snapshot = latest
        updateKeepAwakePolicy()
        transport?.broadcast(latest)
        remoteTransport?.broadcast(latest)
    }

    private func reportDesktopApprovalError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    private func setStatus(_ key: String, session: String? = nil) {
        // Keep canonical keys: storing a translated sentence freezes the
        // old language until a network state changes, and translating only
        // the format leaves its embedded session label in Chinese.
        statusKey = key
        statusSessionKey = session
    }

    /// Power monitoring never keeps the machine awake by itself. It only
    /// reevaluates a short-lived assertion owned by real local work.
    private func startPowerSourceMonitoring() {
        guard powerSourceMonitorTask == nil else { return }
        refreshExternalPowerState()
        powerSourceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.refreshExternalPowerState()
            }
        }
    }

    private func refreshExternalPowerState() {
        let connected = Self.readExternalPowerState()
        isConnectedToExternalPower = connected
        updateKeepAwakePolicy()
    }

    private func beginLocalOperation() {
        activeLocalOperationCount += 1
        updateKeepAwakePolicy()
    }

    private func endLocalOperation() {
        activeLocalOperationCount = max(0, activeLocalOperationCount - 1)
        updateKeepAwakePolicy()
    }

    /// The bridge is no longer a reason to keep the Mac awake. A sleep
    /// assertion exists only while plugged in *and* genuine local work is in
    /// progress. Waiting relay connections and idle monitoring consume no
    /// sleep assertion.
    private func updateKeepAwakePolicy() {
        let hasActiveWork = activeLocalOperationCount > 0
            || snapshot.activeTaskCount > 0
            || !snapshot.pendingApprovals.isEmpty
        let shouldKeepAwake = hasActiveWork && isConnectedToExternalPower

        if shouldKeepAwake {
            guard keepAwakeActivity == nil else { return }
            keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Keep Codex Control awake for active work while plugged in."
            )
        } else if let keepAwakeActivity {
            ProcessInfo.processInfo.endActivity(keepAwakeActivity)
            self.keepAwakeActivity = nil
        }
    }

    private static func readExternalPowerState() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(
                info,
                source as CFTypeRef
            )?.takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                return true
            }
        }
        // Fail safe: an unknown power source never grants a sleep assertion.
        return false
    }

    /// Register the currently signed app bundle with macOS after an update or
    /// an explicit TCC reset. The actual command path still reports a real
    /// denial, but this one-time system request prevents an old Debug-signing
    /// record from being mistaken for the running Agent Bridge.
    private func requestAccessibilityBindingIfNeeded() {
        guard isConnectedToExternalPower else { return }
        guard !AXIsProcessTrusted() else { return }
        guard !didRequestAccessibilityBinding else { return }
        didRequestAccessibilityBinding = true
        // Use the documented string value rather than referencing the legacy
        // imported C global directly; Swift 6 rightfully treats that mutable
        // global as non-concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
