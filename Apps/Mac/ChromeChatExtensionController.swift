import AppKit
import CodexBridgeKit
import CodexWatchCore
import Foundation
import Network

/// The browser extension owns the ChatGPT web page.  This controller is only
/// a localhost message broker, so the Mac never guesses at browser focus,
/// keyboard layout, or clipboard state.
@MainActor
final class ChromeChatExtensionController {
    private struct Session: Codable {
        var sentPrompts: [String]
        var assistantReplies: [String]
        var assistantText: String?
        var assistantStreaming = false

        private enum CodingKeys: String, CodingKey {
            case sentPrompts, assistantReplies, assistantText, assistantStreaming
        }

        init(
            sentPrompts: [String],
            assistantReplies: [String] = [],
            assistantText: String? = nil,
            assistantStreaming: Bool = false
        ) {
            self.sentPrompts = sentPrompts
            self.assistantReplies = assistantReplies
            self.assistantText = assistantText
            self.assistantStreaming = assistantStreaming
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sentPrompts = try values.decode([String].self, forKey: .sentPrompts)
            assistantReplies = try values.decodeIfPresent([String].self, forKey: .assistantReplies) ?? []
            assistantText = try values.decodeIfPresent(String.self, forKey: .assistantText)
            assistantStreaming = try values.decodeIfPresent(Bool.self, forKey: .assistantStreaming) ?? false
        }
    }

    private static let sessionsKey = "CodexWatch.chromeExtensionSessions"
    private var sessions: [String: Session] = [:]
    private let server: ChromeExtensionHTTPServer
    private var lastExtensionHello = Date.distantPast
    private var assistantFinalizationTasks: [String: Task<Void, Never>] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.sessionsKey),
           let decoded = try? PropertyListDecoder().decode([String: Session].self, from: data) {
            sessions = decoded
        }
        server = ChromeExtensionHTTPServer()
        server.onHello = { [weak self] in
            Task { @MainActor in self?.lastExtensionHello = Date() }
        }
        server.onEvent = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        for (sessionID, session) in sessions where session.assistantStreaming {
            scheduleStableFinalization(sessionID: sessionID, expectedText: session.assistantText)
        }
        do {
            try server.start()
        } catch {
            // The user-facing error is surfaced when a Chat command is sent.
        }
    }

    var isConnected: Bool {
        Date().timeIntervalSince(lastExtensionHello) < 15
    }

    func hasSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    func startNewChat(prompt: String, sessionID: String) throws {
        guard isConnected else { throw ChatGPTDesktopControlError.webChatExtensionUnavailable }
        sessions[sessionID] = Session(sentPrompts: [prompt], assistantText: nil)
        persistSessions()
        server.enqueue(
            ChromeExtensionCommand(sessionID: sessionID, text: prompt, newSession: true)
        )
    }

    func sendFollowUp(_ prompt: String, sessionID: String) throws {
        guard isConnected else { throw ChatGPTDesktopControlError.webChatExtensionUnavailable }
        guard var session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        session.sentPrompts.append(prompt)
        if let previousReply = session.assistantText,
           !previousReply.isEmpty,
           !session.assistantStreaming,
           session.assistantReplies.last != previousReply {
            session.assistantReplies.append(previousReply)
        }
        session.assistantText = nil
        session.assistantStreaming = false
        sessions[sessionID] = session
        persistSessions()
        server.enqueue(
            ChromeExtensionCommand(sessionID: sessionID, text: prompt, newSession: false)
        )
    }

    func visibleTranscript(sessionID: String) throws -> [ChatMessage] {
        guard let session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        let now = Date()
        var messages: [ChatMessage] = []
        for (index, prompt) in session.sentPrompts.enumerated() {
            messages.append(
                ChatMessage(
                    id: "chrome-extension-user-\(sessionID)-\(index)",
                    role: .user,
                    text: prompt,
                    isStreaming: false,
                    createdAt: now.addingTimeInterval(Double(messages.count))
                )
            )
            if index < session.assistantReplies.count {
                messages.append(
                    ChatMessage(
                        id: "chrome-extension-assistant-\(sessionID)-\(index)",
                        role: .assistant,
                        text: session.assistantReplies[index],
                        isStreaming: false,
                        createdAt: now.addingTimeInterval(Double(messages.count))
                    )
                )
            }
        }
        if let assistantText = session.assistantText, !assistantText.isEmpty {
            messages.append(
                ChatMessage(
                    id: "chrome-extension-assistant-\(sessionID)-streaming",
                    role: .assistant,
                    text: assistantText,
                    isStreaming: session.assistantStreaming,
                    createdAt: now.addingTimeInterval(Double(messages.count))
                )
            )
        }
        return messages
    }

    private func apply(_ event: ChromeExtensionEvent) {
        guard event.type == "assistant",
              let sessionID = event.sessionID,
              let text = event.text,
              var session = sessions[sessionID] else { return }
        let isStreaming = event.isStreaming ?? false
        if isStreaming {
            session.assistantText = text
            scheduleStableFinalization(sessionID: sessionID, expectedText: text)
        } else {
            assistantFinalizationTasks.removeValue(forKey: sessionID)?.cancel()
            if session.assistantReplies.last != text {
                session.assistantReplies.append(text)
            }
            session.assistantText = nil
        }
        session.assistantStreaming = isStreaming
        sessions[sessionID] = session
        persistSessions()
    }

    /// Older already-loaded extension builds can publish the final text without
    /// a matching `isStreaming = false` event. Treat unchanged text as complete
    /// after a conservative quiet period so companions never remain stuck in a
    /// running state and follow-up messages retain the preceding reply.
    private func scheduleStableFinalization(sessionID: String, expectedText: String?) {
        assistantFinalizationTasks.removeValue(forKey: sessionID)?.cancel()
        guard let expectedText, !expectedText.isEmpty else { return }
        assistantFinalizationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            guard var session = self.sessions[sessionID],
                  session.assistantStreaming,
                  session.assistantText == expectedText else { return }
            if session.assistantReplies.last != expectedText {
                session.assistantReplies.append(expectedText)
            }
            session.assistantText = nil
            session.assistantStreaming = false
            self.sessions[sessionID] = session
            self.assistantFinalizationTasks.removeValue(forKey: sessionID)
            self.persistSessions()
        }
    }

    private func persistSessions() {
        guard let data = try? PropertyListEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionsKey)
    }
}

