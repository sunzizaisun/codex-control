import Foundation
import Darwin
import Testing
@testable import CodexBridgeKit
@testable import CodexWatchCore

@Test func namedCodexBucketWinsOverLegacyLimits() async {
    let store = CodexSnapshotStore()
    await store.applyRateLimits(.object([
        "rateLimits": .object(["primary": .object(["usedPercent": .integer(100)])]),
        "rateLimitsByLimitId": .object(["codex": .object([
            "primary": .object(["usedPercent": .integer(12)]), "planType": .string("prolite")
        ])])
    ]))
    #expect(await store.snapshot().usage?.primary?.remainingPercent == 88)
    #expect(await store.snapshot().usage?.plan == "prolite")
}

@Test func resumedExistingTaskKeepsItsLiveFollowupRouteWithoutRelabeling() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-followup-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    case "$request" in *'"method":"thread'*'resume"'*) ;; *) exit 10 ;; esac
    printf '%s\\n' '{"id":2,"result":{}}'
    IFS= read -r request
    case "$request" in *'"method":"turn'*'start"'*) ;; *) exit 11 ;; esac
    printf '%s\\n' '{"id":3,"result":{}}'
    printf '%s\\n' '{"method":"turn/started","params":{"threadId":"existing","turn":{"id":"live-turn"}}}'
    IFS= read -r request
    case "$request" in *'"method":"turn'*'steer"'*) ;; *) exit 12 ;; esac
    case "$request" in *'"expectedTurnId":"live-turn"'*) ;; *) exit 13 ;; esac
    case "$request" in *'运行中跟进🙂'*) ;; *) exit 14 ;; esac
    printf '%s\\n' '{"id":4,"result":{}}'
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("existing"), "name": .string("已有测试任务")
    ])])]))
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), store: store, isolateCommandSessions: false)
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    #expect(!(await service.canContinueDirectly(threadID: "existing")))
    try await service.send(TaskCommand(taskID: "existing", prompt: "首次继续", deviceID: "watch"))
    #expect(await service.canContinueDirectly(threadID: "existing"))
    #expect(!(await service.isBridgeManaged(threadID: "existing")))
    try await service.send(TaskCommand(taskID: "existing", prompt: "运行中跟进🙂", activeTurnID: "live-turn", deviceID: "watch"))
    #expect(await service.task(threadID: "existing")?.messages.filter { $0.role == .user }.map(\.text) == ["首次继续", "运行中跟进🙂"])
    await service.stop()
    #expect(!(await service.canContinueDirectly(threadID: "existing")))
}

private actor SnapshotPublicationProbe {
    private(set) var snapshots: [DashboardSnapshot] = []
    func record(_ snapshot: DashboardSnapshot) { snapshots.append(snapshot) }
}

@Test func streamedRepliesPublishPromptlyWithoutOneUploadPerDelta() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-publish-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification
    printf '%s\\n' '{"method":"turn/started","params":{"threadId":"stream","turn":{"id":"live"}}}'
    for n in $(seq 1 100); do
      printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"stream","itemId":"reply","delta":"字"}}'
    done
    printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"stream","turn":{"id":"live","status":"completed"}}}'
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("stream"), "name": .string("流式测试任务")
    ])])]))
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), store: store, isolateCommandSessions: false)
    let probe = SnapshotPublicationProbe()
    await service.setSnapshotChangedHandler { await probe.record(service.snapshot()) }
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    try await Task.sleep(for: .milliseconds(700))
    let published = await probe.snapshots
    #expect(!published.isEmpty && published.count < 10)
    let task = published.last?.tasks.first { $0.id == "stream" }
    #expect(task?.state == .completed)
    #expect(task?.messages.last?.text == String(repeating: "字", count: 100))
    #expect(task?.messages.last?.isStreaming == false)
    await service.setSnapshotChangedHandler(nil)
    await service.stop()
}

@Test func quotaRefreshPrecedesHistoryAndServerExitIsNotOnline() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-quota-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    case "$request" in *'"method":"account'*'rateLimits'*'read"'*) ;; *) exit 10 ;; esac
    printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
    IFS= read -r request
    case "$request" in *'"method":"model'*'list"'*) ;; *) exit 12 ;; esac
    printf '%s\\n' '{"id":3,"result":{"data":[]}}'
    IFS= read -r request
    case "$request" in *'"method":"thread'*'list"'*) ;; *) exit 11 ;; esac
    printf '%s\\n' '{"id":4,"result":{"data":[]}}'
    IFS= read -r request
    printf '%s\\n' '{"id":5,"result":{"summary":{},"dailyUsageBuckets":null}}'
    sleep 1
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), isolateCommandSessions: false)
    try await service.start(preferManagedDaemon: false)
    #expect(await service.snapshot().usage?.primary?.remainingPercent == 88)
    #expect(await service.snapshot().bridgeConnected)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(!(await service.snapshot().bridgeConnected))
    await service.stop()
}

