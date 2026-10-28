import Foundation
import CodexWatchCore

public final class MacRemoteRelayTransport: @unchecked Sendable {
    public typealias SnapshotProvider = @Sendable () async -> DashboardSnapshot
    public typealias DecisionHandler = @Sendable (ApprovalDecision) async throws -> Void
    public typealias CommandHandler = @Sendable (TaskCommand) async throws -> Void
    public typealias CommandRecoveryHandler = @Sendable (TaskCommand) async -> Bool
    public typealias UsageResetHandler = @Sendable (UsageResetRequest) async throws -> String
    public typealias HistoryHandler = @Sendable (TaskHistoryRequest) async throws -> TaskHistoryPage
    /// Reports a verified relay round trip. Configuration alone is not proof
    /// that an internet relay is reachable (a VPN can accept DNS but reject
    /// the HTTPS connection), so the UI must use this instead of assuming it.
    public typealias ReachabilityHandler = @Sendable (_ isReachable: Bool, _ error: Error?) -> Void

    private let client: RemoteRelayClient
    private let deviceID: String
    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var snapshotProvider: SnapshotProvider?
    private var decisionHandler: DecisionHandler?
    private var commandHandler: CommandHandler?
    private var commandRecoveryHandler: CommandRecoveryHandler?
    private var usageResetHandler: UsageResetHandler?
    private var historyHandler: HistoryHandler?
    private var reachabilityHandler: ReachabilityHandler?
    private let actionDeduplicator: BridgeMessageDeduplicator
    // A dashboard refresh happens on a short timer.  Do not turn every refresh
    // into another URLSession task: on a reconnecting VPN that created a queue
    // of stale uploads, which made the relay appear permanently unavailable.
    private var pendingSnapshot: DashboardSnapshot?
    private var uploadTask: Task<Void, Never>?

    public init(
        configuration: RemoteRelayConfiguration,
        deviceID: String,
        actionDeduplicator: BridgeMessageDeduplicator = BridgeMessageDeduplicator()
    ) {
        self.client = RemoteRelayClient(configuration: configuration)
        self.deviceID = deviceID
        self.actionDeduplicator = actionDeduplicator
    }

    public func start(
        snapshotProvider: @escaping SnapshotProvider,
        decisionHandler: @escaping DecisionHandler,
        commandHandler: @escaping CommandHandler,
        usageResetHandler: @escaping UsageResetHandler,
        historyHandler: HistoryHandler? = nil,
        commandRecoveryHandler: CommandRecoveryHandler? = nil,
        reachabilityHandler: @escaping ReachabilityHandler = { _, _ in }
    ) {
        lock.lock()
        self.snapshotProvider = snapshotProvider
        self.decisionHandler = decisionHandler
        self.commandHandler = commandHandler
        self.usageResetHandler = usageResetHandler
        self.historyHandler = historyHandler
        self.commandRecoveryHandler = commandRecoveryHandler
        self.reachabilityHandler = reachabilityHandler
        let shouldStart = loopTask == nil
        lock.unlock()
        guard shouldStart else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
        lock.lock()
        loopTask = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let task = loopTask
        let pendingUpload = uploadTask
        loopTask = nil
        uploadTask = nil
        pendingSnapshot = nil
        snapshotProvider = nil
        decisionHandler = nil
        commandHandler = nil
        usageResetHandler = nil
        historyHandler = nil
        commandRecoveryHandler = nil
        reachabilityHandler = nil
        lock.unlock()
        task?.cancel()
        pendingUpload?.cancel()
    }

    public func broadcast(_ snapshot: DashboardSnapshot) {
        lock.lock()
        pendingSnapshot = compactSnapshot(snapshot)
        guard uploadTask == nil else {
            lock.unlock()
            return
        }
        uploadTask = Task { [weak self] in
            await self?.drainSnapshotUploads()
        }
        lock.unlock()
    }

