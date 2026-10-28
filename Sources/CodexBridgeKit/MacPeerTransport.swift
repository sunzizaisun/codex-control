@preconcurrency import Foundation
@preconcurrency import MultipeerConnectivity
import CodexWatchCore
import CryptoKit

/// Both Mac ingress routes enforce the deadline at the execution boundary,
/// including requests that waited in WatchConnectivity after leaving an outbox.
/// Cached outcomes take precedence: an expired retry may ask for its original
/// receipt, but must never start a new action.
enum MacReliableActionGate {
    typealias CommandRecoveryHandler = @Sendable (TaskCommand) async -> Bool

    private static func fingerprint(_ envelope: BridgeEnvelope) -> String? {
        (try? CodexWatchCoding.makeEncoder().encode(envelope)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func errorEnvelope(for original: BridgeEnvelope, sender: String, version: Int,
                              message: String, deduplicator: BridgeMessageDeduplicator) -> BridgeEnvelope {
        let status: CommandStatusReceipt?
        if original.kind == .taskCommand, let fingerprint = fingerprint(original) {
            status = deduplicator.inspect(original.messageID, fingerprint: fingerprint)
        } else { status = nil }
        return BridgeEnvelope(version: version, kind: .error, senderDeviceID: sender,
            acknowledgedMessageID: original.messageID, message: message, commandStatusReceipt: status)
    }

    static func begin(
        _ envelope: BridgeEnvelope,
        deduplicator: BridgeMessageDeduplicator,
        now: Date = Date()
    ) -> BridgeMessageDeduplicator.BeginResult {
        guard envelope.commandStatusQuery == nil, envelope.commandStatusReceipt == nil,
              envelope.taskHistoryRequest == nil, envelope.taskHistoryPage == nil, envelope.snapshot == nil else {
            return .failed(message: AppLocalizer.text("远程数据校验失败"))
        }
        guard let fingerprint = fingerprint(envelope) else {
            return .failed(message: AppLocalizer.text("远程数据校验失败"))
        }
        let result = deduplicator.begin(envelope.messageID, fingerprint: fingerprint,
            command: envelope.kind == .taskCommand ? envelope.taskCommand : nil)
        guard result == .started else { return result }
        guard RelayOutboxPolicy.isDeliverable(envelope, now: now) else {
            let message = AppLocalizer.text("发送已过期，执行结果未确认。请查看原任务后再试。")
            deduplicator.fail(envelope.messageID, message: message)
            return .failed(message: message)
        }
        return .started
    }

    static func beginCheckingOwner(
        _ envelope: BridgeEnvelope, deduplicator: BridgeMessageDeduplicator,
        recoveryHandler: CommandRecoveryHandler?, now: Date = Date()
    ) async -> BridgeMessageDeduplicator.BeginResult {
        let result = begin(envelope, deduplicator: deduplicator, now: now)
        guard case .failed = result else { return result }
        return await recoverOwner(envelope, deduplicator: deduplicator, recoveryHandler: recoveryHandler, now: now)
            ? .completed(outcome: nil) : result
    }

    private static func recoverOwner(_ envelope: BridgeEnvelope, deduplicator: BridgeMessageDeduplicator,
                                     recoveryHandler: CommandRecoveryHandler?, now: Date) async -> Bool {
        guard envelope.kind == .taskCommand,
              let command = envelope.taskCommand,
              !command.targetsBrowserChat, command.executionTarget != .browser,
              let recoveryHandler, let fingerprint = fingerprint(envelope),
              let claim = deduplicator.claimRecovery(envelope.messageID, fingerprint: fingerprint,
                  command: command, now: now) else { return false }
        let ownerID = command.startsNewCodexChat ? claim.ownerThreadID : command.taskID
        guard let ownerID else { _ = deduplicator.finishRecovery(claim, accepted: false); return false }
        let lookup = TaskCommand(id: command.id, taskID: ownerID, prompt: command.prompt,
            activeTurnID: command.activeTurnID, sentAt: command.sentAt, deviceID: command.deviceID,
            executionTarget: command.executionTarget, options: command.options)
        let accepted = await recoveryHandler(lookup)
        return deduplicator.finishRecovery(claim, accepted: accepted)
    }

    /// Sending a receipt is a separate transport operation. Its failure must
    /// not turn an already executed action into an execution-error response.
    @discardableResult
    static func finish(
        _ envelope: BridgeEnvelope,
        deduplicator: BridgeMessageDeduplicator,
        outcome: String? = nil,
        acknowledge: () throws -> Void
    ) -> Bool {
        guard deduplicator.finish(envelope.messageID, outcome: outcome) else { return false }
        try? acknowledge()
        return true
    }

    static func inspect(_ query: BridgeEnvelope, deduplicator: BridgeMessageDeduplicator,
                        now: Date = Date()) -> CommandStatusReceipt? {
        guard let original = query.commandStatusQuery?.validatedOriginal(for: query, now: now),
              let fingerprint = fingerprint(original) else { return nil }
        return deduplicator.inspect(original.messageID, fingerprint: fingerprint)
    }

    /// Unlike resubmitting taskCommand, this can never call begin or execute
    /// absent work. Only an existing unknown receipt may ask its bound owner
    /// for exact input proof using the same bounded read-only recovery path.
    static func inspectCheckingOwner(_ query: BridgeEnvelope, deduplicator: BridgeMessageDeduplicator,
                                     recoveryHandler: CommandRecoveryHandler?, now: Date = Date()) async -> CommandStatusReceipt? {
        guard let current = inspect(query, deduplicator: deduplicator, now: now) else { return nil }
        guard current.state == .unconfirmed,
              let original = query.commandStatusQuery?.validatedOriginal(for: query, now: now) else { return current }
        _ = await recoverOwner(original, deduplicator: deduplicator, recoveryHandler: recoveryHandler, now: now)
        return inspect(query, deduplicator: deduplicator, now: now)
    }
}

public final class MacPeerTransport: NSObject, @unchecked Sendable {
    public typealias SnapshotProvider = @Sendable () async -> DashboardSnapshot
    public typealias DecisionHandler = @Sendable (ApprovalDecision) async throws -> Void
    public typealias CommandHandler = @Sendable (TaskCommand) async throws -> Void
    public typealias CommandRecoveryHandler = @Sendable (TaskCommand) async -> Bool
    public typealias UsageResetHandler = @Sendable (UsageResetRequest) async throws -> String
    public typealias HistoryHandler = @Sendable (TaskHistoryRequest) async throws -> TaskHistoryPage

    public static let serviceType = "codexrelay"

    public let deviceID: String

    private static let deviceIDKey = "CodexWatch.mac.deviceID"
    private static let trustedPhoneIDKey = "CodexWatch.mac.trustedPhoneID"

    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let lock = NSLock()
    private var snapshotProvider: SnapshotProvider?
    private var decisionHandler: DecisionHandler?
    private var commandHandler: CommandHandler?
    private var commandRecoveryHandler: CommandRecoveryHandler?
    private var usageResetHandler: UsageResetHandler?
    private var historyHandler: HistoryHandler?
    private let actionDeduplicator: BridgeMessageDeduplicator
    private var trustedPhoneID: String?
    private var pairingCode: String?
    private var pairingCodeExpiry: Date?

    public init(
        displayName: String? = nil,
        actionDeduplicator: BridgeMessageDeduplicator = BridgeMessageDeduplicator()
    ) {
        let storedID = UserDefaults.standard.string(forKey: Self.deviceIDKey)
        let resolvedID = storedID ?? UUID().uuidString
        if storedID == nil {
            UserDefaults.standard.set(resolvedID, forKey: Self.deviceIDKey)
        }
        let suffix = String(resolvedID.prefix(4))
        let baseName = displayName ?? Host.current().localizedName ?? "Mac"
        let peerID = MCPeerID(displayName: String("\(baseName)-\(suffix)".prefix(63)))
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["version": String(BridgeEnvelope.currentVersion), "role": "mac"],
            serviceType: Self.serviceType
        )
        self.actionDeduplicator = actionDeduplicator
        self.deviceID = resolvedID
        self.trustedPhoneID = UserDefaults.standard.string(forKey: Self.trustedPhoneIDKey)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    public var connectedPeerCount: Int { session.connectedPeers.count }

    public var peerDisplayName: String { session.myPeerID.displayName }

    public var hasTrustedPhone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return trustedPhoneID != nil
    }

    /// A nearby iPhone must present this short-lived code before it becomes
    /// trusted. Existing trusted iPhones continue to reconnect without it.
    public func setPairingCode(_ code: String, expiresAt: Date) {
        lock.lock()
        pairingCode = code
        pairingCodeExpiry = expiresAt
        lock.unlock()
    }

    /// Removes only the remembered nearby-phone identity. The next iPhone
    /// invitation must present a fresh short-lived pairing code.
    public func forgetTrustedPhone() {
        lock.lock()
        trustedPhoneID = nil
        pairingCode = nil
        pairingCodeExpiry = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.trustedPhoneIDKey)
        // Revocation applies to an already connected session too. Forgetting
        // only its saved ID would leave the old phone able to send actions
        // until it happened to disconnect on its own.
        session.disconnect()
    }

