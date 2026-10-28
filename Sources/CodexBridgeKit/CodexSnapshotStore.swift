import Foundation
import CodexWatchCore

public actor CodexSnapshotStore {
    private var models: [CodexModelOption] = []
    public func applyModels(_ result: JSONValue) {
        guard let rows = result["data"]?.arrayValue else { return }
        models = rows.compactMap { row in
            guard row["hidden"]?.boolValue != true,
                  let model = row["model"]?.stringValue,
                  let name = row["displayName"]?.stringValue,
                  let effort = row["defaultReasoningEffort"]?.stringValue else { return nil }
            let efforts = (row["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue }
            guard efforts.contains(effort) else { return nil }
            return CodexModelOption(model: model, displayName: name, defaultReasoningEffort: effort,
                                    supportedReasoningEfforts: efforts, isDefault: row["isDefault"]?.boolValue ?? false)
        }
    }
    private static let chatThreadIDsKey = "CodexWatch.chatThreadIDs"
    private static let nativeChatThreadIDsKey = "CodexWatch.nativeChatThreadIDs"
    private static let bridgeThreadIDsKey = "CodexWatch.bridgeThreadIDs"
    private var tasks: [String: AgentTask] = [:]
    /// A ChatGPT chat does not expose a dedicated public "mode" field in the
    /// app-server thread list. Remember the threads we create so they stay in
    /// the Chat tab after the bridge restarts.
    private var chatThreadIDs: Set<String>
    /// Native ChatGPT conversations have no public app-server thread ID. Keep
    /// their companion projections separate from Codex task polling.
    private var nativeChatThreadIDs: Set<String>
    /// Persist the threads created by this bridge so delivery can prefer its
    /// own app-server session. Other threads use ChatGPT desktop task-following.
    private var bridgeThreadIDs: Set<String>
    private var usage: UsageSnapshot?
    private var approvals: [String: ApprovalRequest] = [:]
    private var connected = false
    /// Companion command IDs can differ from persisted server item IDs.
    /// Retire only a tracked provisional prompt when a new exact-text server
    /// echo arrives, rather than leaving all local receipts after the reply.
    private var provisionalUserMessageIDs: [String: Set<String>] = [:]
    private var canonicalUserMessageIDs: [String: Set<String>] = [:]
    private struct RuntimeState { var state: AgentTask.State; var activeTurnID: String? }
    private var desktopRuntime: [String: RuntimeState] = [:]
    private var commandRuntime: [String: RuntimeState] = [:]

    public init() {
        chatThreadIDs = Set(UserDefaults.standard.stringArray(forKey: Self.chatThreadIDsKey) ?? [])
        nativeChatThreadIDs = Set(UserDefaults.standard.stringArray(forKey: Self.nativeChatThreadIDsKey) ?? [])
        bridgeThreadIDs = Set(UserDefaults.standard.stringArray(forKey: Self.bridgeThreadIDsKey) ?? [])
    }

    public func setConnected(_ connected: Bool) {
        self.connected = connected
    }

    public func applyThreadList(_ result: JSONValue, now: Date = Date()) {
        guard let rows = result["data"]?.arrayValue else { return }
        var next = Dictionary(uniqueKeysWithValues: tasks
            // The desktop task list is paged and can briefly omit completed
            // conversations while it refreshes. Retain a bounded recent
            // window so the companion list does not make tasks disappear and
            // reappear every few seconds.
            .filter {
                $0.value.isNativeChat
                    || $0.value.isBridgeManaged
                    || $0.value.isInProgress
                    || now.timeIntervalSince($0.value.updatedAt) < 20 * 60
            }
            .map { ($0.key, $0.value) })
        for row in rows {
            guard let id = row["id"]?.stringValue else { continue }
            guard let title = Self.displayTitle(for: row, id: id) else { continue }
            let status = row["status"]
            let runtime = commandRuntime[id] ?? desktopRuntime[id]
            let persistedUpdatedAt = Self.date(fromUnixSeconds: row["updatedAt"]?.doubleValue) ?? now
            // A metadata response can lag behind a live owner event. Do not
            // move a freshly updated task back down the companion list.
            let updatedAt = max(persistedUpdatedAt, tasks[id]?.updatedAt ?? persistedUpdatedAt)
            next[id] = AgentTask(
                id: id,
                title: title,
                detail: tasks[id]?.detail,
                state: runtime?.state ?? Self.mapThreadState(status),
                model: row["model"]?.stringValue ?? tasks[id]?.model,
                reasoningEffort: tasks[id]?.reasoningEffort,
                workspace: AgentTaskPresentation.workspace(row["cwd"]?.stringValue),
                // Runtime comes from the owner, not this observer's unloaded
                // view of the same persisted conversation.
                progress: tasks[id]?.progress,
                activeTurnID: runtime != nil ? runtime?.activeTurnID : (Self.mapThreadState(status).isActive ? tasks[id]?.activeTurnID : nil),
                updatedAt: updatedAt,
                messages: tasks[id]?.messages ?? [],
                isNativeChat: tasks[id]?.isNativeChat ?? nativeChatThreadIDs.contains(id),
                isChat: tasks[id]?.isChat ?? chatThreadIDs.contains(id),
                isBridgeManaged: tasks[id]?.isBridgeManaged ?? bridgeThreadIDs.contains(id)
            )
            next[id]?.awaitingUserInput = runtime != nil ? tasks[id]?.awaitingUserInput : Self.waitingForInput(status)
        }

        // Live notifications can be newer than a polling response; keep those active rows.
        for (id, task) in tasks where task.isInProgress && next[id] == nil {
            next[id] = task
        }
        tasks = next
        provisionalUserMessageIDs = provisionalUserMessageIDs.filter { next[$0.key] != nil }
        canonicalUserMessageIDs = canonicalUserMessageIDs.filter { next[$0.key] != nil }
        desktopRuntime = desktopRuntime.filter { next[$0.key] != nil }
        commandRuntime = commandRuntime.filter { next[$0.key] != nil }
    }

    public func applyRateLimits(_ result: JSONValue, now: Date = Date()) {
        // Prefer the named Codex bucket. The legacy aggregate can be absent
        // or refer to another bucket on multi-limit accounts.
        let candidate = result["rateLimitsByLimitId"]?["codex"] ?? result["rateLimits"]
        guard let rateLimits = candidate, rateLimits.objectValue != nil else { return }
        let credits = result["rateLimitResetCredits"]
        usage = UsageSnapshot(
            plan: rateLimits["planType"]?.stringValue,
            primary: Self.usageWindow(rateLimits["primary"]),
            secondary: Self.usageWindow(rateLimits["secondary"]),
            creditsBalance: rateLimits["credits"]?["balance"]?.stringValue,
            resetCreditsAvailable: credits?["availableCount"]?.intValue,
            resetCredits: Self.resetCredits(credits?["credits"]),
            todayTokens: usage?.todayTokens,
            monthlyLimit: rateLimits["individualLimit"]?.doubleValue,
            spendControlReached: rateLimits["spendControlReached"]?.boolValue,
            capturedAt: now
        )
    }

    public func applyUsage(_ result: JSONValue) {
        guard var usage else { return }
        let today = Self.todayTokenUsage(from: result)
        usage.todayTokens = today
        self.usage = usage
    }

    public func applyEvent(method: String, params: JSONValue, now: Date = Date()) {
        applyEvent(method: method, params: params, isCommandRuntime: false, now: now)
    }

    public func applyEvent(method: String, params: JSONValue, isCommandRuntime: Bool, now: Date = Date()) {
        let threadID = params["threadId"]?.stringValue
            ?? params["thread"]?["id"]?.stringValue
            ?? params["turn"]?["threadId"]?.stringValue

        switch method {
        case "thread/started":
            if let thread = params["thread"] {
                upsertThread(thread, now: now)
            }
        case "thread/status/changed":
            guard let threadID else { return }
            if !isCommandRuntime, desktopRuntime[threadID] != nil || commandRuntime[threadID] != nil { return }
            updateState(threadID: threadID, state: Self.mapThreadState(params["status"]), awaitingUserInput: Self.waitingForInput(params["status"]), now: now)
        case "turn/started":
            guard let threadID else { return }
            if !isCommandRuntime, desktopRuntime[threadID] != nil || commandRuntime[threadID] != nil { return }
            updateState(
                threadID: threadID,
                state: .running,
                activeTurnID: params["turn"]?["id"]?.stringValue,
                now: now
            )
        case "turn/completed":
            guard let threadID else { return }
            if !isCommandRuntime, desktopRuntime[threadID] != nil || commandRuntime[threadID] != nil { return }
            let turnStatus = params["turn"]?["status"]?.stringValue
                ?? params["status"]?.stringValue
            let state: AgentTask.State = turnStatus == "failed" ? .failed : turnStatus == "interrupted" ? .idle : .completed
            updateState(threadID: threadID, state: state, activeTurnID: nil, now: now)
            finishStreamingMessages(threadID: threadID)
        case "item/agentMessage/delta", "agentMessage/delta":
            guard let threadID,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue else { return }
            appendAssistantDelta(threadID: threadID, messageID: itemID, delta: delta, now: now)
        case "turn/plan/updated":
            guard let threadID, let plan = params["plan"]?.arrayValue, !plan.isEmpty else { return }
            let completed = plan.lazy.filter { $0["status"]?.stringValue == "completed" }.count
            let currentStep = plan.first { $0["status"]?.stringValue == "inProgress" }?["step"]?.stringValue
            updatePlan(
                threadID: threadID,
                detail: currentStep ?? params["explanation"]?.stringValue,
                progress: Double(completed) / Double(plan.count),
                now: now
            )
        case "account/rateLimits/updated":
            applyRateLimits(params, now: now)
        default:
            break
        }
        if isCommandRuntime, let threadID, let task = tasks[threadID] {
            commandRuntime[threadID] = RuntimeState(state: task.state, activeTurnID: task.activeTurnID)
        }
    }

    public func applyDesktopRuntime(_ projection: DesktopRuntimeProjection, now: Date = Date()) {
        let id = projection.threadID
        if tasks[id] == nil {
            guard let title = projection.title, AgentTaskPresentation.isVisible(AgentTask(id: id, title: title, state: .unknown, updatedAt: now)) else { return }
            tasks[id] = AgentTask(id: id, title: title, state: .unknown, workspace: AgentTaskPresentation.workspace(projection.workspace), updatedAt: projection.updatedAt ?? now)
        }
        var state = Self.mapThreadState(projection.status)
        if projection.status == nil {
            switch projection.latestTurnStatus {
            case "inProgress": state = .running
            case "failed": state = .failed
            case "completed", "interrupted": state = .idle
            default: state = .unknown
            }
        }
        let waitingForInput = Self.waitingForInput(projection.status)
        let runtime = RuntimeState(state: state, activeTurnID: state.isActive || waitingForInput ? projection.activeTurnID : nil)
        desktopRuntime[id] = runtime
        guard commandRuntime[id] == nil, var task = tasks[id] else { return }
        task.state = runtime.state
        task.awaitingUserInput = waitingForInput
        task.activeTurnID = runtime.activeTurnID
        if let title = projection.title, Self.humanReadableTitle(title, excluding: id) != nil { task.title = title }
        if let workspace = projection.workspace { task.workspace = AgentTaskPresentation.workspace(workspace) }
        task.updatedAt = projection.updatedAt ?? task.updatedAt
        tasks[id] = task
    }

    public func desktopRuntimeUnavailable(threadID: String) {
        guard desktopRuntime[threadID] != nil else { return }
        desktopRuntime[threadID] = RuntimeState(state: .unknown, activeTurnID: nil)
        if commandRuntime[threadID] == nil { tasks[threadID]?.state = .unknown; tasks[threadID]?.activeTurnID = nil; tasks[threadID]?.awaitingUserInput = false }
    }

    public func releaseCommandRuntime(threadID: String) { commandRuntime.removeValue(forKey: threadID) }

    public func hasLiveRuntime(threadID: String) -> Bool {
        commandRuntime[threadID] != nil || (desktopRuntime[threadID] != nil && (desktopRuntime[threadID]?.state != .unknown || tasks[threadID]?.awaitingUserInput == true))
    }

    public func commandRuntimeUnavailable(threadID: String) {
        commandRuntime.removeValue(forKey: threadID)
        // Losing the executor stream cannot prove the owner failed. It may
        // still be running, or may have completed before its final event.
        if tasks[threadID]?.isInProgress == true || tasks[threadID]?.awaitingUserInput == true {
            invalidateUnconfirmedRuntime(threadID: threadID)
        }
    }

    public func commandStartRejected(threadID: String, isNewConversation: Bool = false) {
        commandRuntime.removeValue(forKey: threadID)
        // The command's error belongs in its receipt. A rejected follow-up
        // must not change the entire existing task into a failed task.
        if isNewConversation {
            // A worker shutdown may already have marked this seed unknown
            // before the explicit RPC rejection reaches the service actor.
            invalidateUnconfirmedRuntime(threadID: threadID)
            tasks[threadID]?.state = .failed
        } else if tasks[threadID]?.isInProgress == true || tasks[threadID]?.awaitingUserInput == true {
            invalidateUnconfirmedRuntime(threadID: threadID)
        }
    }

    /// A lost start response proves neither acceptance nor rejection. Keep
    /// any real executor event that already arrived; otherwise discard only
    /// the optimistic seed and wait for a fresh owner projection/history.
    public func commandStartUnconfirmed(threadID: String) {
        guard commandRuntime[threadID] == nil else { return }
        invalidateUnconfirmedRuntime(threadID: threadID)
    }

    private func invalidateUnconfirmedRuntime(threadID: String) {
        // A pre-command desktop projection is not a fresh post-disconnect
        // confirmation. Metadata polling must not resurrect its old state.
        if desktopRuntime[threadID] != nil {
            desktopRuntime[threadID] = RuntimeState(state: .unknown, activeTurnID: nil)
        }
        tasks[threadID]?.state = .unknown
        tasks[threadID]?.activeTurnID = nil
        tasks[threadID]?.awaitingUserInput = false
        tasks[threadID]?.progress = nil
    }

    /// Record only settings confirmed by a response or an accepted command.
    public func applyExecutionSettings(threadID: String, model: String?, effort: String?) {
        if let model { tasks[threadID]?.model = model }
        if let effort { tasks[threadID]?.reasoningEffort = effort }
    }

    public func addApproval(_ approval: ApprovalRequest) {
        approvals[approval.id] = approval
        if approval.blocksTask { updateState(threadID: approval.taskID, state: .waitingForApproval, now: Date()) }
    }

    public func removeApproval(id: String) {
        guard let approval = approvals.removeValue(forKey: id) else { return }
        if approval.blocksTask, tasks[approval.taskID]?.state == .waitingForApproval,
           !approvals.values.contains(where: { $0.taskID == approval.taskID && $0.blocksTask }) {
            // Removal confirms only that this question/request is no longer
            // pending, not that the owner resumed execution successfully.
            updateState(threadID: approval.taskID, state: .unknown, now: Date())
            tasks[approval.taskID]?.progress = nil
        }
    }

    public func snapshot(now: Date = Date()) -> DashboardSnapshot {
        let validApprovals = approvals.values
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
        return DashboardSnapshot(
            tasks: tasks.values.sorted { lhs, rhs in
                if lhs.isInProgress != rhs.isInProgress {
                    return lhs.isInProgress
                }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            },
            models: models,
            usage: usage,
            pendingApprovals: validApprovals,
            bridgeConnected: connected,
            capturedAt: now
        )
    }

    public func transcriptThreadIDs(limit: Int = 12) -> [String] {
        tasks.values
            .filter { !$0.isNativeChat }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.id)
    }

    /// Threads which are currently running in the server. A second app-server
    /// client must explicitly resume these threads before it can receive live
    /// turn/item notifications (including permission requests).
    public func activeThreadIDs(limit: Int = 20) -> [String] {
        tasks.values
            .filter { $0.isInProgress }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.id)
    }

    public func applyThreadItems(threadID: String, result: JSONValue, now: Date = Date()) {
        guard var task = tasks[threadID] else { return }
        guard result["data"]?.arrayValue != nil || result["thread"]?["turns"]?.arrayValue != nil else { return }
        if commandRuntime[threadID] == nil && desktopRuntime[threadID] == nil,
           let activeTurnID = result["thread"]?["turns"]?.arrayValue?
            .last(where: { $0["status"]?.stringValue == "inProgress" })?["id"]?.stringValue {
            task.state = .running
            task.activeTurnID = activeTurnID
            task.updatedAt = now
        } else if result["thread"]?["turns"]?.arrayValue != nil,
                  commandRuntime[threadID] == nil && desktopRuntime[threadID] == nil && task.state.isActive {
            // A resumed/read thread with no in-progress turn is safe to start
            // again. Clear any ID retained from an older live notification.
            task.activeTurnID = nil
        }
        let provisionalIDs = provisionalUserMessageIDs[threadID] ?? []
        let parsed = ThreadHistoryParser.messages(from: result, existing: task.messages, now: now).filter { message in
            // A reused canonical ID must not overwrite or retire a different
            // local pending prompt. Keep that receipt pending until an exact
            // owner echo arrives, even when both rows share a message ID.
            guard provisionalIDs.contains(message.id), let local = task.messages.first(where: { $0.id == message.id }) else { return true }
            return message.role == .user && local.role == .user
                && message.text.utf8.elementsEqual(local.text.utf8)
                && (message.clientMessageID.map { $0.utf8.elementsEqual(local.id.utf8) } ?? true)
        }
        let canonicalUsers = parsed.filter { $0.role == .user }
        let previouslySeen = canonicalUserMessageIDs[threadID] ?? []
        var provisional = provisionalUserMessageIDs[threadID] ?? []
        var superseded: Set<String> = []
        // Full history can contain very old repeated prompts. Only recent,
        // previously unseen echoes can acknowledge a new provisional item.
        for message in canonicalUsers.suffix(30) {
            if provisional.remove(message.id) != nil { continue }
            if let clientID = message.clientMessageID {
                guard let local = task.messages.first(where: {
                    provisional.contains($0.id) && $0.id == clientID && $0.role == .user
                        && $0.text.utf8.elementsEqual(message.text.utf8)
                }) else { continue }
                provisional.remove(local.id)
                superseded.insert(local.id)
                continue
            }
            guard !previouslySeen.contains(message.id),
                  let local = task.messages.first(where: {
                    provisional.contains($0.id) && $0.role == .user && $0.text.utf8.elementsEqual(message.text.utf8)
                  }) else { continue }
            provisional.remove(local.id)
            superseded.insert(local.id)
        }
        task.messages.removeAll { superseded.contains($0.id) }
        provisionalUserMessageIDs[threadID] = provisional
        canonicalUserMessageIDs[threadID] = Set(canonicalUsers.suffix(128).map(\.id))
        var byID = Dictionary(uniqueKeysWithValues: task.messages.map { ($0.id, $0) })
        for message in parsed { byID[message.id] = message }
        let parsedIDs = Set(parsed.map(\.id))
        let unmatched = task.messages.filter { !parsedIDs.contains($0.id) }
        let pending = unmatched.filter { provisional.contains($0.id) || $0.isStreaming }
        let pendingIDs = Set(pending.map(\.id))
        // A desktop stream is a bounded history window. Older canonical
        // rows outside that window belong before it, never after the latest
        // reply. Only genuinely pending receipts/deltas belong at the end.
        let orderedIDs = unmatched.filter { !pendingIDs.contains($0.id) }.map(\.id)
            + parsed.map(\.id) + pending.map(\.id)
        task.messages = orderedIDs.compactMap { byID[$0] }
            .suffix(30)
            .map { $0 }
        tasks[threadID] = task
    }

    public func recordUserMessage(threadID: String, id: String, text: String, now: Date = Date(), previousMessageIDs: Set<String>? = nil) {
        guard var task = tasks[threadID] else { return }
        if let previousMessageIDs,
           task.messages.contains(where: { $0.role == .user && $0.text.utf8.elementsEqual(text.utf8)
               && ($0.clientMessageID.map { $0 == id } ?? !previousMessageIDs.contains($0.id))
               && canonicalUserMessageIDs[threadID]?.contains($0.id) == true }) {
            // The owner's echo can beat its RPC acknowledgement. It is
            // already the real prompt; do not append a second local receipt.
            return
        }
        task.messages.removeAll { $0.id == id }
        // A fast reply can arrive between the successful RPC response and
        // this receipt. Insert by the Mac-side submission time so it never
        // appears before its own prompt. Do not use the Watch's clock.
        let message = ChatMessage(id: id, role: .user, text: text, createdAt: now, clientMessageID: id)
        let insertion = previousMessageIDs.map { previous in task.messages.firstIndex { !previous.contains($0.id) } }
            ?? task.messages.firstIndex(where: { $0.createdAt > now })
        if let index = insertion {
            task.messages.insert(message, at: index)
        } else { task.messages.append(message) }
        task.messages = Array(task.messages.suffix(30))
        provisionalUserMessageIDs[threadID, default: []].insert(id)
        provisionalUserMessageIDs[threadID]?.formIntersection(Set(task.messages.map(\.id)))
        task.updatedAt = max(task.updatedAt, now)
        tasks[threadID] = task
    }

    /// Applies a small transcript projected from ChatGPT desktop's Work stream.
    /// Keep the companion-generated user message if the desktop snapshot has
    /// not echoed it yet, then prefer the desktop text for all shared IDs.
    public func applyDesktopTranscript(
        threadID: String,
        messages: [ChatMessage],
        now: Date = Date()
    ) {
        applyHistoryMessages(threadID: threadID, messages: messages, now: now)
    }

    /// Item pages carry text, not authoritative runtime status. Never infer a
    /// completed/idle turn from the absence of turn metadata in a small page.
    public func applyHistoryMessages(threadID: String, messages: [ChatMessage], now: Date = Date()) {
        let items = messages.map { message -> JSONValue in
            var item: [String: JSONValue] = [
                "id": .string(message.id),
                "type": .string(message.role == .user ? "userMessage" : "agentMessage"),
                "status": .string(message.isStreaming ? "inProgress" : "completed"),
            ]
            if message.role == .user {
                item["content"] = .array([.object(["type": .string("text"), "text": .string(message.text)])])
                if let clientID = message.clientMessageID { item["clientId"] = .string(clientID) }
            } else { item["text"] = .string(message.text) }
            return .object(item)
        }
        // Use the same canonical echo reconciliation as persisted history so
        // a local command receipt cannot reappear after the desktop reply.
        applyThreadItems(threadID: threadID, result: .object([
            "data": .array(items.map { .object(["item": $0]) })
        ]), now: now)
    }

    public func isBridgeManaged(threadID: String) -> Bool {
        tasks[threadID]?.isBridgeManaged ?? bridgeThreadIDs.contains(threadID)
    }

    public func task(threadID: String) -> AgentTask? {
        tasks[threadID]
    }

    public func seedManagedTask(
        _ thread: JSONValue,
        initialPrompt: String,
        messageID: String,
        isChat: Bool,
        now: Date = Date()
    ) {
        upsertThread(thread, now: now)
        guard let id = thread["id"]?.stringValue else { return }
        if tasks[id] == nil {
            tasks[id] = AgentTask(
                id: id,
                title: String(initialPrompt.prefix(80)),
                state: .running,
                updatedAt: now,
                isChat: isChat,
                isBridgeManaged: true
            )
        }
        tasks[id]?.isChat = isChat
        tasks[id]?.isBridgeManaged = true
        bridgeThreadIDs.insert(id)
        persistBridgeThreadIDs()
        if isChat {
            chatThreadIDs.insert(id)
            persistChatThreadIDs()
        }
        recordUserMessage(threadID: id, id: messageID, text: initialPrompt, now: now)
    }

    /// Creates a companion projection for a real ChatGPT Chat launched from
    /// the desktop Chat Bar. It intentionally never becomes an app-server
    /// thread, so a later refresh cannot turn it into a Codex conversation.
    public func seedNativeChat(
        id: String,
        initialPrompt: String,
        messageID: String,
        now: Date = Date()
    ) {
        tasks[id] = AgentTask(
            id: id,
            title: String(initialPrompt.prefix(80)),
            state: .running,
            updatedAt: now,
            messages: [ChatMessage(id: messageID, role: .user, text: initialPrompt, createdAt: now)],
            isNativeChat: true,
            isChat: false,
            isBridgeManaged: false
        )
        nativeChatThreadIDs.insert(id)
        persistNativeChatThreadIDs()
    }

    public func completeNativeChat(
        id: String,
        message: String,
        now: Date = Date()
    ) {
        guard var task = tasks[id], task.isNativeChat else { return }
        task.state = .completed
        task.updatedAt = now
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.messages.append(ChatMessage(
                id: "native-status-\(UUID().uuidString)",
                role: .assistant,
                text: message,
                createdAt: now
            ))
        }
        task.messages = Array(task.messages.suffix(30))
        tasks[id] = task
    }

    /// Applies the live projection read from the active first-party ChatGPT
    /// Chat tab. Native chats intentionally do not become app-server work,
    /// but their real replies should still be visible on the companions.
    public func applyNativeChatTranscript(
        id: String,
        messages: [ChatMessage],
        now: Date = Date()
    ) {
        guard var task = tasks[id], task.isNativeChat, !messages.isEmpty else { return }
        // The browser projection already carries the authoritative transcript
        // order. Do not sort by timestamps here: several ChatGPT messages can
        // legitimately share a timestamp (or have only second-level
        // precision), and Dictionary.values has no stable order. Rebuilding
        // from an ordered ID list keeps repeated heartbeats from making a
        // conversation appear to jump backwards on the companion UI while
        // still allowing a later snapshot to replace a streaming message.
        var messagesByID: [String: ChatMessage] = [:]
        var orderedIDs: [String] = []
        for message in messages where !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if messagesByID[message.id] == nil {
                orderedIDs.append(message.id)
            }
            messagesByID[message.id] = message
        }
        let ordered = orderedIDs.compactMap { messagesByID[$0] }
        guard !ordered.isEmpty else { return }
        task.messages = Array(ordered.suffix(30))
        task.updatedAt = now
        if let last = ordered.last {
            task.detail = last.role == .assistant ? last.text : nil
            task.state = last.role == .assistant && !last.isStreaming ? .completed : .running
        }
        tasks[id] = task
    }

    public func seedThread(_ thread: JSONValue, initialPrompt: String, messageID: String, now: Date = Date()) {
        seedManagedTask(thread, initialPrompt: initialPrompt, messageID: messageID, isChat: true, now: now)
    }

    private func upsertThread(_ thread: JSONValue, now: Date) {
        guard let id = thread["id"]?.stringValue else { return }
        let existing = tasks[id]
        let runtime = commandRuntime[id] ?? desktopRuntime[id]
        guard let title = Self.displayTitle(for: thread, id: id, fallback: existing?.title) else {
            return
        }
        let workspace: String?
        if let rawWorkspace = thread["cwd"]?.stringValue {
            workspace = AgentTaskPresentation.workspace(rawWorkspace)
        } else {
            workspace = existing?.workspace
        }
        tasks[id] = AgentTask(
            id: id,
            title: title,
            detail: existing?.detail,
            state: runtime?.state ?? Self.mapThreadState(thread["status"]),
            model: thread["model"]?.stringValue ?? existing?.model,
            reasoningEffort: existing?.reasoningEffort,
            workspace: workspace,
            progress: existing?.progress,
            activeTurnID: runtime != nil ? runtime?.activeTurnID : existing?.activeTurnID,
            updatedAt: now,
            messages: existing?.messages ?? [],
            isNativeChat: existing?.isNativeChat ?? nativeChatThreadIDs.contains(id),
            isChat: existing?.isChat ?? chatThreadIDs.contains(id),
            isBridgeManaged: existing?.isBridgeManaged ?? bridgeThreadIDs.contains(id)
        )
        tasks[id]?.awaitingUserInput = runtime != nil ? existing?.awaitingUserInput : Self.waitingForInput(thread["status"])
    }

    private func updateState(
        threadID: String,
        state: AgentTask.State,
        activeTurnID: String? = nil,
        awaitingUserInput: Bool = false,
        now: Date
    ) {
        if var existing = tasks[threadID] {
            existing.state = state
            existing.awaitingUserInput = awaitingUserInput
            existing.activeTurnID = state.isActive || awaitingUserInput ? (activeTurnID ?? existing.activeTurnID) : nil
            if state == .completed, existing.progress != nil {
                existing.progress = 1
            }
            existing.updatedAt = now
            tasks[threadID] = existing
            if commandRuntime[threadID] != nil { commandRuntime[threadID] = RuntimeState(state: state, activeTurnID: existing.activeTurnID) }
            else if desktopRuntime[threadID] != nil { desktopRuntime[threadID] = RuntimeState(state: state, activeTurnID: existing.activeTurnID) }
        }
    }

    private func updatePlan(threadID: String, detail: String?, progress: Double, now: Date) {
        if var existing = tasks[threadID] {
            existing.detail = detail
            existing.progress = max(0, min(1, progress))
            existing.state = .running
            existing.updatedAt = now
            tasks[threadID] = existing
        }
    }

    private func appendAssistantDelta(threadID: String, messageID: String, delta: String, now: Date) {
        guard var task = tasks[threadID] else { return }
        if let index = task.messages.firstIndex(where: { $0.id == messageID }) {
            task.messages[index].text += delta
            task.messages[index].isStreaming = true
        } else {
            task.messages.append(ChatMessage(id: messageID, role: .assistant, text: delta, isStreaming: true, createdAt: now))
        }
        task.messages = Array(task.messages.suffix(30))
        task.updatedAt = now
        tasks[threadID] = task
    }

    private func finishStreamingMessages(threadID: String) {
        guard var task = tasks[threadID] else { return }
        for index in task.messages.indices where task.messages[index].isStreaming {
            task.messages[index].isStreaming = false
        }
        tasks[threadID] = task
    }

    private func persistChatThreadIDs() {
        // Keep the storage bounded even if the user creates chats for years.
        let retained = Array(chatThreadIDs.sorted().suffix(300))
        chatThreadIDs = Set(retained)
        UserDefaults.standard.set(retained, forKey: Self.chatThreadIDsKey)
    }

    private func persistNativeChatThreadIDs() {
        let retained = Array(nativeChatThreadIDs.sorted().suffix(300))
        nativeChatThreadIDs = Set(retained)
        UserDefaults.standard.set(retained, forKey: Self.nativeChatThreadIDsKey)
    }

    private func persistBridgeThreadIDs() {
        let retained = Array(bridgeThreadIDs.sorted().suffix(300))
        bridgeThreadIDs = Set(retained)
        UserDefaults.standard.set(retained, forKey: Self.bridgeThreadIDsKey)
    }

    private static func mapThreadState(_ status: JSONValue?) -> AgentTask.State {
        let type = status?["type"]?.stringValue
        if type == "active" {
            let flags = status?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            // Older installed companions have no waiting-for-input enum. Do
            // not misrepresent a blocked elicitation as actively executing.
            if flags.contains("waitingOnUserInput") { return .unknown }
            return flags.contains("waitingOnApproval") ? .waitingForApproval : .running
        }
        switch type {
        case "idle", "notLoaded": return .idle
        case "systemError": return .failed
        default: return .unknown
        }
    }

    private static func waitingForInput(_ status: JSONValue?) -> Bool {
        status?["type"]?.stringValue == "active" && status?["activeFlags"]?.arrayValue?.contains(.string("waitingOnUserInput")) == true
    }

    private static func displayTitle(
        for thread: JSONValue,
        id: String,
        fallback: String? = nil
    ) -> String? {
        let candidates = [
            thread["name"]?.stringValue,
            thread["title"]?.stringValue,
            thread["displayName"]?.stringValue,
            thread["preview"]?.stringValue,
            fallback,
        ]
        return candidates.lazy.compactMap { candidate in
            Self.humanReadableTitle(candidate, excluding: id)
        }.first
    }

    private static func humanReadableTitle(_ candidate: String?, excluding id: String) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let lowercased = firstLine.lowercased()
        let isInternalContent = firstLine == id
            || firstLine.hasPrefix("/")
            || firstLine.hasPrefix("<")
            || firstLine.hasPrefix("[$")
            || lowercased.contains("<realtime_")
            || lowercased.contains("<input")
            || lowercased.contains("$plugin-")
            || lowercased.contains("://")
            || lowercased.hasPrefix("file:")
        guard !isInternalContent else { return nil }
        return String(firstLine.prefix(120))
    }

    private static func usageWindow(_ value: JSONValue?) -> UsageWindow? {
        guard let usedPercent = value?["usedPercent"]?.doubleValue else { return nil }
        return UsageWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: value?["windowDurationMins"]?.intValue,
            resetsAt: date(fromUnixSeconds: value?["resetsAt"]?.doubleValue)
        )
    }

    /// The desktop app-server returns only genuine, account-bound reset
    /// credits here. Keep unavailable/redeemed credits out of the dashboard:
    /// a card is shown only when it can actually be used.
    private static func resetCredits(_ value: JSONValue?) -> [ResetCredit]? {
        guard let values = value?.arrayValue else { return nil }
        return values.compactMap { value in
            guard let id = value["id"]?.stringValue,
                  let rawStatus = value["status"]?.stringValue,
                  let status = ResetCredit.Status(rawValue: rawStatus),
                  status == .available else {
                return nil
            }
            return ResetCredit(
                id: id,
                title: value["title"]?.stringValue,
                detail: value["description"]?.stringValue,
                expiresAt: date(fromUnixSeconds: value["expiresAt"]?.doubleValue),
                status: status
            )
        }
    }

    private static func todayTokenUsage(from value: JSONValue, now: Date = Date()) -> Int? {
        guard let buckets = value["dailyUsageBuckets"]?.arrayValue else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.timeZone = calendar.timeZone
        dateOnly.dateFormat = "yyyy-MM-dd"
        let iso8601 = ISO8601DateFormatter()

        for bucket in buckets {
            guard let rawDate = bucket["startDate"]?.stringValue,
                  let date = iso8601.date(from: rawDate) ?? dateOnly.date(from: rawDate),
                  calendar.isDate(date, inSameDayAs: now) else {
                continue
            }
            return bucket["tokens"]?.intValue
        }
        // An empty result is not proof of zero usage. Some ChatGPT account
        // modes currently return no daily token history even while tasks are
        // actively running. Keep this unavailable rather than presenting a
        // fabricated zero on the phone or Watch.
        return nil
    }

    private static func date(fromUnixSeconds seconds: Double?) -> Date? {
        seconds.map(Date.init(timeIntervalSince1970:))
    }
}