    private func runLoop() async {
        var retrySeconds = 2
        while !Task.isCancelled {
            do {
                var snapshot = DashboardSnapshot.empty
                if let provider = lockedSnapshotProvider() {
                    snapshot = await provider()
                    // Status uploads are coalesced, so a weak/reconnecting VPN
                    // never accumulates a backlog that blocks incoming actions.
                    broadcast(snapshot)
                }
                let messages = try await client.messages(for: .mac)
                reportReachability(true, error: nil)
                for envelope in messages {
                    await process(envelope)
                    try? await client.acknowledge(envelope.messageID, in: .mac)
                }
                // A command or approval can change the dashboard immediately.
                // Publish that change in the same pass so the originating
                // phone or watch does not have to wait for the next heartbeat.
                if !messages.isEmpty, let provider = lockedSnapshotProvider() {
                    snapshot = await provider()
                    broadcast(snapshot)
                }
                retrySeconds = 2
                // Wait for Cloudflare to signal a persisted mailbox change.
                // The Durable Object hibernates while idle, and this Mac no
                // longer wakes its network stack every five seconds. A
                // bounded recovery timeout handles VPNs that silently discard
                // long-lived connections without losing queued actions.
                try await client.waitForMailboxActivity(
                    .mac,
                    timeout: remoteRecoveryInterval(for: snapshot)
                )
            } catch {
                reportReachability(false, error: error)
                try? await Task.sleep(for: .seconds(retrySeconds))
                retrySeconds = min(retrySeconds * 2, 30)
            }
        }
    }

    private func reportReachability(_ isReachable: Bool, error: Error?) {
        lock.lock()
        let handler = reachabilityHandler
        lock.unlock()
        handler?(isReachable, error)
    }

    private func compactSnapshot(_ snapshot: DashboardSnapshot) -> DashboardSnapshot {
        // Keep the encrypted packet comfortably below the size at which some
        // mobile VPN proxies reset a Cloudflare request. Full history is read
        // on demand. Preserve the full task list and every pending approval.
        var compact = snapshot.compactForWatch(
            maximumTasks: snapshot.tasks.count,
            messagesPerTask: 4,
            maximumTextLength: 600,
            maximumApprovals: snapshot.pendingApprovals.count
        )
        compact.pendingApprovals = snapshot.pendingApprovals.filter { !$0.isExpired }
        return compact
    }

    private func drainSnapshotUploads() async {
        while !Task.isCancelled {
            let snapshot = dequeuePendingSnapshot()
            guard let snapshot else { return }
            do {
                try await client.uploadSnapshot(snapshot, sender: deviceID)
            } catch {
                // Incoming mailbox polling remains independent.  Reporting the
                // failure makes the UI truthful without stalling local updates.
                reportReachability(false, error: error)
            }
        }
    }

