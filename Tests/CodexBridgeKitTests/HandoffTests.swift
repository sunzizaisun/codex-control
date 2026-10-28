import Foundation
import Testing
@testable import CodexBridgeKit
@testable import CodexWatchCore

private func desktopState(_ type: String, flags: [String] = [], turnID: String? = nil) -> JSONValue {
    var state: [String: JSONValue] = ["title": .string("接续测试"), "updatedAt": .number(2_000_000),
        "threadRuntimeStatus": .object(["type": .string(type), "activeFlags": .array(flags.map(JSONValue.string))])]
    if let turnID { state["turnHistory"] = .object(["history": .object(["entitiesByKey": .object([
        "tail": .object(["turnId": .string(turnID), "status": .string("inProgress"), "turnStartedAtMs": .number(10)])
    ])])]) }
    return .object(state)
}

@Test func desktopOwnerStatusCannotBeOverwrittenByObserverNotLoaded() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("active", turnID: "live")))
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("owner"), "name": .string("接续测试"), "status": .object(["type": .string("notLoaded")])
    ])])]))
    #expect(await store.task(threadID: "owner")?.state == .running)
    #expect(await store.task(threadID: "owner")?.activeTurnID == "live")
    await store.applyEvent(method: "thread/status/changed", params: .object(["threadId": .string("owner"), "status": .object(["type": .string("notLoaded")])]))
    #expect(await store.task(threadID: "owner")?.state == .running)
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("active", flags: ["waitingOnApproval"], turnID: "live")))
    #expect(await store.task(threadID: "owner")?.state == .waitingForApproval)
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    #expect(await store.task(threadID: "owner")?.state == .idle)
    #expect(await store.task(threadID: "owner")?.activeTurnID == nil)
}

@Test func waitingForInputIsNotMisrepresentedAsExecuting() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("active", flags: ["waitingOnUserInput"], turnID: "live")))
    #expect(await store.task(threadID: "owner")?.state == .unknown)
}

@Test func lostDesktopOwnerBecomesUnknownAndRecoversFromRealState() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("active", turnID: "live")))
    await store.desktopRuntimeUnavailable(threadID: "owner")
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("owner"), "name": .string("接续测试"), "status": .object(["type": .string("notLoaded")])
    ])])]))
    #expect(await store.task(threadID: "owner")?.state == .unknown)
    #expect(await store.task(threadID: "owner")?.activeTurnID == nil)
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("systemError")))
    #expect(await store.task(threadID: "owner")?.state == .failed)
}

@Test func runtimeFlagsPreserveSteeringIDAndInterruptIsNotSuccess() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    await store.applyEvent(method: "turn/started", params: .object(["threadId": .string("owner"), "turn": .object(["id": .string("live")])]), isCommandRuntime: true)
    await store.applyEvent(method: "thread/status/changed", params: .object(["threadId": .string("owner"), "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])])]), isCommandRuntime: true)
    #expect(await store.task(threadID: "owner")?.activeTurnID == "live")
    await store.applyEvent(method: "turn/completed", params: .object(["threadId": .string("owner"), "turn": .object(["status": .string("interrupted")])]), isCommandRuntime: true)
    #expect(await store.task(threadID: "owner")?.state == .idle)
    #expect(await store.task(threadID: "owner")?.activeTurnID == nil)
}

@Test func modernDesktopHistoryHasStableOrderAndCompletedReplies() async {
    func turn(_ id: String, _ timestamp: Int, _ status: String) -> JSONValue {
        .object(["turnId": .string(id), "turnStartedAtMs": .integer(timestamp), "status": .string(status),
            "items": .array([.object(["id": .string(id + "-u"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string(id)])])]),
                .object(["id": .string(id + "-a"), "type": .string("agentMessage"), "text": .string(id + "回复")])])])
    }
    let state = JSONValue.object(["threadRuntimeStatus": .object(["type": .string("active")]),
        "turnHistory": .object(["history": .object(["entitiesByKey": .object([
            "z": turn("first", 1, "completed"), "a": turn("second", 2, "inProgress")
        ])])])])
    #expect(DesktopRuntimeProjection.messages(from: state).map(\.text) == ["first", "first回复", "second", "second回复"])
    #expect(DesktopRuntimeProjection.messages(from: state).map(\.isStreaming) == [false, false, false, true])
    let compact = DesktopRuntimeProjection.compactState(state)
    #expect(compact["turnHistory"]?["history"]?["entitiesByKey"]?["z"]?["items"] == nil)
    #expect(DesktopRuntimeProjection(threadID: "owner", state: compact).activeTurnID == "second")
}

