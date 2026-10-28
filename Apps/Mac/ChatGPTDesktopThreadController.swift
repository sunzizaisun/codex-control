import AppKit
import ApplicationServices
import Darwin
import Foundation
import Network
import CodexBridgeKit
import CodexWatchCore

enum ChatGPTDesktopControlError: LocalizedError {
    case desktopNotRunning
    case invalidSocket
    case connectionFailed(String)
    case protocolError(String)
    case noOwningWindow
    case targetDidNotOpen
    case composerUnavailable
    case composerContainsDraft
    case sendButtonUnavailable
    case accessibilityPermissionRequired
    case powerRequiredForDesktopControl
    case normalChatUnavailable
    case webChatBrowserNotRunning
    case webChatSignInRequired
    case webChatExtensionUnavailable
    case browserRouteRequired
    case chatUnavailable
    case appleEventFailed(String)

    var errorDescription: String? {
        switch self {
        case .desktopNotRunning:
            AppLocalizer.text("ChatGPT 桌面端未运行")
        case .invalidSocket:
            AppLocalizer.text("ChatGPT 桌面控制通道不可用")
        case .connectionFailed(let detail):
            AppLocalizer.format("无法连接 ChatGPT 桌面控制：%@", detail)
        case .protocolError(let detail):
            AppLocalizer.format("ChatGPT 桌面控制协议错误：%@", detail)
        case .noOwningWindow:
            AppLocalizer.text("没有桌面窗口正在管理这个任务")
        case .targetDidNotOpen:
            AppLocalizer.text("无法在 ChatGPT 中打开目标任务")
        case .composerUnavailable:
            AppLocalizer.text("找不到 ChatGPT 消息输入框")
        case .composerContainsDraft:
            AppLocalizer.text("目标任务中已有未发送的草稿，为避免覆盖已取消发送")
        case .sendButtonUnavailable:
            AppLocalizer.text("找不到 ChatGPT 发送按钮")
        case .accessibilityPermissionRequired:
            AppLocalizer.text("请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试")
        case .powerRequiredForDesktopControl:
            AppLocalizer.text("桌面控制仅在接通电源时启用")
        case .normalChatUnavailable:
            AppLocalizer.text("当前 ChatGPT 桌面端未启用 Quick Chat；标准新对话会进入 Work，已停止发送以避免消耗 Codex/Work 额度")
        case .webChatBrowserNotRunning:
            AppLocalizer.text("Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试")
        case .webChatSignInRequired:
            AppLocalizer.text("请先在 Google Chrome 登录 chatgpt.com，再从 iPhone 或 Apple Watch 发送 Chat")
        case .webChatExtensionUnavailable:
            AppLocalizer.text("Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com")
        case .browserRouteRequired:
            AppLocalizer.text("此 ChatGPT Chat 已绑定远程浏览器网关，Mac 本地桥接器不会把它送入 Work 或 Codex")
        case .chatUnavailable:
            AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务")
        case .appleEventFailed(let detail):
            AppLocalizer.format("无法控制 ChatGPT 桌面端：%@", detail)
        }
    }
}

struct ChatGPTDesktopApproval: Sendable {
    let externalKey: String
    let conversationID: String
    let requestID: AppServerRequestID
    let method: String
    let params: JSONValue

    var event: AppServerEvent {
        AppServerEvent(method: method, params: params, requestID: requestID)
    }
}

private enum ChatGPTDesktopMonitorEvent: Sendable {
    case approval(ChatGPTDesktopApproval)
    case resolved(externalKey: String, confirmed: Bool)
    case transcript(conversationID: String, messages: [ChatMessage])
    case runtime(DesktopRuntimeProjection)
    case runtimeUnavailable(conversationID: String)
}

/// Only keep a desktop conversation's larger live state while a companion has
/// just sent it a message.  Approval monitoring follows many conversations at
/// once, and retaining every full Work transcript would make the bridge
/// needlessly memory-hungry.
private final class DesktopTranscriptInterest: @unchecked Sendable {
    private let lock = NSLock()
    private var expiryByConversation: [String: Date] = [:]
    private var refreshRequested: Set<String> = []

    func retain(_ conversationID: String, for seconds: TimeInterval = 10 * 60) {
        lock.lock()
        expiryByConversation[conversationID] = Date().addingTimeInterval(seconds)
        refreshRequested.insert(conversationID)
        lock.unlock()
    }

    func contains(_ conversationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        expiryByConversation = expiryByConversation.filter { $0.value > now }
        return expiryByConversation[conversationID] != nil
    }

    /// The approval monitor normally retains only a compact state. Ask it to
    /// obtain one fresh full snapshot before applying the next turn patches.
    func consumeRefreshRequest(for conversationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        expiryByConversation = expiryByConversation.filter { $0.value > now }
        guard expiryByConversation[conversationID] != nil else {
            refreshRequested.remove(conversationID)
            return false
        }
        return refreshRequested.remove(conversationID) != nil
    }
}

