import Foundation
import Testing
@testable import CodexBridgeKit
import CodexWatchCore

private actor QuestionResponseRecorder {
    var result: JSONValue?
    var count = 0
    func record(_ value: JSONValue) { result = value; count += 1 }
}
private func questionEvent(label: String = "方案 A", timeout: Int = 20_000) -> AppServerEvent {
    AppServerEvent(method: "item/tool/requestUserInput", params: .object([
        "threadId": .string("test-thread"), "turnId": .string("turn"), "itemId": .string("item"),
        "autoResolutionMs": .integer(timeout),
        "isBlocking": .bool(true),
        "questions": .array([.object(["id": .string("route"), "header": .string("方案"), "question": .string("请选择？"),
            "options": .array([.object(["label": .string(label), "description": .string("描述🙂")])])])])
    ]), requestID: .integer(91))
}

@Test func ambiguousActionFailureIsReplayedAcrossTransportRetries() {
    let shared = BridgeMessageDeduplicator(capacity: 2)
    #expect(shared.begin("stable-envelope") == .started)
    shared.fail("stable-envelope", message: "Codex reply timed out")
    // Nearby and internet transports share this exact gate. Neither retry
    // may start a second operation after an ambiguous first attempt.
    #expect(shared.begin("stable-envelope") == .failed(message: "Codex reply timed out"))
    shared.cancel("stable-envelope")
    #expect(shared.begin("stable-envelope") == .failed(message: "Codex reply timed out"))
    #expect(shared.begin("explicit-new-action") == .started)
    shared.finish("explicit-new-action")
    // A later acknowledgement transport error cannot replace real success.
    shared.fail("explicit-new-action", message: "ack lost")
    #expect(shared.begin("explicit-new-action") == .completed(outcome: nil))
    #expect(shared.begin("third-action") == .started)
    shared.finish("third-action")
    #expect(shared.begin("stable-envelope") == .started) // bounded cache
}

@Test func macIngressRejectsExpiredAndFutureReliableActionsWithoutStarting() {
    let now = Date(timeIntervalSince1970: 100_000)
    let shared = BridgeMessageDeduplicator()
    var executions = 0
    for kind in [BridgeMessageKind.approvalDecision, .taskCommand, .usageReset] {
        let lifetime: TimeInterval = kind == .taskCommand ? 24 * 60 * 60 : 15 * 60
        for sentAt in [now.addingTimeInterval(-lifetime), now.addingTimeInterval(-lifetime - 1),
                       now.addingTimeInterval(60.001), Date(timeIntervalSince1970: .infinity)] {
            let envelope = BridgeEnvelope(sentAt: sentAt, kind: kind, senderDeviceID: "watch")
            let result = MacReliableActionGate.begin(envelope, deduplicator: shared, now: now)
            if result == .started { executions += 1 }
            guard case .failed(let message) = result else {
                Issue.record("Invalid queued action must produce a failure receipt")
                continue
            }
            #expect(!message.isEmpty)
            // A retry via the other route must replay the same rejection,
            // even if its timestamp would now fall within the skew window.
            #expect(MacReliableActionGate.begin(envelope, deduplicator: shared,
                now: now.addingTimeInterval(1)) == result)
        }
    }
    #expect(executions == 0)
}

@Test func macIngressDeadlineBoundariesAndCompletedReceiptsRemainIdempotent() {
    let now = Date(timeIntervalSince1970: 100_000)
    let shared = BridgeMessageDeduplicator()
    for kind in [BridgeMessageKind.approvalDecision, .taskCommand, .usageReset] {
        let lifetime: TimeInterval = kind == .taskCommand ? 24 * 60 * 60 : 15 * 60
        for sentAt in [now.addingTimeInterval(-lifetime + 0.001), now.addingTimeInterval(60)] {
            let envelope = BridgeEnvelope(sentAt: sentAt, kind: kind, senderDeviceID: "watch")
            #expect(MacReliableActionGate.begin(envelope, deduplicator: shared, now: now) == .started)
            #expect(MacReliableActionGate.begin(envelope, deduplicator: shared, now: now) == .inFlight)
            shared.finish(envelope.messageID, outcome: "Original success")
            #expect(MacReliableActionGate.begin(envelope, deduplicator: shared,
                now: now.addingTimeInterval(lifetime + 61)) == .completed(outcome: "Original success"))
        }
    }
}