@Test func newCodexStaysVisibleAndSupportsThreeExactChineseMessages() async throws {
    let prompts = ["你好，你是什么模型？", "继续测试：请保留中文、标点🙂", "第三轮确认：原消息不要改成 aaaaaa。"]
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-conversation-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    case "$request" in *'"method":"thread'*'start"'*) ;; *) exit 10 ;; esac
    case "$request" in *'"sandbox":"read-only"'*) ;; *) exit 11 ;; esac
    printf '%s\\n' '{"id":2,"result":{"thread":{"id":"new-codex","preview":"新建测试任务","status":{"type":"active","activeFlags":[]}}}}'
    IFS= read -r request
    case "$request" in *'"method":"turn'*'start"'*) ;; *) exit 12 ;; esac
    case "$request" in *'\(prompts[0])'*) ;; *) exit 13 ;; esac
    printf '%s\\n' '{"id":3,"result":{}}'
    IFS= read -r request
    case "$request" in *'"method":"thread'*'resume"'*) ;; *) exit 14 ;; esac
    printf '%s\\n' '{"id":4,"result":{}}'
    IFS= read -r request
    case "$request" in *'\(prompts[1])'*) ;; *) exit 15 ;; esac
    printf '%s\\n' '{"id":5,"result":{}}'
    IFS= read -r request
    case "$request" in *'"method":"thread'*'resume"'*) ;; *) exit 16 ;; esac
    printf '%s\\n' '{"id":6,"result":{}}'
    IFS= read -r request
    case "$request" in *'\(prompts[2])'*) ;; *) exit 17 ;; esac
    printf '%s\\n' '{"id":7,"result":{}}'
    IFS= read -r request
    case "$request" in *'"method":"thread'*'items'*'list"'*) ;; *) exit 18 ;; esac
    printf '%s\\n' '{"id":8,"result":{"data":[{"turnId":"fixture-turn","item":{"id":"reply","type":"agentMessage","text":"三轮完成"}}],"nextCursor":null}}'
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), isolateCommandSessions: false)
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    do {
        let first = TaskCommand(id: "send-1", taskID: TaskCommand.newChatTaskID, prompt: prompts[0], deviceID: "watch")
        try await service.send(first)
        let task = try #require(await service.task(threadID: "new-codex"))
        #expect(!task.isChat && !task.isNativeChat && task.isBridgeManaged && AgentTaskPresentation.isVisible(task))
        for index in 1..<3 {
            try await service.send(TaskCommand(id: "send-\(index + 1)", taskID: task.id, prompt: prompts[index], deviceID: "watch"))
        }
        // Replaying a delivery ID must not start an additional turn.
        try await service.send(first)
        #expect(await service.task(threadID: task.id)?.messages.filter { $0.role == .user }.map(\.text) == prompts)
        for identifier in [TaskCommand.legacyNewChatTaskID, TaskCommand.newNativeChatTaskID, "chatgpt-chat:old"] {
            await #expect(throws: CodexCompanionCommandError.self) {
                try await service.send(TaskCommand(taskID: identifier, prompt: "retired", deviceID: "watch"))
            }
        }
        let history = try await service.history(TaskHistoryRequest(taskID: task.id))
        #expect(history.messages.last?.text == "三轮完成")
        await service.stop()
    } catch {
        await service.stop()
        throw error
    }
}

@Test func legacyServicePagesHistoryWithoutResumingOrMutatingTasks() async throws {
    let text = String(repeating: "完整的历史回复。🙂", count: 300)
    let items: [JSONValue] = (0..<55).map { index in
        .object(["id": .string("message-\(index)"), "type": .string("agentMessage"), "text": .string(text)])
    }
    let result: JSONValue = .object(["thread": .object(["turns": .array([.object(["items": .array(items)])])])])
    let resultJSON = String(decoding: try CodexWatchCoding.makeEncoder().encode(result), as: UTF8.self)
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-history-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    case "$request" in *'"method":"thread'*'items'*'list"'*) ;; *) exit 12 ;; esac
    printf '%s\\n' '{"id":2,"error":{"code":-32601,"message":"legacy fixture: method not found"}}'
    for response_id in 3 4; do
      IFS= read -r request
      case "$request" in
        *'"method":"thread'*'read"'*) ;;
        *) exit 10 ;;
      esac
      case "$request" in
        *'"includeTurns":true'*)
          printf '{"id":%s,"result":%s}\\n' "$response_id" '\(resultJSON)' ;;
        *) exit 11 ;;
      esac
    done
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL))
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    do {
        let latest = try await service.history(TaskHistoryRequest(taskID: "history"))
        let older = try await service.history(TaskHistoryRequest(taskID: "history", beforeMessageID: latest.nextBeforeMessageID))
        #expect(!latest.messages.isEmpty && latest.messages.count <= 20 && latest.messages.last?.text == text)
        #expect(older.messages.last?.id != latest.messages.first?.id)
        #expect(older.messages.last?.text == text)
        #expect(await service.snapshot().tasks.isEmpty)
        await service.stop()
    } catch {
        await service.stop()
        throw error
    }
}

