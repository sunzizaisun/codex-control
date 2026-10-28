import CryptoKit
import Foundation
import CodexWatchCore

public enum ApprovalBrokerError: LocalizedError, Sendable {
    case unsupportedRequest
    case requestNotFound
    case requestExpired
    case requestChanged
    case decisionNotAllowed

    public var errorDescription: String? {
        switch self {
        case .unsupportedRequest: AppLocalizer.text("这个 Codex 请求无法通过 Apple Watch 批准。")
        case .requestNotFound: AppLocalizer.text("审批请求已不再等待处理。")
        case .requestExpired: AppLocalizer.text("审批请求已过期。")
        case .requestChanged: AppLocalizer.text("审批内容已经变化，请重新检查。")
        case .decisionNotAllowed: AppLocalizer.text("Codex 没有提供这个审批选项。")
        }
    }
}

public actor ApprovalBroker {
    public typealias ResponseSender = @Sendable (AppServerRequestID, JSONValue) async throws -> Void

    private struct Pending: Sendable {
        let rpcRequestID: AppServerRequestID
        let method: String
        let rawParams: JSONValue
        let request: ApprovalRequest
        let allowedChoices: Set<ApprovalChoice>
        let externalKey: String?
        let responseSender: ResponseSender
    }

    private let store: CodexSnapshotStore
    private let responseSender: ResponseSender
    private var pendingByPublicID: [String: Pending] = [:]
    private var publicIDByRPCID: [AppServerRequestID: String] = [:]
    private var publicIDByExternalKey: [String: String] = [:]
    private var consumedDecisionIDs: Set<String> = []
    private var submittingRequestIDs: Set<String> = []
    private static let approvalLifetime: TimeInterval = 15 * 60

    public init(store: CodexSnapshotStore, responseSender: @escaping ResponseSender) {
        self.store = store
        self.responseSender = responseSender
    }

    @discardableResult
    public func register(_ event: AppServerEvent, now: Date = Date()) async throws -> ApprovalRequest {
        return try await register(
            event,
            externalKey: nil,
            responseSender: responseSender,
            now: now
        )
    }

    /// Registers an approval observed through a trusted external transport,
    /// such as ChatGPT Desktop's task-follower stream. The transport supplies
    /// its own response sender while the broker keeps the same digest, nonce,
    /// expiration, and one-shot validation used for app-server approvals.
    @discardableResult
    public func registerExternal(
        _ event: AppServerEvent,
        externalKey: String,
        responseSender: @escaping ResponseSender,
        now: Date = Date()
    ) async throws -> ApprovalRequest {
        return try await register(
            event,
            externalKey: externalKey,
            responseSender: responseSender,
            now: now
        )
    }

    private func register(
        _ event: AppServerEvent,
        externalKey: String?,
        responseSender: @escaping ResponseSender,
        now: Date
    ) async throws -> ApprovalRequest {
        guard let rpcRequestID = event.requestID,
              let threadID = event.params["threadId"]?.stringValue,
              Self.isSupported(event) else {
            throw ApprovalBrokerError.unsupportedRequest
        }

        let previousID: String?
        if let externalKey {
            previousID = publicIDByExternalKey[externalKey]
        } else {
            previousID = publicIDByRPCID[rpcRequestID]
        }
        let previous = previousID.flatMap { pendingByPublicID[$0] }
        if let previous, previous.method == event.method, previous.rawParams == event.params {
            return previous.request
        }

        let publicID = UUID().uuidString
        let itemID = event.params["itemId"]?.stringValue ?? "unknown-item"
        let turnID = event.params["turnId"]?.stringValue ?? "unknown-turn"
        let command = event.params["command"]?.stringValue
        let cwd = event.params["cwd"]?.stringValue
        let paths = Self.requestedPaths(from: event.params)
        let questions = Self.isUserInput(event.method) ? try UserInputValidation.questions(from: event.params) : nil
        let requestsNetwork = event.params["permissions"]?["network"]?["enabled"]?.boolValue
            ?? event.params["additionalPermissions"]?["network"]?["enabled"]?.boolValue
            ?? (event.params["networkApprovalContext"] != nil)

        let digest = Self.digest(
            method: event.method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            command: command,
            cwd: cwd,
            paths: paths,
            requestsNetwork: requestsNetwork,
            rawParams: event.params
        )
        let presentation = Self.presentation(for: event.method, params: event.params)
        let request = ApprovalRequest(
            id: publicID,
            taskID: threadID,
            kind: presentation.kind,
            title: presentation.title,
            summary: presentation.summary,
            command: command,
            workingDirectory: cwd,
            requestedPaths: paths,
            requestsNetwork: requestsNetwork,
            createdAt: now,
            expiresAt: now.addingTimeInterval(min(Self.approvalLifetime,
                Self.isUserInput(event.method) ? (event.params["autoResolutionMs"]?.doubleValue.map { max(0, $0 / 1000) } ?? Self.approvalLifetime) : Self.approvalLifetime)),
            nonce: UUID().uuidString,
            requestDigest: digest,
            questions: questions,
            isBlocking: questions != nil ? event.params["isBlocking"]?.boolValue : nil
        )

        let pending = Pending(
            rpcRequestID: rpcRequestID,
            method: event.method,
            rawParams: event.params,
            request: request,
            allowedChoices: Self.allowedChoices(for: event),
            externalKey: externalKey,
            responseSender: responseSender
        )
        // Invalidate the old decision and install its replacement without
        // suspending this actor. Awaiting store removal between these steps
        // lets concurrent registrations create two approvable public IDs.
        if let previous { removeFromIndex(previous) }
        pendingByPublicID[publicID] = pending
        if let externalKey {
            publicIDByExternalKey[externalKey] = publicID
        } else {
            publicIDByRPCID[rpcRequestID] = publicID
        }
        if let previous { await store.removeApproval(id: previous.request.id) }
        // The store is a separate actor. A newer registration or resolution
        // may supersede this one while either projection update is suspended.
        guard pendingByPublicID[publicID] != nil else { return request }
        await store.addApproval(request)
        if pendingByPublicID[publicID] == nil {
            await store.removeApproval(id: publicID)
        }
        return request
    }

    public func submit(_ decision: ApprovalDecision, now: Date = Date()) async throws {
        guard !consumedDecisionIDs.contains(decision.id) else { return }
        guard let pending = pendingByPublicID[decision.requestID] else {
            throw ApprovalBrokerError.requestNotFound
        }
        guard pending.request.expiresAt > now else {
            await remove(pending)
            throw ApprovalBrokerError.requestExpired
        }
        guard decision.requestDigest == pending.request.requestDigest,
              decision.nonce == pending.request.nonce else {
            throw ApprovalBrokerError.requestChanged
        }
        guard pending.allowedChoices.contains(decision.choice) else {
            throw ApprovalBrokerError.decisionNotAllowed
        }

        let result: JSONValue
        if let questions = pending.request.questions {
            guard decision.choice == .allowOnce, let answers = decision.answers else { throw UserInputValidation.Failure.invalidAnswers }
            try UserInputValidation.validate(answers, questions: questions)
            result = .object(["answers": .object(answers.mapValues { .object(["answers": .array($0.map(JSONValue.string))]) })])
        } else {
            guard decision.answers == nil else { throw ApprovalBrokerError.decisionNotAllowed }
            result = Self.response(for: pending.method, choice: decision.choice, params: pending.rawParams)
        }
        // Different devices may decide concurrently with different envelope
        // IDs. Never send two responses to the same one-shot server request.
        guard submittingRequestIDs.insert(decision.requestID).inserted else {
            throw ApprovalBrokerError.requestChanged
        }
        defer { submittingRequestIDs.remove(decision.requestID) }
        try await pending.responseSender(pending.rpcRequestID, result)
        consumedDecisionIDs.insert(decision.id)
        await remove(pending)
    }

    public func resolve(rpcRequestID: AppServerRequestID) async {
        guard let publicID = publicIDByRPCID[rpcRequestID],
              let pending = pendingByPublicID[publicID] else { return }
        await remove(pending)
    }

    public func resolve(externalKey: String) async {
        guard let publicID = publicIDByExternalKey[externalKey],
              let pending = pendingByPublicID[publicID] else { return }
        await remove(pending)
    }

    private func remove(_ pending: Pending) async {
        removeFromIndex(pending)
        await store.removeApproval(id: pending.request.id)
    }

    private func removeFromIndex(_ pending: Pending) {
        pendingByPublicID.removeValue(forKey: pending.request.id)
        if let externalKey = pending.externalKey {
            if publicIDByExternalKey[externalKey] == pending.request.id {
                publicIDByExternalKey.removeValue(forKey: externalKey)
            }
        } else {
            if publicIDByRPCID[pending.rpcRequestID] == pending.request.id {
                publicIDByRPCID.removeValue(forKey: pending.rpcRequestID)
            }
        }
    }

    private static let supportedMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "mcpServer/elicitation/request",
        "item/tool/requestUserInput",
        "tool/requestUserInput",
    ]

    private static func isUserInput(_ method: String) -> Bool {
        method == "item/tool/requestUserInput" || method == "tool/requestUserInput"
    }

    private static func isSupported(_ event: AppServerEvent) -> Bool {
        guard supportedMethods.contains(event.method) else { return false }
        if event.method == "mcpServer/elicitation/request" {
            return isMCPToolApproval(event.params)
        }
        return true
    }

    /// MCP elicitations can also be forms that require typed answers. The
    /// Watch approval UI intentionally handles only decision-only tool
    /// approvals, never forms whose required values it cannot safely collect.
    private static func isMCPToolApproval(_ params: JSONValue) -> Bool {
        guard params["mode"]?.stringValue == "form" else { return false }
        let metadata = params["_meta"]
        if metadata?["codex_approval_kind"]?.stringValue == "mcp_tool_call" {
            return true
        }

        let serverName = params["serverName"]?.stringValue ?? ""
        let isDecisionServer = ["browser", "browser-use", "computer-use"].contains(serverName)
        let propertyCount = params["requestedSchema"]?["properties"]?.objectValue?.count ?? 0
        return isDecisionServer && propertyCount == 0 && metadata?["persist"] != nil
    }

    private static func allowedChoices(for event: AppServerEvent) -> Set<ApprovalChoice> {
        if isUserInput(event.method) { return [.allowOnce] }
        if event.method == "item/permissions/requestApproval"
            || event.method == "mcpServer/elicitation/request" {
            return [.allowOnce, .deny]
        }
        guard let values = event.params["availableDecisions"]?.arrayValue else {
            return [.allowOnce, .deny, .cancelTask]
        }
        let strings = Set(values.compactMap(\.stringValue))
        var choices: Set<ApprovalChoice> = []
        if strings.contains("accept") { choices.insert(.allowOnce) }
        if strings.contains("decline") { choices.insert(.deny) }
        if strings.contains("cancel") { choices.insert(.cancelTask) }
        return choices.isEmpty ? [.deny] : choices
    }

    private static func response(for method: String, choice: ApprovalChoice, params: JSONValue) -> JSONValue {
        if method == "item/permissions/requestApproval" {
            let permissions = choice == .allowOnce
                ? (params["permissions"] ?? .object([:]))
                : .object([:])
            return .object([
                "scope": .string("turn"),
                "permissions": permissions,
            ])
        }
        if method == "mcpServer/elicitation/request" {
            let action: String
            switch choice {
            case .allowOnce: action = "accept"
            case .deny: action = "decline"
            case .cancelTask: action = "cancel"
            }
            return .object([
                "action": .string(action),
                "content": choice == .allowOnce ? .object([:]) : .null,
                "_meta": .null,
            ])
        }

        let wireDecision: String
        switch choice {
        case .allowOnce: wireDecision = "accept"
        case .deny: wireDecision = "decline"
        case .cancelTask: wireDecision = "cancel"
        }
        return .object(["decision": .string(wireDecision)])
    }

    private static func presentation(
        for method: String,
        params: JSONValue
    ) -> (kind: ApprovalKind, title: String, summary: String) {
        let reason = params["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            return (.userInput, AppLocalizer.text("Codex 等待回答"), AppLocalizer.text("请回答问题以继续任务"))
        case "item/commandExecution/requestApproval":
            return (
                .command,
                AppLocalizer.text("运行命令"),
                reason?.isEmpty == false ? reason! : AppLocalizer.text("Codex 希望运行一条命令")
            )
        case "item/fileChange/requestApproval":
            return (
                .fileChange,
                AppLocalizer.text("修改文件"),
                reason?.isEmpty == false ? reason! : AppLocalizer.text("Codex 希望应用文件更改")
            )
        case "item/permissions/requestApproval":
            return (
                .permissions,
                AppLocalizer.text("请求权限"),
                reason?.isEmpty == false ? reason! : AppLocalizer.text("Codex 希望扩大本次任务的访问范围")
            )
        case "mcpServer/elicitation/request":
            let metadata = params["_meta"]
            let tool = metadata?["tool_title"]?.stringValue
                ?? metadata?["tool_name"]?.stringValue
                ?? metadata?["tool_params"]?["app"]?.stringValue
                ?? metadata?["connector_name"]?.stringValue
                ?? params["serverName"]?.stringValue
            let message = params["message"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                .permissions,
                tool?.isEmpty == false ? tool! : AppLocalizer.text("请求权限"),
                message?.isEmpty == false
                    ? message!
                    : AppLocalizer.text("ChatGPT 希望使用一个外部工具")
            )
        default:
            return (.unknown, AppLocalizer.text("需要确认"), reason ?? AppLocalizer.text("Codex 正在等待确认"))
        }
    }

    private static func requestedPaths(from params: JSONValue) -> [String] {
        let fileSystem = params["permissions"]?["fileSystem"]
            ?? params["additionalPermissions"]?["fileSystem"]
        let read = fileSystem?["read"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let write = fileSystem?["write"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return Array(Set(read + write)).sorted()
    }

    private static func digest(
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        command: String?,
        cwd: String?,
        paths: [String],
        requestsNetwork: Bool,
        rawParams: JSONValue
    ) -> String {
        let fields = [
            method,
            threadID,
            turnID,
            itemID,
            command ?? "",
            cwd ?? "",
            paths.joined(separator: "\u{1E}"),
            requestsNetwork ? "network:1" : "network:0",
        ]
        var bytes = Data(fields.joined(separator: "\u{1F}").utf8)
        // Bind the complete request, including question/options and separate
        // read/write permission scopes, not only a union of displayed paths.
        bytes.append((try? CodexWatchCoding.makeEncoder().encode(rawParams)) ?? Data())
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