@Test func lostNearbyAcknowledgementDoesNotReportAnExecutedActionAsFailed() {
    enum LostReceipt: Error { case disconnected }
    let shared = BridgeMessageDeduplicator()
    for kind in [BridgeMessageKind.approvalDecision, .taskCommand, .usageReset] {
        let envelope = BridgeEnvelope(kind: kind, senderDeviceID: "watch")
        #expect(MacReliableActionGate.begin(envelope, deduplicator: shared) == .started)
        let outcome = kind == .usageReset ? "Reset confirmed" : nil
        var receiptAttempts = 0
        MacReliableActionGate.finish(envelope, deduplicator: shared, outcome: outcome) {
            receiptAttempts += 1
            throw LostReceipt.disconnected
        }
        #expect(receiptAttempts == 1)
        // The same request on either route can only retrieve real success;
        // a failed ACK does not escape into the action-error response path.
        #expect(MacReliableActionGate.begin(envelope, deduplicator: shared) == .completed(outcome: outcome))
    }
}

@Test func nonBlockingQuestionDoesNotPretendTheTaskHasStopped() async throws {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object(["id": .string("test-thread"), "name": .string("独立测试"), "status": .object(["type": .string("active")])])])]))
    var params = questionEvent().params.objectValue!
    params["isBlocking"] = .bool(false)
    let broker = ApprovalBroker(store: store) { _, _ in }
    let request = try await broker.register(.init(method: "item/tool/requestUserInput", params: .object(params), requestID: .integer(91)))
    #expect(request.isBlocking == false)
    #expect(!request.blocksTask)
    #expect(await store.task(threadID: "test-thread")?.state == .running)
    #expect(await store.snapshot().pendingApprovals.count == 1)
}
@Test func structuredQuestionIsAnsweredOnOriginalRPCWithExactOption() async throws {
    let store = CodexSnapshotStore(), recorder = QuestionResponseRecorder()
    let broker = ApprovalBroker(store: store) { _, result in await recorder.record(result) }
    let request = try await broker.register(questionEvent())
    #expect(request.kind == .userInput)
    #expect(request.questions?.first?.id == "route")
    let decision = ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: request.nonce, answers: ["route": ["方案 A"]])
    try await broker.submit(decision)
    #expect(await recorder.result == .object(["answers": .object(["route": .object(["answers": .array([.string("方案 A")])])])]))
    #expect(await store.snapshot().pendingApprovals.isEmpty)
    try await broker.submit(decision) // identical duplicate is idempotent
}
@Test func staleAndInvalidQuestionAnswersAreNeverSent() async throws {
    let store = CodexSnapshotStore(), recorder = QuestionResponseRecorder()
    let broker = ApprovalBroker(store: store) { _, result in await recorder.record(result) }
    let old = try await broker.registerExternal(questionEvent(), externalKey: "same") { _, result in await recorder.record(result) }
    let changed = try await broker.registerExternal(questionEvent(label: "方案 B"), externalKey: "same") { _, result in await recorder.record(result) }
    #expect(old.requestDigest != changed.requestDigest)
    for (request, answers) in [(old, ["route": ["方案 A"]]), (changed, ["route": ["方案 A"]]), (changed, [String: [String]]())] {
        let d = ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
            decidedAt: Date(), deviceID: "watch", nonce: request.nonce, answers: answers)
        await #expect(throws: (any Error).self) { try await broker.submit(d) }
    }
    #expect(await recorder.result == nil)
}