@Test func fullHistoryParserDoesNotCapOrDuplicateRows() {
    let text = String(repeating: "完整内容🙂", count: 1_000)
    let items: [JSONValue] = (0..<55).map { index in
        .object(["id": .string("item-\(index)"), "type": .string("agentMessage"), "text": .string(text)])
    }
    let result: JSONValue = .object(["thread": .object(["turns": .array([.object(["items": .array(items + [items[0]])])])])])
    let messages = ThreadHistoryParser.messages(from: result)
    #expect(messages.count == 55)
    #expect(messages.last?.id == "item-54")
    #expect(messages.last?.text == text)
}
@Test func codexExecutableDiscoverySupportsCurrentDesktopBundle() throws {
    let path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    let result = try CodexExecutableLocator.resolve(environment: [:], isExecutable: { $0 == path })
    #expect(result.path == path)
}

@Test func codexExecutableDiscoveryPreservesOverridesAndLegacyFallbacks() throws {
    let override = URL(fileURLWithPath: "/tmp/test-private-codex")
    let available = Set([override.path, "/custom/codex", "/opt/homebrew/bin/codex"])
    let result = try CodexExecutableLocator.resolve(
        overriding: override, environment: ["CODEX_BIN": "/custom/codex"],
        isExecutable: available.contains
    )
    #expect(result == override)
    let environmentResult = try CodexExecutableLocator.resolve(
        environment: ["CODEX_BIN": "/custom/codex"], isExecutable: available.contains
    )
    #expect(environmentResult.path == "/custom/codex")
    let fallback = try CodexExecutableLocator.resolve(environment: [:], isExecutable: available.contains)
    #expect(fallback.path == "/opt/homebrew/bin/codex")
    let legacy = "/Applications/ChatGPT.app/Contents/Resources/codex"
    #expect(try CodexExecutableLocator.resolve(environment: [:], isExecutable: { $0 == legacy }).path == legacy)
}

@Test func codexExecutableDiscoveryRejectsMissingExecutables() {
    #expect(throws: AppServerClientError.self) {
        try CodexExecutableLocator.resolve(environment: ["CODEX_BIN": "/missing"], isExecutable: { _ in false })
    }
}

@Test func threadAndRateLimitMapping() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("thread-1"),
                "name": .string("Apple Watch 控制中心"),
                "preview": .string("Build watch app"),
                "updatedAt": .number(100),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([]),
                ]),
            ]),
        ]),
    ]), now: Date(timeIntervalSince1970: 101))
    await store.applyRateLimits(.object([
        "rateLimits": .object([
            "planType": .string("plus"),
            "primary": .object([
                "usedPercent": .number(11),
                "windowDurationMins": .number(10_080),
                "resetsAt": .number(200),
            ]),
        ]),
        "rateLimitResetCredits": .object(["availableCount": .number(3)]),
    ]), now: Date(timeIntervalSince1970: 102))

    let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 103))
    #expect(snapshot.tasks.first?.state == .running)
    #expect(snapshot.tasks.first?.title == "Apple Watch 控制中心")
    #expect(snapshot.usage?.primary?.remainingPercent == 89)
    #expect(snapshot.usage?.resetCreditsAvailable == 3)
}

@Test func dailyTokenUsageMapsTodayAndLeavesAnEmptyHistoryUnavailable() async {
    let store = CodexSnapshotStore()
    await store.applyRateLimits(.object([
        "rateLimits": .object([
            "planType": .string("plus"),
        ]),
    ]))

    let formatter = ISO8601DateFormatter()
    await store.applyUsage(.object([
        "dailyUsageBuckets": .array([
            .object([
                "startDate": .string(formatter.string(from: Date())),
                "tokens": .integer(12_345),
            ]),
        ]),
        "summary": .object([:]),
    ]))
    let populatedSnapshot = await store.snapshot()
    #expect(populatedSnapshot.usage?.todayTokens == 12_345)

    await store.applyUsage(.object([
        "dailyUsageBuckets": .array([]),
        "summary": .object([:]),
    ]))
    let emptySnapshot = await store.snapshot()
    #expect(emptySnapshot.usage?.todayTokens == nil)
}

@Test func reliableBridgeActionsAreAcknowledgedOnlyOnce() {
    let deduplicator = BridgeMessageDeduplicator(capacity: 2)

    #expect(deduplicator.begin("reset-1") == .started)
    #expect(deduplicator.begin("reset-1") == .inFlight)

    deduplicator.finish("reset-1", outcome: "reset")
    #expect(deduplicator.begin("reset-1") == .completed(outcome: "reset"))

    #expect(deduplicator.begin("approval-1") == .started)
    deduplicator.cancel("approval-1")
    #expect(deduplicator.begin("approval-1") == .started)
}

@Test func machineGeneratedThreadPreviewIsNeverShownAsATitle() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("voice-thread"),
                "preview": .string("""
                    <realtime_delegation>
                      <input>Test spoken English</input>
                    </realtime_delegation>
                    """),
                "updatedAt": .number(100),
                "status": .object(["type": .string("idle")]),
            ]),
        ]),
    ]), now: Date(timeIntervalSince1970: 101))

    let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 102))
    #expect(snapshot.tasks.isEmpty)
}

@Test func rootWorkingDirectoryIsHiddenFromConversationDetails() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("root-directory-thread"),
                "name": .string("A real conversation"),
                "cwd": .string("/"),
                "status": .object(["type": .string("idle")]),
            ]),
        ]),
    ]))

    let task = await store.snapshot().tasks.first
    #expect(task?.title == "A real conversation")
    #expect(task?.workspace == nil)
    #expect(AgentTaskPresentation.workspace("/") == nil)
}

