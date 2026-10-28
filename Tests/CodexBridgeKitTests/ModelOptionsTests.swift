import Foundation
import Testing
@testable import CodexBridgeKit
@testable import CodexWatchCore

@Test func actualModelCatalogExcludesHiddenAndUnsupportedDefaults() async {
    let store = CodexSnapshotStore()
    func row(_ name: String, hidden: Bool = false, effort: String = "medium") -> JSONValue {
        .object(["model": .string(name), "displayName": .string(name), "hidden": .bool(hidden), "isDefault": .bool(true),
                 "defaultReasoningEffort": .string(effort), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("medium")])])])
    }
    await store.applyModels(.object(["data": .array([row("visible"), row("hidden", hidden: true), row("bad", effort: "unknown")])]))
    #expect(await store.snapshot().models.map(\.model) == ["visible"])
}
@Test func modelAndEffortAreCarriedAsActualTurnStartFields() {
    let base: [String: JSONValue] = ["threadId": .string("task"), "input": .array([]), "approvalPolicy": .string("on-request")]
    let params = CodexTurnOptions.applying(.init(model: "actual-model", effort: "high"), to: base)
    #expect(params["model"]?.stringValue == "actual-model")
    #expect(params["effort"]?.stringValue == "high")
    #expect(params["reasoningEffort"] == nil)
    #expect(params["approvalPolicy"]?.stringValue == "on-request")
    #expect(CodexTurnOptions.applying(nil, to: base) == .object(base))
}
@Test func allActiveProjectsAndWaitingInputSurviveMetadataRefresh() async {
    let store = CodexSnapshotStore()
    for index in 0..<8 {
        let status: JSONValue = .object(["threadRuntimeStatus": .object(["type": .string("active"),
            "activeFlags": .array(index == 7 ? [.string("waitingOnUserInput")] : [])]), "title": .string("项目 \(index)")])
        await store.applyDesktopRuntime(.init(threadID: "task-\(index)", state: status))
    }
    await store.applyThreadList(.object(["data": .array([])]))
    #expect(await store.snapshot().activeTaskCount == 8)
    #expect(await store.task(threadID: "task-7")?.awaitingUserInput == true)
}
@Test func commandRuntimeWaitingInputIsVisibleUntilRealCompletion() async {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object(["id": .string("question"), "name": .string("Question"), "status": .object(["type": .string("idle")])])])]))
    await store.applyEvent(method: "turn/started", params: .object(["threadId": .string("question"), "turn": .object(["id": .string("live")])]), isCommandRuntime: true)
    await store.applyEvent(method: "thread/status/changed", params: .object(["threadId": .string("question"), "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnUserInput")])])]), isCommandRuntime: true)
    #expect(await store.task(threadID: "question")?.isInProgress == true)
    #expect(await store.task(threadID: "question")?.activeTurnID == "live")
    await store.applyExecutionSettings(threadID: "question", model: "actual", effort: "high")
    await store.applyThreadList(.object(["data": .array([])]))
    #expect(await store.task(threadID: "question")?.reasoningEffort == "high")
    await store.applyEvent(method: "turn/completed", params: .object(["threadId": .string("question"), "turn": .object(["status": .string("completed")])]), isCommandRuntime: true)
    #expect(await store.task(threadID: "question")?.isInProgress == false)
    #expect(await store.task(threadID: "question")?.activeTurnID == nil)
}

@Test func metadataPaginationFindsActiveProjectsAfterFirstPage() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-model-page-\(UUID())")
    let script = """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r request
    IFS= read -r request
    printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
    IFS= read -r request
    printf '%s\\n' '{"id":3,"result":{"data":[]}}'
    IFS= read -r request
    case "$request" in *'"useStateDbOnly":true'*) ;; *) exit 10 ;; esac
    printf '%s\\n' '{"id":4,"result":{"data":[{"id":"recent","name":"Recent","status":{"type":"idle"}}],"nextCursor":"second-page"}}'
    IFS= read -r request
    case "$request" in *'"cursor":"second-page"'*) ;; *) exit 11 ;; esac
    printf '%s\\n' '{"id":5,"result":{"data":[{"id":"late-active","name":"Running project","status":{"type":"active","activeFlags":[]}}],"nextCursor":null}}'
    IFS= read -r request
    printf '%s\\n' '{"id":6,"result":{}}'
    sleep 2
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL))
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    await service.refresh(readTranscripts: false)
    #expect(await service.snapshot().tasks.map(\.id).contains("late-active"))
    #expect(await service.snapshot().activeTaskCount == 1)
    await service.stop()
}
