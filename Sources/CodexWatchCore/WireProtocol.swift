import Foundation

/// Sent only in MultipeerConnectivity's encrypted invitation context.  It is
/// deliberately separate from relay traffic: the short-lived code authorizes
/// the first nearby iPhone, while normal reconnection only needs device ID.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public let phoneDeviceID: String
    public let code: String?

    public init(phoneDeviceID: String, code: String?) {
        self.phoneDeviceID = phoneDeviceID
        self.code = code
    }
}

public enum BridgeMessageKind: String, Codable, Sendable {
    case hello
    case requestSnapshot
    case snapshot
    case approvalDecision
    case taskCommand
    case usageReset
    case acknowledgement
    case error
}

public struct BridgeEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public var version: Int
    public var messageID: String
    public var sentAt: Date
    public var kind: BridgeMessageKind
    public var senderDeviceID: String
    public var snapshot: DashboardSnapshot?
    public var decision: ApprovalDecision?
    public var taskCommand: TaskCommand?
    public var usageReset: UsageResetRequest?
    public var acknowledgedMessageID: String?
    public var message: String?
    /// The public-relay mailbox that should receive a response.  This is
    /// optional for compatibility with builds already installed on a paired
    /// device; old packets fall back to the legacy fan-out behaviour.
    public var replyMailbox: String?
    /// Optional version-3 extension. Old clients still decode the envelope;
    /// they cannot mistake a dashboard snapshot for a complete history page.
    public var taskHistoryRequest: TaskHistoryRequest?
    public var taskHistoryPage: TaskHistoryPage?
    /// Optional v3 read-only extensions. No new enum case, so an older
    /// paired build can ignore them without failing to decode the envelope.
    public var commandStatusQuery: CommandStatusQuery?
    public var commandStatusReceipt: CommandStatusReceipt?

    public var deliveryExpiresAt: Date {
        sentAt.addingTimeInterval(kind == .taskCommand ? 24 * 60 * 60 : 15 * 60)
    }

    public init(
        version: Int = BridgeEnvelope.currentVersion,
        messageID: String = UUID().uuidString,
        sentAt: Date = Date(),
        kind: BridgeMessageKind,
        senderDeviceID: String,
        snapshot: DashboardSnapshot? = nil,
        decision: ApprovalDecision? = nil,
        taskCommand: TaskCommand? = nil,
        usageReset: UsageResetRequest? = nil,
        acknowledgedMessageID: String? = nil,
        message: String? = nil,
        replyMailbox: String? = nil,
        taskHistoryRequest: TaskHistoryRequest? = nil,
        taskHistoryPage: TaskHistoryPage? = nil,
        commandStatusQuery: CommandStatusQuery? = nil,
        commandStatusReceipt: CommandStatusReceipt? = nil
    ) {
        self.version = version
        self.messageID = messageID
        self.sentAt = sentAt
        self.kind = kind
        self.senderDeviceID = senderDeviceID
        self.snapshot = snapshot
        self.decision = decision
        self.taskCommand = taskCommand
        self.usageReset = usageReset
        self.acknowledgedMessageID = acknowledgedMessageID
        self.message = message
        self.replyMailbox = replyMailbox
        self.taskHistoryRequest = taskHistoryRequest
        self.taskHistoryPage = taskHistoryPage
        self.commandStatusQuery = commandStatusQuery
        self.commandStatusReceipt = commandStatusReceipt
    }

    public static func snapshot(
        _ snapshot: DashboardSnapshot,
        sender: String,
        version: Int = BridgeEnvelope.currentVersion
    ) -> Self {
        BridgeEnvelope(version: version, kind: .snapshot, senderDeviceID: sender, snapshot: snapshot)
    }

    public static func decision(
        _ decision: ApprovalDecision,
        sender: String,
        replyMailbox: String? = nil
    ) -> Self {
        BridgeEnvelope(
            kind: .approvalDecision,
            senderDeviceID: sender,
            decision: decision,
            replyMailbox: replyMailbox
        )
    }

    public static func taskCommand(
        _ command: TaskCommand,
        sender: String,
        replyMailbox: String? = nil
    ) -> Self {
        BridgeEnvelope(
            kind: .taskCommand,
            senderDeviceID: sender,
            taskCommand: command,
            replyMailbox: replyMailbox
        )
    }

    public static func usageReset(
        _ request: UsageResetRequest,
        sender: String,
        replyMailbox: String? = nil
    ) -> Self {
        BridgeEnvelope(
            kind: .usageReset,
            senderDeviceID: sender,
            usageReset: request,
            replyMailbox: replyMailbox
        )
    }

    public static func acknowledgement(
        for messageID: String,
        sender: String,
        version: Int = BridgeEnvelope.currentVersion
    ) -> Self {
        BridgeEnvelope(
            version: version,
            kind: .acknowledgement,
            senderDeviceID: sender,
            acknowledgedMessageID: messageID
        )
    }
}

public enum CodexWatchCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            guard let milliseconds = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()) else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Invalid date"))
            }
            try container.encode(milliseconds)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let milliseconds = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        return decoder
    }
}