@Test func watchSnapshotCompactionKeepsActiveTaskAndBoundsHistory() {
    let now = Date()
    let longText = String(repeating: "x", count: 4_000)
    let active = AgentTask(
        id: "active",
        title: longText,
        detail: longText,
        state: .running,
        updatedAt: now,
        messages: (0..<10).map {
            ChatMessage(id: "active-\($0)", role: .assistant, text: longText, createdAt: now)
        }
    )
    let old = AgentTask(
        id: "old",
        title: "Older task",
        state: .completed,
        updatedAt: now.addingTimeInterval(-1_000),
        messages: [ChatMessage(id: "old-message", role: .user, text: longText, createdAt: now)]
    )
    let snapshot = DashboardSnapshot(
        tasks: [old, active],
        bridgeConnected: true,
        capturedAt: now
    )

    let compact = snapshot.compactForWatch(
        maximumTasks: 1,
        messagesPerTask: 2,
        maximumTextLength: 120,
        maximumApprovals: 1
    )

    #expect(compact.tasks.map(\.id) == ["active"])
    #expect(compact.tasks[0].messages.count == 2)
    #expect(compact.tasks[0].title.count <= 121)
    #expect(compact.tasks[0].messages.allSatisfy { $0.text.count <= 121 })
}

@Test func internalThreadNameIsIgnoredInFavorOfUserVisibleTitle() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("internal-thread"),
                "name": .string("<realtime_delegation><input>internal</input>"),
                "title": .string("Plan Apple Watch control"),
                "status": .object(["type": .string("idle")]),
            ]),
        ]),
    ]))

    let snapshot = await store.snapshot()
    #expect(snapshot.tasks.first?.title == "Plan Apple Watch control")
}

@Test func threadReadHistoryIsMappedToConversationMessages() async {
    let store = CodexSnapshotStore()
    let timestamp = Date(timeIntervalSince1970: 1_000)
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("thread-history"),
                "name": .string("Design review"),
                "status": .object(["type": .string("idle")]),
            ]),
        ]),
    ]), now: timestamp)

    // This is the current desktop ChatGPT app-server shape:
    // thread/read(includeTurns: true) -> thread.turns[].items[].
    await store.applyThreadItems(threadID: "thread-history", result: .object([
        "thread": .object([
            "turns": .array([
                .object([
                    "items": .array([
                        .object([
                            "id": .string("user-1"),
                            "type": .string("userMessage"),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("Review this")]),
                            ]),
                        ]),
                        .object([
                            "id": .string("assistant-1"),
                            "type": .string("agentMessage"),
                            "text": .string("Here is the review."),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ]), now: timestamp)

    let messages = await store.snapshot().tasks.first?.messages
    #expect(messages?.map(\.role) == [.user, .assistant])
    #expect(messages?.map(\.text) == ["Review this", "Here is the review."])
}

@Test func confirmedServerEchoDoesNotLeaveProvisionalPromptsAfterReplies() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([
        .object(["id": .string("echo-thread"), "name": .string("Echo test"), "status": .object(["type": .string("idle")])]),
    ])]))
    var items: [JSONValue] = []
    for round in 1...3 {
        let prompt = "第\(round)轮测试"
        await store.recordUserMessage(threadID: "echo-thread", id: "local-\(round)", text: prompt)
        items.append(.object(["id": .string("server-user-\(round)"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string(prompt)])])]))
        items.append(.object(["id": .string("server-reply-\(round)"), "type": .string("agentMessage"), "text": .string("回复\(round)")]))
        let history = JSONValue.object(["thread": .object(["turns": .array([.object(["items": .array(items)])])])])
        await store.applyThreadItems(threadID: "echo-thread", result: history)
        await store.applyThreadItems(threadID: "echo-thread", result: history)
    }
    let task = await store.task(threadID: "echo-thread")
    #expect(task?.messages.map(\.text) == ["第1轮测试", "回复1", "第2轮测试", "回复2", "第3轮测试", "回复3"])
    #expect(task?.messages.suffix(4).map(\.role) == [.user, .assistant, .user, .assistant])
}

@Test func oldEchoCannotAcknowledgeANewRepeatedPrompt() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([
        .object(["id": .string("repeat-thread"), "name": .string("Repeat test"), "status": .object(["type": .string("idle")])]),
    ])]))
    func history(_ ids: [String]) -> JSONValue {
        .object(["thread": .object(["turns": .array([.object(["items": .array(ids.map {
            .object(["id": .string($0), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("重复")])])])
        })])])])])
    }
    await store.applyThreadItems(threadID: "repeat-thread", result: history(["server-1"]))
    await store.recordUserMessage(threadID: "repeat-thread", id: "pending-2", text: "重复")
    await store.recordUserMessage(threadID: "repeat-thread", id: "pending-3", text: "重复")
    await store.applyThreadItems(threadID: "repeat-thread", result: history(["server-1"]))
    #expect(await store.task(threadID: "repeat-thread")?.messages.map(\.id) == ["server-1", "pending-2", "pending-3"])
    await store.applyThreadItems(threadID: "repeat-thread", result: history(["server-1", "server-2"]))
    #expect(await store.task(threadID: "repeat-thread")?.messages.map(\.id) == ["server-1", "server-2", "pending-3"])
    await store.applyThreadItems(threadID: "repeat-thread", result: history(["server-1", "server-2", "server-3"]))
    #expect(await store.task(threadID: "repeat-thread")?.messages.map(\.id) == ["server-1", "server-2", "server-3"])
}

