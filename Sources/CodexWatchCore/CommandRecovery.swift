import Foundation

public struct RecoverableCommandDraft: Equatable, Sendable, Identifiable {
    public let messageID: String
    public let originalData: Data
    public let taskID: String?
    public var id: String { messageID }
    public var verifiedPrompt: String? {
        guard let envelope = CommandRecovery.original(originalData), envelope.messageID == messageID,
              let command = envelope.taskCommand, taskID == nil || taskID == command.taskID else { return nil }
        return command.prompt
    }
    public init(messageID: String, originalData: Data, taskID: String? = nil) {
        self.messageID = messageID; self.originalData = originalData; self.taskID = taskID
    }
}

public struct CommandReviewState: Equatable, Sendable {
    public let receipt: CommandReceipt?
    public let isPending: Bool
    public let isChecking: Bool
    public init(receipt: CommandReceipt?, isPending: Bool, isChecking: Bool) {
        self.receipt = receipt; self.isPending = isPending; self.isChecking = isChecking
    }
}

/// Shared by both clients. Stored stopped commands keep their original bytes;
/// a missing ACK is never converted into a fresh command with a new ID.
public enum CommandRecovery {
    public static let acknowledgementWindow: TimeInterval = 90
    public static let maximumStoredBytes = 48_000
    /// Old queues can contain more than one stopped action for a task. Review
    /// the actual submission order, not random UUID ordering. Invalid records
    /// remain visible first so they can be discarded rather than hidden.
    public static func earliest(_ drafts: [RecoverableCommandDraft]) -> RecoverableCommandDraft? {
        drafts.min { lhs, rhs in
            let left = original(lhs.originalData)?.sentAt ?? .distantPast
            let right = original(rhs.originalData)?.sentAt ?? .distantPast
            return left == right ? lhs.messageID < rhs.messageID : left < right
        }
    }
    public static func requiresLocalReview(senderDeviceID: String, localDeviceID: String, hasStoppedTask: Bool) -> Bool {
        // An iPhone's shadow copy must not veto a different explicit Watch
        // action after the Watch user discarded its own local draft.
        hasStoppedTask && senderDeviceID == localDeviceID
    }
    public static func original(_ data: Data) -> BridgeEnvelope? {
        guard !data.isEmpty, data.count <= maximumStoredBytes,
              let envelope = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data),
              envelope.version > 0, envelope.kind == .taskCommand, let command = envelope.taskCommand,
              !envelope.senderDeviceID.isEmpty, envelope.senderDeviceID.utf8.count <= 160,
              envelope.senderDeviceID == command.deviceID,
              !command.id.isEmpty, command.id.utf8.count <= 160, !command.taskID.isEmpty, command.taskID.utf8.count <= 160,
              !envelope.messageID.isEmpty, envelope.messageID.utf8.count <= 160,
              !command.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.targetsBrowserChat, command.executionTarget != .browser,
              envelope.commandStatusQuery == nil, envelope.commandStatusReceipt == nil,
              envelope.snapshot == nil, envelope.taskHistoryRequest == nil, envelope.taskHistoryPage == nil,
              envelope.decision == nil, envelope.usageReset == nil else { return nil }
        return envelope
    }
    public static func shouldPause(_ data: Data, now: Date = Date()) -> Bool {
        guard let envelope = original(data), RelayOutboxPolicy.isDeliverable(envelope, now: now) else { return true }
        return now.timeIntervalSince(envelope.sentAt) >= acknowledgementWindow
    }
    public static func errorReceipt(_ envelope: BridgeEnvelope, originalData: Data) -> CommandReceipt {
        guard let original = original(originalData), envelope.kind == .error,
              envelope.acknowledgedMessageID == original.messageID else { return .unconfirmed(unconfirmedText) }
        // Old Mac errors have no typed proof. Do not guess certainty by
        // comparing a localized error string in a different device language.
        guard let status = envelope.commandStatusReceipt, valid(status, for: original),
              status.state == .rejected else { return .unconfirmed(unconfirmedText) }
        return .failed(status.message ?? envelope.message ?? unconfirmedText)
    }
    public static var unconfirmedText: String { AppLocalizer.text("上次操作结果未确认，请先检查原任务。") }
    static func valid(_ receipt: CommandStatusReceipt, for original: BridgeEnvelope) -> Bool {
        guard receipt.originalMessageID == original.messageID,
              (receipt.message?.utf8.count ?? 0) <= 8_000 else { return false }
        if let owner = receipt.ownerThreadID {
            guard !owner.isEmpty, owner.utf8.count <= 160, !owner.hasPrefix("__codex_watch_"),
                  !owner.hasPrefix("chatgpt-chat:"), !owner.hasPrefix("chatgpt-web:"),
                  !owner.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  !owner.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            if original.taskCommand?.startsNewCodexChat == false, owner != original.taskCommand?.taskID { return false }
        }
        return true
    }
}

