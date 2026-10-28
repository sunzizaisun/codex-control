import Foundation
import CodexBridgeKit
import CodexWatchCore

@main
struct CodexWatchSelfTest {
    static func main() async throws {
        if CommandLine.arguments.contains("--relay-v2-local") {
            try await testLocalSecureRelay()
            return
        }
        if CommandLine.arguments.contains("--probe-models") {
            let client = AppServerClient()
            try await client.start(preferManagedDaemon: false)
            do {
                let result = try await client.request(method: "model/list", params: .object(["limit": .integer(100), "includeHidden": .bool(false)]), timeout: .seconds(15))
                let store = CodexSnapshotStore()
                await store.applyModels(result)
                let models = await store.snapshot().models
                print(String(decoding: try JSONEncoder().encode(models), as: UTF8.self))
                await client.stop()
            } catch { await client.stop(); throw error }
            return
        }
        if CommandLine.arguments.contains("--probe-status") {
            let client = AppServerClient()
            try await client.start(preferManagedDaemon: false)
            do {
                let limits = try await client.request(method: "account/rateLimits/read", timeout: .seconds(15))
                let bucket = limits["rateLimitsByLimitId"]?["codex"] ?? limits["rateLimits"]
                for name in ["primary", "secondary"] {
                    guard let window = bucket?[name] else { continue }
                    print("\(name): usedPercent=\(window["usedPercent"]?.doubleValue ?? -1), windowMinutes=\(window["windowDurationMins"]?.doubleValue ?? -1), resetsAt=\(window["resetsAt"]?.doubleValue ?? -1)")
                }
                await client.stop()
            } catch {
                await client.stop()
                throw error
            }
            return
        }
        if CommandLine.arguments.contains("--probe-installed") {
            let service = CodexBridgeService()
            // Initialize only: never resume or mutate the user's conversations
            // when checking whether the installed desktop CLI can be launched.
            try await service.start(refreshImmediately: false, preferManagedDaemon: false)
            let running = await service.isRunning()
            await service.stop()
            guard running else { throw Failure("installed app-server handshake") }
            print("Installed app-server handshake passed; no conversations were changed")
            return
        }
        if CommandLine.arguments.contains("--probe-conversation") || CommandLine.arguments.contains("--probe-conversation-models") {
            try await testInstalledConversation(withModelChanges: CommandLine.arguments.contains("--probe-conversation-models"))
            return
        }
        try testWireRoundTrip()
        try await testSnapshotMapping()
        try await testApprovalBinding()
        print("Codex Watch self-test passed")
    }

    private static func testLocalSecureRelay() async throws {
        // This fixture has no app-server, desktop IPC, account or device
        // dependency. The destination is fixed to the isolated local Worker.
        let credentials = try RelayCredentials.migrating(secret: String(repeating: "fixture-only-", count: 4), roomID: "qa-room")
        let configuration = try RemoteRelayConfiguration(baseURL: URL(string: "http://127.0.0.1:18793")!, roomID: "qa-room", credentials: credentials)
        let client = RemoteRelayClient(configuration: configuration)
        if CommandLine.arguments.contains("--relay-v2-read-node") {
            guard try await client.latestSnapshot()?.snapshot?.tasks.first?.title == "Node互通🦦" else {
                throw Failure("Node to Swift authenticated encryption")
            }
            print("Node to Swift v2 authenticated encryption passed.")
            return
        }
        for mailbox in [RemoteRelayMailbox.mac, .phone, .watch] {
            let original = BridgeEnvelope(kind: .hello, senderDeviceID: "isolated-qa", message: "原文一致：海狸-428🍁")
            try await client.enqueue(original, to: mailbox)
            try await client.enqueue(original, to: mailbox)
            let messages = try await client.messages(for: mailbox)
            guard messages.filter({ $0.messageID == original.messageID }).count == 1,
                  messages.first(where: { $0.messageID == original.messageID })?.message == original.message else {
                throw Failure("secure relay exact message/dedup")
            }
            try await client.acknowledge(original.messageID, in: mailbox)
            guard try await client.messages(for: mailbox).isEmpty else { throw Failure("secure relay acknowledgement") }
        }
        let snapshot = DashboardSnapshot(tasks: [AgentTask(id: "fixture-task", title: "中文🦦", state: .running, updatedAt: Date())], bridgeConnected: true, capturedAt: Date())
        try await client.uploadSnapshot(snapshot, sender: "isolated-qa")
        guard try await client.latestSnapshot()?.snapshot?.tasks.first?.title == "中文🦦" else { throw Failure("secure snapshot") }
        print("Native Swift v2 relay passed: three mailboxes, Unicode, dedup, acknowledgement and encrypted snapshot; no Mac runtime bridge used.")
    }