@Test func onlyBridgeCreatedThreadsAreMarkedControllable() async {
    let store = CodexSnapshotStore()
    let now = Date(timeIntervalSince1970: 1_000)
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("desktop-thread"),
                "name": .string("Desktop work"),
                "status": .object(["type": .string("idle")]),
            ]),
        ]),
    ]), now: now)

    await store.seedManagedTask(
        .object([
            "id": .string("bridge-thread"),
            "name": .string("Bridge work"),
            "status": .object(["type": .string("idle")]),
        ]),
        initialPrompt: "Check the bridge",
        messageID: "message-1",
        isChat: false,
        now: now
    )

    #expect(await store.isBridgeManaged(threadID: "desktop-thread") == false)
    #expect(await store.isBridgeManaged(threadID: "bridge-thread") == true)
    let tasks = await store.snapshot(now: now).tasks
    #expect(tasks.first(where: { $0.id == "desktop-thread" })?.isBridgeManaged == false)
    #expect(tasks.first(where: { $0.id == "bridge-thread" })?.isBridgeManaged == true)
}

@Test func desktopFollowerMessageIsRecordedWithoutChangingTaskOwnership() async {
    let store = CodexSnapshotStore()
    let now = Date(timeIntervalSince1970: 1_000)
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("desktop-thread"),
                "name": .string("Desktop work"),
                "status": .object(["type": .string("active")]),
            ]),
        ]),
    ]), now: now)

    await store.recordUserMessage(
        threadID: "desktop-thread",
        id: "watch-message",
        text: "Continue from the Watch",
        now: now.addingTimeInterval(1)
    )

    let task = await store.task(threadID: "desktop-thread")
    #expect(task?.messages.last?.id == "watch-message")
    #expect(task?.messages.last?.text == "Continue from the Watch")
    #expect(task?.isBridgeManaged == false)
}

@Test func resumedActiveTurnRestoresSteeringTarget() async {
    let store = CodexSnapshotStore()
    let now = Date(timeIntervalSince1970: 1_000)
    await store.applyThreadList(.object([
        "data": .array([
            .object([
                "id": .string("bridge-thread"),
                "name": .string("Bridge work"),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([]),
                ]),
            ]),
        ]),
    ]), now: now)
    await store.applyThreadItems(threadID: "bridge-thread", result: .object([
        "thread": .object([
            "turns": .array([
                .object([
                    "id": .string("turn-active"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ]),
        ]),
    ]), now: now)

    let task = await store.snapshot(now: now).tasks.first
    #expect(task?.activeTurnID == "turn-active")
    #expect(task?.state == .running)
}

@Test func approvalIsBoundToDigestAndNonce() async throws {
    let store = CodexSnapshotStore()
    let recorder = ResponseRecorder()
    let broker = ApprovalBroker(store: store) { id, result in
        await recorder.record(id: id, result: result)
    }
    let event = AppServerEvent(
        method: "item/commandExecution/requestApproval",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "command": .string("swift test"),
            "cwd": .string("/tmp/project"),
            "availableDecisions": .array([.string("accept"), .string("decline")]),
        ]),
        requestID: .integer(42)
    )
    let request = try await broker.register(event, now: Date())
    let decision = ApprovalDecision(
        requestID: request.id,
        requestDigest: request.requestDigest,
        choice: .allowOnce,
        decidedAt: Date(),
        deviceID: "watch",
        nonce: request.nonce
    )
    try await broker.submit(decision)

    let recorded = await recorder.last
    #expect(recorded?.id == .integer(42))
    #expect(recorded?.result["decision"]?.stringValue == "accept")
    let snapshot = await store.snapshot()
    #expect(snapshot.pendingApprovals.isEmpty)
}

@Test func watchApprovalOriginRoundTripsAcrossTheRelayProtocol() throws {
    let decision = ApprovalDecision(
        requestID: "approval-1",
        requestDigest: "digest",
        choice: .allowOnce,
        decidedAt: Date(timeIntervalSince1970: 1_000),
        deviceID: "watch-device",
        nonce: "nonce",
        origin: .watch
    )
    let envelope = BridgeEnvelope.decision(decision, sender: "watch-device")
    let data = try CodexWatchCoding.makeEncoder().encode(envelope)
    let decoded = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
    #expect(decoded.decision?.origin == .watch)
}