@Test func reusedAppServerRequestIDInvalidatesTheOldDecision() async throws {
    let store = CodexSnapshotStore(), recorder = QuestionResponseRecorder()
    let broker = ApprovalBroker(store: store) { _, response in await recorder.record(response) }
    let old = try await broker.register(questionEvent())
    let duplicate = try await broker.register(questionEvent())
    #expect(duplicate.id == old.id)
    #expect(await store.snapshot().pendingApprovals.count == 1)
    let replacement = try await broker.register(questionEvent(label: "方案 B"))
    #expect(replacement.id != old.id)
    #expect(await store.snapshot().pendingApprovals.map(\.id) == [replacement.id])
    let stale = ApprovalDecision(requestID: old.id, requestDigest: old.requestDigest, choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: old.nonce, answers: ["route": ["方案 A"]])
    await #expect(throws: (any Error).self) { try await broker.submit(stale) }
    #expect(await recorder.result == nil)
    let current = ApprovalDecision(requestID: replacement.id, requestDigest: replacement.requestDigest, choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: replacement.nonce, answers: ["route": ["方案 B"]])
    try await broker.submit(current)
    #expect(await recorder.result?["answers"]?["route"]?["answers"] == .array([.string("方案 B")]))
}

private func checkConcurrentApprovalReplacement(external: Bool) async throws {
    for round in 0..<8 {
        let store = CodexSnapshotStore(), recorder = QuestionResponseRecorder()
        let sender: ApprovalBroker.ResponseSender = { _, value in await recorder.record(value) }
        let broker = ApprovalBroker(store: store, responseSender: sender)
        func register(_ index: Int) async throws -> ApprovalRequest {
            let event = questionEvent(label: "方案 \(round)-\(index)")
            if external {
                return try await broker.registerExternal(event, externalKey: "one-wire-key", responseSender: sender)
            }
            return try await broker.register(event)
        }
        let old = try await register(-1)
        let requests = try await withThrowingTaskGroup(of: ApprovalRequest.self) { group in
            for index in 0..<24 { group.addTask { try await register(index) } }
            var results = [old]
            for try await request in group { results.append(request) }
            return results
        }
        let visible = await store.snapshot().pendingApprovals
        #expect(visible.count == 1)
        let current = try #require(visible.first)
        func answer(_ request: ApprovalRequest) -> ApprovalDecision {
            ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
                decidedAt: Date(), deviceID: "watch", nonce: request.nonce,
                answers: ["route": [request.questions!.first!.options!.first!.label]])
        }
        for stale in requests where stale.id != current.id {
            await #expect(throws: (any Error).self) { try await broker.submit(answer(stale)) }
        }
        #expect(await recorder.count == 0)
        try await broker.submit(answer(current))
        #expect(await recorder.count == 1)
        #expect(await store.snapshot().pendingApprovals.isEmpty)
    }
}

@Test func concurrentRPCRequestReplacementLeavesOnlyOneApprovableID() async throws {
    try await checkConcurrentApprovalReplacement(external: false)
}

@Test func concurrentExternalRequestReplacementLeavesOnlyOneApprovableID() async throws {
    try await checkConcurrentApprovalReplacement(external: true)
}

@Test func questionDeadlineRespectsHostAutoResolution() async throws {
    let now = Date(timeIntervalSince1970: 1000)
    let broker = ApprovalBroker(store: CodexSnapshotStore()) { _, _ in }
    let request = try await broker.register(questionEvent(timeout: 1500), now: now)
    #expect(request.expiresAt == now.addingTimeInterval(1.5))
    let d = ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
        decidedAt: now, deviceID: "watch", nonce: request.nonce, answers: ["route": ["方案 A"]])
    await #expect(throws: (any Error).self) { try await broker.submit(d, now: now.addingTimeInterval(2)) }
}
@Test func approvalDigestDistinguishesReadAndWriteScopes() async throws {
    let broker = ApprovalBroker(store: CodexSnapshotStore()) { _, _ in }
    func event(_ scope: String) -> AppServerEvent { .init(method: "item/permissions/requestApproval", params: .object([
        "threadId": .string("t"), "permissions": .object(["fileSystem": .object([scope: .array([.string("/tmp/one")])])])
    ]), requestID: .integer(3)) }
    let read = try await broker.register(event("read")), write = try await broker.register(event("write"))
    #expect(read.requestedPaths == write.requestedPaths)
    #expect(read.requestDigest != write.requestDigest)
}
@Test func remoteDecisionRequiresOwnerResolutionNotJustSubmission() async throws {
    let tracker = RequestResolutionTracker()
    await tracker.registered("decision")
    await #expect(throws: (any Error).self) { try await tracker.wait("decision", timeout: .milliseconds(20)) }
    await tracker.resolved("decision", confirmed: true)
    try await tracker.wait("decision") // owner event may precede IPC reply
}
@Test func disconnectAndChangedRequestAreNotRemoteApprovalSuccess() async throws {
    let tracker = RequestResolutionTracker()
    await tracker.registered("one")
    await tracker.resolved("one", confirmed: false)
    await #expect(throws: (any Error).self) { try await tracker.wait("one") }
    await tracker.registered("one")
    let waiting = Task { try await tracker.wait("one", timeout: .milliseconds(100)) }
    await Task.yield()
    await tracker.registered("one")
    await #expect(throws: (any Error).self) { try await waiting.value }
}