    /// Opt-in integration check. Unlike --probe-installed this deliberately
    /// creates one Codex test conversation in the signed-in account. It never
    /// resumes other threads, runs tools, or approves a permission request.
    private static func testInstalledConversation(withModelChanges: Bool = false) async throws {
        var roundOptions: [CodexExecutionOptions] = []
        if withModelChanges {
            let catalogClient = AppServerClient()
            try await catalogClient.start(preferManagedDaemon: false)
            do {
                let response = try await catalogClient.request(method: "model/list", params: .object(["limit": .integer(100), "includeHidden": .bool(false)]))
                let store = CodexSnapshotStore(); await store.applyModels(response)
                let models = await store.snapshot().models
                guard let first = models.first(where: \.isDefault) ?? models.first,
                      let otherEffort = first.supportedReasoningEfforts.first(where: { $0 != first.defaultReasoningEffort }),
                      let second = models.first(where: { $0.model != first.model && $0.model.contains("luna") }) else { throw Failure("model variation unavailable") }
                roundOptions = [.init(model: first.model, effort: first.defaultReasoningEffort),
                                .init(model: first.model, effort: otherEffort),
                                .init(model: second.model, effort: second.defaultReasoningEffort)]
                await catalogClient.stop()
            } catch { await catalogClient.stop(); throw error }
        }
        let service = CodexBridgeService()
        try await service.start(refreshImmediately: false, preferManagedDaemon: false)
        do {
            let prompts = [
                "Codex Control 中文联调测试。不要使用工具、读取文件或运行命令。请记住字符串：松果-742。只回复：已记住松果-742。",
                "跟进测试：刚才要求记住的字符串是什么？不要使用工具。只回复这个字符串。",
                "第三轮测试。不要使用工具。只回复以下原文，保留中文标点和表情：中文收发成功，松果-742🙂",
            ]
            let expected = ["已记住松果-742。", "松果-742", "中文收发成功，松果-742🙂"]
            var threadID = ""
            for index in prompts.indices {
                let startedAt = Date()
                let previous = threadID.isEmpty ? [] : await service.task(threadID: threadID)?.messages ?? []
                let previousReplyIDs = Set(previous.filter { $0.role == .assistant }.map(\.id))
                let options = withModelChanges ? roundOptions[index] : nil
                if index == 0 {
                    threadID = try await service.startCodexConversation(prompt: prompts[index], options: options)
                    print("Created isolated Codex integration thread: \(threadID)")
                } else {
                    try await service.send(TaskCommand(taskID: threadID, prompt: prompts[index], deviceID: "self-test", options: options))
                }
                let deadline = Date().addingTimeInterval(90)
                var reply: ChatMessage?
                while Date() < deadline {
                    let snapshot = await service.snapshot()
                    guard snapshot.pendingApprovals.isEmpty else {
                        throw Failure("unexpected permission request; nothing approved")
                    }
                    if let task = await service.task(threadID: threadID) {
                        guard !task.isChat && task.isBridgeManaged else { throw Failure("new Codex route classification") }
                        if task.state == .failed { throw Failure(task.detail ?? "conversation turn failed") }
                        if !task.state.isActive,
                           let latest = task.messages.last(where: { $0.role == .assistant }),
                           !latest.isStreaming, !previousReplyIDs.contains(latest.id) {
                            reply = latest
                            break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard let reply else { throw Failure("turn \(index + 1) did not finish in 90 seconds") }
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
                print("Turn \(index + 1), \(elapsed)s, response: \(reply.text)")
                guard reply.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected[index] else {
                    throw Failure("turn \(index + 1) response mismatch")
                }
                if let options {
                    let task = await service.task(threadID: threadID)
                    guard task?.model == options.model, task?.reasoningEffort == options.effort else { throw Failure("accepted model settings not projected") }
                    print("Accepted settings: model=\(options.model), effort=\(options.effort)")
                }
            }
            let page = try await service.history(TaskHistoryRequest(taskID: threadID))
            let userTexts = page.messages.filter { $0.role == .user }.map(\.text)
            guard userTexts == prompts else { throw Failure("authoritative Chinese prompt history mismatch") }
            guard page.messages.filter({ $0.role == .assistant }).count == 3 else { throw Failure("three authoritative replies") }
            print("Three-turn live Codex integration passed; prompts and replies preserved in history")
            await service.stop()
            if let expected = roundOptions.last {
                // Reopen ONLY the newly created QA thread after releasing its
                // executor and verify the authoritative persisted settings.
                let verifier = AppServerClient()
                try await verifier.start(preferManagedDaemon: false)
                do {
                    let resumed = try await verifier.request(method: "thread/resume", params: .object(["threadId": .string(threadID)]))
                    guard resumed["model"]?.stringValue == expected.model,
                          resumed["reasoningEffort"]?.stringValue == expected.effort else { throw Failure("persisted model settings mismatch") }
                    print("Persisted model and reasoning settings verified after executor handoff")
                    await verifier.stop()
                } catch { await verifier.stop(); throw error }
            }
        } catch {
            await service.stop()
            throw error
        }
    }

    private static func testWireRoundTrip() throws {
        let window = UsageWindow(usedPercent: 11)
        guard window.remainingPercent == 89 else { throw Failure("remaining percent") }
        let fixedDate = Date(timeIntervalSince1970: 100)
        let snapshot = DashboardSnapshot(
            usage: UsageSnapshot(primary: window, capturedAt: fixedDate),
            bridgeConnected: true,
            capturedAt: fixedDate
        )
        let envelope = BridgeEnvelope(
            messageID: "message-1",
            sentAt: fixedDate,
            kind: .snapshot,
            senderDeviceID: "mac",
            snapshot: snapshot
        )
        let data = try CodexWatchCoding.makeEncoder().encode(envelope)
        let decoded = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
        guard decoded == envelope else { throw Failure("wire round trip") }
    }

    private static func testSnapshotMapping() async throws {
        let store = CodexSnapshotStore()
        await store.applyThreadList(.object([
            "data": .array([
                .object([
                    "id": .string("thread-1"),
                    "preview": .string("Task"),
                    "updatedAt": .number(100),
                    "status": .object([
                        "type": .string("active"),
                        "activeFlags": .array([]),
                    ]),
                ]),
            ]),
        ]))
        await store.applyEvent(method: "turn/plan/updated", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "plan": .array([
                .object(["step": .string("Inspect"), "status": .string("completed")]),
                .object(["step": .string("Build"), "status": .string("inProgress")]),
            ]),
        ]))
        let snapshot = await store.snapshot()
        guard snapshot.tasks.first?.state == .running else { throw Failure("thread mapping") }
        guard snapshot.tasks.first?.progress == 0.5,
              snapshot.tasks.first?.detail == "Build" else { throw Failure("plan mapping") }
    }

    private static func testApprovalBinding() async throws {
        let store = CodexSnapshotStore()
        let recorder = Recorder()
        let broker = ApprovalBroker(store: store) { id, result in
            await recorder.record(id, result)
        }
        let request = try await broker.register(AppServerEvent(
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "command": .string("swift test"),
                "availableDecisions": .array([.string("accept"), .string("decline")]),
            ]),
            requestID: .integer(7)
        ))
        try await broker.submit(ApprovalDecision(
            requestID: request.id,
            requestDigest: request.requestDigest,
            choice: .allowOnce,
            decidedAt: Date(),
            deviceID: "watch",
            nonce: request.nonce
        ))
        let response = await recorder.value
        guard response?.0 == .integer(7),
              response?.1["decision"]?.stringValue == "accept" else {
            throw Failure("approval binding")
        }
    }
}

private actor Recorder {
    private(set) var value: (AppServerRequestID, JSONValue)?
    func record(_ id: AppServerRequestID, _ result: JSONValue) { value = (id, result) }
}

private struct Failure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { "Self-test failed: \(reason)" }
}
