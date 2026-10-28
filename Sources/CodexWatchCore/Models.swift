import Foundation

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: String
    public var role: Role
    public var text: String
    public var isStreaming: Bool
    public var createdAt: Date
    /// The owner's echoed clientUserMessageId. Never substitute this for the
    /// canonical item ID or infer it from matching message text.
    public var clientMessageID: String?

    public init(id: String, role: Role, text: String, isStreaming: Bool = false, createdAt: Date = Date(), clientMessageID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.clientMessageID = clientMessageID
    }
}

public struct AgentTask: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case running
        case waitingForApproval
        case idle
        case completed
        case failed
        case unknown

        public var isActive: Bool {
            self == .running || self == .waitingForApproval
        }
    }

    public let id: String
    public var title: String
    public var detail: String?
    public var state: State
    public var model: String?
    public var reasoningEffort: String?
    public var awaitingUserInput: Bool?
    public var isInProgress: Bool { state.isActive || awaitingUserInput == true }
    public var workspace: String?
    public var progress: Double?
    public var activeTurnID: String?
    public var updatedAt: Date
    /// Most recent real user/assistant messages for this Codex thread.
    /// The bridge caps this history before it is sent to companion devices.
    public var messages: [ChatMessage]
    /// A normal ChatGPT Chat started through the desktop Chat Bar. Unlike a
    /// Codex conversation, it is intended to be saved in ChatGPT history.
    public var isNativeChat: Bool
    public var isChat: Bool
    /// Threads created by Codex Control are owned by this app-server session.
    /// Desktop-owned threads are continued through ChatGPT's local task
    /// follower, with app-server and targeted UI fallbacks on macOS.
    public var isBridgeManaged: Bool

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        state: State,
        model: String? = nil,
        reasoningEffort: String? = nil,
        workspace: String? = nil,
        progress: Double? = nil,
        activeTurnID: String? = nil,
        updatedAt: Date,
        messages: [ChatMessage] = [],
        isNativeChat: Bool = false,
        isChat: Bool = false,
        isBridgeManaged: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.awaitingUserInput = nil
        self.workspace = workspace
        self.progress = progress.map { max(0, min(1, $0)) }
        self.activeTurnID = activeTurnID
        self.updatedAt = updatedAt
        self.messages = messages
        self.isNativeChat = isNativeChat
        self.isChat = isChat
        self.isBridgeManaged = isBridgeManaged
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, state, model, reasoningEffort, awaitingUserInput, workspace, progress, activeTurnID, updatedAt, messages, isNativeChat, isChat, isBridgeManaged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        state = try c.decode(AgentTask.State.self, forKey: .state)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        awaitingUserInput = try c.decodeIfPresent(Bool.self, forKey: .awaitingUserInput)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress).map { max(0, min(1, $0)) }
        activeTurnID = try c.decodeIfPresent(String.self, forKey: .activeTurnID)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        isNativeChat = try c.decodeIfPresent(Bool.self, forKey: .isNativeChat) ?? false
        isChat = try c.decodeIfPresent(Bool.self, forKey: .isChat) ?? false
        isBridgeManaged = try c.decodeIfPresent(Bool.self, forKey: .isBridgeManaged) ?? false
    }
}

/// Hides app-server implementation artifacts from the companion UI. These
/// records are not user tasks and do not have a useful conversation surface.
public enum AgentTaskPresentation {
    public static func isVisible(_ task: AgentTask) -> Bool {
        isHumanReadable(task.title)
    }

    public static func detail(_ value: String?) -> String? {
        guard let value, isHumanReadable(value) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The desktop protocol sometimes represents an unspecified directory as
    /// `/`. It is not a useful workspace for a person and should not appear
    /// as a malformed conversation detail.
    public static func workspace(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return trimmed
    }

    private static func isHumanReadable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("<")
            && !trimmed.hasPrefix("/")
            && !trimmed.hasPrefix("[$")
            && !lowercased.contains("<realtime_")
            && !lowercased.contains("<input")
            && !lowercased.contains("$plugin-")
            && !lowercased.contains("://")
            && !lowercased.hasPrefix("file:")
    }
}

public enum TaskExecutionTarget: String, Codable, Sendable {
    case mac
    case browser
}

