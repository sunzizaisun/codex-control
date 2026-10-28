import Foundation

/// A read-only inquiry, never an alternative encoding of taskCommand. Keeping
/// the original bytes preserves the immutable transport identity and digest.
public struct CommandStatusQuery: Codable, Equatable, Sendable {
    public static let maximumOriginalBytes = 32_000
    public let originalEnvelope: Data
    public init(originalEnvelope: Data) { self.originalEnvelope = originalEnvelope }

    public func validatedOriginal(for query: BridgeEnvelope, now: Date = Date()) -> BridgeEnvelope? {
        guard query.version > 0, !query.messageID.isEmpty, query.messageID.utf8.count <= 160,
              query.kind == .requestSnapshot, query.taskHistoryRequest == nil,
              query.taskHistoryPage == nil, query.snapshot == nil, query.commandStatusReceipt == nil,
              query.taskCommand == nil, query.decision == nil, query.usageReset == nil,
              RelayOutboxPolicy.isDeliverable(query, now: now),
              !originalEnvelope.isEmpty, originalEnvelope.count <= Self.maximumOriginalBytes,
              let original = try? CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: originalEnvelope),
              original.version > 0, original.kind == .taskCommand, let command = original.taskCommand,
              original.senderDeviceID == query.senderDeviceID, command.deviceID == query.senderDeviceID,
              !original.messageID.isEmpty, original.messageID.utf8.count <= 160,
              original.commandStatusQuery == nil, original.commandStatusReceipt == nil,
              original.taskHistoryRequest == nil, original.taskHistoryPage == nil, original.snapshot == nil,
              original.decision == nil, original.usageReset == nil,
              !command.targetsBrowserChat, command.executionTarget != .browser else { return nil }
        return original
    }
}

/// `accepted` means the owner received input, not that generation completed.
/// Missing receipts cannot prove non-delivery and never authorize resending.
public struct CommandStatusReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case accepted, inFlight, unconfirmed, rejected, notFound, unavailable
    }
    public let originalMessageID: String
    public let state: State
    public let ownerThreadID: String?
    public let message: String?
    public init(originalMessageID: String, state: State, ownerThreadID: String? = nil, message: String? = nil) {
        self.originalMessageID = originalMessageID; self.state = state
        self.ownerThreadID = ownerThreadID; self.message = message
    }
}
