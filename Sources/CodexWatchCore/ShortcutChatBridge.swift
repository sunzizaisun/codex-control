import Foundation

/// Bridges an active iPhone or Apple Watch app to an Apple Shortcut that owns
/// the first-party ChatGPT action. This is intentionally separate from the
/// Mac relay: it provides a no-API fallback when the Mac is genuinely asleep,
/// without copying ChatGPT browser cookies to a third-party server.
public enum ShortcutChatBridge {
    public static let shortcutName = "Codex Control Chat"
    public static let callbackScheme = "codexcontrol"
    public static let callbackHost = "shortcut-chat"

    public enum Outcome: String, Sendable {
        case success
        case cancel
        case error
    }

    public struct Callback: Equatable, Sendable {
        public let outcome: Outcome
        public let requestID: String
        public let chatID: String
        public let result: String?
        public let errorMessage: String?

        public init(
            outcome: Outcome,
            requestID: String,
            chatID: String,
            result: String?,
            errorMessage: String?
        ) {
            self.outcome = outcome
            self.requestID = requestID
            self.chatID = chatID
            self.result = result
            self.errorMessage = errorMessage
        }
    }

    public struct PendingRequest: Codable, Equatable, Sendable {
        public let requestID: String
        public let chatID: String
        public let createdAt: Date

        public init(requestID: String, chatID: String, createdAt: Date = Date()) {
            self.requestID = requestID
            self.chatID = chatID
            self.createdAt = createdAt
        }
    }

    public static func chatID() -> String {
        "shortcut-chat:\(UUID().uuidString)"
    }

    public static func isShortcutChat(_ taskID: String) -> Bool {
        taskID.hasPrefix("shortcut-chat:")
    }

    public static func newTask(chatID: String, prompt: String, now: Date = Date()) -> AgentTask {
        AgentTask(
            id: chatID,
            title: String(prompt.prefix(80)),
            detail: nil,
            state: .running,
            model: "ChatGPT",
            updatedAt: now,
            messages: [
                ChatMessage(
                    id: UUID().uuidString,
                    role: .user,
                    text: prompt,
                    createdAt: now
                )
            ],
            isNativeChat: true
        )
    }

    public static func appendingUserMessage(
        _ prompt: String,
        to task: AgentTask,
        now: Date = Date()
    ) -> AgentTask {
        var result = task
        result.messages.append(ChatMessage(
            id: UUID().uuidString,
            role: .user,
            text: prompt,
            createdAt: now
        ))
        result.state = .running
        result.detail = nil
        result.updatedAt = now
        return result
    }

    public static func completing(
        _ task: AgentTask,
        response: String,
        now: Date = Date()
    ) -> AgentTask {
        var result = task
        result.messages.append(ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            text: response,
            createdAt: now
        ))
        result.state = .idle
        result.detail = nil
        result.updatedAt = now
        return result
    }

    public static func failing(
        _ task: AgentTask,
        message: String,
        now: Date = Date()
    ) -> AgentTask {
        var result = task
        result.state = .failed
        result.detail = message
        result.updatedAt = now
        return result
    }

    /// Builds Apple's documented x-callback URL. Shortcuts appends its textual
    /// output as `result` before reopening Codex Control.
    public static func runURL(
        prompt: String,
        requestID: String,
        chatID: String
    ) -> URL? {
        guard let success = callbackURL(
            outcome: .success,
            requestID: requestID,
            chatID: chatID
        ), let cancel = callbackURL(
            outcome: .cancel,
            requestID: requestID,
            chatID: chatID
        ), let error = callbackURL(
            outcome: .error,
            requestID: requestID,
            chatID: chatID
        ) else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: prompt),
            URLQueryItem(name: "x-success", value: success.absoluteString),
            URLQueryItem(name: "x-cancel", value: cancel.absoluteString),
            URLQueryItem(name: "x-error", value: error.absoluteString),
        ]
        return components.url
    }

    public static func parseCallback(_ url: URL) -> Callback? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == callbackScheme,
              components.host == callbackHost else { return nil }
        let outcomeText = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let outcome = Outcome(rawValue: outcomeText) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        guard let requestID = values["request"], !requestID.isEmpty,
              let chatID = values["chat"], !chatID.isEmpty else { return nil }
        return Callback(
            outcome: outcome,
            requestID: requestID,
            chatID: chatID,
            result: values["result"],
            errorMessage: values["errorMessage"]
        )
    }

    /// Each Shortcut invocation is stateless, so include a bounded transcript
    /// for follow-ups. The text stays on the user's device and is sent only to
    /// the ChatGPT action selected inside their Apple Shortcut.
    public static func contextualPrompt(
        newMessage: String,
        messages: [ChatMessage]
    ) -> String {
        guard !messages.isEmpty else { return newMessage }
        let transcript = messages.suffix(12).map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(String(message.text.prefix(1_500)))"
        }.joined(separator: "\n")
        return """
        Continue the same conversation using the context below. Answer only the newest user message, in the language used by the user.

        \(transcript)
        User: \(newMessage)
        """
    }

    private static func callbackURL(
        outcome: Outcome,
        requestID: String,
        chatID: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        components.path = "/\(outcome.rawValue)"
        components.queryItems = [
            URLQueryItem(name: "request", value: requestID),
            URLQueryItem(name: "chat", value: chatID),
        ]
        return components.url
    }
}