@Test func desktopEchoRetiresTheLocalReceiptInConversationOrder() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    await store.recordUserMessage(threadID: "owner", id: "local", text: "原文🙂")
    let transcript = [ChatMessage(id: "canonical", role: .user, text: "原文🙂"), ChatMessage(id: "reply", role: .assistant, text: "收到🙂")]
    await store.applyDesktopTranscript(threadID: "owner", messages: transcript)
    await store.applyDesktopTranscript(threadID: "owner", messages: transcript)
    #expect(await store.task(threadID: "owner")?.messages.map(\.id) == ["canonical", "reply"])
}

@Test func fastReplyDoesNotAppearBeforeItsAcknowledgedPrompt() async {
    let store = CodexSnapshotStore(), submittedAt = Date(timeIntervalSince1970: 100)
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    await store.applyEvent(method: "item/agentMessage/delta", params: .object(["threadId": .string("owner"), "itemId": .string("reply"), "delta": .string("回复")]), now: submittedAt.addingTimeInterval(1))
    await store.recordUserMessage(threadID: "owner", id: "prompt", text: "指令", now: submittedAt)
    #expect(await store.task(threadID: "owner")?.messages.map(\.text) == ["指令", "回复"])
}

@Test func canonicalEchoBeforeAcknowledgementIsNotDuplicated() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    await store.applyDesktopTranscript(threadID: "owner", messages: [ChatMessage(id: "real-prompt", role: .user, text: "原文🙂"), ChatMessage(id: "reply", role: .assistant, text: "收到")])
    await store.recordUserMessage(threadID: "owner", id: "local", text: "原文🙂", previousMessageIDs: [])
    #expect(await store.task(threadID: "owner")?.messages.map(\.id) == ["real-prompt", "reply"])
    // Identical text in an older turn must not suppress a genuinely new send.
    await store.recordUserMessage(threadID: "owner", id: "next-local", text: "原文🙂", previousMessageIDs: ["real-prompt", "reply"])
    #expect(await store.task(threadID: "owner")?.messages.map(\.id) == ["real-prompt", "reply", "next-local"])
}

@Test func boundedDesktopHistoryDoesNotMoveOlderCanonicalRowsAfterTheNewReply() async {
    let store = CodexSnapshotStore()
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "owner", state: desktopState("idle")))
    func message(_ id: String, _ role: ChatMessage.Role) -> ChatMessage { ChatMessage(id: id, role: role, text: id) }
    await store.applyDesktopTranscript(threadID: "owner", messages: [message("old-user", .user), message("old-reply", .assistant), message("last-user", .user), message("last-reply", .assistant)])
    let latest = [message("last-user", .user), message("last-reply", .assistant), message("new-user", .user), message("new-reply", .assistant)]
    await store.applyDesktopTranscript(threadID: "owner", messages: latest)
    await store.applyDesktopTranscript(threadID: "owner", messages: latest)
    #expect(await store.task(threadID: "owner")?.messages.map(\.id) == ["old-user", "old-reply", "last-user", "last-reply", "new-user", "new-reply"])
}