@Test func permissionApprovalUsesCurrentAppServerResponseShape() async throws {
    let store = CodexSnapshotStore()
    let recorder = ResponseRecorder()
    let broker = ApprovalBroker(store: store) { id, result in
        await recorder.record(id: id, result: result)
    }
    let permissions: JSONValue = .object([
        "network": .object(["enabled": .bool(true)]),
    ])
    let now = Date(timeIntervalSince1970: 1_000)
    let event = AppServerEvent(
        method: "item/permissions/requestApproval",
        params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "permissions": permissions,
            "cwd": .string("/tmp/project"),
        ]),
        requestID: .integer(43)
    )
    let request = try await broker.register(event, now: now)
    #expect(request.expiresAt.timeIntervalSince(now) == 15 * 60)

    try await broker.submit(
        ApprovalDecision(
            requestID: request.id,
            requestDigest: request.requestDigest,
            choice: .allowOnce,
            decidedAt: now,
            deviceID: "watch",
            nonce: request.nonce
        ),
        now: now
    )

    let recorded = await recorder.last
    #expect(recorded?.id == .integer(43))
    #expect(recorded?.result["scope"]?.stringValue == "turn")
    #expect(recorded?.result["permissions"] == permissions)
}

@Test func desktopApprovalUsesExternalResponderAndDeduplicatesStreamSnapshots() async throws {
    let store = CodexSnapshotStore()
    let appServerRecorder = ResponseRecorder()
    let desktopRecorder = ResponseRecorder()
    let broker = ApprovalBroker(store: store) { id, result in
        await appServerRecorder.record(id: id, result: result)
    }
    let event = AppServerEvent(
        method: "item/fileChange/requestApproval",
        params: .object([
            "threadId": .string("desktop-thread"),
            "turnId": .string("desktop-turn"),
            "itemId": .string("desktop-item"),
            "reason": .string("Update the project"),
        ]),
        requestID: .string("desktop-request")
    )
    let first = try await broker.registerExternal(
        event,
        externalKey: "desktop\u{1F}desktop-thread\u{1F}desktop-request"
    ) { id, result in
        await desktopRecorder.record(id: id, result: result)
    }
    let duplicate = try await broker.registerExternal(
        event,
        externalKey: "desktop\u{1F}desktop-thread\u{1F}desktop-request"
    ) { id, result in
        await desktopRecorder.record(id: id, result: result)
    }
    #expect(first.id == duplicate.id)
    #expect(await store.snapshot().pendingApprovals.count == 1)

    try await broker.submit(ApprovalDecision(
        requestID: first.id,
        requestDigest: first.requestDigest,
        choice: .deny,
        decidedAt: Date(),
        deviceID: "watch",
        nonce: first.nonce
    ))

    #expect(await desktopRecorder.last?.id == .string("desktop-request"))
    #expect(await desktopRecorder.last?.result["decision"]?.stringValue == "decline")
    #expect(await appServerRecorder.last == nil)
    #expect(await store.snapshot().pendingApprovals.isEmpty)
}

@Test func desktopApprovalDisappearingFromFollowerSnapshotIsResolved() async throws {
    let store = CodexSnapshotStore()
    let recorder = ResponseRecorder()
    let broker = ApprovalBroker(store: store) { _, _ in }
    let externalKey = "desktop\u{1F}thread\u{1F}request"
    _ = try await broker.registerExternal(
        AppServerEvent(
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "command": .string("swift test"),
            ]),
            requestID: .string("request")
        ),
        externalKey: externalKey
    ) { id, result in
        await recorder.record(id: id, result: result)
    }
    #expect(await store.snapshot().pendingApprovals.count == 1)

    await broker.resolve(externalKey: externalKey)

    #expect(await store.snapshot().pendingApprovals.isEmpty)
    #expect(await recorder.last == nil)
}

@Test func mcpToolElicitationCanBeApprovedFromWatch() async throws {
    let store = CodexSnapshotStore()
    let recorder = ResponseRecorder()
    let broker = ApprovalBroker(store: store) { id, result in
        await recorder.record(id: id, result: result)
    }
    let event = AppServerEvent(
        method: "mcpServer/elicitation/request",
        params: .object([
            "threadId": .string("desktop-thread"),
            "turnId": .string("desktop-turn"),
            "mode": .string("form"),
            "serverName": .string("computer-use"),
            "message": .string("Allow ChatGPT to use Safari?"),
            "requestedSchema": .object(["properties": .object([:])]),
            "_meta": .object([
                "codex_approval_kind": .string("mcp_tool_call"),
                "connector_id": .string("computer-use"),
                "connector_name": .string("Computer Use"),
                "tool_title": .string("Safari"),
                "tool_params": .object(["app": .string("Safari")]),
            ]),
        ]),
        requestID: .string("mcp-request")
    )

    let request = try await broker.register(event)
    #expect(request.kind == .permissions)
    #expect(request.title == "Safari")
    #expect(request.summary == "Allow ChatGPT to use Safari?")

    try await broker.submit(ApprovalDecision(
        requestID: request.id,
        requestDigest: request.requestDigest,
        choice: .allowOnce,
        decidedAt: Date(),
        deviceID: "watch",
        nonce: request.nonce
    ))

    #expect(await recorder.last?.id == .string("mcp-request"))
    #expect(await recorder.last?.result["action"]?.stringValue == "accept")
    #expect(await recorder.last?.result["content"]?.objectValue?.isEmpty == true)
    #expect(await recorder.last?.result["_meta"] == .null)
}

