import Foundation

/// The MCP event inbox has its own wire format; never route it through Slack.
public actor DotsEventsClient: DotsTransport {
    public nonisolated let channel = DotsChannel.mcpEvents
    private let http: DotsHTTPClient
    public init(configuration: DotsConfiguration) { http = DotsHTTPClient(configuration: configuration) }
    init(configuration: DotsConfiguration, session: URLSession) { http = DotsHTTPClient(configuration: configuration, session: session) }
    private struct Status: Decodable, Sendable {
        let subscribed: Bool
        let expiresAt: Double?
        let transport: String
    }
    struct Record: Decodable, Sendable {
        let id: String
        let thread: String
        let text: String
        let createdAt: Double
        let state: String
        let reply: String?
        let repliedAt: Double?
        struct Timing: Decodable, Sendable { let readAt: Double? }
        let timing: Timing?
        func validate() throws {
            guard UUID(uuidString: id) != nil, UUID(uuidString: thread) != nil,
                  DotsEventsClient.validText(text, maximum: 4000),
                  DotsEventsClient.validTimestamp(createdAt),
                  DotsEventsClient.messageStates.contains(state),
                  timing?.readAt.map(DotsEventsClient.validTimestamp) != false else { throw DotsError("invalid_response") }
            if state == "replied" {
                guard let reply, let repliedAt, DotsEventsClient.validText(reply, maximum: 16000),
                      DotsEventsClient.validTimestamp(repliedAt) else { throw DotsError("invalid_response") }
            } else if reply != nil || repliedAt != nil { throw DotsError("invalid_response") }
        }
        var receipt: DotReceipt {
            DotReceipt(id: id, state: state, thread: thread, timestamp: id + ".user", error: nil,
                       text: text, createdAt: createdAt, reply: reply, repliedAt: repliedAt, readAt: timing?.readAt)
        }
        var messages: [DotMessage] {
            var result = [DotMessage(id: id + ".user", role: "user", text: text, sentAt: createdAt, deliveryState: state, readAt: timing?.readAt)]
            if let reply, let repliedAt {
                result.append(DotMessage(id: id + ".reply", role: "assistant", text: reply, sentAt: repliedAt))
            }
            return result
        }
    }
    private struct Page: Decodable, Sendable {
        let messages: [Record]
        let nextCursor: String?
        let capturedAt: Double
    }
    public func connection() async throws -> DotConnection {
        let status: Status = try await http.request("v2/status")
        guard status.transport == "mcp-events" else { throw DotsError("invalid_response") }
        return DotConnection(connected: status.subscribed && (status.expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000,
                             dotName: "dot", verifiedAt: Date().timeIntervalSince1970 * 1000, expiresAt: status.expiresAt)
    }
    public func threads(cursor: String?) async throws -> DotThreadPage {
        try await http.request("v2/threads", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }
    public func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage {
        try validID(thread)
        let page: Page = try await http.request("v2/threads/\(thread)/messages",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        try Self.validateRecordPage(page)
        guard page.messages.allSatisfy({ $0.thread == thread.lowercased() }) else { throw DotsError("invalid_response") }
        return DotMessagePage(messages: DotMessage.merging([], page.messages.flatMap(\.messages)), nextCursor: page.nextCursor, capturedAt: page.capturedAt)
    }
    public func send(_ command: DotCommand) async throws -> DotReceipt {
        let record: Record = try await http.request("v2/messages", body: JSONEncoder().encode(command))
        // A write may already have committed even when its acknowledgement is
        // malformed. Keep its original lookup ID instead of claiming success.
        do { try record.validate() } catch { throw DotsError("delivery_uncertain") }
        guard record.id == command.id, record.text.utf8.elementsEqual(command.text.utf8), record.createdAt == Double(command.createdAt),
              (command.shared == true ? UUID(uuidString: record.thread) != nil : record.thread == (command.thread ?? command.id)) else { throw DotsError("delivery_uncertain") }
        return record.receipt
    }
    public func timeline(cursor: String?) async throws -> DotMessagePage {
        do {
            let page: DotMessagePage = try await http.request("v3/messages", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            try Self.validateTimeline(page)
            return page
        } catch let error as DotsError where error.code == "not_found" {
            // Compatibility only, never hide authentication or network errors.
        }
        let page: Page = try await http.request("v2/messages", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        try Self.validateRecordPage(page)
        guard page.messages.allSatisfy({ UUID(uuidString: $0.thread) != nil && UUID(uuidString: $0.id) != nil }) else { throw DotsError("invalid_response") }
        return DotMessagePage(messages: DotMessage.merging([], page.messages.flatMap(\.messages)), nextCursor: page.nextCursor, capturedAt: page.capturedAt)
    }
    public func receipt(_ id: String) async throws -> DotReceipt {
        try validID(id)
        do {
            let record: Record = try await http.request("v2/receipts/\(id)")
            try record.validate()
            guard record.id == id.lowercased() else { throw DotsError("invalid_response") }
            return record.receipt
        } catch let error as DotsError where error.code == "message_not_found" { throw DotsError("receipt_not_found") }
    }
    public func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt {
        do {
            let result: DotHistorySyncReceipt = try await http.request("v3/sync", body: JSONEncoder().encode(request))
            try Self.validateHistoryReceipt(result)
            return result
        } catch let error as DotsError where error.code == "not_found" { throw DotsError("history_sync_unavailable") }
    }
    public func historySyncStatus(_ id: String) async throws -> DotHistorySyncReceipt {
        try validID(id)
        let result: DotHistorySyncReceipt = try await http.request("v3/sync/\(id)")
        guard result.id == id else { throw DotsError("invalid_response") }
        try Self.validateHistoryReceipt(result)
        return result
    }
    static func validateHistoryReceipt(_ result: DotHistorySyncReceipt) throws {
        let messages = result.messages ?? [], hidden = result.hiddenMessageIDs ?? []
        func officialID(_ value: String) -> Bool {
            value.range(of: "^official\\.[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
        }
        guard UUID(uuidString: result.id) != nil, validTimestamp(result.expiresAt),
              result.recoverableUntil.map(validTimestamp) != false,
              ["pending", "delayed", "completed", "expired", "delivery_failed"].contains(result.state),
              messages.count + hidden.count <= 30,
              result.state == "completed" || (messages.isEmpty && hidden.isEmpty),
              messages.allSatisfy({ officialID($0.id) && ["user", "assistant"].contains($0.role)
                  && $0.sentAt.isFinite && $0.sentAt > 0 && !$0.text.isEmpty && $0.text.unicodeScalars.count <= 16000
                  && !$0.controlsInSlack && $0.deliveryState == nil && $0.readAt == nil }),
              hidden.allSatisfy(officialID), Set(messages.map(\.id)).count == messages.count,
              Set(hidden).count == hidden.count, Set(messages.map(\.id)).isDisjoint(with: hidden)
        else { throw DotsError("invalid_response") }
    }
    private static let messageStates: Set<String> = ["queued", "delivered", "replied", "delivery_failed", "expired"]
    private static func validTimestamp(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 9_007_199_254_740_991 && value.rounded(.towardZero) == value
    }
    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= maximum
    }
    private static func validateRecordPage(_ page: Page) throws {
        guard page.messages.count <= 30, validTimestamp(page.capturedAt),
              Set(page.messages.map(\.id)).count == page.messages.count else { throw DotsError("invalid_response") }
        for record in page.messages { try record.validate() }
    }
    static func validateTimeline(_ page: DotMessagePage) throws {
        guard page.messages.count <= 30, validTimestamp(page.capturedAt),
              Set(page.messages.map(\.id)).count == page.messages.count else { throw DotsError("invalid_response") }
        for message in page.messages {
            let official = message.id.range(of: "^official\\.[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
            let user = message.id.hasSuffix(".user") && UUID(uuidString: String(message.id.dropLast(5))) != nil
            let reply = message.id.hasSuffix(".reply") && UUID(uuidString: String(message.id.dropLast(6))) != nil
            guard validText(message.text, maximum: 16000), validTimestamp(message.sentAt), !message.controlsInSlack,
                  (official && ["user", "assistant"].contains(message.role)) || (user && message.role == "user") || (reply && message.role == "assistant"),
                  message.readAt.map(validTimestamp) != false else { throw DotsError("invalid_response") }
            if user {
                guard let state = message.deliveryState, messageStates.contains(state) else { throw DotsError("invalid_response") }
            } else if message.deliveryState != nil || message.readAt != nil { throw DotsError("invalid_response") }
        }
    }
    private func validID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else { throw DotsError("invalid_id") }
    }
}
