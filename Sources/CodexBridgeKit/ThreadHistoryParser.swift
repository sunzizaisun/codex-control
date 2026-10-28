import Foundation
import CodexWatchCore

enum ThreadHistoryParser {
    static func messages(from result: JSONValue, existing: [ChatMessage] = [], now: Date = Date()) -> [ChatMessage] {
        let rows: [JSONValue]
        if let data = result["data"]?.arrayValue {
            rows = data.compactMap { $0["item"] }
        } else if let turns = result["thread"]?["turns"]?.arrayValue {
            rows = turns.flatMap { $0["items"]?.arrayValue ?? [] }
        } else {
            return []
        }
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var messages: [ChatMessage] = []
        var seen: Set<String> = []
        for (index, item) in rows.enumerated() {
            guard let id = item["id"]?.stringValue, seen.insert(id).inserted else { continue }
            let role: ChatMessage.Role
            let text: String
            switch item["type"]?.stringValue {
            case "userMessage":
                role = .user
                text = item["content"]?.arrayValue?
                    .filter { $0["type"]?.stringValue == "text" }
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n") ?? ""
            case "agentMessage":
                role = .assistant
                text = item["text"]?.stringValue ?? ""
            default:
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            messages.append(ChatMessage(
                id: id, role: role, text: text,
                isStreaming: item["status"]?.stringValue == "inProgress",
                createdAt: previous[id]?.createdAt ?? now.addingTimeInterval(Double(index) / 1_000),
                clientMessageID: role == .user ? (item["clientId"]?.stringValue ?? previous[id]?.clientMessageID) : nil
            ))
        }
        return messages
    }
}