    public func start(
        snapshotProvider: @escaping SnapshotProvider,
        decisionHandler: @escaping DecisionHandler,
        commandHandler: @escaping CommandHandler,
        usageResetHandler: @escaping UsageResetHandler,
        historyHandler: HistoryHandler? = nil,
        commandRecoveryHandler: CommandRecoveryHandler? = nil
    ) {
        lock.lock()
        self.snapshotProvider = snapshotProvider
        self.decisionHandler = decisionHandler
        self.commandHandler = commandHandler
        self.usageResetHandler = usageResetHandler
        self.historyHandler = historyHandler
        self.commandRecoveryHandler = commandRecoveryHandler
        lock.unlock()
        advertiser.startAdvertisingPeer()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        lock.lock()
        snapshotProvider = nil
        decisionHandler = nil
        commandHandler = nil
        usageResetHandler = nil
        historyHandler = nil
        commandRecoveryHandler = nil
        lock.unlock()
    }

    public func broadcast(_ snapshot: DashboardSnapshot) {
        try? send(.snapshot(snapshot, sender: deviceID), to: session.connectedPeers)
    }

    private func handle(_ envelope: BridgeEnvelope, from peer: MCPeerID) async {
        // A queued callback can outlive disconnect/reset pairing.
        guard session.connectedPeers.contains(peer) else { return }
        guard envelope.version >= 1 else {
            try? send(
                BridgeEnvelope(
                    version: BridgeEnvelope.currentVersion,
                    kind: .error,
                    senderDeviceID: deviceID,
                    message: "Unsupported protocol version"
                ),
                to: [peer]
            )
            return
        }
        // A queued request can outlive an app update in either direction.
        // Codable ignores unknown optional fields, so accept any decodable
        // positive version and reply at the newest version this bridge knows.
        let replyVersion = min(envelope.version, BridgeEnvelope.currentVersion)

        switch envelope.kind {
        case .hello, .requestSnapshot:
            if envelope.commandStatusQuery != nil {
                guard let receipt = await MacReliableActionGate.inspectCheckingOwner(envelope, deduplicator: actionDeduplicator,
                    recoveryHandler: lockedCommandRecoveryHandler()) else {
                    try? send(BridgeEnvelope(version: replyVersion, kind: .error, senderDeviceID: deviceID,
                        acknowledgedMessageID: envelope.messageID, message: AppLocalizer.text("远程数据校验失败")), to: [peer])
                    return
                }
                try? send(BridgeEnvelope(version: replyVersion, kind: .snapshot, senderDeviceID: deviceID,
                    acknowledgedMessageID: envelope.messageID, commandStatusReceipt: receipt), to: [peer])
                return
            }
            if let request = envelope.taskHistoryRequest, let handler = lockedHistoryHandler() {
                do {
                    let page = try await handler(request)
                    try send(BridgeEnvelope(version: replyVersion, kind: .snapshot, senderDeviceID: deviceID,
                        acknowledgedMessageID: envelope.messageID, taskHistoryPage: page), to: [peer])
                } catch {
                    try? send(BridgeEnvelope(version: replyVersion, kind: .error, senderDeviceID: deviceID,
                        acknowledgedMessageID: envelope.messageID, message: error.localizedDescription), to: [peer])
                }
                return
            }
            if let provider = lockedSnapshotProvider() {
                let snapshot = await provider()
                try? send(.snapshot(snapshot, sender: deviceID, version: replyVersion), to: [peer])
            }
        case .approvalDecision:
            guard let decision = envelope.decision,
                  let handler = lockedDecisionHandler() else { return }
            guard await beginActionIfNeeded(envelope, peer: peer, version: replyVersion) else { return }
            do {
                try await handler(decision)
                MacReliableActionGate.finish(envelope, deduplicator: actionDeduplicator) {
                    try send(.acknowledgement(for: envelope.messageID, sender: deviceID, version: replyVersion), to: [peer])
                }
                if let provider = lockedSnapshotProvider() {
                    let snapshot = await provider()
                    try? send(.snapshot(snapshot, sender: deviceID, version: replyVersion), to: [peer])
                }
            } catch {
                let message = MacActionFailure.record(error, messageID: envelope.messageID, in: actionDeduplicator)
                try? send(
                    BridgeEnvelope(
                        version: replyVersion,
                        kind: .error,
                        senderDeviceID: deviceID,
                        acknowledgedMessageID: envelope.messageID,
                        message: message
                    ),
                    to: [peer]
                )
            }
        case .taskCommand:
            guard let command = envelope.taskCommand,
                  let handler = lockedCommandHandler() else { return }
            guard await beginActionIfNeeded(envelope, peer: peer, version: replyVersion) else { return }
            do {
                try await handler(command)
                MacReliableActionGate.finish(envelope, deduplicator: actionDeduplicator) {
                    try send(.acknowledgement(for: envelope.messageID, sender: deviceID, version: replyVersion), to: [peer])
                }
                if let provider = lockedSnapshotProvider() {
                    try? send(.snapshot(await provider(), sender: deviceID, version: replyVersion), to: [peer])
                }
            } catch {
                let message = MacActionFailure.record(error, messageID: envelope.messageID, in: actionDeduplicator)
                if case .completed = await MacReliableActionGate.beginCheckingOwner(envelope,
                    deduplicator: actionDeduplicator, recoveryHandler: lockedCommandRecoveryHandler()) {
                    try? send(.acknowledgement(for: envelope.messageID, sender: deviceID, version: replyVersion), to: [peer])
                    return
                }
                try? send(MacReliableActionGate.errorEnvelope(for: envelope, sender: deviceID, version: replyVersion,
                    message: message, deduplicator: actionDeduplicator), to: [peer])
            }
        case .usageReset:
            guard let request = envelope.usageReset,
                  let handler = lockedUsageResetHandler() else { return }
            guard await beginActionIfNeeded(envelope, peer: peer, version: replyVersion) else { return }
            do {
                let outcome = try await handler(request)
                MacReliableActionGate.finish(envelope, deduplicator: actionDeduplicator, outcome: outcome) {
                    try send(
                        BridgeEnvelope(
                            version: replyVersion,
                            kind: .acknowledgement,
                            senderDeviceID: deviceID,
                            acknowledgedMessageID: envelope.messageID,
                            message: outcome
                        ),
                        to: [peer]
                    )
                }
                if let provider = lockedSnapshotProvider() {
                    try? send(.snapshot(await provider(), sender: deviceID, version: replyVersion), to: [peer])
                }
            } catch {
                let message = MacActionFailure.record(error, messageID: envelope.messageID, in: actionDeduplicator)
                try? send(
                    BridgeEnvelope(
                        version: replyVersion,
                        kind: .error,
                        senderDeviceID: deviceID,
                        acknowledgedMessageID: envelope.messageID,
                        message: message
                    ),
                    to: [peer]
                )
            }
        case .snapshot, .acknowledgement, .error:
            break
        }
    }