@Test func concurrentDecisionsAndReusedExternalKeysDoNotConsumeReplacementQuestions() async throws {
    let store = CodexSnapshotStore(), recorder = QuestionResponseRecorder(), gate = RequestResolutionTracker()
    let broker = ApprovalBroker(store: store) { _, _ in }
    let old = try await broker.registerExternal(questionEvent(), externalKey: "replace") { _, response in
        await recorder.record(response)
        try await gate.wait("continue", timeout: .seconds(2))
    }
    func answer(_ request: ApprovalRequest) -> ApprovalDecision {
        .init(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
              decidedAt: Date(), deviceID: "phone", nonce: request.nonce, answers: ["route": ["方案 A"]])
    }
    let first = Task { try await broker.submit(answer(old)) }
    for _ in 0..<100 {
        if await recorder.result != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await recorder.result != nil)
    await #expect(throws: (any Error).self) { try await broker.submit(answer(old)) }
    let replacement = try await broker.registerExternal(questionEvent(label: "方案 B"), externalKey: "replace") { _, _ in }
    await gate.resolved("continue", confirmed: true)
    try await first.value
    #expect(await store.snapshot().pendingApprovals.map(\.id) == [replacement.id])
    await broker.resolve(externalKey: "replace")
    #expect(await store.snapshot().pendingApprovals.isEmpty)
}

@Test func structuredQuestionCompletesOriginalAppServerRequestAndPublishesReply() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-question-fixture-\(UUID().uuidString)")
    let markerURL = scriptURL.appendingPathExtension("reply")
    let marker = String(data: try JSONEncoder().encode(markerURL.path), encoding: .utf8)!
    let question = String(data: try JSONEncoder().encode(questionEvent().params), encoding: .utf8)!
    let script = """
    #!/opt/homebrew/bin/node
    const fs=require('fs'),emit=v=>process.stdout.write(JSON.stringify(v)+'\\n');
    require('readline').createInterface({input:process.stdin}).on('line',line=>{
      const v=JSON.parse(line);
      if(v.id===91 && v.method===undefined){
        fs.writeFileSync(\(marker),JSON.stringify(v.result));
        emit({method:'serverRequest/resolved',params:{threadId:'test-thread',requestId:91}});
        emit({method:'item/agentMessage/delta',params:{threadId:'test-thread',itemId:'reply',delta:'已按方案 A 继续🙂'}});
        return;
      }
      if(v.method==='fixture/question')emit({id:91,method:'item/tool/requestUserInput',params:\(question)});
      if(v.id!==undefined)emit({id:v.id,result:{}});
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL); try? FileManager.default.removeItem(at: markerURL) }
    let client = AppServerClient(executableURL: scriptURL), store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object(["id": .string("test-thread"), "name": .string("独立提问测试")])])]))
    let service = CodexBridgeService(client: client, store: store, isolateCommandSessions: false)
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    _ = try await client.request(method: "fixture/question")
    let request = try #require(await service.snapshot().pendingApprovals.first)
    let decision = ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: request.nonce, origin: .watch, answers: ["route": ["方案 A"]])
    try await service.submit(decision)
    let response = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: markerURL))
    #expect(response["answers"]?["route"]?["answers"] == .array([.string("方案 A")]))
    #expect(await service.snapshot().pendingApprovals.isEmpty)
    for _ in 0..<50 {
        if await service.task(threadID: "test-thread")?.messages.last?.text == "已按方案 A 继续🙂" { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await service.task(threadID: "test-thread")?.messages.last?.text == "已按方案 A 继续🙂")
    await service.stop()
}
