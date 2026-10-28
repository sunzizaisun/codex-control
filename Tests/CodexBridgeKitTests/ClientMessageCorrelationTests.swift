import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

private func correlationStore() async -> CodexSnapshotStore {
    let store = CodexSnapshotStore()
    await store.applyThreadList(.object(["data": .array([.object([
        "id": .string("fixture"), "name": .string("Correlation fixture"), "status": .object(["type": .string("idle")])
    ])])]))
    return store
}

@Test func reusedCanonicalIDCannotOverwriteOrRetireDifferentPendingText() async {
    let store = await correlationStore()
    await store.recordUserMessage(threadID: "fixture", id: "pending", text: "原文🦦")
    for row in [
        ChatMessage(id: "pending", role: .user, text: "其他原文", clientMessageID: "pending"),
        ChatMessage(id: "pending", role: .user, text: "原文🦦", clientMessageID: "other-client"),
        ChatMessage(id: "pending", role: .assistant, text: "其他回复")
    ] {
        await store.applyDesktopTranscript(threadID: "fixture", messages: [row])
        #expect(await store.task(threadID: "fixture")?.messages.map(\.text) == ["原文🦦"])
    }
    await store.applyDesktopTranscript(threadID: "fixture", messages: [
        ChatMessage(id: "real-owner", role: .user, text: "原文🦦", clientMessageID: "pending")
    ])
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["real-owner"])
}

@Test func ownerClientIdIsPreservedWithoutReplacingCanonicalMessageId() {
    let result: JSONValue = .object(["data": .array([.object([
        "turnId": .string("t"), "item": .object(["id": .string("canonical"), "type": .string("userMessage"),
            "clientId": .string("original-command"), "content": .array([.object([
                "type": .string("text"), "text": .string("中文🦦")])])])
    ])])])
    let rows = ThreadHistoryParser.messages(from: result)
    #expect(rows.first?.id == "canonical")
    #expect(rows.first?.clientMessageID == "original-command")
}

@Test func sameTextFromAnotherClientCannotAcknowledgeThePendingCommand() async {
    let store = await correlationStore()
    await store.recordUserMessage(threadID: "fixture", id: "pending", text: "重复原文🦦")
    let other = ChatMessage(id: "other-canonical", role: .user, text: "重复原文🦦", clientMessageID: "other-client")
    await store.applyDesktopTranscript(threadID: "fixture", messages: [other])
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["other-canonical", "pending"])
    let own = ChatMessage(id: "own-canonical", role: .user, text: "重复原文🦦", clientMessageID: "pending")
    await store.applyDesktopTranscript(threadID: "fixture", messages: [other, own])
    await store.applyDesktopTranscript(threadID: "fixture", messages: [other, own])
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["other-canonical", "own-canonical"])
}

@Test func earlyOwnerEchoMustMatchClientIdNotMerelyAnIdenticalNewPrompt() async {
    let store = await correlationStore()
    await store.applyDesktopTranscript(threadID: "fixture", messages: [
        ChatMessage(id: "other", role: .user, text: "相同", clientMessageID: "other-client")
    ])
    await store.recordUserMessage(threadID: "fixture", id: "pending", text: "相同", previousMessageIDs: [])
    // previousMessageIDs is the pre-submission view. This unrelated echo
    // arrived after that point, so the pending send precedes it.
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["pending", "other"])
    await store.applyDesktopTranscript(threadID: "fixture", messages: [
        ChatMessage(id: "other", role: .user, text: "相同", clientMessageID: "other-client"),
        ChatMessage(id: "own", role: .user, text: "相同", clientMessageID: "pending")
    ])
    await store.recordUserMessage(threadID: "fixture", id: "pending", text: "相同", previousMessageIDs: ["other", "own"])
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["other", "own"])
}

@Test func normalizedButDifferentUnicodeCannotConsumeAnOriginalPendingReceipt() async {
    let store = await correlationStore()
    let original = "e\u{301}", changed = "\u{e9}"
    #expect(original == changed)
    #expect(!original.utf8.elementsEqual(changed.utf8))
    await store.recordUserMessage(threadID: "fixture", id: "pending", text: original)
    await store.applyHistoryMessages(threadID: "fixture", messages: [
        ChatMessage(id: "canonical", role: .user, text: changed, clientMessageID: "pending")
    ])
    #expect(await store.task(threadID: "fixture")?.messages.map(\.id) == ["canonical", "pending"])
}
