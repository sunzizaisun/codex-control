import Foundation
import CodexWatchCore

/// Positive proof from the owner's real clientId, never matching prompt text
/// alone. Deliberately no thread/resume, turn/start, full-rollout fallback or
/// broad account/thread scan. New-conversation IDs must first be resolved by
/// the original journal binding; the sentinel itself is never queried here.
enum CommandReceiptLookup {
    typealias Requester = @Sendable (String, JSONValue) async throws -> JSONValue

    static func confirms(_ command: TaskCommand, requester: Requester) async throws -> Bool {
        guard !command.startsNewCodexChat, !command.targetsBrowserChat,
              command.executionTarget != .browser, !command.taskID.isEmpty,
              command.taskID.utf8.count <= 160, !command.id.isEmpty,
              command.id.utf8.count <= 160, !command.prompt.isEmpty else { return false }
        var cursor: String?
        var seenCursors = Set<String>()
        var seenItems = Set<String>()
        for _ in 0..<3 {
            var params: [String: JSONValue] = ["threadId": .string(command.taskID),
                "limit": .integer(30), "sortDirection": .string("desc")]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await requester("thread/items/list", .object(params))
            guard let entries = result["data"]?.arrayValue, entries.count <= 30 else {
                throw AppServerClientError.invalidResponse
            }
            var proofFound = false
            for entry in entries {
                guard let item = entry["item"], let id = item["id"]?.stringValue,
                      !id.isEmpty, id.utf8.count <= 160, seenItems.insert(id).inserted,
                      entry["turnId"]?.stringValue?.isEmpty == false,
                      let type = item["type"]?.stringValue, !type.isEmpty else {
                    throw AppServerClientError.invalidResponse
                }
                guard type == "userMessage", let rawClientID = item["clientId"], rawClientID != .null else { continue }
                guard let clientID = rawClientID.stringValue, !clientID.isEmpty, clientID.utf8.count <= 160 else {
                    throw AppServerClientError.invalidResponse
                }
                guard clientID.utf8.elementsEqual(command.id.utf8) else { continue }
                guard !proofFound, let content = item["content"]?.arrayValue, content.count == 1,
                      content[0]["type"]?.stringValue == "text",
                      let text = content[0]["text"]?.stringValue,
                      text.utf8.elementsEqual(command.prompt.utf8) else { return false }
                proofFound = true
            }
            let next: String?
            if let raw = result["nextCursor"], raw != .null {
                guard let value = raw.stringValue, !value.isEmpty, value.utf8.count <= 4_096,
                      seenCursors.insert(value).inserted else { throw AppServerClientError.invalidResponse }
                next = value
            } else { next = nil }
            if proofFound { return true }
            guard let next else { return false }
            cursor = next
        }
        return false
    }
}