@Test func mcpFormRequiringInputIsNotTreatedAsApproval() async throws {
    let store = CodexSnapshotStore()
    let broker = ApprovalBroker(store: store) { _, _ in }
    let event = AppServerEvent(
        method: "mcpServer/elicitation/request",
        params: .object([
            "threadId": .string("desktop-thread"),
            "turnId": .string("desktop-turn"),
            "mode": .string("form"),
            "serverName": .string("calendar"),
            "message": .string("Choose a calendar"),
            "requestedSchema": .object([
                "properties": .object([
                    "calendar": .object(["type": .string("string")]),
                ]),
            ]),
        ]),
        requestID: .string("form-request")
    )

    await #expect(throws: ApprovalBrokerError.unsupportedRequest) {
        try await broker.register(event)
    }
}

@Test func changedDesktopApprovalInvalidatesThePreviouslyReviewedRequest() async throws {
    let store = CodexSnapshotStore()
    let broker = ApprovalBroker(store: store) { _, _ in }
    let externalKey = "desktop\u{1F}thread\u{1F}request"
    let original = try await broker.registerExternal(
        AppServerEvent(
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "command": .string("swift test"),
            ]),
            requestID: .string("request")
        ),
        externalKey: externalKey
    ) { _, _ in }
    let changed = try await broker.registerExternal(
        AppServerEvent(
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread"),
                "turnId": .string("turn"),
                "itemId": .string("item"),
                "command": .string("swift test --enable-code-coverage"),
            ]),
            requestID: .string("request")
        ),
        externalKey: externalKey
    ) { _, _ in }

    #expect(changed.id != original.id)
    #expect(changed.requestDigest != original.requestDigest)
    #expect(await store.snapshot().pendingApprovals.map(\.id) == [changed.id])

    await #expect(throws: ApprovalBrokerError.requestNotFound) {
        try await broker.submit(ApprovalDecision(
            requestID: original.id,
            requestDigest: original.requestDigest,
            choice: .allowOnce,
            decidedAt: Date(),
            deviceID: "watch",
            nonce: original.nonce
        ))
    }
}

@Test func nativeChatProjectionKeepsTheRealAssistantReply() async {
    let store = CodexSnapshotStore()
    let started = Date(timeIntervalSince1970: 1_000)
    await store.seedNativeChat(
        id: "native-chat",
        initialPrompt: "Explain the relay",
        messageID: "user-1",
        now: started
    )
    await store.applyNativeChatTranscript(
        id: "native-chat",
        messages: [
            ChatMessage(id: "user-1", role: .user, text: "Explain the relay", createdAt: started),
            ChatMessage(
                id: "assistant-1",
                role: .assistant,
                text: "The relay carries encrypted companion updates.",
                createdAt: started.addingTimeInterval(1)
            ),
        ],
        now: started.addingTimeInterval(2)
    )

    let task = await store.snapshot(now: started.addingTimeInterval(3)).tasks.first
    #expect(task?.isNativeChat == true)
    #expect(task?.state == .completed)
    #expect(task?.messages.map(\.text) == ["Explain the relay", "The relay carries encrypted companion updates."])
}

@Test func transcriptRefreshDoesNotRouteNativeChatThroughAppServer() async {
    let store = CodexSnapshotStore()
    await store.seedNativeChat(
        id: "chatgpt-chat:native",
        initialPrompt: "Hello",
        messageID: "native-user"
    )
    await store.seedThread(
        .object([
            "id": .string("codex-thread"),
            "name": .string("A Codex task"),
            "status": .object(["type": .string("idle")]),
        ]),
        initialPrompt: "Run the tests",
        messageID: "codex-user"
    )

    let transcriptIDs = await store.transcriptThreadIDs(limit: 100)
    #expect(transcriptIDs == ["codex-thread"])
}

@Test func nativeChatProjectionKeepsMultiTurnOrderAcrossRepeatedSnapshots() async {
    let store = CodexSnapshotStore()
    let timestamp = Date(timeIntervalSince1970: 2_000)
    await store.seedNativeChat(
        id: "native-multi-turn",
        initialPrompt: "第一轮",
        messageID: "user-1",
        now: timestamp
    )

    // Deliberately give every message the same timestamp. This reproduces the
    // coarse timestamp precision seen in some desktop/browser projections.
    let firstSnapshot = [
        ChatMessage(id: "user-1", role: .user, text: "第一轮", createdAt: timestamp),
        ChatMessage(id: "assistant-1", role: .assistant, text: "第一轮回复", createdAt: timestamp),
        ChatMessage(id: "user-2", role: .user, text: "第二轮", createdAt: timestamp),
        ChatMessage(id: "assistant-2", role: .assistant, text: "第二轮回复", createdAt: timestamp),
    ]
    await store.applyNativeChatTranscript(
        id: "native-multi-turn",
        messages: firstSnapshot,
        now: timestamp.addingTimeInterval(1)
    )

    // A later heartbeat repeats the transcript and updates only the last
    // answer. It must replace that row in place, not duplicate or reorder it.
    var secondSnapshot = firstSnapshot
    secondSnapshot[3] = ChatMessage(
        id: "assistant-2",
        role: .assistant,
        text: "第二轮回复（最终）",
        createdAt: timestamp
    )
    await store.applyNativeChatTranscript(
        id: "native-multi-turn",
        messages: secondSnapshot + [secondSnapshot[1]],
        now: timestamp.addingTimeInterval(2)
    )

    let task = await store.snapshot(now: timestamp.addingTimeInterval(3)).tasks.first
    #expect(task?.messages.map(\.id) == ["user-1", "assistant-1", "user-2", "assistant-2"])
    #expect(task?.messages.map(\.text) == ["第一轮", "第一轮回复", "第二轮", "第二轮回复（最终）"])
}

