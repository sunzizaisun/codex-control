import Foundation

extension DotMessage {
    var eventDeliveryLabelKey: String? {
        switch deliveryState {
        case "queued", "sent": "dot 云端已接收"
        case "delivered": readAt == nil ? "dot 等待读取" : "dot 已收到"
        case "replied": "dot 已回复"
        case "delivery_failed", "expired", "rejected": "dot 投递失败"
        default: nil
        }
    }
    /// Event records are immutable; unlike Slack edits, older pages must not
    /// undo a durable reply or erase a known read timestamp.
    static func mergingEvents(_ existing: [Self], _ incoming: [Self]) -> [Self] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming {
            guard let old = byID[message.id], old.role == message.role,
                  old.text.utf8.elementsEqual(message.text.utf8), old.sentAt == message.sentAt else {
                byID[message.id] = message
                continue
            }
            let state = stateRank(old.deliveryState) > stateRank(message.deliveryState) ? old.deliveryState : message.deliveryState
            byID[message.id] = .init(id: message.id, role: message.role, text: message.text,
                sentAt: message.sentAt, controlsInSlack: message.controlsInSlack,
                deliveryState: state, readAt: old.readAt ?? message.readAt)
        }
        // A separately paged reply is itself authoritative evidence of reply
        // completion. It is not evidence of when the dot first read the input.
        for (id, user) in byID where user.role == "user" && id.hasSuffix(".user") {
            let root = String(id.dropLast(5))
            if UUID(uuidString: root) != nil, byID[root + ".reply"]?.role == "assistant", user.deliveryState != "replied" {
                byID[id] = .init(id: id, role: user.role, text: user.text, sentAt: user.sentAt,
                    controlsInSlack: user.controlsInSlack, deliveryState: "replied", readAt: user.readAt)
            }
        }
        return byID.values.filter { !isVerifiedMirror($0, in: byID) }
            .sorted { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
    }

    private static func stateRank(_ state: String?) -> Int {
        switch state {
        case "replied": 3
        case "expired", "delivery_failed", "rejected": 2
        case "delivered": 1
        case "queued", "sent": 0
        default: -1
        }
    }

    /// Reconcile a mirror already held in memory after the server has hidden
    /// it. Match complete fields byte-for-byte, not just a suffix or answer.
    private static func isVerifiedMirror(_ message: Self, in byID: [String: Self]) -> Bool {
        guard message.id.hasPrefix("official."), message.role == "assistant",
              let marker = message.text.range(of: "[ \\t\\r\\n]同步编号：([a-f0-9-]{36})[ \\t\\r\\n]*$", options: .regularExpression) else { return false }
        let suffix = message.text[marker].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        let id = String(suffix.dropFirst("同步编号：".count))
        guard UUID(uuidString: id) != nil, let user = byID[id + ".user"], user.role == "user",
              let reply = byID[id + ".reply"], reply.role == "assistant" else { return false }
        let fields = ["来自手机／手表", "用户：" + user.text, "dot：" + reply.text, "同步编号：" + id]
        var remaining = ArraySlice(message.text.utf8)
        for (index, field) in fields.enumerated() {
            guard remaining.starts(with: field.utf8) else { return false }
            remaining = remaining.dropFirst(field.utf8.count)
            let whitespace = remaining.prefix { [0x20, 0x09, 0x0d, 0x0a].contains($0) }
            if index < fields.count - 1 && whitespace.isEmpty { return false }
            remaining = remaining.dropFirst(whitespace.count)
        }
        return remaining.isEmpty
    }
}