/// Talks to the per-user desktop IPC router used by ChatGPT's own task
/// follower. This is deliberately version-gated and falls back cleanly when a
/// future desktop build changes the protocol.
actor ChatGPTDesktopThreadController {
    private static let initializeVersion = 0
    private static let followerVersion = 1
    private static let streamStateVersion = 11
    private var handledCommandIDs: Set<String> = []
    private var inFlightCommandIDs: Set<String> = []
    private var approvalMonitorTask: Task<Void, Never>?
    private let transcriptInterest = DesktopTranscriptInterest()
    private let resolutionTracker = RequestResolutionTracker()

    func startApprovalMonitoring(
        existingConversationIDs: Set<String>,
        onApproval: @escaping @Sendable (ChatGPTDesktopApproval) async -> Void,
        onResolved: @escaping @Sendable (String) async -> Void,
        onTranscript: @escaping @Sendable (String, [ChatMessage]) async -> Void,
        onRuntime: @escaping @Sendable (DesktopRuntimeProjection) async -> Void,
        onRuntimeUnavailable: @escaping @Sendable (String) async -> Void
    ) {
        guard approvalMonitorTask == nil else { return }
        let interest = transcriptInterest
        let tracker = resolutionTracker
        approvalMonitorTask = Task.detached(priority: .utility) {
            let stream = AsyncStream<ChatGPTDesktopMonitorEvent> { continuation in
                let producer = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        do {
                            try Self.monitorApprovalsSynchronously(
                                existingConversationIDs: existingConversationIDs,
                                transcriptInterest: interest
                            ) { event in continuation.yield(event) }
                        } catch is CancellationError {
                            break
                        } catch {
                            if !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(2))
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }

            for await event in stream {
                switch event {
                case .approval(let approval):
                    await tracker.registered(approval.externalKey)
                    await onApproval(approval)
                case .resolved(let externalKey, let confirmed):
                    await tracker.resolved(externalKey, confirmed: confirmed)
                    await onResolved(externalKey)
                case .transcript(let conversationID, let messages):
                    await onTranscript(conversationID, messages)
                case .runtime(let projection):
                    await onRuntime(projection)
                case .runtimeUnavailable(let conversationID):
                    await onRuntimeUnavailable(conversationID)
                }
            }
        }
    }

    func stopApprovalMonitoring() {
        approvalMonitorTask?.cancel()
        approvalMonitorTask = nil
    }

    func send(_ command: TaskCommand, task: AgentTask?) async throws {
        guard !handledCommandIDs.contains(command.id) else { return }
        guard inFlightCommandIDs.insert(command.id).inserted else { return }
        defer { inFlightCommandIDs.remove(command.id) }

        // Work replies are streamed by the desktop owner, not by this bridge's
        // app-server session. Keep that conversation projected until its reply
        // arrives so the phone and Watch receive the same transcript.
        transcriptInterest.retain(command.taskID)

        try await Task.detached(priority: .userInitiated) {
            try Self.sendSynchronously(command, task: task)
        }.value

        handledCommandIDs.insert(command.id)
        if handledCommandIDs.count > 512 {
            handledCommandIDs.remove(handledCommandIDs.first!)
        }
    }

    func respond(
        to approval: ChatGPTDesktopApproval,
        result: JSONValue
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.respondSynchronously(to: approval, result: result)
        }.value
        try await resolutionTracker.wait(approval.externalKey)
    }

    private static func respondSynchronously(
        to approval: ChatGPTDesktopApproval,
        result: JSONValue
    ) throws {
        let socketPath = try resolveTrustedSocket()
        let connection = try UnixFramedConnection(path: socketPath)
        defer { connection.close() }
        let clientID = try initialize(connection)

        let method: String
        var params: [String: Any] = [
            "conversationId": approval.conversationID,
            "requestId": wireValue(approval.requestID),
        ]
        switch approval.method {
        case "item/commandExecution/requestApproval":
            method = "thread-follower-command-approval-decision"
            params["decision"] = result["decision"]?.stringValue ?? "decline"
        case "item/fileChange/requestApproval":
            method = "thread-follower-file-approval-decision"
            params["decision"] = result["decision"]?.stringValue ?? "decline"
        case "item/permissions/requestApproval":
            method = "thread-follower-permissions-request-approval-response"
            params["response"] = try foundationObject(result)
        case "mcpServer/elicitation/request":
            method = "thread-follower-submit-mcp-server-elicitation-response"
            params["response"] = try foundationObject(result)
        case "item/tool/requestUserInput", "tool/requestUserInput":
            // Verified in the installed desktop's v1 follower protocol.
            method = "thread-follower-submit-user-input"
            params["response"] = try foundationObject(result)
        default:
            throw ChatGPTDesktopControlError.protocolError("unsupported approval method")
        }
        try sendFollowerRequest(
            connection: connection,
            clientID: clientID,
            method: method,
            params: params
        )
    }

    private static func monitorApprovalsSynchronously(
        existingConversationIDs: Set<String>,
        transcriptInterest: DesktopTranscriptInterest,
        emit: @escaping @Sendable (ChatGPTDesktopMonitorEvent) -> Void
    ) throws {
        let socketPath = try resolveTrustedSocket()
        let connection = try UnixFramedConnection(path: socketPath)
        let clientID = try initialize(connection)
        defer { connection.close() }

        var states: [String: JSONValue] = [:]
        var activeKeysByConversation: [String: Set<String>] = [:]
        var requestByExternalKey: [String: JSONValue] = [:]
        var ownerClientByConversation: [String: String] = [:]
        var subscribedRoutes: Set<String> = []
        var transcriptStateConversationIDs: Set<String> = []
        var runtimeProjections: [String: DesktopRuntimeProjection] = [:]

        // The desktop owner asks whether anyone is following when it first
        // opens a conversation. If this bridge starts later, that one-time
        // broadcast has already happened. Proactively follow the account's
        // existing local conversations so an already-running Work task sends
        // its current snapshot (including any pending approval).
        for conversationID in existingConversationIDs where !conversationID.isEmpty {
            let routeKey = "local\u{1F}\(conversationID)"
            subscribedRoutes.insert(routeKey)
            try connection.send([
                "type": "broadcast",
                "method": "thread-stream-following-changed",
                "sourceClientId": clientID,
                "version": followerVersion,
                "params": [
                    "conversationId": conversationID,
                    "hostId": "local",
                    "following": true,
                ],
            ])
        }

        defer {
            for id in ownerClientByConversation.keys { emit(.runtimeUnavailable(conversationID: id)) }
            for keys in activeKeysByConversation.values {
                for key in keys {
                    emit(.resolved(externalKey: key, confirmed: false))
                }
            }
        }

        while !Task.isCancelled {
            let message = try connection.nextMessage()
            if message["type"] as? String == "client-discovery-request" {
                try connection.send([
                    "type": "client-discovery-response",
                    "requestId": message["requestId"] ?? "",
                    "response": ["canHandle": false],
                ])
                continue
            }
            if message["type"] as? String == "request" {
                try connection.send([
                    "type": "response",
                    "requestId": message["requestId"] ?? "",
                    "resultType": "error",
                    "error": "no-handler-for-request",
                ])
                continue
            }
            if message["type"] as? String == "broadcast",
               message["method"] as? String == "client-status-changed",
               let params = message["params"] as? [String: Any],
               params["status"] as? String == "disconnected",
               let disconnectedClientID = params["clientId"] as? String {
                for conversationID in ownerClientByConversation
                    .filter({ $0.value == disconnectedClientID })
                    .map(\.key) {
                    ownerClientByConversation.removeValue(forKey: conversationID)
                    states.removeValue(forKey: conversationID)
                    runtimeProjections.removeValue(forKey: conversationID)
                    emit(.runtimeUnavailable(conversationID: conversationID))
                    resolveConversation(
                        conversationID,
                        activeKeysByConversation: &activeKeysByConversation,
                        requestByExternalKey: &requestByExternalKey,
                        emit: emit
                    )
                }
                continue
            }
            guard message["type"] as? String == "broadcast",
                  let method = message["method"] as? String,
                  let sourceClientID = message["sourceClientId"] as? String,
                  sourceClientID != clientID,
                  let params = message["params"] as? [String: Any],
                  let conversationID = params["conversationId"] as? String,
                  let hostID = params["hostId"] as? String else {
                continue
            }

            switch method {
            case "thread-stream-following-changed":
                guard Self.integer(message["version"]) == followerVersion else { continue }
                let routeKey = "\(hostID)\u{1F}\(conversationID)"
                if params["following"] as? Bool == true {
                    if subscribedRoutes.insert(routeKey).inserted {
                        try connection.send([
                            "type": "broadcast",
                            "method": "thread-stream-following-changed",
                            "sourceClientId": clientID,
                            "version": followerVersion,
                            "params": [
                                "conversationId": conversationID,
                                "hostId": hostID,
                                "following": true,
                            ],
                        ])
                    }
                } else if ownerClientByConversation[conversationID] == sourceClientID,
                          subscribedRoutes.remove(routeKey) != nil {
                    try connection.send([
                        "type": "broadcast",
                        "method": "thread-stream-following-changed",
                        "sourceClientId": clientID,
                        "version": followerVersion,
                        "params": [
                            "conversationId": conversationID,
                            "hostId": hostID,
                            "following": false,
                        ],
                    ])
                    states.removeValue(forKey: conversationID)
                    runtimeProjections.removeValue(forKey: conversationID)
                    emit(.runtimeUnavailable(conversationID: conversationID))
                    resolveConversation(
                        conversationID,
                        activeKeysByConversation: &activeKeysByConversation,
                        requestByExternalKey: &requestByExternalKey,
                        emit: emit
                    )
                }

            case "thread-stream-following-status-requested":
                guard Self.integer(message["version"]) == followerVersion else { continue }
                let routeKey = "\(hostID)\u{1F}\(conversationID)"
                subscribedRoutes.insert(routeKey)
                try connection.send([
                    "type": "broadcast",
                    "method": "thread-stream-following-changed",
                    "sourceClientId": clientID,
                    "version": followerVersion,
                    "params": [
                        "conversationId": conversationID,
                        "hostId": hostID,
                        "following": true,
                    ],
                ])

            case "thread-stream-state-changed":
                guard Self.integer(message["version"]) == streamStateVersion,
                      let change = params["change"] as? [String: Any],
                      let changeType = change["type"] as? String else {
                    continue
                }
                // A command can be sent after this monitor has already
                // compacted the conversation to approvals only. Re-following
                // requests a new snapshot from the desktop owner, so response
                // patches have a complete state to apply to.
                if transcriptInterest.consumeRefreshRequest(for: conversationID) {
                    states.removeValue(forKey: conversationID)
                    transcriptStateConversationIDs.remove(conversationID)
                    let followParams: [String: Any] = [
                        "conversationId": conversationID,
                        "hostId": hostID,
                    ]
                    try connection.send([
                        "type": "broadcast",
                        "method": "thread-stream-following-changed",
                        "sourceClientId": clientID,
                        "version": followerVersion,
                        "params": followParams.merging(["following": false]) { _, new in new },
                    ])
                    try connection.send([
                        "type": "broadcast",
                        "method": "thread-stream-following-changed",
                        "sourceClientId": clientID,
                        "version": followerVersion,
                        "params": followParams.merging(["following": true]) { _, new in new },
                    ])
                    continue
                }
                if changeType == "snapshot",
                   let rawState = change["conversationState"],
                   let state = try? monitoredState(
                       from: rawState,
                       includeTranscript: transcriptInterest.contains(conversationID)
                   ) {
                    ownerClientByConversation[conversationID] = sourceClientID
                    states[conversationID] = state
                    if transcriptInterest.contains(conversationID) {
                        transcriptStateConversationIDs.insert(conversationID)
                    } else {
                        transcriptStateConversationIDs.remove(conversationID)
                    }
                } else if changeType == "patches",
                          ownerClientByConversation[conversationID] == sourceClientID,
                          var state = states[conversationID],
                          let patches = try? jsonValue(change["patches"] ?? []) {
                    if transcriptStateConversationIDs.contains(conversationID) {
                        applyAllPatches(patches, to: &state)
                    } else {
                        applyApprovalPatches(patches, to: &state)
                    }
                    states[conversationID] = state
                }
                guard let state = states[conversationID] else { continue }
                let projection = DesktopRuntimeProjection(threadID: conversationID, state: state)
                if runtimeProjections[conversationID] != projection {
                    runtimeProjections[conversationID] = projection
                    emit(.runtime(projection))
                }
                syncApprovals(
                    conversationID: conversationID,
                    state: state,
                    activeKeysByConversation: &activeKeysByConversation,
                    requestByExternalKey: &requestByExternalKey,
                    emit: emit
                )
                if transcriptStateConversationIDs.contains(conversationID) {
                    emit(.transcript(
                        conversationID: conversationID,
                        messages: transcriptMessages(from: state)
                    ))
                    // Once a response has arrived, continuing to hold an
                    // unbounded desktop state is unnecessary. The store keeps
                    // the compact message projection for companion devices.
                    if !transcriptInterest.contains(conversationID) {
                        states[conversationID] = approvalState(from: state)
                        transcriptStateConversationIDs.remove(conversationID)
                    }
                }

            default:
                continue
            }
        }

        throw CancellationError()
    }

    /// Desktop snapshots can be tens of megabytes. Most followed Work threads
    /// only need their approval queue; a thread that just received a companion
    /// message temporarily retains its full state so its reply can be mirrored.
    private static func monitoredState(
        from rawState: Any,
        includeTranscript: Bool
    ) throws -> JSONValue {
        guard let object = rawState as? [String: Any] else {
            throw ChatGPTDesktopControlError.protocolError("invalid conversation state")
        }
        if includeTranscript {
            return try jsonValue(object)
        }
        return try approvalState(from: object)
    }

    private static func approvalState(from rawState: Any) throws -> JSONValue {
        guard let object = rawState as? [String: Any] else {
            throw ChatGPTDesktopControlError.protocolError("invalid conversation state")
        }
        var fields: [String: Any] = [:]
        for key in ["requests", "threadRuntimeStatus", "title", "cwd", "updatedAt", "turns", "turnHistory"] { fields[key] = object[key] }
        return DesktopRuntimeProjection.compactState(try jsonValue(fields))
    }

    private static func approvalState(from state: JSONValue) -> JSONValue {
        DesktopRuntimeProjection.compactState(state)
    }

    private static func syncApprovals(
        conversationID: String,
        state: JSONValue,
        activeKeysByConversation: inout [String: Set<String>],
        requestByExternalKey: inout [String: JSONValue],
        emit: @escaping @Sendable (ChatGPTDesktopMonitorEvent) -> Void
    ) {
        let supportedMethods: Set<String> = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "mcpServer/elicitation/request",
            "item/tool/requestUserInput",
            "tool/requestUserInput",
        ]
        let requests = state["requests"]?.arrayValue ?? []
        var nextKeys: Set<String> = []

        for request in requests {
            guard let method = request["method"]?.stringValue,
                  supportedMethods.contains(method),
                  let requestID = AppServerRequestID(request["id"]) else {
                continue
            }
            let externalKey = desktopApprovalKey(
                conversationID: conversationID,
                requestID: requestID
            )
            nextKeys.insert(externalKey)
            guard requestByExternalKey[externalKey] != request else {
                continue
            }
            requestByExternalKey[externalKey] = request
            var params = request["params"]?.objectValue ?? [:]
            params["threadId"] = params["threadId"] ?? .string(conversationID)
            emit(.approval(ChatGPTDesktopApproval(
                externalKey: externalKey,
                conversationID: conversationID,
                requestID: requestID,
                method: method,
                params: .object(params)
            )))
        }

        let previousKeys = activeKeysByConversation[conversationID] ?? []
        for removedKey in previousKeys.subtracting(nextKeys) {
            requestByExternalKey.removeValue(forKey: removedKey)
            emit(.resolved(externalKey: removedKey, confirmed: true))
        }
        activeKeysByConversation[conversationID] = nextKeys
    }

    private static func resolveConversation(
        _ conversationID: String,
        activeKeysByConversation: inout [String: Set<String>],
        requestByExternalKey: inout [String: JSONValue],
        emit: @escaping @Sendable (ChatGPTDesktopMonitorEvent) -> Void
    ) {
        let keys = activeKeysByConversation.removeValue(forKey: conversationID) ?? []
        for key in keys {
            requestByExternalKey.removeValue(forKey: key)
            emit(.resolved(externalKey: key, confirmed: false))
        }
    }

    private static func desktopApprovalKey(
        conversationID: String,
        requestID: AppServerRequestID
    ) -> String {
        let requestComponent: String
        switch requestID {
        case .integer(let value):
            requestComponent = "i:\(value)"
        case .string(let value):
            requestComponent = "s:\(value)"
        }
        return "chatgpt-desktop\u{1F}\(conversationID)\u{1F}\(requestComponent)"
    }

    private static func initialize(_ connection: UnixFramedConnection) throws -> String {
        let initializeID = UUID().uuidString
        let initialize = try connection.request(
            [
                "type": "request",
                "requestId": initializeID,
                "sourceClientId": "initializing-client",
                "version": initializeVersion,
                "method": "initialize",
                "params": ["clientType": "codex-watch-bridge"],
                "timeoutMs": 10_000,
            ],
            requestID: initializeID
        )
        guard initialize["resultType"] as? String == "success",
              let result = initialize["result"] as? [String: Any],
              let clientID = result["clientId"] as? String else {
            throw responseError(initialize)
        }
        return clientID
    }

    private static func sendSynchronously(_ command: TaskCommand, task: AgentTask?) throws {
        let socketPath = try resolveTrustedSocket()
        let connection = try UnixFramedConnection(path: socketPath)
        defer { connection.close() }

        let clientID = try initialize(connection)

        let input: [[String: Any]] = [
            [
                "type": "text",
                "text": command.prompt,
                "text_elements": [],
            ],
        ]

        if task?.isInProgress == true {
            if command.options != nil { throw CodexTurnOptionsError.activeTurn }
            do {
                try sendFollowerRequest(
                    connection: connection,
                    clientID: clientID,
                    method: "thread-follower-steer-turn",
                    params: [
                        "conversationId": command.taskID,
                        "clientUserMessageId": command.id,
                        "input": input,
                        "serviceTier": NSNull(),
                        "attachments": [],
                        "additionalContext": NSNull(),
                        "restoreMessage": restoreMessage(for: command, task: task),
                    ]
                )
                return
            } catch {
                // Failure is not proof that a steer was rejected. In
                // particular a timeout must not send the same prompt again
                // as a new turn. Refresh and let the user explicitly retry.
                throw error
            }
        }

        var turnRequest: [String: Any] = [
            "threadId": command.taskID,
            "clientUserMessageId": command.id,
            "input": input,
        ]
        if let options = command.options {
            turnRequest["model"] = options.model
            turnRequest["effort"] = options.effort
        }
        try sendFollowerRequest(
            connection: connection,
            clientID: clientID,
            method: "thread-follower-start-turn",
            params: [
                "conversationId": command.taskID,
                "turnStart": [
                    "request": turnRequest,
                    // An inherited collaboration-mode preset would override
                    // explicit model/effort in the installed desktop runtime.
                    "context": ["inheritThreadSettings": command.options == nil],
                ],
            ]
        )
    }

    private static func sendFollowerRequest(
        connection: UnixFramedConnection,
        clientID: String,
        method: String,
        params: [String: Any]
    ) throws {
        let requestID = UUID().uuidString
        let response = try connection.request(
            [
                "type": "request",
                "requestId": requestID,
                "sourceClientId": clientID,
                // Installed desktop 0.160.1 uses v2 for start-turn and v1
                // for steer/approvals. Do not apply one version to all RPCs.
                "version": method == "thread-follower-start-turn" ? 2 : followerVersion,
                "method": method,
                "params": params,
                "timeoutMs": 30_000,
            ],
            requestID: requestID
        )
        guard response["resultType"] as? String == "success" else {
            throw responseError(response)
        }
    }

    private enum PatchSegment {
        case key(String)
        case index(Int)
        case append
    }

    /// Applies only approval queue patches to the compact monitor state.
    private static func applyApprovalPatches(_ patches: JSONValue, to state: inout JSONValue) {
        guard let rows = patches.arrayValue else { return }
        for patch in rows {
            guard let operation = patch["op"]?.stringValue,
                  let path = patchPath(patch["path"]) else {
                continue
            }
            if path.isEmpty {
                if let replacement = patch["value"],
                   operation == "add" || operation == "replace" {
                    state = DesktopRuntimeProjection.compactState(replacement)
                } else if operation == "remove" {
                    state = .object(["requests": .array([])])
                }
                continue
            }
            guard case .key(let root) = path[0],
                  ["requests", "threadRuntimeStatus", "title", "cwd", "updatedAt", "turns", "turnHistory"].contains(root),
                  !path.contains(where: { if case .key("items") = $0 { return true }; return false }) else {
                continue
            }
            applyPatch(
                operation: operation,
                path: path,
                replacement: patch["value"],
                to: &state
            )
            state = DesktopRuntimeProjection.compactState(state)
        }
    }

    /// Uses the standard JSON patch interpreter while a recently steered Work
    /// conversation is being mirrored. The complete state is released again
    /// after the brief transcript-interest window above.
    private static func applyAllPatches(_ patches: JSONValue, to state: inout JSONValue) {
        guard let rows = patches.arrayValue else { return }
        for patch in rows {
            guard let operation = patch["op"]?.stringValue,
                  let path = patchPath(patch["path"]) else {
                continue
            }
            applyPatch(
                operation: operation,
                path: path,
                replacement: patch["value"],
                to: &state
            )
        }
    }

    /// Conversation state is an internal desktop protocol, so it has changed
    /// shape across releases. Extract only real user/assistant items by their
    /// stable item types instead of relying on one container path.
    private static func transcriptMessages(from state: JSONValue) -> [ChatMessage] {
        DesktopRuntimeProjection.messages(from: state)
    }

    private static func patchPath(_ value: JSONValue?) -> [PatchSegment]? {
        if let rows = value?.arrayValue {
            var path: [PatchSegment] = []
            for component in rows {
                if let index = component.intValue {
                    path.append(.index(index))
                } else if let key = component.stringValue {
                    if key == "-" {
                        path.append(.append)
                    } else if let index = Int(key) {
                        path.append(.index(index))
                    } else {
                        path.append(.key(key))
                    }
                } else {
                    return nil
                }
            }
            return path
        }
        guard let pointer = value?.stringValue else { return nil }
        if pointer.isEmpty { return [] }
        guard pointer.first == "/" else { return nil }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { raw in
            let component = raw
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            if component == "-" { return .append }
            if let index = Int(component) { return .index(index) }
            return .key(component)
        }
    }

    private static func applyPatch(
        operation: String,
        path: [PatchSegment],
        replacement: JSONValue?,
        to value: inout JSONValue
    ) {
        guard let head = path.first else {
            if operation == "remove" {
                value = .null
            } else if let replacement, operation == "add" || operation == "replace" {
                value = replacement
            }
            return
        }

        let tail = Array(path.dropFirst())
        switch (value, head) {
        case (.object(var object), .key(let key)):
            if tail.isEmpty {
                if operation == "remove" {
                    object.removeValue(forKey: key)
                } else if let replacement, operation == "add" || operation == "replace" {
                    object[key] = replacement
                }
            } else if var child = object[key] {
                applyPatch(
                    operation: operation,
                    path: tail,
                    replacement: replacement,
                    to: &child
                )
                object[key] = child
            }
            value = .object(object)

        case (.array(var array), .index(let index)):
            guard index >= 0 else { return }
            if tail.isEmpty {
                if operation == "remove", array.indices.contains(index) {
                    array.remove(at: index)
                } else if let replacement, operation == "add", index <= array.count {
                    array.insert(replacement, at: index)
                } else if let replacement, operation == "replace", array.indices.contains(index) {
                    array[index] = replacement
                }
            } else if array.indices.contains(index) {
                var child = array[index]
                applyPatch(
                    operation: operation,
                    path: tail,
                    replacement: replacement,
                    to: &child
                )
                array[index] = child
            }
            value = .array(array)

        case (.array(var array), .append):
            if tail.isEmpty, operation == "add", let replacement {
                array.append(replacement)
                value = .array(array)
            }

        default:
            return
        }
    }

    private static func jsonValue(_ value: Any) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func foundationObject(_ value: JSONValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func wireValue(_ requestID: AppServerRequestID) -> Any {
        switch requestID {
        case .integer(let value): value
        case .string(let value): value
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func restoreMessage(for command: TaskCommand, task: AgentTask?) -> [String: Any] {
        let cwd = task?.workspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCWD = cwd?.isEmpty == false ? cwd! : "/"
        return [
            "id": command.id,
            "text": command.prompt,
            "context": [
                "prompt": command.prompt,
                "addedFiles": [],
                "fileAttachments": [],
                "ideContext": NSNull(),
                "imageAttachments": [],
                "workspaceRoots": [resolvedCWD],
            ],
            "cwd": resolvedCWD,
            "createdAt": Int(Date().timeIntervalSince1970 * 1_000),
        ]
    }

    private static func responseError(_ response: [String: Any]) -> ChatGPTDesktopControlError {
        let detail = response["error"] as? String ?? "unknown response"
        if detail == "no-client-found" || detail == "client-cannot-handle-request" {
            return .noOwningWindow
        }
        return .protocolError(detail)
    }

    private static func resolveTrustedSocket() throws -> String {
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(userHome)/.codex/ipc/ipc.sock",
            "\(NSTemporaryDirectory())codex-ipc/ipc-\(getuid()).sock",
        ]
        for path in candidates where isTrustedSocket(path) {
            return path
        }
        throw ChatGPTDesktopControlError.invalidSocket
    }

    private static func isTrustedSocket(_ path: String) -> Bool {
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              socketInfo.st_uid == getuid(),
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }

        var directoryInfo = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return true
    }
}