public struct TaskCommand: Codable, Identifiable, Equatable, Sendable {
    /// The old companion build used this identifier for its Chat button.  It
    /// must now be treated as native Chat so an already-installed Watch/iPhone
    /// cannot fall through to the desktop keyboard/shortcut route.
    public static let legacyNewChatTaskID = "__codex_watch_new_chat__"
    /// New builds use a distinct identifier for the Codex entry point.
    public static let newChatTaskID = "__codex_watch_new_codex__"
    public static let newNativeChatTaskID = "__codex_watch_new_native_chat__"
    public let id: String
    public let taskID: String
    public let prompt: String
    public let activeTurnID: String?
    public let sentAt: Date
    public let deviceID: String
    /// Pins a normal Chat command to one owner so WatchConnectivity and the
    /// direct internet relay cannot disagree and submit it twice.
    public let executionTarget: TaskExecutionTarget?
    public let options: CodexExecutionOptions?

    public var startsNewCodexChat: Bool { taskID == Self.newChatTaskID }
    public var startsNativeChat: Bool {
        taskID == Self.newNativeChatTaskID || taskID == Self.legacyNewChatTaskID
    }
    /// Routes normal ChatGPT conversations to the independently hosted browser
    /// gateway.  Codex/Work task identifiers never match these prefixes.
    public var targetsBrowserChat: Bool {
        startsNativeChat
            || taskID.hasPrefix("chatgpt-chat:")
            || taskID.hasPrefix("chatgpt-web:")
    }
    public var startsNewChat: Bool { startsNewCodexChat }
    /// Native Chat is owned by the first-party desktop app, but the companion
    /// still needs a stable local projection before the Mac receives the
    /// command. Deriving it from the command id lets the Watch enter the
    /// conversation immediately instead of waiting for an unrelated snapshot.
    public var nativeChatProjectionID: String? {
        startsNativeChat ? Self.nativeChatProjectionID(commandID: id) : nil
    }

    public static func nativeChatProjectionID(commandID: String) -> String {
        "chatgpt-chat:\(commandID)"
    }

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        prompt: String,
        activeTurnID: String? = nil,
        sentAt: Date = Date(),
        deviceID: String,
        executionTarget: TaskExecutionTarget? = nil,
        options: CodexExecutionOptions? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.prompt = prompt
        self.activeTurnID = activeTurnID
        self.sentAt = sentAt
        self.deviceID = deviceID
        self.executionTarget = executionTarget
        self.options = options
    }
}

public struct UsageResetRequest: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let creditID: String?
    public let deviceID: String
    public let requestedAt: Date

    public init(id: String = UUID().uuidString, creditID: String?, deviceID: String, requestedAt: Date = Date()) {
        self.id = id
        self.creditID = creditID
        self.deviceID = deviceID
        self.requestedAt = requestedAt
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowDurationMinutes: Int?
    public var resetsAt: Date?

    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    public init(
        usedPercent: Double,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.usedPercent = max(0, min(100, usedPercent))
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case available
        case redeeming
        case redeemed
        case unknown
    }

    public let id: String
    public var title: String?
    public var detail: String?
    public var expiresAt: Date?
    public var status: Status

    public init(id: String, title: String? = nil, detail: String? = nil, expiresAt: Date? = nil, status: Status = .available) {
        self.id = id
        self.title = title
        self.detail = detail
        self.expiresAt = expiresAt
        self.status = status
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var plan: String?
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    public var creditsBalance: String?
    public var resetCreditsAvailable: Int?
    public var resetCredits: [ResetCredit]?
    public var todayTokens: Int?
    public var monthlyLimit: Double?
    public var spendControlReached: Bool?
    public var capturedAt: Date

    public init(
        plan: String? = nil,
        primary: UsageWindow? = nil,
        secondary: UsageWindow? = nil,
        creditsBalance: String? = nil,
        resetCreditsAvailable: Int? = nil,
        resetCredits: [ResetCredit]? = nil,
        todayTokens: Int? = nil,
        monthlyLimit: Double? = nil,
        spendControlReached: Bool? = nil,
        capturedAt: Date
    ) {
        self.plan = plan
        self.primary = primary
        self.secondary = secondary
        self.creditsBalance = creditsBalance
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCredits = resetCredits
        self.todayTokens = todayTokens
        self.monthlyLimit = monthlyLimit
        self.spendControlReached = spendControlReached
        self.capturedAt = capturedAt
    }
}

public enum ApprovalKind: String, Codable, Sendable {
    case command
    case fileChange
    case permissions
    case userInput
    case unknown
}

public struct ApprovalRequest: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: String
    public var kind: ApprovalKind
    public var title: String
    public var summary: String
    public var command: String?
    public var workingDirectory: String?
    public var requestedPaths: [String]
    public var requestsNetwork: Bool
    public var createdAt: Date
    public var expiresAt: Date
    public var nonce: String
    public var requestDigest: String
    /// A structured Codex question, not an allow/deny permission prompt.
    /// Optional to keep snapshots decodable by existing version-3 clients.
    public var questions: [UserInputQuestion]?
    public var isBlocking: Bool?
    public var blocksTask: Bool { questions == nil || isBlocking != false }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    public init(
        id: String,
        taskID: String,
        kind: ApprovalKind,
        title: String,
        summary: String,
        command: String? = nil,
        workingDirectory: String? = nil,
        requestedPaths: [String] = [],
        requestsNetwork: Bool = false,
        createdAt: Date,
        expiresAt: Date,
        nonce: String,
        requestDigest: String,
        questions: [UserInputQuestion]? = nil,
        isBlocking: Bool? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.command = command
        self.workingDirectory = workingDirectory
        self.requestedPaths = requestedPaths
        self.requestsNetwork = requestsNetwork
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.requestDigest = requestDigest
        self.questions = questions
        self.isBlocking = isBlocking
    }
}

