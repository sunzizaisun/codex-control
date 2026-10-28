import Foundation
import CodexWatchCore

/// Matches the installed 0.163.0-alpha.10.2 app-server schema. No full rollout
/// hydration and no speculative pagination endpoint or cursor construction.
enum PaginatedThreadHistory {
    typealias Requester = @Sendable (String, JSONValue) async throws -> JSONValue

    static func page(_ request: TaskHistoryRequest, requester: Requester) async throws -> TaskHistoryPage {
        guard !request.taskID.isEmpty, (1...30).contains(request.limit),
              request.continuation == nil || (!request.continuation!.isEmpty && request.continuation!.utf8.count <= 4_096) else {
            throw AppServerClientError.invalidResponse
        }
        var cursor = request.continuation
        var itemLimit = request.limit
        var seenCursors = Set<String>()
        if let cursor { seenCursors.insert(cursor) }
        // Tool activity can occupy whole item pages. Read at most three small
        // pages; preserve a continuation even when no chat row was found.
        for pass in 0..<3 {
            var params: [String: JSONValue] = ["threadId": .string(request.taskID),
                "limit": .integer(itemLimit), "sortDirection": .string("desc")]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await requester("thread/items/list", .object(params))
            guard let entries = result["data"]?.arrayValue, entries.count <= itemLimit else {
                throw AppServerClientError.invalidResponse
            }
            var itemIDs = Set<String>()
            for entry in entries {
                guard let id = entry["item"]?["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 160,
                      itemIDs.insert(id).inserted, entry["turnId"]?.stringValue?.isEmpty == false,
                      entry["item"]?["type"]?.stringValue?.isEmpty == false else {
                    throw AppServerClientError.invalidResponse
                }
            }
            let next: String?
            if let raw = result["nextCursor"], raw != .null {
                guard let value = raw.stringValue, !value.isEmpty, value.utf8.count <= 4_096,
                      !seenCursors.contains(value) else { throw AppServerClientError.invalidResponse }
                next = value
            } else { next = nil }
            let messages = ThreadHistoryParser.messages(from: .object(["data": .array(Array(entries.reversed()))]))
            let encodedBytes = try CodexWatchCoding.makeEncoder().encode(messages).count
            if encodedBytes > 36_000, itemLimit > 1, pass < 2 {
                // Re-read the SAME position with a smaller item limit; do not
                // slice this page and skip discarded messages using its end
                // cursor. This is a bounded GET, never another user action.
                itemLimit = max(1, min(itemLimit - 1, entries.count * 36_000 / encodedBytes))
                continue
            }
            if !messages.isEmpty || next == nil || pass == 2 {
                return TaskHistoryPage(taskID: request.taskID, messages: messages,
                    beforeMessageID: request.beforeMessageID,
                    nextBeforeMessageID: next == nil ? nil : messages.first?.id,
                    continuation: next, requestContinuation: request.continuation)
            }
            if let next { seenCursors.insert(next) }
            cursor = next
        }
        throw AppServerClientError.invalidResponse
    }
}