@Test func metadataRefreshPreservesLiveActivityTimeAndPlanDetail() async {
    let store = CodexSnapshotStore(), liveTime = Date(timeIntervalSince1970: 200)
    let page = JSONValue.object(["data": .array([.object([
        "id": .string("owner"), "name": .string("进行中的计划"),
        "updatedAt": .integer(100), "status": .object(["type": .string("active")])
    ])])])
    await store.applyThreadList(page)
    await store.applyEvent(method: "turn/plan/updated", params: .object([
        "threadId": .string("owner"), "plan": .array([
            .object(["step": .string("已检查"), "status": .string("completed")]),
            .object(["step": .string("正在验证"), "status": .string("inProgress")])
        ])
    ]), now: liveTime)
    await store.applyThreadList(page)
    #expect(await store.task(threadID: "owner")?.updatedAt == liveTime)
    #expect(await store.task(threadID: "owner")?.detail == "正在验证")
    #expect(await store.task(threadID: "owner")?.progress == 0.5)
}

@Test func equalTimestampTasksHaveStableListAndRefreshOrder() async {
    let store = CodexSnapshotStore()
    func row(_ id: String) -> JSONValue { .object([
        "id": .string(id), "name": .string("任务 \(id)"), "updatedAt": .integer(100),
        "status": .object(["type": .string("active")])
    ]) }
    for ids in [["c", "a", "b"], ["b", "c", "a"], ["a", "b", "c"]] {
        await store.applyThreadList(.object(["data": .array(ids.map(row))]))
        #expect(await store.snapshot().tasks.map(\.id) == ["a", "b", "c"])
        #expect(await store.activeThreadIDs() == ["a", "b", "c"])
        #expect(await store.transcriptThreadIDs() == ["a", "b", "c"])
    }
}

