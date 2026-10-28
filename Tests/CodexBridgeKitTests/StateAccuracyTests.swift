import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

private func stateAccuracyThread(_ store: CodexSnapshotStore, id: String = "state-test") async {
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string(id), "name": .string("State accuracy fixture"),
        "status": .object(["type": .string("active")]), "updatedAt": .integer(1)
    ])])]))
    await store.applyEvent(method: "turn/started", params: .object([
        "threadId": .string(id), "turn": .object(["id": .string("turn-fixture")])
    ]), isCommandRuntime: true)
    await store.applyEvent(method: "turn/plan/updated", params: .object([
        "threadId": .string(id), "plan": .array([
            .object(["step": .string("first"), "status": .string("completed")]),
            .object(["step": .string("second"), "status": .string("inProgress")])
        ])
    ]), isCommandRuntime: true)
}

@Test func executorDisconnectDoesNotInventTaskFailureOrRetainProgress() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.commandRuntimeUnavailable(threadID: "state-test")
    let task = await store.snapshot().tasks.first
    #expect(task?.state == .unknown)
    #expect(task?.activeTurnID == nil)
    #expect(task?.progress == nil)
    #expect(task?.awaitingUserInput != true)
    #expect(task?.title == "State accuracy fixture")
    #expect(await store.hasLiveRuntime(threadID: "state-test") == false)
}

@Test func rejectedFollowupDoesNotTurnAnExistingIdleTaskIntoFailed() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.applyEvent(method: "turn/completed", params: .object([
        "threadId": .string("state-test"), "turn": .object([
            "id": .string("turn-fixture"), "status": .string("completed")
        ])
    ]), isCommandRuntime: true)
    let before = await store.snapshot().tasks.first
    await store.commandStartRejected(threadID: "state-test")
    let after = await store.snapshot().tasks.first
    #expect(after?.state == before?.state)
    #expect(after?.state != .failed)
    #expect(after?.activeTurnID == nil)
}

@Test func metadataCannotResurrectAStaleOwnerAfterExecutorDisconnect() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.applyDesktopRuntime(.init(threadID: "state-test", state: .object([
        "threadRuntimeStatus": .object(["type": .string("active")]),
        "turns": .array([.object(["id": .string("old-turn"), "status": .string("inProgress")])])
    ])))
    await store.commandRuntimeUnavailable(threadID: "state-test")
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("state-test"), "name": .string("State accuracy fixture"),
        "status": .object(["type": .string("active")])
    ])])]))
    #expect(await store.snapshot().tasks.first?.state == .unknown)
    #expect(await store.hasLiveRuntime(threadID: "state-test") == false)
    await store.applyDesktopRuntime(.init(threadID: "state-test", state: .object([
        "threadRuntimeStatus": .object(["type": .string("idle")])
    ])))
    #expect(await store.snapshot().tasks.first?.state == .idle)
}

@Test func rejectedStartKeepsUnconfirmedSeedUnknownUntilOwnerUpdate() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.commandStartRejected(threadID: "state-test")
    #expect(await store.snapshot().tasks.first?.state == .unknown)
    await store.applyDesktopRuntime(.init(threadID: "state-test", state: .object([
        "threadRuntimeStatus": .object(["type": .string("idle")])
    ])))
    #expect(await store.snapshot().tasks.first?.state == .idle)
}

@Test func explicitNewConversationRejectionIsStillAKnownFailedStart() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.commandStartRejected(threadID: "state-test", isNewConversation: true)
    #expect(await store.snapshot().tasks.first?.state == .failed)
    #expect(await store.snapshot().tasks.first?.activeTurnID == nil)
}

@Test func workerDisconnectBeforeExplicitNewRejectionDoesNotHideKnownFailure() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.commandRuntimeUnavailable(threadID: "state-test")
    #expect(await store.snapshot().tasks.first?.state == .unknown)
    await store.commandStartRejected(threadID: "state-test", isNewConversation: true)
    #expect(await store.snapshot().tasks.first?.state == .failed)
}

@Test func lostStartResponseDoesNotLeaveAnOptimisticSeedRunning() async {
    let store = CodexSnapshotStore()
    await store.seedManagedTask(.object(["id": .string("seed")]),
        initialPrompt: "Fixture only", messageID: "seed-message", isChat: false)
    await store.commandStartUnconfirmed(threadID: "seed")
    let task = await store.task(threadID: "seed")
    #expect(task?.state == .unknown)
    #expect(task?.activeTurnID == nil)
    #expect(task?.messages.last?.text == "Fixture only")
    #expect(await store.hasLiveRuntime(threadID: "seed") == false)
}

@Test func lostStartResponseCannotEraseARealExecutorStartOrCompletion() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.commandStartUnconfirmed(threadID: "state-test")
    #expect(await store.task(threadID: "state-test")?.state == .running)
    #expect(await store.task(threadID: "state-test")?.activeTurnID == "turn-fixture")
    await store.applyEvent(method: "turn/completed", params: .object([
        "threadId": .string("state-test"), "turn": .object([
            "id": .string("turn-fixture"), "status": .string("completed")
        ])
    ]), isCommandRuntime: true)
    let before = await store.task(threadID: "state-test")
    await store.commandStartUnconfirmed(threadID: "state-test")
    #expect(await store.task(threadID: "state-test")?.state == before?.state)
}

private func stateAccuracyApproval(id: String) -> ApprovalRequest {
    ApprovalRequest(id: id, taskID: "state-test", kind: .command,
        title: "Fixture approval", summary: "No actual operation", createdAt: Date(),
        expiresAt: Date().addingTimeInterval(60), nonce: "fixture-nonce", requestDigest: "fixture-digest")
}

@Test func lastApprovalRemovalWaitsForOwnerInsteadOfInventingRunning() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.addApproval(stateAccuracyApproval(id: "first"))
    await store.addApproval(stateAccuracyApproval(id: "second"))
    await store.removeApproval(id: "first")
    #expect(await store.snapshot().tasks.first?.state == .waitingForApproval)
    await store.removeApproval(id: "second")
    let task = await store.snapshot().tasks.first
    #expect(task?.state == .unknown)
    #expect(task?.activeTurnID == nil)
    #expect(task?.progress == nil)
}

@Test func approvalCleanupDoesNotOverwriteAnAlreadyConfirmedOwnerOutcome() async {
    let store = CodexSnapshotStore()
    await stateAccuracyThread(store)
    await store.addApproval(stateAccuracyApproval(id: "first"))
    await store.applyEvent(method: "turn/completed", params: .object([
        "threadId": .string("state-test"), "turn": .object([
            "id": .string("turn-fixture"), "status": .string("failed")
        ])
    ]), isCommandRuntime: true)
    let before = await store.snapshot().tasks.first
    await store.removeApproval(id: "first")
    let after = await store.snapshot().tasks.first
    #expect(after?.state == before?.state)
    #expect(after?.state == .failed)
}