public enum ApprovalChoice: String, Codable, Sendable {
    case allowOnce
    case deny
    case cancelTask
}

/// Informational origin. Authentication happens on the originating device;
/// remote Watch decisions must not trigger proximity authentication on Mac.
public enum ApprovalOrigin: String, Codable, Sendable {
    case watch
    case phone
    case mac
}

public struct ApprovalDecision: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let requestID: String
    public let requestDigest: String
    public let choice: ApprovalChoice
    public let decidedAt: Date
    public let deviceID: String
    public let nonce: String
    public let origin: ApprovalOrigin?
    public var signature: Data?
    public let answers: [String: [String]]?

    public init(
        id: String = UUID().uuidString,
        requestID: String,
        requestDigest: String,
        choice: ApprovalChoice,
        decidedAt: Date,
        deviceID: String,
        nonce: String,
        origin: ApprovalOrigin? = nil,
        signature: Data? = nil,
        answers: [String: [String]]? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.choice = choice
        self.decidedAt = decidedAt
        self.deviceID = deviceID
        self.nonce = nonce
        self.origin = origin
        self.signature = signature
        self.answers = answers
    }
}

public struct DashboardSnapshot: Codable, Equatable, Sendable {
    public var tasks: [AgentTask]
    public var models: [CodexModelOption]
    public var usage: UsageSnapshot?
    public var pendingApprovals: [ApprovalRequest]
    public var bridgeConnected: Bool
    public var capturedAt: Date

    public var activeTaskCount: Int {
        tasks.lazy.filter { !$0.isChat && !$0.isNativeChat && $0.isInProgress }.count
    }

    public init(
        tasks: [AgentTask] = [],
        models: [CodexModelOption] = [],
        usage: UsageSnapshot? = nil,
        pendingApprovals: [ApprovalRequest] = [],
        bridgeConnected: Bool,
        capturedAt: Date
    ) {
        self.tasks = tasks
        self.models = models
        self.usage = usage
        self.pendingApprovals = pendingApprovals
        self.bridgeConnected = bridgeConnected
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey { case tasks, models, usage, pendingApprovals, bridgeConnected, capturedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([AgentTask].self, forKey: .tasks)
        models = try c.decodeIfPresent([CodexModelOption].self, forKey: .models) ?? []
        usage = try c.decodeIfPresent(UsageSnapshot.self, forKey: .usage)
        pendingApprovals = try c.decode([ApprovalRequest].self, forKey: .pendingApprovals)
        bridgeConnected = try c.decode(Bool.self, forKey: .bridgeConnected)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }

    public static var empty: DashboardSnapshot {
        DashboardSnapshot(bridgeConnected: false, capturedAt: .distantPast)
    }

    /// Inserts the user turn immediately when a companion starts a native
    /// ChatGPT conversation. The authoritative browser/Mac snapshot replaces
    /// this draft later, but keeping it locally makes an offline Mac look
    /// queued (rather than lost) and lets the user send a follow-up without
    /// waiting for a heartbeat.
    public mutating func upsertNativeChatDraft(
        id: String,
        prompt: String,
        messageID: String,
        now: Date = Date()
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let draft = AgentTask(
            id: id,
            title: String(trimmedPrompt.prefix(80)),
            state: .running,
            model: "ChatGPT",
            updatedAt: now,
            messages: [ChatMessage(
                id: messageID,
                role: .user,
                text: trimmedPrompt,
                createdAt: now
            )],
            isNativeChat: true,
            isChat: true,
            isBridgeManaged: false
        )
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            // Do not overwrite an authoritative assistant transcript with a
            // late duplicate draft from WatchConnectivity.
            guard tasks[index].messages.isEmpty else { return }
            tasks[index] = draft
        } else {
            tasks.insert(draft, at: 0)
        }
        tasks.sort {
            if $0.state.isActive != $1.state.isActive { return $0.state.isActive }
            return $0.updatedAt > $1.updatedAt
        }
        capturedAt = now
    }

