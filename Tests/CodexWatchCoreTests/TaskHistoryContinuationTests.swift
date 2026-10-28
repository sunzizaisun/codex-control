import Foundation
import Testing
@testable import CodexWatchCore

private func historyRow(_ id: String) -> ChatMessage {
    ChatMessage(id: id, role: .user, text: "原文 \(id)🦦")
}

@Test func legacyHistoryPayloadsStillDecodeWithoutContinuation() throws {
    let request = try CodexWatchCoding.makeDecoder().decode(TaskHistoryRequest.self,
        from: Data(#"{"taskID":"fixture","limit":20}"#.utf8))
    let page = try CodexWatchCoding.makeDecoder().decode(TaskHistoryPage.self,
        from: Data(#"{"taskID":"fixture","messages":[]}"#.utf8))
    #expect(request.continuation == nil)
    #expect(page.isValid(for: request))
}

@Test func emptyToolPagesPreserveAnOlderHistoryContinuation() {
    var state = TaskHistoryState()
    state.apply(.init(taskID: "fixture", messages: [], continuation: "c1"))
    #expect(state.hasMore)
    #expect(state.nextBeforeMessageID == nil)
    state.apply(.init(taskID: "fixture", messages: [historyRow("older")],
        continuation: "c2", requestContinuation: "c1"))
    state.apply(.init(taskID: "fixture", messages: [historyRow("latest")], continuation: "latest-cursor"))
    #expect(state.messages.map(\.id) == ["older", "latest"])
    #expect(state.nextContinuation == "c2")
    state.apply(.init(taskID: "fixture", messages: [], requestContinuation: "c2"))
    #expect(!state.hasMore)
}

@Test func historyReceiptsMustMatchTheRequestedCursorAndExactPage() {
    let request = TaskHistoryRequest(taskID: "fixture", beforeMessageID: "anchor", limit: 1, continuation: "c1")
    #expect(TaskHistoryPage(taskID: "fixture", messages: [historyRow("one")], beforeMessageID: "anchor",
        continuation: "c2", requestContinuation: "c1").isValid(for: request))
    #expect(!TaskHistoryPage(taskID: "fixture", messages: [], beforeMessageID: "anchor").isValid(for: request))
    #expect(!TaskHistoryPage(taskID: "other", messages: [], beforeMessageID: "anchor",
        requestContinuation: "c1").isValid(for: request))
    #expect(!TaskHistoryPage(taskID: "fixture", messages: [], beforeMessageID: "anchor",
        continuation: "c1", requestContinuation: "c1").isValid(for: request))
    #expect(!TaskHistoryPage(taskID: "fixture", messages: [historyRow("one"), historyRow("one")],
        beforeMessageID: "anchor", requestContinuation: "c1").isValid(for: request))
}

@Test func continuationRoundTripKeepsOpaqueUnicodeBytes() throws {
    let request = TaskHistoryRequest(taskID: "fixture", continuation: "opaque-中文🦦+/=")
    let bytes = try CodexWatchCoding.makeEncoder().encode(request)
    #expect(try CodexWatchCoding.makeDecoder().decode(TaskHistoryRequest.self, from: bytes) == request)
}

@Test func latePersistedHistoryCannotShrinkALiveReplyButOwnerCompletionCan() {
    var state = TaskHistoryState()
    state.applyLive([ChatMessage(id: "reply", role: .assistant, text: "中文🦦完整流", isStreaming: true)])
    state.apply(.init(taskID: "fixture", messages: [ChatMessage(id: "reply", role: .assistant, text: "中文🦦")]))
    #expect(state.messages.first?.text == "中文🦦完整流")
    #expect(state.messages.first?.isStreaming == true)
    state.applyLive([ChatMessage(id: "reply", role: .assistant, text: "中文🦦最终", isStreaming: false)])
    #expect(state.messages.first?.text == "中文🦦最终")
    #expect(state.messages.first?.isStreaming == false)
}

@Test func clientMessageIdentityIsOptionalForOldPayloadsAndSurvivesRoundTrip() throws {
    let old = try CodexWatchCoding.makeDecoder().decode(ChatMessage.self, from: Data(
        #"{"id":"canonical","role":"user","text":"原文🦦","isStreaming":false,"createdAt":0}"#.utf8))
    #expect(old.clientMessageID == nil)
    var current = old
    current.clientMessageID = "original-command"
    #expect(try CodexWatchCoding.makeDecoder().decode(ChatMessage.self,
        from: CodexWatchCoding.makeEncoder().encode(current)) == current)
    var state = TaskHistoryState()
    state.apply(.init(taskID: "fixture", messages: [current]))
    state.applyLive([old])
    #expect(state.messages.first?.clientMessageID == "original-command")
}