@Test func taskWorkerClosesAfterReplyWithoutClosingTheObserver() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-handoff-\(UUID().uuidString)")
    let markerURL = scriptURL.appendingPathExtension("events")
    let markerLiteral = String(data: try JSONEncoder().encode(markerURL.path), encoding: .utf8)!
    let script = """
    #!/opt/homebrew/bin/node
    const fs = require('fs'), rl = require('readline').createInterface({input:process.stdin});
    const marker = \(markerLiteral);
    function emit(v){process.stdout.write(JSON.stringify(v)+'\\n');}
    // stdin EOF may exit before SIGTERM arrives. Both paths must release the
    // writer; record actual process exit, not just receipt of a signal.
    process.on('exit',()=>fs.appendFileSync(marker,'exit '+process.pid+'\\n'));
    process.on('SIGTERM',()=>process.exit(0));
    rl.on('line',l=>{
      const v=JSON.parse(l);if(v.id===undefined)return;
      if(v.method==='initialize'){emit({id:v.id,result:{}});return;}
      if(v.method==='thread/resume'){emit({id:v.id,result:{thread:{id:v.params.threadId,turns:[]}}});return;}
      if(v.method==='turn/start'){
        fs.appendFileSync(marker,'turn '+process.pid+'\\n');
        emit({id:v.id,result:{turn:{id:'live'}}});
        emit({method:'turn/started',params:{threadId:v.params.threadId,turn:{id:'live'}}});
        emit({method:'item/agentMessage/delta',params:{threadId:v.params.threadId,itemId:'reply',delta:'接续成功'}});
        setTimeout(()=>emit({method:'turn/completed',params:{threadId:v.params.threadId,turn:{id:'live',status:'completed'}}}),30);return;
      }
      emit({id:v.id,result:{}});
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL); try? FileManager.default.removeItem(at: markerURL) }
    let observer = AppServerClient(executableURL: scriptURL), store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object(["id": .string("isolated"), "name": .string("接续测试"), "status": .object(["type": .string("idle")])])])]))
    let service = CodexBridgeService(client: observer, store: store)
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    try await service.send(TaskCommand(taskID: "isolated", prompt: "第一轮", deviceID: "watch"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(await observer.isRunning)
    #expect(!(await service.canContinueDirectly(threadID: "isolated")))
    #expect(await service.task(threadID: "isolated")?.messages.last?.text == "接续成功")
    let first = try String(contentsOf: markerURL, encoding: .utf8)
    #expect(first.contains("exit "))
    try await service.send(TaskCommand(taskID: "isolated", prompt: "第二轮", activeTurnID: "stale-completed-turn", deviceID: "watch"))
    try await Task.sleep(for: .milliseconds(500))
    let events = try String(contentsOf: markerURL, encoding: .utf8).split(separator: "\n")
    #expect(events.filter { $0.hasPrefix("turn ") }.count == 2)
    #expect(events.filter { $0.hasPrefix("exit ") }.count == 2)
    #expect(await observer.isRunning)
    await service.stop()
}

@Test func replacingAChildDoesNotLetItsOldExitCloseTheNewConnection() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-reconnect-\(UUID().uuidString)")
    let script = """
    #!/opt/homebrew/bin/node
    require('readline').createInterface({input:process.stdin}).on('line',l=>{
      const v=JSON.parse(l);if(v.id!==undefined)process.stdout.write(JSON.stringify({id:v.id,result:{ok:true}})+'\\n');
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let client = AppServerClient(executableURL: scriptURL)
    for _ in 0..<5 {
        _ = try await client.start(preferManagedDaemon: false)
        await client.stop()
        _ = try await client.start(preferManagedDaemon: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.isRunning)
        #expect(try await client.request(method: "ping")["ok"]?.boolValue == true)
        await client.stopAndWaitForExit()
    }
}

@Test func rejectedNewTurnDoesNotStayRunningOrHoldItsWorker() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-reject-\(UUID().uuidString)")
    let script = """
    #!/opt/homebrew/bin/node
    require('readline').createInterface({input:process.stdin}).on('line',l=>{
      const v=JSON.parse(l);if(v.id===undefined)return;
      let result={};
      if(v.method==='thread/start')result={thread:{id:'rejected',preview:'独立失败测试',status:{type:'idle'}}};
      const reply=v.method==='turn/start'?{id:v.id,error:{code:-32600,message:'explicit rejection'}}:{id:v.id,result};
      process.stdout.write(JSON.stringify(reply)+'\\n');
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let observer = AppServerClient(executableURL: scriptURL), service = CodexBridgeService(client: observer)
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    do { _ = try await service.startCodexConversation(prompt: "不能假装发送成功")
        Issue.record("Expected an explicit server rejection")
    } catch { #expect(error.localizedDescription == "explicit rejection") }
    try await Task.sleep(for: .milliseconds(400))
    #expect(await service.task(threadID: "rejected")?.state == .failed)
    #expect(!(await service.canContinueDirectly(threadID: "rejected")))
    #expect(await observer.isRunning)
    await service.stop()
}

@Test func backgroundSyncDoesNotRereadDesktopRolloutsWithLiveStatus() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-light-sync-\(UUID().uuidString)")
    let markerURL = scriptURL.appendingPathExtension("requests")
    let markerLiteral = String(data: try JSONEncoder().encode(markerURL.path), encoding: .utf8)!
    let script = """
    #!/opt/homebrew/bin/node
    const fs=require('fs');
    require('readline').createInterface({input:process.stdin}).on('line',l=>{
      const v=JSON.parse(l);if(v.id===undefined)return;
      fs.appendFileSync(\(markerLiteral),v.method+'\\n');
      let result={};
      if(v.method==='account/rateLimits/read')result={rateLimits:{primary:{usedPercent:23}}};
      if(v.method==='thread/list')result={data:[{id:'live-desktop',name:'桌面运行项目',status:{type:'notLoaded'}},{id:'large-idle',name:'历史大型项目',status:{type:'notLoaded'}}]};
      process.stdout.write(JSON.stringify({id:v.id,result})+'\\n');
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL); try? FileManager.default.removeItem(at: markerURL) }
    let store = CodexSnapshotStore(), service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), store: store)
    await store.applyDesktopRuntime(DesktopRuntimeProjection(threadID: "live-desktop", state: desktopState("active", turnID: "live")))
    try await service.start(preferManagedDaemon: false)
    await service.refresh()
    #expect(await service.activeTasksHaveLiveUpdates())
    #expect(await service.task(threadID: "live-desktop")?.state == .running)
    #expect(await service.snapshot().usage?.primary?.remainingPercent == 77)
    let methods = try String(contentsOf: markerURL, encoding: .utf8)
    #expect(!methods.contains("thread/read"))
    #expect(!methods.contains("thread/resume"))
    await service.stop()
}