    /// Merge an independently produced ChatGPT browser projection without
    /// replacing Mac-owned Codex tasks, usage, approvals, or bridge state.
    public func mergingChatSnapshot(_ chatSnapshot: DashboardSnapshot) -> DashboardSnapshot {
        let chatTasks = chatSnapshot.tasks.filter { $0.isNativeChat || $0.isChat }
        guard !chatTasks.isEmpty else { return self }

        var result = self
        var indexByID = Dictionary(uniqueKeysWithValues: result.tasks.enumerated().map {
            ($0.element.id, $0.offset)
        })
        for task in chatTasks {
            if let index = indexByID[task.id] {
                result.tasks[index] = task
            } else {
                indexByID[task.id] = result.tasks.count
                result.tasks.append(task)
            }
        }
        result.tasks.sort { lhs, rhs in
            if lhs.state.isActive != rhs.state.isActive { return lhs.state.isActive }
            return lhs.updatedAt > rhs.updatedAt
        }
        return result
    }

    /// Produces a deliberately bounded representation for WatchConnectivity.
    /// WatchConnectivity accepts only small application-context and immediate
    /// message payloads. A desktop snapshot can otherwise grow without bound
    /// as followed threads accumulate message history, which causes the whole
    /// update to be rejected rather than delivering a useful partial update.
    public func compactForWatch(
        maximumTasks: Int,
        messagesPerTask: Int,
        maximumTextLength: Int,
        maximumApprovals: Int
    ) -> DashboardSnapshot {
        let orderedTasks = tasks.sorted { lhs, rhs in
            if lhs.isInProgress != rhs.isInProgress {
                return lhs.isInProgress
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        // Never omit a running/blocked project to satisfy a recent-task cap.
        // The caller falls back to the independent relay if this exceeds WC.
        let taskLimit = max(maximumTasks, orderedTasks.filter(\.isInProgress).count)
        let compactTasks = orderedTasks.prefix(taskLimit).map { source in
            var task = source
            task.title = Self.shortened(task.title, to: maximumTextLength)
            task.detail = task.detail.map { Self.shortened($0, to: maximumTextLength) }
            task.workspace = task.workspace.map { Self.shortened($0, to: maximumTextLength) }
            task.messages = Array(task.messages.suffix(messagesPerTask)).map { message in
                var compact = message
                compact.text = Self.shortened(message.text, to: maximumTextLength)
                return compact
            }
            return task
        }

        let compactApprovals = pendingApprovals
            .filter { !$0.isExpired }
            .prefix(maximumApprovals)
            // A signed digest still binds the ORIGINAL command. Never show
            // a shortened command/path and invite the user to approve a
            // larger, unseen request. Oversized approval packets use relay.
            .map { $0 }

        var compactUsage = usage
        if var usage = compactUsage {
            usage.plan = usage.plan.map { Self.shortened($0, to: maximumTextLength) }
            usage.creditsBalance = usage.creditsBalance.map { Self.shortened($0, to: maximumTextLength) }
            usage.resetCredits = usage.resetCredits?.prefix(8).map { source in
                var credit = source
                credit.title = source.title.map { Self.shortened($0, to: maximumTextLength) }
                credit.detail = source.detail.map { Self.shortened($0, to: maximumTextLength) }
                return credit
            }
            compactUsage = usage
        }

        return DashboardSnapshot(
            tasks: compactTasks,
            models: models,
            usage: compactUsage,
            pendingApprovals: compactApprovals,
            bridgeConnected: bridgeConnected,
            capturedAt: capturedAt
        )
    }

    private static func shortened(_ value: String, to maximumLength: Int) -> String {
        guard maximumLength > 0, value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)) + "…"
    }