    private func dequeuePendingSnapshot() -> DashboardSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        if snapshot == nil {
            uploadTask = nil
        }
        return snapshot
    }

    private func remoteRecoveryInterval(for snapshot: DashboardSnapshot) -> Double {
        snapshot.activeTaskCount > 0 || !snapshot.pendingApprovals.isEmpty ? 20 : RelayTimingPolicy.idleInterval
    }

    private func process(_ envelope: BridgeEnvelope) async {
        guard envelope.version >= 1 else { return }
        let replyVersion = min(envelope.version, BridgeEnvelope.currentVersion)
        if envelope.commandStatusQuery != nil {
            guard let receipt = await MacReliableActionGate.inspectCheckingOwner(envelope, deduplicator: actionDeduplicator,
                recoveryHandler: lockedCommandRecoveryHandler()) else {
                await sendFailure(for: envelope, version: replyVersion, message: AppLocalizer.text("远程数据校验失败"))
                return
            }
            let response = BridgeEnvelope(version: replyVersion, kind: .snapshot, senderDeviceID: deviceID,
                acknowledgedMessageID: envelope.messageID, commandStatusReceipt: receipt)
            for destination in replyDestinations(for: envelope) { try? await client.enqueue(response, to: destination) }
            return
        }
        var startedAction = false
        switch envelope.kind {
        case .approvalDecision, .taskCommand, .usageReset:
            switch await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: actionDeduplicator,
                recoveryHandler: lockedCommandRecoveryHandler()) {
            case .completed(let outcome):
                await sendAcknowledgement(for: envelope, version: replyVersion, outcome: outcome)
                return
            case .inFlight:
                return
            case .failed(let message):
                await sendFailure(for: envelope, version: replyVersion, message: message)
                return
            case .started:
                startedAction = true
            }
        default:
            break
        }
        // A malformed packet or a stopped handler must not leave a permanent
        // in-flight entry. Completed outcomes remain cached by cancel().
        defer { if startedAction { actionDeduplicator.cancel(envelope.messageID) } }
        do {
            if let request = envelope.taskHistoryRequest, let handler = lockedHistoryHandler() {
                let page = try await handler(request)
                let response = BridgeEnvelope(version: replyVersion, kind: .snapshot, senderDeviceID: deviceID,
                    acknowledgedMessageID: envelope.messageID, taskHistoryPage: page)
                for destination in replyDestinations(for: envelope) {
                    try await client.enqueue(response, to: destination)
                }
                return
            }
            let outcome: String?
            switch envelope.kind {
            case .approvalDecision:
                guard let decision = envelope.decision,
                      let handler = lockedDecisionHandler() else { return }
                try await handler(decision)
                outcome = nil
            case .taskCommand:
                guard let command = envelope.taskCommand,
                      let handler = lockedCommandHandler() else { return }
                try await handler(command)
                outcome = nil
            case .usageReset:
                guard let request = envelope.usageReset,
                      let handler = lockedUsageResetHandler() else { return }
                outcome = try await handler(request)
            default:
                return
            }
            guard actionDeduplicator.finish(envelope.messageID, outcome: outcome) else {
                await sendFailure(for: envelope, version: replyVersion,
                    message: AppLocalizer.text("上次操作结果未确认，请先检查原任务。"))
                return
            }
            await sendAcknowledgement(for: envelope, version: replyVersion, outcome: outcome)
        } catch {
            let message = startedAction
                ? MacActionFailure.record(error, messageID: envelope.messageID, in: actionDeduplicator)
                : error.localizedDescription
            if startedAction, envelope.kind == .taskCommand,
               case .completed = await MacReliableActionGate.beginCheckingOwner(envelope,
                   deduplicator: actionDeduplicator, recoveryHandler: lockedCommandRecoveryHandler()) {
                await sendAcknowledgement(for: envelope, version: replyVersion, outcome: nil)
                return
            }
            await sendFailure(for: envelope, version: replyVersion, message: message)
        }
    }

    private func sendFailure(for envelope: BridgeEnvelope, version: Int, message: String) async {
        let response = MacReliableActionGate.errorEnvelope(for: envelope, sender: deviceID, version: version,
            message: message, deduplicator: actionDeduplicator)
        for destination in replyDestinations(for: envelope) {
            try? await client.enqueue(response, to: destination)
        }
    }

    private func sendAcknowledgement(
        for envelope: BridgeEnvelope,
        version: Int,
        outcome: String?
    ) async {
        let ack = BridgeEnvelope(
            version: version,
            kind: .acknowledgement,
            senderDeviceID: deviceID,
            acknowledgedMessageID: envelope.messageID,
            message: outcome
        )
        for destination in replyDestinations(for: envelope) {
            try? await client.enqueue(ack, to: destination)
        }
    }

    private func replyDestinations(for envelope: BridgeEnvelope) -> [RemoteRelayMailbox] {
        if let rawValue = envelope.replyMailbox,
           let destination = RemoteRelayMailbox(rawValue: rawValue) {
            // A Watch action may arrive over WatchConnectivity while the
            // Watch's own internet route is temporarily unavailable (for
            // example, through a carrier or VPN hand-off). Mirror that reply
            // to the paired phone too: PhoneRelay forwards it over Apple's
            // reliable WatchConnectivity channel. Phone-originated actions
            // still stay private to the phone.
            if destination == .watch {
                return [.watch, .phone]
            }
            return [destination]
        }
        // Legacy builds predate reply targeting. Preserve their behavior until
        // they are replaced, then avoid sending either device someone else's
        // acknowledgement.
        return [.phone, .watch]
    }

    private func lockedSnapshotProvider() -> SnapshotProvider? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotProvider
    }

    private func lockedDecisionHandler() -> DecisionHandler? {
        lock.lock()
        defer { lock.unlock() }
        return decisionHandler
    }

    private func lockedCommandHandler() -> CommandHandler? {
        lock.lock()
        defer { lock.unlock() }
        return commandHandler
    }

    private func lockedCommandRecoveryHandler() -> CommandRecoveryHandler? {
        lock.lock()
        defer { lock.unlock() }
        return commandRecoveryHandler
    }

    private func lockedUsageResetHandler() -> UsageResetHandler? {
        lock.lock()
        defer { lock.unlock() }
        return usageResetHandler
    }

    private func lockedHistoryHandler() -> HistoryHandler? {
        lock.lock()
        defer { lock.unlock() }
        return historyHandler
    }
}
