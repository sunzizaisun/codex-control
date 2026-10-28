import Foundation
import CodexWatchCore

public actor CodexBridgeService {
    public typealias OwnerBindingRecorder = @Sendable (TaskCommand, String) throws -> Void
    private let client: AppServerClient
    private let store: CodexSnapshotStore
    private let broker: ApprovalBroker
    private let resolutionTracker: RequestResolutionTracker
    private var mainRequestKeys: [AppServerRequestID: String] = [:]
    private let isolateCommandSessions: Bool
    private let ownerBindingRecorder: OwnerBindingRecorder?
    private var commandClients: [String: AppServerClient] = [:]
    private var commandSessions: [String: String] = [:]
    private var inFlightThreadCommands: Set<String> = []
    private var releaseTasks: [String: Task<Void, Never>] = [:]
    private var commandRequestKeys: [String: Set<String>] = [:]
    private var handledCommandIDs: [String] = []
    private var handledCommandIDSet: Set<String> = []
    private var resumedThreadIDs: Set<String> = []
    /// Existing desktop tasks explicitly resumed for a companion command are
    /// owned by this live app-server connection too. This is session-local;
    /// it must not relabel a desktop-created task as bridge-created.
    private var locallyContinuedThreadIDs: Set<String> = []
    /// Full history reads are expensive for large desktop conversations. Live
    /// turns remain on the event stream; idle transcripts only need a bounded
    /// refresh cadence so the menu-bar bridge does not periodically burn a CPU
    /// core while rebuilding unchanged history.
    private var transcriptReadAt: [String: Date] = [:]
    private let idleTranscriptRefreshInterval: TimeInterval = 120
    private var snapshotChangedHandler: (@Sendable () async -> Void)?
    private var snapshotNotificationTask: Task<Void, Never>?
    private var modelsRefreshedAt = Date.distantPast
    private var supportsPaginatedHistory: Bool?

    public func setSnapshotChangedHandler(_ handler: (@Sendable () async -> Void)?) {
        snapshotChangedHandler = handler
    }

    private func notifySnapshotChanged() {
        guard snapshotChangedHandler != nil, snapshotNotificationTask == nil else { return }
        snapshotNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await self.publishSnapshotChange()
        }
    }

    private func publishSnapshotChange() async {
        snapshotNotificationTask = nil
        await snapshotChangedHandler?()
    }

    public init(client: AppServerClient = AppServerClient(), store: CodexSnapshotStore = CodexSnapshotStore(), isolateCommandSessions: Bool = true,
                ownerBindingRecorder: OwnerBindingRecorder? = nil) {
        self.client = client
        self.store = store
        self.isolateCommandSessions = isolateCommandSessions
        self.ownerBindingRecorder = ownerBindingRecorder
        let tracker = RequestResolutionTracker()
        self.resolutionTracker = tracker
        self.broker = ApprovalBroker(store: store) { [client] requestID, result in
            try await client.respond(to: requestID, result: result)
            try await tracker.wait(Self.commandRequestKey(sessionID: "main", requestID: requestID))
        }
    }

    public func start(
        refreshImmediately: Bool = true,
        preferManagedDaemon: Bool = true
    ) async throws {
        if !(await client.isRunning) {
            locallyContinuedThreadIDs.removeAll()
            supportsPaginatedHistory = nil
        }
        await client.setEventHandler { [weak self] event in
            await self?.handle(event)
        }
        _ = try await client.start(preferManagedDaemon: preferManagedDaemon)
        await store.setConnected(true)
        notifySnapshotChanged()
        if refreshImmediately {
            await refresh()
        }
    }

    public func stop() async {
        for task in releaseTasks.values { task.cancel() }
        releaseTasks.removeAll()
        for worker in commandClients.values { await worker.stop() }
        commandClients.removeAll()
        commandSessions.removeAll()
        for key in commandRequestKeys.values.flatMap({ $0 }) {
            await resolutionTracker.resolved(key, confirmed: false)
            await broker.resolve(externalKey: key)
        }
        for (id, key) in mainRequestKeys {
            await resolutionTracker.resolved(key, confirmed: false)
            await broker.resolve(rpcRequestID: id)
        }
        mainRequestKeys.removeAll()
        commandRequestKeys.removeAll()
        snapshotNotificationTask?.cancel()
        snapshotNotificationTask = nil
        await store.setConnected(false)
        await client.stop()
        notifySnapshotChanged()
        resumedThreadIDs.removeAll()
        locallyContinuedThreadIDs.removeAll()
        transcriptReadAt.removeAll()
    }

    /// Companion transports can receive a queued action a moment before the
    /// Mac finishes launching app-server. Exposing the lifecycle state lets
    /// the desktop bridge wait for that short startup window instead of
    /// turning a valid queued command into a permanent failure.
    public func isRunning() async -> Bool {
        await client.isRunning
    }

    /// Installs a lightweight lifecycle hook used by the desktop bridge to
    /// wake its recovery state machine as soon as the child process exits.
    /// This is separate from refresh so idle sessions do not need to poll the
    /// full thread list just to discover a dead local process.
    public func setServiceLostHandler(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        await client.setLifecycleHandler { [weak self, store] in
            await self?.invalidateMainRequests()
            await store.setConnected(false)
            await handler?()
        }
    }

    private func invalidateMainRequests() async {
        let pending = mainRequestKeys
        mainRequestKeys.removeAll()
        for (id, key) in pending {
            await resolutionTracker.resolved(key, confirmed: false)
            await broker.resolve(rpcRequestID: id)
        }
    }

    public func refresh(readTranscripts: Bool = true) async {
        // Quota is small and independent of a large conversation transcript.
        // Fetch it first; one slow history read must not starve the balance.
        do {
            let rateLimits = try await refreshRequest(method: "account/rateLimits/read")
            await store.applyRateLimits(rateLimits)
            notifySnapshotChanged()
        } catch {
            // Preserve the timestamp of the last real result, not fake zero.
        }
        if Date().timeIntervalSince(modelsRefreshedAt) > 300 { try? await refreshModels() }

        do {
            var threadRows: [JSONValue] = [], cursor: String?
            var seenCursors = Set<String>()
            repeat {
                var params: [String: JSONValue] = [
                    "limit": .integer(100),
                    // Metadata only: never scan every rollout on a status poll.
                    "useStateDbOnly": .bool(true),
                    "sortKey": .string("updated_at"),
                    "sortDirection": .string("desc"),
                    "sourceKinds": .array([
                        .string("cli"),
                        .string("vscode"),
                        .string("exec"),
                        .string("appServer"),
                        .string("unknown"),
                    ]),
                ]
                if let cursor { params["cursor"] = .string(cursor) }
                let page = try await refreshRequest(method: "thread/list", params: .object(params))
                threadRows += page["data"]?.arrayValue ?? []
                let next = page["nextCursor"]?.stringValue
                if let next, !seenCursors.insert(next).inserted { throw AppServerClientError.invalidResponse }
                cursor = next
            } while cursor != nil
            await store.applyThreadList(.object(["data": .array(threadRows)]))
            // thread/list only returns persisted metadata. Resuming active
            // rows is what subscribes this client to the live event stream
            // for an existing Work/Chat thread.
            for threadID in await store.activeThreadIDs() {
                // A standalone child is not the owner of desktop Work turns.
                // The desktop follower monitors those without resuming them
                // and changing their approval configuration on every poll.
                // The long-lived observer must never acquire a writer lock.
                // Isolated command workers already subscribe to their turns.
                guard !isolateCommandSessions, await store.isBridgeManaged(threadID: threadID) else { continue }
                guard !resumedThreadIDs.contains(threadID) else { continue }
                if let resumed = try? await refreshRequest(
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(threadID),
                        "approvalPolicy": .string("on-request"),
                        "approvalsReviewer": .string("user"),
                    ])
                ) {
                    resumedThreadIDs.insert(threadID)
                    // `thread/resume` is the authoritative source for an
                    // in-progress turn after the bridge reconnects. Without
                    // this, a continuing task can have no activeTurnID on the
                    // phone/Watch and its Send button is unnecessarily locked.
                    await store.applyThreadItems(threadID: threadID, result: resumed)
                }
            }
            let activeThreadIDs = Set(await store.activeThreadIDs())
            let now = Date()
            var readsThisPass = 0
            let transcriptIDs = readTranscripts ? await store.transcriptThreadIDs() : []
            for threadID in transcriptIDs {
                let isActive = activeThreadIDs.contains(threadID)
                if isolateCommandSessions {
                    // Desktop status/replies already arrive on the live IPC
                    // stream. Some real rollouts are hundreds of MB: reading
                    // them in full every five seconds is both redundant and
                    // expensive. Non-bridge history is fetched on navigation.
                    if await store.hasLiveRuntime(threadID: threadID) { continue }
                    guard await store.isBridgeManaged(threadID: threadID) else { continue }
                }
                if !isActive,
                   let lastRead = transcriptReadAt[threadID],
                   now.timeIntervalSince(lastRead) < idleTranscriptRefreshInterval {
                    continue
                }
                guard readsThisPass < 2 else { break }
                readsThisPass += 1
                if (try? await history(TaskHistoryRequest(taskID: threadID))) != nil {
                    transcriptReadAt[threadID] = Date()
                }
            }
            let knownTranscriptIDs = Set(await store.transcriptThreadIDs(limit: 1_000))
            transcriptReadAt = transcriptReadAt.filter { knownTranscriptIDs.contains($0.key) }
        } catch {
            // Keep the last good snapshot when a refresh fails.
        }

        do {
            // The app-server protocol specifies `null` here (rather than an
            // empty object). Sending `{}` can yield a response without the
            // daily buckets, which in turn made the Watch show Usage
            // Unavailable even though the account supports usage history.
            let usage = try await refreshRequest(method: "account/usage/read", params: .null)
            await store.applyUsage(usage)
        } catch {
            // Usage history can be unavailable for some account types.
        }
        await store.setConnected(await client.isRunning)
        notifySnapshotChanged()
    }

    /// Refreshes are background synchronization, not user-submitted turns.
    /// A single slow history read must not terminate unrelated command RPCs
    /// or discard an otherwise healthy quota session. Process termination is
    /// handled separately by the lifecycle callback.
    private func refreshRequest(
        method: String,
        params: JSONValue = .object([:])
    ) async throws -> JSONValue {
        try await client.request(method: method, params: params, timeout: .seconds(15))
    }

    public func snapshot() async -> DashboardSnapshot {
        await store.setConnected(await client.isRunning)
        return await store.snapshot()
    }

    /// Bounded owner receipt inspection. Missing/legacy IDs or any read error
    /// are not evidence of rejection and never authorize a second execution.
    public func confirmsAcceptedCommand(_ command: TaskCommand) async -> Bool {
        guard await client.isRunning else { return false }
        return (try? await CommandReceiptLookup.confirms(command) { [client] method, params in
            try await client.request(method: method, params: params, timeout: .seconds(6))
        }) == true
    }

    /// Explicit user navigation, not a timer: read full text without resuming
    /// the thread or changing its approval policy. Only a bounded page leaves
    /// the Mac; dashboard broadcasts stay small.
    public func history(_ request: TaskHistoryRequest) async throws -> TaskHistoryPage {
        // Old message-ID-only requests retain their compatibility path.
        // For modern clients only method-not-found permits old-server fallback.
        // A timeout, malformed page or stale cursor must not silently trigger
        // a huge read of the complete rollout as a recovery operation.
        if supportsPaginatedHistory != false, request.beforeMessageID == nil || request.continuation != nil {
            do {
                let page = try await PaginatedThreadHistory.page(request) { [client] method, params in
                    try await client.request(method: method, params: params, timeout: .seconds(15))
                }
                supportsPaginatedHistory = true
                if !page.isOlderPage {
                    await store.applyHistoryMessages(threadID: request.taskID, messages: page.messages)
                    notifySnapshotChanged()
                }
                return page
            } catch AppServerClientError.server(let code, _) where code == -32601 && request.continuation == nil {
                supportsPaginatedHistory = false
            }
        }
        guard request.continuation == nil else { throw AppServerClientError.invalidResponse }
        let result = try await client.request(
            method: "thread/read",
            params: .object(["threadId": .string(request.taskID), "includeTurns": .bool(true)]),
            timeout: .seconds(15)
        )
        await store.applyThreadItems(threadID: request.taskID, result: result)
        notifySnapshotChanged()
        return try TaskHistoryPaging.page(messages: ThreadHistoryParser.messages(from: result), request: request)
    }

    public func connectionSource() async -> AppServerConnectionSource {
        await client.connectionSource
    }

    public func activeTasksHaveLiveUpdates() async -> Bool {
        let ids = await store.activeThreadIDs(limit: 1_000)
        guard !ids.isEmpty else { return false }
        for id in ids where !(await store.hasLiveRuntime(threadID: id)) { return false }
        return true
    }

    public func task(threadID: String) async -> AgentTask? {
        await store.task(threadID: threadID)
    }

    public func isBridgeManaged(threadID: String) async -> Bool {
        await store.isBridgeManaged(threadID: threadID)
    }

    public func canContinueDirectly(threadID: String) async -> Bool {
        guard await client.isRunning else { return false }
        if isolateCommandSessions {
            guard commandClients[threadID] != nil else { return false }
            return (await store.task(threadID: threadID))?.state.isActive == true
        }
        if locallyContinuedThreadIDs.contains(threadID) { return true }
        return await store.isBridgeManaged(threadID: threadID)
    }

    public func recordNativeChatStarted(
        id: String,
        prompt: String,
        messageID: String
    ) async {
        await store.seedNativeChat(id: id, initialPrompt: prompt, messageID: messageID)
    }

    public func recordNativeChatSubmitted(id: String) async {
        // The user message was already recorded when the projection was
        // seeded. Keep it running until the desktop tab yields a real reply.
        _ = id
    }

    public func applyNativeChatTranscript(id: String, messages: [ChatMessage]) async {
        await store.applyNativeChatTranscript(id: id, messages: messages)
    }

    public func recordExternallySentCommand(_ command: TaskCommand, submittedAt: Date = Date(), previousMessageIDs: Set<String>? = nil) async {
        if let options = command.options { await store.applyExecutionSettings(threadID: command.taskID, model: options.model, effort: options.effort) }
        await store.recordUserMessage(
            threadID: command.taskID,
            id: command.id,
            text: command.prompt,
            now: submittedAt,
            previousMessageIDs: previousMessageIDs
        )
    }

    /// Mirrors the compact reply projection emitted by the signed-in ChatGPT
    /// desktop owner for a Work conversation. This is separate from app-server
    /// events because desktop-owned Work turns do not reliably broadcast their
    /// assistant deltas to a second app-server client.
    public func applyDesktopTranscript(
        threadID: String,
        messages: [ChatMessage]
    ) async {
        await store.applyDesktopTranscript(threadID: threadID, messages: messages)
    }

    public func applyDesktopRuntime(_ projection: DesktopRuntimeProjection) async {
        await store.applyDesktopRuntime(projection)
        notifySnapshotChanged()
    }

    public func desktopRuntimeUnavailable(threadID: String) async {
        await store.desktopRuntimeUnavailable(threadID: threadID)
        notifySnapshotChanged()
    }

    private func makeCommandClient() async throws -> (AppServerClient, String) {
        guard isolateCommandSessions else { return (client, "observer") }
        let worker = client.makeSibling()
        let sessionID = UUID().uuidString
        await worker.setEventHandler { [weak self, weak worker] event in
            guard let worker else { return }
            await self?.handle(event, commandClient: worker, sessionID: sessionID)
        }
        await worker.setLifecycleHandler { [weak self] in
            await self?.commandSessionLost(sessionID)
        }
        _ = try await worker.start(preferManagedDaemon: false)
        return (worker, sessionID)
    }

    private func commandClient(for threadID: String) async throws -> (AppServerClient, String) {
        if let worker = commandClients[threadID], await worker.isRunning {
            return (worker, commandSessions[threadID] ?? "observer")
        }
        let (worker, sessionID) = try await makeCommandClient()
        if isolateCommandSessions {
            commandClients[threadID] = worker
            commandSessions[threadID] = sessionID
        }
        return (worker, sessionID)
    }

    private func commandSessionLost(_ sessionID: String) async {
        for key in commandRequestKeys.removeValue(forKey: sessionID) ?? [] {
            await resolutionTracker.resolved(key, confirmed: false)
            await broker.resolve(externalKey: key)
        }
        for threadID in commandSessions.filter({ $0.value == sessionID }).map(\.key) {
            commandClients.removeValue(forKey: threadID)
            commandSessions.removeValue(forKey: threadID)
            await store.commandRuntimeUnavailable(threadID: threadID)
        }
        notifySnapshotChanged()
    }

    private func scheduleCommandRelease(threadID: String) {
        guard isolateCommandSessions, releaseTasks[threadID] == nil else { return }
        // Never wait for an RPC inside the ordered stdout event callback.
        releaseTasks[threadID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.releaseCommandClient(threadID: threadID)
        }
    }

    private func releaseCommandClient(threadID: String) async {
        while inFlightThreadCommands.contains(threadID), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        defer { releaseTasks.removeValue(forKey: threadID) }
        guard !Task.isCancelled, (await store.task(threadID: threadID))?.state.isActive != true,
              let worker = commandClients.removeValue(forKey: threadID) else { return }
        if let sessionID = commandSessions.removeValue(forKey: threadID) {
            for key in commandRequestKeys.removeValue(forKey: sessionID) ?? [] {
                await resolutionTracker.resolved(key, confirmed: false)
                await broker.resolve(externalKey: key)
            }
        }
        await worker.setEventHandler(nil)
        await worker.setLifecycleHandler(nil)
        // unsubscribe keeps the server's writer alive for its idle grace
        // period. Closing this task's dedicated worker actually releases it,
        // without interrupting any other running task or the quota observer.
        await worker.stopAndWaitForExit()
        await store.releaseCommandRuntime(threadID: threadID)
        locallyContinuedThreadIDs.remove(threadID)
        notifySnapshotChanged()
    }

    public func submit(_ decision: ApprovalDecision) async throws {
        try await broker.submit(decision)
    }

    @discardableResult
    public func registerExternalApproval(
        _ event: AppServerEvent,
        externalKey: String,
        responseSender: @escaping ApprovalBroker.ResponseSender
    ) async throws -> ApprovalRequest {
        try await broker.registerExternal(
            event,
            externalKey: externalKey,
            responseSender: responseSender
        )
    }

    public func resolveExternalApproval(externalKey: String) async {
        await broker.resolve(externalKey: externalKey)
    }

    /// Consumes one real reset card from the signed-in desktop account. The
    /// client supplies a stable UUID, so a network retry cannot spend it twice.
    @discardableResult
    public func consumeResetCredit(_ request: UsageResetRequest) async throws -> String {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.id.utf8.count <= 160,
              request.creditID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1024 }) ?? true else {
            throw CodexCompanionCommandError.invalidCommand
        }
        var params: [String: JSONValue] = [
            "idempotencyKey": .string(request.id),
        ]
        if let creditID = request.creditID {
            params["creditId"] = .string(creditID)
        }
        let result = try await client.request(
            method: "account/rateLimitResetCredit/consume",
            params: .object(params)
        )
        guard let rawOutcome = result["outcome"]?.stringValue,
              let outcome = UsageResetOutcome(rawValue: rawOutcome) else {
            throw AppServerClientError.invalidResponse
        }
        await refresh(readTranscripts: false)
        return outcome.rawValue
    }

    @discardableResult
    public func startTask(prompt: String, workingDirectory: String, options: CodexExecutionOptions? = nil) async throws -> String {
        try Self.validatePrompt(prompt)
        try await validateOptions(TaskCommand(taskID: TaskCommand.newChatTaskID, prompt: prompt, deviceID: "mac", options: options))
        let messageID = UUID().uuidString
        let (worker, sessionID) = try await makeCommandClient()
        let threadResult: JSONValue
        do { threadResult = try await worker.request(
            method: "thread/start",
            params: .object([
                "model": options.map { .string($0.model) } ?? .null,
                "cwd": .string(workingDirectory),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"),
                "threadSource": .string("appServer"),
            ])
        ) } catch { if isolateCommandSessions { await worker.stop() }; throw error }
        guard let threadID = threadResult["thread"]?["id"]?.stringValue,
              CommandOwnerBinding.validOwnerID(threadID) else {
            if isolateCommandSessions { await worker.stop() }
            throw AppServerClientError.invalidResponse
        }
        if isolateCommandSessions { commandClients[threadID] = worker; commandSessions[threadID] = sessionID }
        inFlightThreadCommands.insert(threadID)
        defer { inFlightThreadCommands.remove(threadID) }
        if let thread = threadResult["thread"] {
            await store.seedManagedTask(
                thread,
                initialPrompt: prompt,
                messageID: messageID,
                isChat: false
            )
            await store.applyExecutionSettings(threadID: threadID, model: threadResult["model"]?.stringValue, effort: threadResult["reasoningEffort"]?.stringValue)
        }

        do { _ = try await worker.request(
            method: "turn/start",
            params: CodexTurnOptions.applying(options, to: [
                "threadId": .string(threadID),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"),
                "clientUserMessageId": .string(messageID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(prompt),
                    ]),
                ]),
            ])
        ) } catch {
            await handleStartFailure(error, threadID: threadID)
            throw error
        }
        if let options { await store.applyExecutionSettings(threadID: threadID, model: options.model, effort: options.effort) }
        return threadID
    }

    public func send(_ command: TaskCommand) async throws {
        guard !command.targetsBrowserChat, command.executionTarget != .browser else {
            throw CodexCompanionCommandError.chatRemoved
        }
        try Self.validatePrompt(command.prompt)
        try await validateOptions(command)
        guard handledCommandIDSet.insert(command.id).inserted else { return }
        var submittedAt = Date()
        var previousMessageIDs: Set<String>?
        do {
            if command.startsNewCodexChat {
                _ = try await startCodexConversation(prompt: command.prompt, messageID: command.id,
                    options: command.options, ownerBindingCommand: command)
            } else {
                if let release = releaseTasks[command.taskID] { await release.value }
                while inFlightThreadCommands.contains(command.taskID) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                }
                inFlightThreadCommands.insert(command.taskID)
                defer { inFlightThreadCommands.remove(command.taskID) }
                let (worker, _) = try await commandClient(for: command.taskID)
                submittedAt = Date()
                let current = await store.task(threadID: command.taskID)
                previousMessageIDs = Set(current?.messages.map(\.id) ?? [])
                // A delayed Watch packet can still contain the ID of a
                // completed turn. Use this executor's live state, not the
                // sender's old snapshot, when choosing steer versus start.
                let activeTurnID = isolateCommandSessions
                    ? (current?.isInProgress == true ? current?.activeTurnID : nil)
                    : command.activeTurnID
                if isolateCommandSessions, current?.isInProgress == true, activeTurnID == nil {
                    throw AppServerClientError.invalidResponse
                }
                if let activeTurnID {
                if command.options != nil { throw CodexTurnOptionsError.activeTurn }
                _ = try await worker.request(
                    method: "turn/steer",
                    params: .object([
                        "threadId": .string(command.taskID),
                        "expectedTurnId": .string(activeTurnID),
                        "clientUserMessageId": .string(command.id),
                        "input": Self.textInput(command.prompt),
                    ])
                )
                } else {
                let resumed = try await worker.request(
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(command.taskID),
                        "approvalPolicy": .string("on-request"),
                        "approvalsReviewer": .string("user"),
                    ])
                )
                await store.applyExecutionSettings(threadID: command.taskID, model: resumed["model"]?.stringValue, effort: resumed["reasoningEffort"]?.stringValue)
                _ = try await worker.request(
                    method: "turn/start",
                    params: CodexTurnOptions.applying(command.options, to: [
                        "threadId": .string(command.taskID),
                        "approvalPolicy": .string("on-request"),
                        "approvalsReviewer": .string("user"),
                        "clientUserMessageId": .string(command.id),
                        "input": Self.textInput(command.prompt),
                    ])
                )
                if let options = command.options { await store.applyExecutionSettings(threadID: command.taskID, model: options.model, effort: options.effort) }
                locallyContinuedThreadIDs.insert(command.taskID)
                }
            }
            if !command.startsNewCodexChat {
                await store.recordUserMessage(threadID: command.taskID, id: command.id, text: command.prompt, now: submittedAt, previousMessageIDs: previousMessageIDs)
            }
            handledCommandIDs.append(command.id)
            if handledCommandIDs.count > 512 {
                handledCommandIDSet.remove(handledCommandIDs.removeFirst())
            }
        } catch {
            handledCommandIDSet.remove(command.id)
            if isolateCommandSessions, !command.startsNewCodexChat,
               (await store.task(threadID: command.taskID))?.state.isActive != true {
                scheduleCommandRelease(threadID: command.taskID)
            }
            throw error
        }
    }

    /// A bridge-owned Codex conversation with no selected workspace. Do not
    /// mark it as the retired Chat route: companion lists and follow-ups
    /// deliberately exclude those old conversations.
    @discardableResult
    public func startCodexConversation(prompt: String, messageID: String = UUID().uuidString, options: CodexExecutionOptions? = nil,
                                       ownerBindingCommand: TaskCommand? = nil) async throws -> String {
        try Self.validatePrompt(prompt)
        if let command = ownerBindingCommand {
            guard command.startsNewCodexChat, command.id.utf8.elementsEqual(messageID.utf8),
                  command.prompt.utf8.elementsEqual(prompt.utf8), command.options == options else {
                throw CommandOwnerBindingError.invalidOwner
            }
        }
        let (worker, sessionID) = try await makeCommandClient()
        let threadResult: JSONValue
        do { threadResult = try await worker.request(
            method: "thread/start",
            params: .object([
                "model": options.map { .string($0.model) } ?? .null,
                "cwd": .null,
                "sandbox": .string("read-only"),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"),
                "threadSource": .string("appServer"),
            ])
        ) } catch { if isolateCommandSessions { await worker.stop() }; throw error }
        guard let threadID = threadResult["thread"]?["id"]?.stringValue,
              CommandOwnerBinding.validOwnerID(threadID) else {
            if isolateCommandSessions { await worker.stop() }
            throw AppServerClientError.invalidResponse
        }
        do {
            if let command = ownerBindingCommand { try ownerBindingRecorder?(command, threadID) }
        } catch {
            // No turn has been submitted. Do not seed an optimistic Running
            // task or continue after a failed durable owner binding.
            if isolateCommandSessions { await worker.stop() }
            throw error
        }
        if isolateCommandSessions { commandClients[threadID] = worker; commandSessions[threadID] = sessionID }
        inFlightThreadCommands.insert(threadID)
        defer { inFlightThreadCommands.remove(threadID) }
        if let thread = threadResult["thread"] {
            await store.seedManagedTask(thread, initialPrompt: prompt, messageID: messageID, isChat: false)
            await store.applyExecutionSettings(threadID: threadID, model: threadResult["model"]?.stringValue, effort: threadResult["reasoningEffort"]?.stringValue)
        }
        do { _ = try await worker.request(
            method: "turn/start",
            params: CodexTurnOptions.applying(options, to: [
                "threadId": .string(threadID),
                "clientUserMessageId": .string(messageID),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"),
                "input": Self.textInput(prompt),
            ])
        ) } catch {
            await handleStartFailure(error, threadID: threadID)
            throw error
        }
        if let options { await store.applyExecutionSettings(threadID: threadID, model: options.model, effort: options.effort) }
        return threadID
    }

    public func validateOptions(_ command: TaskCommand) async throws {
        guard let options = command.options else { return }
        if !(await store.snapshot()).models.contains(where: { $0.model == options.model }) {
            try await refreshModels()
        }
        guard options.isSupported(by: (await store.snapshot()).models) else { throw CodexTurnOptionsError.unsupported }
        if !command.startsNewCodexChat, (await store.task(threadID: command.taskID))?.isInProgress == true {
            throw CodexTurnOptionsError.activeTurn
        }
    }

    private func refreshModels() async throws {
        var rows: [JSONValue] = [], cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var params: [String: JSONValue] = ["limit": .integer(100), "includeHidden": .bool(false)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await refreshRequest(method: "model/list", params: .object(params))
            rows += page["data"]?.arrayValue ?? []
            let next = page["nextCursor"]?.stringValue
            if let next, !seenCursors.insert(next).inserted { throw AppServerClientError.invalidResponse }
            cursor = next
        } while cursor != nil && rows.count < 500
        await store.applyModels(.object(["data": .array(rows)]))
        modelsRefreshedAt = Date()
    }

    private func handleStartFailure(_ error: any Error, threadID: String) async {
        // A timeout is ambiguous: the server may have accepted the turn. Do
        // not close its executor or allow an automatic duplicate. An explicit
        // rejection, however, must not strand a seeded task as "Running".
        guard let error = error as? AppServerClientError else { return }
        switch error {
        case .server, .notRunning:
            if MacActionFailure.isUnconfirmed(error) {
                await store.commandStartUnconfirmed(threadID: threadID)
            } else {
                await store.commandStartRejected(threadID: threadID, isNewConversation: true)
                scheduleCommandRelease(threadID: threadID)
            }
            notifySnapshotChanged()
        case .processExited:
            // The executor can exit after accepting the write but before
            // its response. Do not mislabel an uncertain outcome as failed.
            await store.commandRuntimeUnavailable(threadID: threadID)
            scheduleCommandRelease(threadID: threadID)
            notifySnapshotChanged()
        case .timedOut, .invalidResponse:
            await store.commandStartUnconfirmed(threadID: threadID)
            // Retain the live executor: a late event can still establish the
            // original outcome. Never start another turn to probe acceptance.
            notifySnapshotChanged()
        default: break
        }
    }

    private static func validatePrompt(_ prompt: String) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexCompanionCommandError.invalidCommand
        }
    }

    private static func textInput(_ prompt: String) -> JSONValue {
        .array([
            .object([
                "type": .string("text"),
                "text": .string(prompt),
                "text_elements": .array([]),
            ]),
        ])
    }

    private func handle(_ event: AppServerEvent, commandClient: AppServerClient? = nil, sessionID: String? = nil) async {
        // Push actual changes promptly instead of waiting for an idle
        // 60-second poll. Coalesce streaming deltas to at most 5 updates/sec.
        defer { notifySnapshotChanged() }
        if let requestID = event.requestID {
            do {
                if let commandClient, let sessionID {
                    let key = Self.commandRequestKey(sessionID: sessionID, requestID: requestID)
                    let tracker = resolutionTracker
                    await tracker.registered(key)
                    _ = try await broker.registerExternal(event, externalKey: key) { requestID, result in
                        try await commandClient.respond(to: requestID, result: result)
                        try await tracker.wait(key)
                    }
                    commandRequestKeys[sessionID, default: []].insert(key)
                } else {
                    let key = Self.commandRequestKey(sessionID: "main", requestID: requestID)
                    await resolutionTracker.registered(key)
                    _ = try await broker.register(event)
                    mainRequestKeys[requestID] = key
                }
            } catch {
                try? await (commandClient ?? client).respondWithError(
                    to: requestID,
                    message: "Codex Watch Bridge does not expose this request type"
                )
            }
            return
        }

        if event.method == "serverRequest/resolved",
           let requestID = AppServerRequestID(event.params["requestId"]) {
            if let sessionID {
                let key = Self.commandRequestKey(sessionID: sessionID, requestID: requestID)
                await resolutionTracker.resolved(key, confirmed: true)
                commandRequestKeys[sessionID]?.remove(key)
                await broker.resolve(externalKey: key)
            } else {
                let key = mainRequestKeys.removeValue(forKey: requestID)
                    ?? Self.commandRequestKey(sessionID: "main", requestID: requestID)
                await resolutionTracker.resolved(key, confirmed: true)
                await broker.resolve(rpcRequestID: requestID)
            }
            return
        }
        await store.applyEvent(method: event.method, params: event.params, isCommandRuntime: commandClient != nil)
        if event.method == "turn/completed", let threadID = event.params["threadId"]?.stringValue {
            scheduleCommandRelease(threadID: threadID)
        }
    }

    private static func commandRequestKey(sessionID: String, requestID: AppServerRequestID) -> String {
        switch requestID {
        case .integer(let id): "command-\(sessionID)-integer-\(id)"
        case .string(let id): "command-\(sessionID)-string-\(id)"
        }
    }
}

public enum CodexCompanionCommandError: LocalizedError {
    case chatRemoved
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .chatRemoved: AppLocalizer.text("Chat 功能已移除，请使用 Codex 任务")
        case .invalidCommand: AppLocalizer.text("远程数据校验失败")
        }
    }
}