    private func beginActionIfNeeded(
        _ envelope: BridgeEnvelope,
        peer: MCPeerID,
        version: Int
    ) async -> Bool {
        switch await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: actionDeduplicator,
            recoveryHandler: lockedCommandRecoveryHandler()) {
        case .started:
            return true
        case .inFlight:
            return false
        case .failed(let message):
            try? send(MacReliableActionGate.errorEnvelope(for: envelope, sender: deviceID, version: version,
                message: message, deduplicator: actionDeduplicator), to: [peer])
            return false
        case .completed(let outcome):
            try? send(
                BridgeEnvelope(
                    version: version,
                    kind: .acknowledgement,
                    senderDeviceID: deviceID,
                    acknowledgedMessageID: envelope.messageID,
                    message: outcome
                ),
                to: [peer]
            )
            return false
        }
    }

    private func send(_ envelope: BridgeEnvelope, to peers: [MCPeerID]) throws {
        guard !peers.isEmpty else { return }
        let data = try CodexWatchCoding.makeEncoder().encode(envelope)
        try session.send(data, toPeers: peers, with: .reliable)
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

extension MacPeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard let context,
              let invitation = try? CodexWatchCoding.makeDecoder().decode(
                PairingInvitation.self,
                from: context
              ),
              !invitation.phoneDeviceID.isEmpty else {
            invitationHandler(false, nil)
            return
        }

        lock.lock()
        defer { lock.unlock() }
        if let trustedPhoneID, trustedPhoneID != invitation.phoneDeviceID {
            invitationHandler(false, nil)
            return
        }
        if trustedPhoneID == nil {
            guard let pairingCode,
                  let pairingCodeExpiry,
                  pairingCodeExpiry > Date(),
                  invitation.code == pairingCode else {
                invitationHandler(false, nil)
                return
            }
            trustedPhoneID = invitation.phoneDeviceID
            UserDefaults.standard.set(invitation.phoneDeviceID, forKey: Self.trustedPhoneIDKey)
            // A code is single-use. A newly generated one is required if the
            // user later removes this trusted phone.
            self.pairingCode = nil
            self.pairingCodeExpiry = nil
        }
        invitationHandler(true, session)
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {}
}

extension MacPeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        // The iPhone immediately sends hello/requestSnapshot once connected.
        // Waiting for that first message lets us answer at its protocol version.
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data) else {
            return
        }
        Task { await handle(envelope, from: peerID) }
    }

    public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    public func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}