/// Final fallback for a desktop task which is not currently owned by an IPC
/// window. It navigates with ChatGPT's registered deep link, verifies the
/// thread ID in the loaded tab, refuses to overwrite drafts, and only then
/// submits the prompt.
@MainActor
final class ChatGPTDesktopInterfaceController {
    private var handledCommandIDs: Set<String> = []

    func send(_ command: TaskCommand) async throws {
        guard !handledCommandIDs.contains(command.id) else { return }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).isEmpty == false else {
            throw ChatGPTDesktopControlError.desktopNotRunning
        }
        guard let encodedID = command.taskID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let deepLink = URL(string: "codex://threads/\(encodedID)") else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }

        guard NSWorkspace.shared.open(deepLink) else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }

        let promptBase64 = Data(command.prompt.utf8).base64EncodedString()
        var prepared = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            let result = try executeJavaScript(Self.prepareJavaScript(
                threadID: command.taskID,
                promptBase64: promptBase64
            ))
            switch result {
            case "READY":
                prepared = true
            case "DRAFT":
                throw ChatGPTDesktopControlError.composerContainsDraft
            default:
                continue
            }
            break
        }
        guard prepared else {
            throw ChatGPTDesktopControlError.composerUnavailable
        }

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(150))
            if try executeJavaScript(Self.submitJavaScript(threadID: command.taskID)) == "SENT" {
                handledCommandIDs.insert(command.id)
                if handledCommandIDs.count > 512 {
                    handledCommandIDs.remove(handledCommandIDs.first!)
                }
                return
            }
        }
        throw ChatGPTDesktopControlError.sendButtonUnavailable
    }

    private func executeJavaScript(_ javascript: String) throws -> String {
        let escaped = Self.appleScriptLiteral(javascript)
        let source = """
        tell application "ChatGPT"
            activate
            if (count of windows) is 0 then error "No ChatGPT window"
            set targetTab to active tab of front window
            return execute targetTab javascript \(escaped)
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let result = script.executeAndReturnError(&errorInfo).stringValue else {
            let detail = (errorInfo?[NSAppleScript.errorMessage] as? String)
                ?? "Apple Events returned no result"
            throw ChatGPTDesktopControlError.appleEventFailed(detail)
        }
        return result
    }

    private static func prepareJavaScript(threadID: String, promptBase64: String) -> String {
        """
        (() => {
          if (!location.href.includes(\(javaScriptLiteral(threadID)))) return "WAIT";
          const visible = element => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 1 && rect.height > 1 && style.visibility !== "hidden" && style.display !== "none";
          };
          const selectors = [
            'textarea[data-testid*="composer"]',
            '[data-testid*="composer"] textarea',
            '[data-testid*="composer"] [contenteditable="true"]',
            '[contenteditable="true"][role="textbox"]',
            'textarea[placeholder]',
            'textarea'
          ];
          const editors = selectors.flatMap(selector => Array.from(document.querySelectorAll(selector)))
            .filter((element, index, all) => all.indexOf(element) === index && visible(element));
          const editor = editors.at(-1);
          if (!editor) return "WAIT";
          const current = ('value' in editor ? editor.value : editor.innerText || editor.textContent || '').trim();
          if (current.length > 0) return "DRAFT";
          const bytes = Uint8Array.from(atob(\(javaScriptLiteral(promptBase64))), char => char.charCodeAt(0));
          const prompt = new TextDecoder().decode(bytes);
          editor.focus();
          if (editor instanceof HTMLTextAreaElement) {
            const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
            setter.call(editor, prompt);
            editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
            editor.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            document.execCommand('insertText', false, prompt);
            editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
          }
          const inserted = ('value' in editor ? editor.value : editor.innerText || editor.textContent || '').trim();
          return inserted === prompt.trim() ? "READY" : "WAIT";
        })()
        """
    }

    private static func submitJavaScript(threadID: String) -> String {
        """
        (() => {
          if (!location.href.includes(\(javaScriptLiteral(threadID)))) return "WAIT";
          const visible = element => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 1 && rect.height > 1 && style.visibility !== "hidden" && style.display !== "none";
          };
          const selectors = [
            'button[data-testid="send-button"]',
            'button[data-testid*="send"]',
            'button[aria-label="Send"]',
            'button[aria-label*="Send message"]',
            'button[aria-label="发送"]',
            'button[aria-label*="发送消息"]'
          ];
          let button = selectors.flatMap(selector => Array.from(document.querySelectorAll(selector)))
            .find(element => visible(element) && !element.disabled);
          if (!button) {
            const editor = Array.from(document.querySelectorAll(
              '[data-testid*="composer"] textarea, [data-testid*="composer"] [contenteditable="true"], [contenteditable="true"][role="textbox"], textarea'
            )).filter(visible).at(-1);
            button = editor?.closest('form')?.querySelector('button[type="submit"]:not([disabled])') ?? null;
          }
          if (!button || !visible(button) || button.disabled) return "WAIT";
          button.click();
          return "SENT";
        })()
        """
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// A deliberately separate route for the user's normal ChatGPT history. It
/// uses the desktop app's Quick Chat command instead of Codex's private
/// app-server, so it cannot silently consume a Work/Codex turn.
@MainActor
final class ChatGPTNativeChatController {
    private struct Session {
        let conversationID: String
        let windowID: String
        var sentPrompts: [String]

        var route: String {
            "app://-/chatgpt/quick-chat/\(conversationID)"
        }
    }

    private var sessions: [String: Session] = [:]

    func startNewChat(prompt: String, sessionID: String) throws {
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).isEmpty == false else {
            throw ChatGPTDesktopControlError.desktopNotRunning
        }
        // Cmd-Option-N is ChatGPT's own Quick Chat command and creates a
        // normal ChatGPT-history conversation. The command is asynchronous,
        // so never paste immediately: first wait for a newly issued classic
        // Chat route, then retain that exact window and route.
        let existingRoutes = Set(try quickChatWindowRecords().map(\.route))
        try triggerQuickChat()
        var created: QuickChatWindowRecord?
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.1)
            let records = try quickChatWindowRecords()
            if let newRecord = records.first(where: {
                !existingRoutes.contains($0.route)
            }) {
                created = newRecord
                break
            }
            // A clean install has no Quick Chat before the shortcut. Accept
            // the first validated classic route once it appears.
            if existingRoutes.isEmpty, let first = records.first {
                created = first
                break
            }
        }
        guard let created,
              let conversationID = created.route
                .split(separator: "/")
                .last
                .map(String.init),
              !conversationID.isEmpty else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }
        var session = Session(
            conversationID: conversationID,
            windowID: created.windowID,
            sentPrompts: []
        )
        sessions[sessionID] = session
        do {
            try pasteAndSubmit(prompt, in: session)
            session.sentPrompts.append(prompt)
            sessions[sessionID] = session
        } catch {
            sessions.removeValue(forKey: sessionID)
            close(session)
            throw error
        }
    }

    private struct QuickChatWindowRecord {
        let windowID: String
        let route: String
    }

    private func triggerQuickChat() throws {
        guard AXIsProcessTrusted() else {
            throw ChatGPTDesktopControlError.accessibilityPermissionRequired
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else {
            throw ChatGPTDesktopControlError.desktopNotRunning
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let elements = accessibilityDescendants(
            of: applicationElement,
            maximumDepth: 32,
            maximumCount: 8_000
        )
        guard let quickChatButton = elements.first(where: { element in
            guard accessibilityString(element, attribute: kAXRoleAttribute) == kAXButtonRole else {
                return false
            }
            let marker = [
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
            ]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            return marker == "quick chat"
                || marker == "快速聊天"
                || marker == "快速对话"
        }) else {
            throw ChatGPTDesktopControlError.normalChatUnavailable
        }
        let frame = accessibilityFrame(quickChatButton)
        guard !frame.isNull, frame.width > 1, frame.height > 1 else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }
        application.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.2)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
        up.post(tap: .cghidEventTap)
    }

    private func quickChatWindowRecords() throws -> [QuickChatWindowRecord] {
        let fieldSeparator = "\u{1F}"
        let recordSeparator = "\u{1E}"
        let source = """
        tell application id "com.openai.codex"
            set output to ""
            repeat with candidateWindow in every window
                try
                    set candidateURL to URL of active tab of candidateWindow
                    if candidateURL contains "/chatgpt/quick-chat/" then
                        set output to output & (id of candidateWindow as text) & ASCII character 31 & candidateURL & ASCII character 30
                    end if
                end try
            end repeat
            return output
        end tell
        """
        let raw = try executeAppleScript(
            source,
            missingResult: "ChatGPT returned no Quick Chat window list",
            allowsMissingResult: true
        )
        return raw
            .components(separatedBy: recordSeparator)
            .compactMap { record in
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count == 2,
                      !fields[0].isEmpty,
                      fields[1].contains("/chatgpt/quick-chat/") else {
                    return nil
                }
                return QuickChatWindowRecord(windowID: fields[0], route: fields[1])
            }
    }

    /// Reads only the conversation rendered by the exact classic Chat window
    /// created for this companion session. It never falls back to the current
    /// Codex/Work window.
    func visibleTranscript(sessionID: String) throws -> [ChatMessage] {
        guard let session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        let window = try accessibilityWindow(for: session)
        let elements = accessibilityDescendants(of: window)
        let visibleTexts = accessibilityTranscriptTexts(in: elements)
        let generating = accessibilityShowsGenerating(in: elements)
        let records = accessibilityTranscript(
            visibleTexts: visibleTexts,
            sentPrompts: session.sentPrompts,
            isGenerating: generating
        )
        let now = Date()
        return records.enumerated().map { index, record in
            ChatMessage(
                id: "native-visible-\(index)-\(record.role.rawValue)",
                role: record.role,
                text: record.text,
                isStreaming: record.isStreaming,
                createdAt: now.addingTimeInterval(Double(index - records.count))
            )
        }
    }

    func sendFollowUp(_ prompt: String, sessionID: String) throws {
        guard var session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        try pasteAndSubmit(prompt, in: session)
        session.sentPrompts.append(prompt)
        sessions[sessionID] = session
    }

    private func accessibilityWindow(for session: Session) throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw ChatGPTDesktopControlError.accessibilityPermissionRequired
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else {
            throw ChatGPTDesktopControlError.desktopNotRunning
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = accessibilityElements(
            applicationElement,
            attribute: kAXWindowsAttribute
        )
        let routeFragment = "/chatgpt/quick-chat/\(session.conversationID)"
        if let exact = windows.first(where: { window in
            [
                accessibilityString(window, attribute: kAXDocumentAttribute),
                accessibilityString(window, attribute: kAXURLAttribute),
                accessibilityString(window, attribute: kAXIdentifierAttribute),
            ].contains { $0.contains(routeFragment) }
        }) {
            return exact
        }

        // Chromium does not expose AXDocument on every macOS release. The
        // scriptable window still exposes stable bounds and a title, allowing
        // us to map the exact isolated Chat window without focusing it.
        let metadata = try scriptableWindowMetadata(for: session)
        let titleMatches = windows.filter {
            accessibilityString($0, attribute: kAXTitleAttribute) == metadata.title
        }
        if titleMatches.count == 1, let only = titleMatches.first {
            return only
        }
        if let nearest = titleMatches.min(by: {
            accessibilityFrameDistance(accessibilityFrame($0), metadata.frame)
                < accessibilityFrameDistance(accessibilityFrame($1), metadata.frame)
        }), accessibilityFrameDistance(accessibilityFrame(nearest), metadata.frame) < 12 {
            return nearest
        }
        throw ChatGPTDesktopControlError.noOwningWindow
    }

    private struct ScriptableWindowMetadata {
        let title: String
        let frame: CGRect
    }

    private func scriptableWindowMetadata(for session: Session) throws -> ScriptableWindowMetadata {
        let separator = "\u{1E}"
        let source = """
        tell application id "com.openai.codex"
            set matches to every window whose id is \(Self.appleScriptLiteral(session.windowID))
            if (count of matches) is 0 then error "The ChatGPT Chat window is closed"
            set targetWindow to item 1 of matches
            set targetTab to active tab of targetWindow
            if URL of targetTab does not contain \(Self.appleScriptLiteral("/chatgpt/quick-chat/\(session.conversationID)")) then error "The ChatGPT Chat window changed"
            set windowBounds to bounds of targetWindow
            return (name of targetWindow as text) & ASCII character 30 & (item 1 of windowBounds as text) & ASCII character 30 & (item 2 of windowBounds as text) & ASCII character 30 & (item 3 of windowBounds as text) & ASCII character 30 & (item 4 of windowBounds as text)
        end tell
        """
        let raw = try executeAppleScript(source, missingResult: "ChatGPT returned no window details")
        let parts = raw.components(separatedBy: separator)
        guard parts.count == 5,
              let left = Double(parts[1]),
              let top = Double(parts[2]),
              let right = Double(parts[3]),
              let bottom = Double(parts[4]) else {
            throw ChatGPTDesktopControlError.appleEventFailed("ChatGPT returned invalid window details")
        }
        return ScriptableWindowMetadata(
            title: parts[0],
            frame: CGRect(x: left, y: top, width: right - left, height: bottom - top)
        )
    }

    private func accessibilityTranscriptTexts(in elements: [AXUIElement]) -> [String] {
        var texts: [String] = []
        for element in elements where
            accessibilityString(element, attribute: kAXRoleAttribute) == kAXStaticTextRole {
            let text = [
                accessibilityString(element, attribute: kAXValueAttribute),
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
            ].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, texts.last != cleaned else { continue }
            texts.append(cleaned)
        }
        return texts
    }

    private func accessibilityShowsGenerating(in elements: [AXUIElement]) -> Bool {
        elements.contains { element in
            let role = accessibilityString(element, attribute: kAXRoleAttribute)
            guard role == kAXButtonRole else { return false }
            let marker = [
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
                accessibilityString(element, attribute: kAXHelpAttribute),
                accessibilityString(element, attribute: kAXIdentifierAttribute),
            ].joined(separator: " ").lowercased()
            return marker.contains("stop generating")
                || marker.contains("stop streaming")
                || marker.contains("停止生成")
                || marker.contains("停止回复")
                || marker.contains("停止回答")
        }
    }

    private func accessibilityTranscript(
        visibleTexts: [String],
        sentPrompts: [String],
        isGenerating: Bool
    ) -> [NativeTranscriptRecord] {
        guard !sentPrompts.isEmpty else { return [] }
        let normalizedTexts = visibleTexts.map(Self.normalizedAccessibilityText)
        let normalizedPrompts = sentPrompts.map(Self.normalizedAccessibilityText)
        var promptLocations: [Int?] = Array(repeating: nil, count: sentPrompts.count)
        var searchStart = 0
        for promptIndex in sentPrompts.indices {
            guard let location = normalizedTexts[searchStart...].firstIndex(
                of: normalizedPrompts[promptIndex]
            ) else {
                continue
            }
            promptLocations[promptIndex] = location
            searchStart = location + 1
        }

        var records: [NativeTranscriptRecord] = []
        for promptIndex in sentPrompts.indices {
            records.append(
                NativeTranscriptRecord(
                    role: .user,
                    text: sentPrompts[promptIndex],
                    isStreaming: false
                )
            )
            guard let location = promptLocations[promptIndex] else { continue }
            let nextLocation = promptLocations[(promptIndex + 1)...].compactMap { $0 }.first
                ?? visibleTexts.endIndex
            guard location + 1 < nextLocation else { continue }
            var assistantParts: [String] = []
            for text in visibleTexts[(location + 1)..<nextLocation] {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Self.isChatChromeText(cleaned),
                      assistantParts.last != cleaned else {
                    continue
                }
                assistantParts.append(cleaned)
            }
            let assistantText = assistantParts.joined(separator: "\n\n")
            guard !assistantText.isEmpty else { continue }
            records.append(
                NativeTranscriptRecord(
                    role: .assistant,
                    text: assistantText,
                    isStreaming: isGenerating && promptIndex == sentPrompts.indices.last
                )
            )
        }
        return records
    }

    private static func normalizedAccessibilityText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isChatChromeText(_ value: String) -> Bool {
        let normalized = normalizedAccessibilityText(value).lowercased()
        return [
            "chatgpt",
            "ask chatgpt",
            "ask anything",
            "message chatgpt",
            "chatgpt can make mistakes. check important info.",
            "chatgpt 可能会犯错。请核查重要信息。",
            "auto",
        ].contains(normalized)
    }

    private func accessibilityDescendants(
        of root: AXUIElement,
        maximumDepth: Int = 32,
        maximumCount: Int = 8_000
    ) -> [AXUIElement] {
        var output: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var readIndex = 0
        while readIndex < queue.count, output.count < maximumCount {
            let (element, depth) = queue[readIndex]
            readIndex += 1
            guard depth < maximumDepth else { continue }
            let children = accessibilityElements(element, attribute: kAXChildrenAttribute)
            output.append(contentsOf: children.prefix(maximumCount - output.count))
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return output
    }

    private func accessibilityElements(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else {
            return ""
        }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return .null
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeDowncast(positionValue, to: AXValue.self),
            .cgPoint,
            &point
        ),
        AXValueGetValue(
            unsafeDowncast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else {
            return .null
        }
        return CGRect(origin: point, size: size)
    }

    private func accessibilityFrameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        guard !lhs.isNull, !rhs.isNull else { return .greatestFiniteMagnitude }
        return abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func pasteAndSubmit(_ prompt: String, in session: Session) throws {
        // `keystroke <Unicode text>` goes through the selected input method.
        // With Chinese/Scribble input that can commit a phonetic fallback
        // (for example "啊啊啊"). Paste the exact UTF-8 string into the
        // already-validated classic Chat window instead.
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems
        pasteboard.clearContents()
        guard pasteboard.setString(prompt, forType: .string) else {
            throw ChatGPTDesktopControlError.appleEventFailed("could not prepare the ChatGPT message")
        }
        let bridgePasteboardChange = pasteboard.changeCount
        defer {
            // Never restore over something the user copied while the command
            // was opening. If the pasteboard is still ours, give their prior
            // clipboard contents back after the paste has completed.
            if pasteboard.changeCount == bridgePasteboardChange {
                pasteboard.clearContents()
                if let previousItems, !previousItems.isEmpty {
                    pasteboard.writeObjects(previousItems)
                }
            }
        }
        let source = """
        tell application id "com.openai.codex"
            set matches to every window whose id is \(Self.appleScriptLiteral(session.windowID))
            if (count of matches) is 0 then error "The ChatGPT Chat window is closed"
            set targetWindow to item 1 of matches
            set targetTab to active tab of targetWindow
            if URL of targetTab does not contain \(Self.appleScriptLiteral("/chatgpt/quick-chat/\(session.conversationID)")) then error "The ChatGPT Chat window changed"
            set minimized of targetWindow to false
            set visible of targetWindow to true
            set index of targetWindow to 1
            activate
            delay 0.2
            paste selection targetTab
        end tell
        delay 0.15
        tell application "System Events"
            tell process "ChatGPT"
                set frontmost to true
                key code 36
            end tell
        end tell
        """
        _ = try executeAppleScript(source, missingResult: "could not submit the ChatGPT message", allowsMissingResult: true)
    }

    private func executeAppleScript(
        _ source: String,
        missingResult: String,
        allowsMissingResult: Bool = false
    ) throws -> String {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ChatGPTDesktopControlError.appleEventFailed(missingResult)
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let detail = errorInfo?[NSAppleScript.errorMessage] as? String {
            throw controlError(forAppleEventDetail: detail)
        }
        if let value = result.stringValue {
            return value
        }
        if allowsMissingResult { return "" }
        throw ChatGPTDesktopControlError.appleEventFailed(missingResult)
    }

    private func close(_ session: Session) {
        let source = """
        tell application id "com.openai.codex"
            set matches to every window whose id is \(Self.appleScriptLiteral(session.windowID))
            if (count of matches) is greater than 0 then close item 1 of matches
        end tell
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    private struct NativeTranscriptRecord {
        let role: ChatMessage.Role
        let text: String
        let isStreaming: Bool
    }

    /// Do not preflight Accessibility with `AXIsProcessTrusted`: a freshly
    /// approved Debug build can briefly be reported as untrusted even though
    /// System Events is already allowed to type.  Let macOS evaluate the
    /// exact action, then translate a real denial into a helpful error.
    private func controlError(forAppleEventDetail detail: String) -> ChatGPTDesktopControlError {
        let normalized = detail.lowercased()
        let accessibilityDenied = [
            "not allowed to send keystrokes",
            "not authorised to send keystrokes",
            "not authorized to send keystrokes",
            "accessibility"
        ].contains { normalized.contains($0) }
        if accessibilityDenied { return .accessibilityPermissionRequired }
        return .appleEventFailed(detail)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

/// Fallback for normal Chat when the fused desktop app does not expose its
/// Quick Chat feature. It owns a dedicated `chatgpt.com` tab in Chrome and
/// never touches the desktop app's Work/Codex surface.
@MainActor
final class ChatGPTLegacyWebChatController {
    private static let chromeBundleID = "com.google.Chrome"
    private static let chatURL = "https://chatgpt.com/"
    private static let persistedSessionsKey = "CodexWatch.webChatSessions"

    private struct Session: Codable {
        let windowID: String
        let tabID: String
        var sentPrompts: [String]
    }

    private struct WindowMetadata {
        let title: String
        let frame: CGRect
    }

    private struct TranscriptRecord {
        let role: ChatMessage.Role
        let text: String
        let isStreaming: Bool
    }

    private var sessions: [String: Session] = [:]

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSessionsKey),
              let decoded = try? JSONDecoder().decode([String: Session].self, from: data) else {
            return
        }
        sessions = decoded
    }

    func hasSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    func startNewChat(prompt: String, sessionID: String) throws {
        guard chromeApplication != nil else {
            throw ChatGPTDesktopControlError.webChatBrowserNotRunning
        }
        guard AXIsProcessTrusted() else {
            throw ChatGPTDesktopControlError.accessibilityPermissionRequired
        }

        var session = try openNewChatTab()
        do {
            try waitForChatPage(session)
            let window = try accessibilityWindow(for: session, activate: true)
            guard !hasSignInPrompt(in: accessibilityDescendants(of: window)) else {
                throw ChatGPTDesktopControlError.webChatSignInRequired
            }
            try pasteAndSubmit(prompt, in: session, window: window)
            session.sentPrompts.append(prompt)
            sessions[sessionID] = session
            persistSessions()
        } catch {
            close(session)
            sessions.removeValue(forKey: sessionID)
            persistSessions()
            throw error
        }
    }

    func sendFollowUp(_ prompt: String, sessionID: String) throws {
        guard var session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        let window = try accessibilityWindow(for: session, activate: true)
        try pasteAndSubmit(prompt, in: session, window: window)
        session.sentPrompts.append(prompt)
        sessions[sessionID] = session
        persistSessions()
    }

    /// Reading a reply does not activate Chrome. The tab can be selected in
    /// its own background window, leaving the person's current app focused.
    func visibleTranscript(sessionID: String) throws -> [ChatMessage] {
        guard let session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        let window = try accessibilityWindow(for: session, activate: false)
        let elements = accessibilityDescendants(of: window)
        let records = transcript(
            visibleTexts: transcriptTexts(in: elements),
            sentPrompts: session.sentPrompts,
            isGenerating: showsGenerating(in: elements)
        )
        let now = Date()
        return records.enumerated().map { index, record in
            ChatMessage(
                id: "web-visible-\(index)-\(record.role.rawValue)",
                role: record.role,
                text: record.text,
                isStreaming: record.isStreaming,
                createdAt: now.addingTimeInterval(Double(index - records.count))
            )
        }
    }

    private var chromeApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.chromeBundleID
        ).first
    }

    private func openNewChatTab() throws -> Session {
        let separator = "\u{1E}"
        let source = """
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then make new window
            set targetWindow to front window
            set targetTab to make new tab at end of tabs of targetWindow with properties {URL:\(Self.appleScriptLiteral(Self.chatURL))}
            set active tab index of targetWindow to index of targetTab
            set index of targetWindow to 1
            activate
            return (id of targetWindow as text) & ASCII character 30 & (id of targetTab as text)
        end tell
        """
        let raw = try executeAppleScript(source, missingResult: "could not open ChatGPT in Chrome")
        let parts = raw.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ChatGPTDesktopControlError.targetDidNotOpen
        }
        return Session(windowID: parts[0], tabID: parts[1], sentPrompts: [])
    }

    private func waitForChatPage(_ session: Session) throws {
        for _ in 0..<100 {
            let state = try selectedTabState(for: session, activate: false)
            if state.url.hasPrefix(Self.chatURL), !state.loading { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ChatGPTDesktopControlError.targetDidNotOpen
    }

    private func accessibilityWindow(for session: Session, activate: Bool) throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw ChatGPTDesktopControlError.accessibilityPermissionRequired
        }
        guard let application = chromeApplication else {
            throw ChatGPTDesktopControlError.webChatBrowserNotRunning
        }
        let metadata = try windowMetadata(for: session, activate: activate)
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = accessibilityElements(applicationElement, attribute: kAXWindowsAttribute)
        let titleMatches = windows.filter {
            accessibilityString($0, attribute: kAXTitleAttribute) == metadata.title
        }
        if titleMatches.count == 1, let only = titleMatches.first { return only }
        if let nearest = titleMatches.min(by: {
            frameDistance(accessibilityFrame($0), metadata.frame)
                < frameDistance(accessibilityFrame($1), metadata.frame)
        }), frameDistance(accessibilityFrame(nearest), metadata.frame) < 12 {
            return nearest
        }
        throw ChatGPTDesktopControlError.noOwningWindow
    }

    private func windowMetadata(for session: Session, activate: Bool) throws -> WindowMetadata {
        let separator = "\u{1E}"
        let activation = activate ? "set index of targetWindow to 1\n            activate" : ""
        let source = """
        tell application id "com.google.Chrome"
            set windowMatches to every window whose id is \(Self.appleScriptLiteral(session.windowID))
            if (count of windowMatches) is 0 then error "The ChatGPT browser window is closed"
            set targetWindow to item 1 of windowMatches
            set tabIndex to 0
            repeat with indexValue from 1 to count of tabs of targetWindow
                if (id of tab indexValue of targetWindow as text) is \(Self.appleScriptLiteral(session.tabID)) then
                    set tabIndex to indexValue
                    exit repeat
                end if
            end repeat
            if tabIndex is 0 then error "The ChatGPT browser tab is closed"
            set active tab index of targetWindow to tabIndex
            \(activation)
            set windowBounds to bounds of targetWindow
            return (name of targetWindow as text) & ASCII character 30 & (item 1 of windowBounds as text) & ASCII character 30 & (item 2 of windowBounds as text) & ASCII character 30 & (item 3 of windowBounds as text) & ASCII character 30 & (item 4 of windowBounds as text)
        end tell
        """
        let raw = try executeAppleScript(source, missingResult: "Chrome returned no window details")
        let parts = raw.components(separatedBy: separator)
        guard parts.count == 5,
              let left = Double(parts[1]), let top = Double(parts[2]),
              let right = Double(parts[3]), let bottom = Double(parts[4]) else {
            throw ChatGPTDesktopControlError.appleEventFailed("Chrome returned invalid window details")
        }
        return WindowMetadata(
            title: parts[0],
            frame: CGRect(x: left, y: top, width: right - left, height: bottom - top)
        )
    }

    private func selectedTabState(for session: Session, activate: Bool) throws -> (url: String, loading: Bool) {
        let activation = activate ? "set index of targetWindow to 1\n            activate" : ""
        let source = """
        tell application id "com.google.Chrome"
            set windowMatches to every window whose id is \(Self.appleScriptLiteral(session.windowID))
            if (count of windowMatches) is 0 then error "The ChatGPT browser window is closed"
            set targetWindow to item 1 of windowMatches
            set tabIndex to 0
            repeat with indexValue from 1 to count of tabs of targetWindow
                if (id of tab indexValue of targetWindow as text) is \(Self.appleScriptLiteral(session.tabID)) then
                    set tabIndex to indexValue
                    exit repeat
                end if
            end repeat
            if tabIndex is 0 then error "The ChatGPT browser tab is closed"
            set active tab index of targetWindow to tabIndex
            \(activation)
            set targetTab to active tab of targetWindow
            return (URL of targetTab as text) & ASCII character 30 & (loading of targetTab as text)
        end tell
        """
        let raw = try executeAppleScript(source, missingResult: "Chrome returned no ChatGPT tab state")
        let parts = raw.components(separatedBy: "\u{1E}")
        guard parts.count == 2 else { throw ChatGPTDesktopControlError.targetDidNotOpen }
        return (parts[0], parts[1].lowercased() == "true")
    }

    private func pasteAndSubmit(_ prompt: String, in session: Session, window: AXUIElement) throws {
        guard let editor = composer(in: window) else {
            let elements = accessibilityDescendants(of: window)
            if hasSignInPrompt(in: elements) { throw ChatGPTDesktopControlError.webChatSignInRequired }
            throw ChatGPTDesktopControlError.composerUnavailable
        }
        let frame = accessibilityFrame(editor)
        guard !frame.isNull, frame.width > 20, frame.height > 10 else {
            throw ChatGPTDesktopControlError.composerUnavailable
        }
        _ = try selectedTabState(for: session, activate: true)
        click(frame: frame)
        Thread.sleep(forTimeInterval: 0.08)
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems
        pasteboard.clearContents()
        guard pasteboard.setString(prompt, forType: .string) else {
            throw ChatGPTDesktopControlError.appleEventFailed("could not prepare the ChatGPT message")
        }
        let changeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
                if let previousItems, !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }

        postKey(code: 9, flags: .maskCommand) // V
        Thread.sleep(forTimeInterval: 0.08)
        postKey(code: 36) // Return
    }

    private func composer(in window: AXUIElement) -> AXUIElement? {
        let candidates = accessibilityDescendants(of: window).filter { element in
            let role = accessibilityString(element, attribute: kAXRoleAttribute)
            guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return false }
            let frame = accessibilityFrame(element)
            return !frame.isNull && frame.width > 160 && frame.height > 18
        }
        return candidates.max { accessibilityFrame($0).maxY < accessibilityFrame($1).maxY }
    }

    private func hasSignInPrompt(in elements: [AXUIElement]) -> Bool {
        let signInMarkers: Set<String> = [
            "log in", "login", "sign in", "connexion", "se connecter",
            "登录", "登入", "注册", "sign up", "s’inscrire", "s'inscrire"
        ]
        return elements.contains { element in
            let role = accessibilityString(element, attribute: kAXRoleAttribute)
            guard role == kAXButtonRole || role == "AXLink" else { return false }
            let marker = [
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
                accessibilityString(element, attribute: kAXValueAttribute),
            ]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            return signInMarkers.contains(marker)
        }
    }

    private func transcriptTexts(in elements: [AXUIElement]) -> [String] {
        var texts: [String] = []
        for element in elements where accessibilityString(element, attribute: kAXRoleAttribute) == kAXStaticTextRole {
            let text = [
                accessibilityString(element, attribute: kAXValueAttribute),
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
            ].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, texts.last != cleaned else { continue }
            texts.append(cleaned)
        }
        return texts
    }

    private func showsGenerating(in elements: [AXUIElement]) -> Bool {
        elements.contains { element in
            guard accessibilityString(element, attribute: kAXRoleAttribute) == kAXButtonRole else { return false }
            let marker = [
                accessibilityString(element, attribute: kAXTitleAttribute),
                accessibilityString(element, attribute: kAXDescriptionAttribute),
                accessibilityString(element, attribute: kAXHelpAttribute),
            ].joined(separator: " ").lowercased()
            return marker.contains("stop generating")
                || marker.contains("stop streaming")
                || marker.contains("arrêter la génération")
                || marker.contains("停止生成")
                || marker.contains("停止回复")
        }
    }

    private func transcript(
        visibleTexts: [String],
        sentPrompts: [String],
        isGenerating: Bool
    ) -> [TranscriptRecord] {
        guard !sentPrompts.isEmpty else { return [] }
        let normalizedTexts = visibleTexts.map(Self.normalize)
        let normalizedPrompts = sentPrompts.map(Self.normalize)
        var locations: [Int?] = Array(repeating: nil, count: sentPrompts.count)
        var start = 0
        for index in sentPrompts.indices {
            guard start < normalizedTexts.endIndex,
                  let location = normalizedTexts[start...].firstIndex(of: normalizedPrompts[index]) else { continue }
            locations[index] = location
            start = location + 1
        }
        var records: [TranscriptRecord] = []
        for index in sentPrompts.indices {
            records.append(TranscriptRecord(role: .user, text: sentPrompts[index], isStreaming: false))
            guard let location = locations[index] else { continue }
            let next = locations[(index + 1)...].compactMap { $0 }.first ?? visibleTexts.endIndex
            guard location + 1 < next else { continue }
            let reply = visibleTexts[(location + 1)..<next]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !Self.isChromeText($0) }
                .reduce(into: [String]()) { parts, text in if parts.last != text { parts.append(text) } }
                .joined(separator: "\n\n")
            guard !reply.isEmpty else { continue }
            records.append(TranscriptRecord(
                role: .assistant,
                text: reply,
                isStreaming: isGenerating && index == sentPrompts.indices.last
            ))
        }
        return records
    }

    private func accessibilityDescendants(
        of root: AXUIElement,
        maximumDepth: Int = 32,
        maximumCount: Int = 8_000
    ) -> [AXUIElement] {
        var output: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var readIndex = 0
        while readIndex < queue.count, output.count < maximumCount {
            let (element, depth) = queue[readIndex]
            readIndex += 1
            guard depth < maximumDepth else { continue }
            let children = accessibilityElements(element, attribute: kAXChildrenAttribute)
            output.append(contentsOf: children.prefix(maximumCount - output.count))
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return output
    }

    private func accessibilityElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let values = value as? [AXUIElement] else { return [] }
        return values
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return "" }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return .null }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return .null }
        return CGRect(origin: point, size: size)
    }

    private func click(frame: CGRect) {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        up?.post(tap: .cghidEventTap)
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        guard !lhs.isNull, !rhs.isNull else { return .greatestFiniteMagnitude }
        return abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func executeAppleScript(_ source: String, missingResult: String) throws -> String {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ChatGPTDesktopControlError.appleEventFailed(missingResult)
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let detail = errorInfo?[NSAppleScript.errorMessage] as? String {
            if detail.lowercased().contains("not allowed") {
                throw ChatGPTDesktopControlError.accessibilityPermissionRequired
            }
            throw ChatGPTDesktopControlError.appleEventFailed(detail)
        }
        guard let value = result.stringValue else {
            throw ChatGPTDesktopControlError.appleEventFailed(missingResult)
        }
        return value
    }

    private func close(_ session: Session) {
        let source = """
        tell application id "com.google.Chrome"
            repeat with candidateWindow in every window
                repeat with candidateTab in every tab of candidateWindow
                    if (id of candidateTab as text) is \(Self.appleScriptLiteral(session.tabID)) then close candidateTab
                end repeat
            end repeat
        end tell
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    private func persistSessions() {
        // Retaining a compact mapping makes a relaunched Agent Bridge able to
        // keep reading an already-open ChatGPT browser tab. Keep only recent
        // conversations so a long-running relay never grows preferences.
        let retained = Dictionary(uniqueKeysWithValues: sessions.sorted { $0.key < $1.key }.suffix(100))
        sessions = retained
        guard let data = try? JSONEncoder().encode(retained) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedSessionsKey)
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isChromeText(_ value: String) -> Bool {
        let normalized = normalize(value).lowercased()
        return [
            "chatgpt", "ask chatgpt", "ask anything", "message chatgpt",
            "converser avec chatgpt", "chatgpt peut faire des erreurs. vérifiez les informations importantes.",
            "chatgpt 可能会犯错。请核查重要信息。", "auto"
        ].contains(normalized)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

private struct ChromeRelayCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case newChat
        case followUp
    }

    let id: String
    let sessionID: String
    let action: Action
    let prompt: String
    let createdAt: Date
}

private struct ChromeRelayMessage: Codable, Sendable {
    let role: String
    let text: String
    let isStreaming: Bool
}

private struct ChromeRelayEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heartbeat
        case accepted
        case transcript
        case error
    }

    let kind: Kind
    let sessionID: String?
    let commandID: String?
    let messages: [ChromeRelayMessage]?
    let message: String?
}

/// A loopback-only transport between Agent Bridge and the companion Chrome
/// extension. The browser never receives the Cloudflare relay secret and the
/// web page never receives this local key. Commands remain queued until the
/// extension confirms that the exact prompt appeared in ChatGPT's DOM.
private final class ChromeRelayLoopbackServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = 39_847
    static let accessKey = "b2c547cbf20e4f1a922784b8ff63f0f02c89e7cd31b6408da78c77120f5218c8"

    private let queue = DispatchQueue(label: "com.sunzizai.codexwatch.chrome-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var commands: [String: ChromeRelayCommand] = [:]
    private var commandOrder: [String] = []
    private var eventHandler: (@Sendable (ChromeRelayEvent) -> Void)?

    func start() throws {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: Self.port
        )
        let newListener = try NWListener(using: parameters, on: Self.port)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.lock.lock()
                self?.listener = nil
                self?.lock.unlock()
            }
        }
        lock.lock()
        listener = newListener
        lock.unlock()
        newListener.start(queue: queue)
    }

    func setEventHandler(_ handler: @escaping @Sendable (ChromeRelayEvent) -> Void) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func enqueue(_ command: ChromeRelayCommand) {
        lock.lock()
        if commands[command.id] == nil {
            commands[command.id] = command
            commandOrder.append(command.id)
        }
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var data = accumulated
            if let chunk { data.append(chunk) }
            if let request = self.parseRequest(data) {
                self.handle(request, on: connection)
                return
            }
            if isComplete || error != nil || data.count > 256 * 1_024 {
                self.respond(status: 400, body: Data(), on: connection)
                return
            }
            self.receive(on: connection, accumulated: data)
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
              ) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1].components(separatedBy: "?").first ?? requestParts[1],
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            respond(status: 204, body: Data(), on: connection)
            return
        }
        guard request.headers["x-codex-extension-key"] == Self.accessKey else {
            respond(status: 401, body: Data(), on: connection)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/command"):
            guard let command = nextCommand(),
                  let body = try? CodexWatchCoding.makeEncoder().encode(command) else {
                respond(status: 204, body: Data(), on: connection)
                return
            }
            respond(status: 200, body: body, on: connection)

        case ("POST", "/v1/event"):
            guard let event = try? CodexWatchCoding.makeDecoder().decode(
                ChromeRelayEvent.self,
                from: request.body
            ) else {
                respond(status: 400, body: Data(), on: connection)
                return
            }
            if event.kind == .accepted || event.kind == .error,
               let commandID = event.commandID {
                complete(commandID)
            }
            lock.lock()
            let handler = eventHandler
            lock.unlock()
            handler?(event)
            respond(status: 204, body: Data(), on: connection)

        default:
            respond(status: 404, body: Data(), on: connection)
        }
    }

    private func nextCommand() -> ChromeRelayCommand? {
        lock.lock()
        defer { lock.unlock() }
        commandOrder.removeAll { commands[$0] == nil }
        guard let id = commandOrder.first else { return nil }
        return commands[id]
    }

    private func complete(_ id: String) {
        lock.lock()
        commands.removeValue(forKey: id)
        commandOrder.removeAll { $0 == id }
        lock.unlock()
    }

    private func respond(status: Int, body: Data, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        default: reason = "Not Found"
        }
        var response = Data(
            """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: application/json; charset=utf-8\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r
            """.utf8
        )
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Normal ChatGPT Chat implementation backed by the companion Chrome
/// extension. It exposes the same small interface as the previous automation
/// controller so the iPhone/Watch projection remains unchanged.
@MainActor
final class ChatGPTWebChatController {
    private static let persistedSessionsKey = "CodexWatch.extensionChatSessions.v1"

    private struct Session: Codable {
        var sentPrompts: [String]
        var messages: [ChatMessage]
        var lastError: String?
    }

    private let server: ChromeRelayLoopbackServer
    private var sessions: [String: Session] = [:]
    private var startupError: Error?

    init() {
        let localServer = ChromeRelayLoopbackServer()
        server = localServer
        if let data = UserDefaults.standard.data(forKey: Self.persistedSessionsKey),
           let decoded = try? JSONDecoder().decode([String: Session].self, from: data) {
            sessions = decoded
        }
        do {
            try localServer.start()
        } catch {
            startupError = error
        }
        localServer.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func hasSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    func startNewChat(prompt: String, sessionID: String) throws {
        if let startupError { throw startupError }
        try wakeChrome()
        let userMessage = ChatMessage(
            id: "extension-user-\(UUID().uuidString)",
            role: .user,
            text: prompt
        )
        sessions[sessionID] = Session(
            sentPrompts: [prompt],
            messages: [userMessage],
            lastError: nil
        )
        persistSessions()
        server.enqueue(ChromeRelayCommand(
            id: UUID().uuidString,
            sessionID: sessionID,
            action: .newChat,
            prompt: prompt,
            createdAt: Date()
        ))
    }

    func sendFollowUp(_ prompt: String, sessionID: String) throws {
        if let startupError { throw startupError }
        guard var session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        try wakeChrome()
        session.sentPrompts.append(prompt)
        session.messages.append(ChatMessage(
            id: "extension-user-\(UUID().uuidString)",
            role: .user,
            text: prompt
        ))
        session.lastError = nil
        sessions[sessionID] = session
        persistSessions()
        server.enqueue(ChromeRelayCommand(
            id: UUID().uuidString,
            sessionID: sessionID,
            action: .followUp,
            prompt: prompt,
            createdAt: Date()
        ))
    }

    func visibleTranscript(sessionID: String) throws -> [ChatMessage] {
        guard let session = sessions[sessionID] else {
            throw ChatGPTDesktopControlError.noOwningWindow
        }
        if let lastError = session.lastError {
            throw ChatGPTDesktopControlError.appleEventFailed(lastError)
        }
        return session.messages
    }

    private func handle(_ event: ChromeRelayEvent) {
        guard let sessionID = event.sessionID,
              var session = sessions[sessionID] else { return }
        switch event.kind {
        case .heartbeat, .accepted:
            return
        case .transcript:
            guard let incoming = event.messages, !incoming.isEmpty else { return }
            let now = Date()
            session.messages = incoming.enumerated().compactMap { index, message in
                guard let role = ChatMessage.Role(rawValue: message.role) else { return nil }
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return ChatMessage(
                    id: "extension-\(sessionID)-\(index)-\(role.rawValue)",
                    role: role,
                    text: text,
                    isStreaming: message.isStreaming,
                    createdAt: now.addingTimeInterval(Double(index - incoming.count))
                )
            }
            session.lastError = nil
        case .error:
            session.lastError = event.message ?? "The ChatGPT Chrome extension reported an error"
        }
        sessions[sessionID] = session
        persistSessions()
    }

    private func wakeChrome() throws {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        ) else {
            throw ChatGPTDesktopControlError.webChatBrowserNotRunning
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(
            [URL(string: "https://chatgpt.com/")!],
            withApplicationAt: chromeURL,
            configuration: configuration
        )
    }

    private func persistSessions() {
        let retained = Dictionary(
            uniqueKeysWithValues: sessions.sorted { $0.key < $1.key }.suffix(100)
        )
        sessions = retained
        guard let data = try? JSONEncoder().encode(retained) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedSessionsKey)
    }
}

private final class UnixFramedConnection {
    private static let maximumOutgoingFrameBytes = 16 * 1_024 * 1_024
    private static let maximumIncomingFrameBytes = 64 * 1_024 * 1_024
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ChatGPTDesktopControlError.connectionFailed(Self.lastError())
        }

        // A desktop update/disconnect can close the router between read and
        // write. Turn that race into a recoverable EPIPE rather than letting
        // SIGPIPE terminate the entire menu-bar bridge.
        var noSigPipe: Int32 = 1
        let signalStatus = withUnsafePointer(to: &noSigPipe) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        guard signalStatus == 0 else {
            let detail = Self.lastError()
            close()
            throw ChatGPTDesktopControlError.connectionFailed(detail)
        }

        var timeout = timeval(tv_sec: 35, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close()
            throw ChatGPTDesktopControlError.connectionFailed("socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { source in
                    _ = strlcpy(destination, source, capacity)
                }
            }
        }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let detail = Self.lastError()
            close()
            throw ChatGPTDesktopControlError.connectionFailed(detail)
        }
    }

    func request(_ message: [String: Any], requestID: String) throws -> [String: Any] {
        try send(message)

        while true {
            let response = try readMessage()
            if response["type"] as? String == "response",
               response["requestId"] as? String == requestID {
                return response
            }
        }
    }

    func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= Self.maximumOutgoingFrameBytes else {
            throw ChatGPTDesktopControlError.protocolError("message is too large")
        }

        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        try writeAll(frame)
    }

    func nextMessage() throws -> [String: Any] {
        try readMessage(allowIdleTimeout: true)
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }

    private func readMessage(allowIdleTimeout: Bool = false) throws -> [String: Any] {
        let header = try readExactly(4, allowIdleTimeout: allowIdleTimeout)
        let bytes = [UInt8](header)
        let length = Int(
            UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
        )
        guard length > 0, length <= Self.maximumIncomingFrameBytes else {
            throw ChatGPTDesktopControlError.protocolError(
                "invalid frame length: \(length) bytes"
            )
        }
        let body = try readExactly(length, allowIdleTimeout: allowIdleTimeout)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ChatGPTDesktopControlError.protocolError("invalid JSON frame")
        }
        return object
    }

    private func readExactly(_ count: Int, allowIdleTimeout: Bool) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < count {
                let readCount = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if readCount > 0 {
                    offset += readCount
                } else if readCount == 0 {
                    throw ChatGPTDesktopControlError.connectionFailed("connection closed")
                } else if allowIdleTimeout, errno == EAGAIN || errno == EWOULDBLOCK {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                } else if errno != EINTR {
                    throw ChatGPTDesktopControlError.connectionFailed(Self.lastError())
                }
            }
        }
        return result
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    throw ChatGPTDesktopControlError.connectionFailed("connection closed")
                } else if written < 0, errno != EINTR {
                    throw ChatGPTDesktopControlError.connectionFailed(Self.lastError())
                }
            }
        }
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}