/// Volatile read-only requests are correlated to immutable stored originals.
/// After relaunch only the stopped original is restored, never an old query
/// or a taskCommand replay. An old Mac's ordinary snapshot is not an answer.
public struct CommandStatusQueries: Sendable {
    public struct Resolution: Equatable, Sendable {
        public let originalMessageID: String
        public let receipt: CommandReceipt
    }
    private struct Request: Sendable { let original: BridgeEnvelope; let deadline: Date }
    private var requests: [String: Request] = [:]
    public init() {}
    public var checkingIDs: Set<String> { Set(requests.values.map { $0.original.messageID }) }
    public mutating func trackForwarded(_ query: BridgeEnvelope, expectedOriginalData: Data, now: Date = Date()) -> Bool {
        guard requests.count < 64, requests[query.messageID] == nil,
              query.commandStatusQuery?.originalEnvelope == expectedOriginalData,
              let original = query.commandStatusQuery?.validatedOriginal(for: query, now: now),
              !checkingIDs.contains(original.messageID) else { return false }
        requests[query.messageID] = Request(original: original, deadline: now.addingTimeInterval(60))
        return true
    }
    public mutating func begin(originalData: Data, replyMailbox: String, now: Date = Date()) -> BridgeEnvelope? {
        guard originalData.count <= CommandStatusQuery.maximumOriginalBytes, requests.count < 64,
              let original = CommandRecovery.original(originalData), !checkingIDs.contains(original.messageID) else { return nil }
        let envelope = BridgeEnvelope(sentAt: now, kind: .requestSnapshot,
            senderDeviceID: original.senderDeviceID, replyMailbox: replyMailbox,
            commandStatusQuery: .init(originalEnvelope: originalData))
        guard envelope.commandStatusQuery?.validatedOriginal(for: envelope, now: now) != nil else { return nil }
        requests[envelope.messageID] = Request(original: original, deadline: now.addingTimeInterval(60))
        return envelope
    }
    public mutating func receive(_ envelope: BridgeEnvelope, now: Date = Date()) -> Resolution? {
        guard envelope.kind == .snapshot, envelope.snapshot == nil, envelope.taskHistoryPage == nil,
              let id = envelope.acknowledgedMessageID, let request = requests[id], now <= request.deadline,
              let status = envelope.commandStatusReceipt, CommandRecovery.valid(status, for: request.original) else { return nil }
        let receipt: CommandReceipt
        switch status.state {
        case .accepted: receipt = .accepted
        case .rejected: receipt = .failed(status.message ?? CommandRecovery.unconfirmedText)
        case .notFound: receipt = .unconfirmed(AppLocalizer.text("暂未找到回执，执行结果仍未确认。"))
        case .inFlight, .unconfirmed: receipt = .unconfirmed(CommandRecovery.unconfirmedText)
        case .unavailable: receipt = .unconfirmed(AppLocalizer.text("无法确认，请检查连接并查看原任务。"))
        }
        requests.removeValue(forKey: id)
        return Resolution(originalMessageID: request.original.messageID, receipt: receipt)
    }
    public mutating func fail(_ queryID: String) -> String? { requests.removeValue(forKey: queryID)?.original.messageID }
    public mutating func expire(_ queryID: String, now: Date = Date()) -> String? {
        guard let request = requests[queryID], now >= request.deadline else { return nil }
        return fail(queryID)
    }
    public mutating func cancel(originalMessageID: String) {
        requests = requests.filter { $0.value.original.messageID != originalMessageID }
    }
}