@Test func appServerReaderSerializesAHighVolumeEventStream() async throws {
    // Feed the client a burst large enough to reproduce the old readability
    // callback/task buildup. The private executable override ensures this
    // test never starts the user's real ChatGPT app-server.
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-flood-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    i=0
    while [ "$i" -lt 4000 ]; do
      printf '{"method":"test/event","params":{"index":%s}}\\n' "$i"
      i=$((i + 1))
    done
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: scriptURL.path
    )
    defer {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    let count = EventCounter()
    let client = AppServerClient(executableURL: scriptURL)
    await client.setEventHandler { event in
        guard event.method == "test/event" else { return }
        await count.increment()
    }
    _ = try await client.start()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if await count.value >= 4_000 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await client.stop()
    #expect(await count.value == 4_000)
}

@Test func appServerReaderDoesNotOverlapSlowEventHandlers() async throws {
    // A count-only flood test can pass even if every readability callback
    // starts a concurrent handler.  Hold each event handler open briefly and
    // verify that the reader still preserves both ordering and single-flight
    // delivery.
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-ordered-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    i=0
    while [ "$i" -lt 200 ]; do
      printf '{"method":"test/ordered","params":{"index":%s}}\\n' "$i"
      i=$((i + 1))
    done
    # Keep stdout alive until the parent closes stdin. A fixed one-second
    # exit can cancel buffered handlers on a loaded CI runner.
    IFS= read -r finished
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: scriptURL.path
    )
    defer {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    let probe = OrderedEventProbe()
    let client = AppServerClient(executableURL: scriptURL)
    await client.setEventHandler { event in
        guard event.method == "test/ordered",
              let index = event.params["index"]?.intValue else { return }
        await probe.record(index)
    }
    _ = try await client.start()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if await probe.count >= 200 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await client.stop()
    #expect(await probe.count == 200)
    #expect(await probe.maxInFlight == 1)
    #expect(await probe.orderViolations == 0)
}

@Test func appServerReaderHandlesAFragmentedLongJsonLineWithoutRescanning() async throws {
    // Keep the JSON object on one logical line but write its payload in many
    // separate pipe chunks. This is the exact shape that used to make the
    // parser scan the already-inspected prefix over and over (O(n²)).
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-fragmented-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    printf '%s' '{"method":"test/partial","params":{"payload":"'
    i=0
    while [ "$i" -lt 2000 ]; do
      printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
      if [ $((i % 20)) -eq 0 ]; then sleep 0.001; fi
      i=$((i + 1))
    done
    printf '%s\\n' '"}}'
    sleep 1
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: scriptURL.path
    )
    defer {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    let payloadLength = 2_000 * 64
    let received = EventCounter()
    let client = AppServerClient(executableURL: scriptURL)
    await client.setEventHandler { event in
        guard event.method == "test/partial",
              event.params["payload"]?.stringValue?.count == payloadLength else { return }
        await received.increment()
    }
    _ = try await client.start()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if await received.value == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await client.stop()
    #expect(await received.value == 1)
}

@Test func appServerLifecycleHandlerFiresWhenChildExits() async throws {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-lifecycle-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r exit_request
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: scriptURL.path
    )
    defer {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    let exited = EventCounter()
    let client = AppServerClient(executableURL: scriptURL)
    await client.setLifecycleHandler {
        await exited.increment()
    }
    _ = try await client.start()

    // Exit after the startup handshake, not on a wall-clock timer that can
    // expire while a loaded CI runner is still resuming initialize().
    do {
        _ = try await client.request(method: "test/exit", timeout: .seconds(5))
        Issue.record("exited child unexpectedly answered exit request")
    } catch AppServerClientError.processExited {
        // Expected: the fixture exits without replying to the final request.
    } catch {
        Issue.record("unexpected exit error: \(error)")
    }

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if await exited.value == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await client.stop()
    #expect(await exited.value == 1)
}

private actor ResponseRecorder {
    struct Entry: Sendable {
        let id: AppServerRequestID
        let result: JSONValue
    }

    private(set) var last: Entry?

    func record(id: AppServerRequestID, result: JSONValue) {
        last = Entry(id: id, result: result)
    }
}

private actor EventCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor OrderedEventProbe {
    private(set) var count = 0
    private(set) var maxInFlight = 0
    private(set) var orderViolations = 0
    private var inFlight = 0

    func record(_ index: Int) async {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if index != count {
            orderViolations += 1
        }
        try? await Task.sleep(for: .milliseconds(1))
        count += 1
        inFlight -= 1
    }
}