private struct ChromeExtensionCommand: Codable, Sendable {
    let sessionID: String
    let text: String
    let newSession: Bool
}

private struct ChromeExtensionEvent: Codable, Sendable {
    let type: String
    let sessionID: String?
    let role: String?
    let text: String?
    let isStreaming: Bool?
    let message: String?
}

private final class ChromeExtensionHTTPServer: @unchecked Sendable {
    static let port: UInt16 = 47831
    static let token = "2a0c61bf-5bb1-4e64-ab1a-1f7d6a932a90"

    private let lock = NSLock()
    private var listener: NWListener?
    private var queue: [Data] = []
    private var lastHelloAt = Date.distantPast
    var onHello: (() -> Void)?
    var onEvent: ((ChromeExtensionEvent) -> Void)?

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { _ in }
        self.listener = listener
        listener.start(queue: DispatchQueue(label: "codex.chrome.extension.http"))
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        queue.removeAll()
        lock.unlock()
        listener?.cancel()
    }

    func enqueue(_ command: ChromeExtensionCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        lock.lock()
        queue.append(data)
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "codex.chrome.extension.connection"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var combined = buffer
            if let data { combined.append(data) }
            guard let request = Self.parseRequest(combined) else {
                if isComplete || error != nil { connection.cancel(); return }
                self.receive(connection, buffer: combined)
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, X-Codex-Extension-Key\r\n"
        // Browser extension POSTs trigger a CORS preflight. The preflight
        // intentionally carries no bridge token, so it must be answered
        // before authenticating the actual request.
        if request.method == "OPTIONS" {
            send(status: "204 No Content", body: Data(), cors: cors, on: connection)
            return
        }
        guard request.headers["x-codex-extension-key"] == Self.token else {
            send(status: "401 Unauthorized", body: Data("Unauthorized".utf8), cors: cors, on: connection)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/next"):
            lock.lock()
            let body = queue.isEmpty ? nil : queue.removeFirst()
            lock.unlock()
            if let body {
                send(status: "200 OK", body: body, cors: cors, on: connection)
            } else {
                send(status: "204 No Content", body: Data(), cors: cors, on: connection)
            }
        case ("POST", "/v1/hello"):
            lock.lock()
            lastHelloAt = Date()
            lock.unlock()
            onHello?()
            send(status: "204 No Content", body: Data(), cors: cors, on: connection)
        case ("GET", "/v1/status"):
            lock.lock()
            let connected = Date().timeIntervalSince(lastHelloAt) < 15
            lock.unlock()
            let body = (try? JSONSerialization.data(withJSONObject: ["connected": connected])) ?? Data("{\"connected\":false}".utf8)
            send(status: "200 OK", body: body, cors: cors, on: connection)
        case ("POST", "/v1/event"):
            if let event = try? JSONDecoder().decode(ChromeExtensionEvent.self, from: request.body) {
                onEvent?(event)
            }
            send(status: "204 No Content", body: Data(), cors: cors, on: connection)
        default:
            send(status: "404 Not Found", body: Data(), cors: cors, on: connection)
        }
    }

    private func send(status: String, body: Data, cors: String, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\(cors)\r\n"
        var output = Data(header.utf8)
        output.append(body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            headers[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyStart = headerEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + length else { return nil }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])
        )
    }
}