    public static func uiPreview(english: Bool = false, longHistory: Bool = false, unknownUsage: Bool = false, questions: Bool = false) -> DashboardSnapshot {
        let now = Date()
        var snapshot = DashboardSnapshot(
            tasks: [
                AgentTask(
                    id: "preview-active",
                    title: english ? "Apple Watch GPT Control" : "Apple Watch GPT 控制",
                    detail: english
                        ? "Optimizing task details and instruction delivery"
                        : "正在优化任务详情与消息发送",
                    state: .running,
                    model: "gpt-5.6-sol",
                    workspace: "/Users/example/Projects",
                    progress: 0.68,
                    activeTurnID: "preview-turn",
                    updatedAt: now
                ),
                AgentTask(
                    id: "preview-recent",
                    title: english ? "Encrypted Cross-Network Sync" : "跨网络加密同步",
                    detail: english
                        ? "Secure relay is ready across all three devices"
                        : "三端公网中继已经完成",
                    state: .completed,
                    model: "gpt-5.6-sol",
                    workspace: "/Users/example/Projects",
                    progress: 1,
                    updatedAt: now.addingTimeInterval(-1_800),
                    messages: [
                        ChatMessage(
                            id: "preview-user-message",
                            role: .user,
                            text: english ? "Summarize the relay design." : "总结一下中继设计。",
                            createdAt: now.addingTimeInterval(-1_900)
                        ),
                        ChatMessage(
                            id: "preview-assistant-message",
                            role: .assistant,
                            text: english
                                ? "The encrypted relay keeps all three devices connected across different networks."
                                : "加密中继让三个设备即使处于不同网络也能保持连接。",
                            createdAt: now.addingTimeInterval(-1_860)
                        ),
                    ]
                ),
                AgentTask(
                    id: "preview-idle",
                    title: english ? "Organize Recent Codex Tasks" : "整理 Codex 最近任务",
                    state: .idle,
                    workspace: "/Users/example/Projects",
                    updatedAt: now.addingTimeInterval(-7_200)
                ),
            ],
            models: [
                // Isolated layout fixture, not an account entitlement claim.
                .init(model: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], isDefault: true),
                .init(model: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            ],
            usage: UsageSnapshot(
                plan: "plus",
                primary: UsageWindow(
                    usedPercent: 36,
                    windowDurationMinutes: 300,
                    resetsAt: now.addingTimeInterval(7_200)
                ),
                resetCreditsAvailable: 2,
                capturedAt: now
            ),
            pendingApprovals: [
                ApprovalRequest(
                    id: "preview-approval",
                    taskID: "preview-active",
                    kind: .command,
                    title: english ? "Run Command" : "运行命令",
                    summary: english
                        ? "Codex wants to run a command"
                        : "Codex 希望运行一条命令",
                    command: "xcodebuild test",
                    workingDirectory: "/Users/example/Projects",
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(3_600),
                    nonce: "preview",
                    requestDigest: "preview"
                ),
            ],
            bridgeConnected: true,
            capturedAt: now
        )
        if questions {
            snapshot.pendingApprovals = [ApprovalRequest(
                id: "preview-question", taskID: "preview-active", kind: .userInput,
                title: english ? "Codex needs your answer" : "Codex 等待回答",
                summary: english ? "Answer to continue the task" : "请回答问题以继续任务",
                createdAt: now, expiresAt: now.addingTimeInterval(3600), nonce: "preview", requestDigest: "preview",
                questions: [UserInputQuestion(id: "route", header: english ? "Approach" : "方案",
                    question: english ? "How should I continue?" : "接下来如何继续？",
                    options: [UserInputOption(label: english ? "Small update" : "小步更新", description: english ? "Keep the current design" : "保留当前设计"),
                              UserInputOption(label: english ? "Review first" : "先检查", description: english ? "Report without changing code" : "只检查，不修改代码")], isOther: true)]
            )]
        }
        if unknownUsage { snapshot.usage = nil }
        if longHistory, let index = snapshot.tasks.firstIndex(where: { $0.id == "preview-recent" }) {
            let replySeed = english ? "Long reply, preserved in full. " : "长回复保留完整内容。"
            let longReply = String(repeating: replySeed, count: 60)
            var history: [ChatMessage] = []
            for number in 0..<55 {
                let isUser = number % 2 == 0
                let text: String
                if isUser { text = english ? "Test message \(number)" : "测试消息 \(number)" }
                else { text = longReply }
                history.append(ChatMessage(
                    id: "preview-history-\(number)",
                    role: isUser ? .user : .assistant,
                    text: text,
                    createdAt: now.addingTimeInterval(Double(number - 55) * 60)
                ))
            }
            snapshot.tasks[index].messages = history
        }
        return snapshot
    }
}
