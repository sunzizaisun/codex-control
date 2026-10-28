import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

private func historyEntry(_ id: String, text: String? = nil) -> JSONValue {
    .object(["turnId": .string("turn-fixture"), "item": .object([
        "id": .string(id), "type": .string(text == nil ? "reasoning" : "agentMessage"),
        "text": text.map(JSONValue.string) ?? .string("")
    ])])
}
private actor HistoryPageFixture {
    var pages: [JSONValue]
    var calls: [(String, JSONValue)] = []
    init(_ pages: [JSONValue]) { self.pages = pages }
    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        calls.append((method, params))
        guard !pages.isEmpty else { throw AppServerClientError.invalidResponse }
        return pages.removeFirst()
    }
}

@Test func itemHistoryUsesRealOpaqueCursorAndRestoresChronologicalFullText() async throws {
    let longText = String(repeating: "完整中文🦦", count: 500)
    let fixture = HistoryPageFixture([.object(["data": .array([
        historyEntry("new", text: "最新🍁"), historyEntry("old", text: longText)
    ]), "nextCursor": .string("server-cursor")])])
    let request = TaskHistoryRequest(taskID: "fixture", beforeMessageID: "boundary", continuation: "original-cursor")
    let page = try await PaginatedThreadHistory.page(request) { try await fixture.request($0, $1) }
    #expect(page.messages.map(\.id) == ["old", "new"])
    #expect(page.messages.first?.text == longText)
    #expect(page.isValid(for: request))
    let calls = await fixture.calls
    #expect(calls.count == 1)
    #expect(calls.first?.0 == "thread/items/list")
    #expect(calls.first?.1["cursor"]?.stringValue == "original-cursor")
    #expect(calls.first?.1["sortDirection"]?.stringValue == "desc")
}

@Test func toolOnlyHistoryStopsAfterThreePagesWithoutLosingContinuation() async throws {
    let fixture = HistoryPageFixture((1...3).map { n in .object([
        "data": .array([historyEntry("tool-\(n)")]), "nextCursor": .string("c\(n)")
    ]) })
    let page = try await PaginatedThreadHistory.page(.init(taskID: "fixture")) { try await fixture.request($0, $1) }
    #expect(page.messages.isEmpty)
    #expect(page.continuation == "c3")
    #expect(await fixture.calls.count == 3)
}

@Test func oversizeHistoryRefetchesTheSamePositionWithoutSkippingRows() async throws {
    let text = String(repeating: "a", count: 20_000)
    let fixture = HistoryPageFixture([
        .object(["data": .array([historyEntry("new", text: text), historyEntry("old", text: text)]),
            "nextCursor": .string("discarded-end")]),
        .object(["data": .array([historyEntry("new", text: text)]), "nextCursor": .string("old-still-available")])
    ])
    let request = TaskHistoryRequest(taskID: "fixture", continuation: "original-position")
    let page = try await PaginatedThreadHistory.page(request) { try await fixture.request($0, $1) }
    #expect(page.messages.map(\.id) == ["new"])
    #expect(page.messages.first?.text == text)
    #expect(page.continuation == "old-still-available")
    let calls = await fixture.calls
    #expect(calls.count == 2)
    #expect(calls.allSatisfy { $0.1["cursor"]?.stringValue == "original-position" })
    #expect(calls.last?.1["limit"] == .integer(1))
}

@Test func aSingleLargeReplyIsNeverTruncatedToFitWatchConnectivity() async throws {
    let full = String(repeating: "完整中文🦦", count: 5_000)
    let fixture = HistoryPageFixture([.object(["data": .array([historyEntry("single", text: full)]), "nextCursor": .null])])
    let page = try await PaginatedThreadHistory.page(.init(taskID: "fixture", limit: 1)) { try await fixture.request($0, $1) }
    #expect(page.messages.first?.text.utf8.elementsEqual(full.utf8) == true)
    #expect(await fixture.calls.count == 1)
}

@Test func invalidOrRepeatingUpstreamPageIsRejectedNotRetried() async {
    let invalid: [JSONValue] = [
        .object(["data": .array([historyEntry("same", text: "a"), historyEntry("same", text: "b")])]),
        .object(["data": .array([]), "nextCursor": .integer(1)]),
        .object(["data": .array([]), "nextCursor": .string("original")]),
        .object([:])
    ]
    for result in invalid {
        let fixture = HistoryPageFixture([result])
        do {
            _ = try await PaginatedThreadHistory.page(.init(taskID: "fixture", continuation: "original")) {
                try await fixture.request($0, $1)
            }
            Issue.record("Malformed history was accepted")
        } catch { #expect(await fixture.calls.count == 1) }
    }
}

@Test func itemTextCannotClearAnOwnerTurnOrInventTaskCompletion() async {
    let store = CodexSnapshotStore()
    await store.applyEvent(method: "thread/started", params: .object(["thread": .object([
        "id": .string("fixture"), "name": .string("Fixture")
    ])]))
    await store.applyEvent(method: "turn/started", params: .object([
        "threadId": .string("fixture"), "turn": .object(["id": .string("active-owner-turn")])
    ]))
    await store.applyHistoryMessages(threadID: "fixture", messages: [ChatMessage(id: "reply", role: .assistant, text: "原文🦦")])
    #expect(await store.task(threadID: "fixture")?.activeTurnID == "active-owner-turn")
    #expect(await store.task(threadID: "fixture")?.state == .running)
}

@Test func historyServiceOnlyFallsBackForAnExplicitOldServer() async throws {
    for mode in ["modern", "legacy", "denied", "malformed"] {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-history-\(UUID().uuidString)")
        let logURL = scriptURL.appendingPathExtension("calls")
        let log = String(data: try JSONEncoder().encode(logURL.path), encoding: .utf8)!
        let script = """
        #!/opt/homebrew/bin/node
        const fs=require('fs'),mode='\(mode)',log=\(log);
        require('readline').createInterface({input:process.stdin}).on('line',l=>{
          const v=JSON.parse(l);if(v.id===undefined)return;
          fs.appendFileSync(log,v.method+'\\n');
          let result={},error;
          if(v.method==='thread/items/list'){
            if(mode==='legacy')error={code:-32601,message:'unknown method'};
            else if(mode==='denied')error={code:401,message:'denied'};
            else if(mode==='modern')result={data:[{turnId:'t',item:{id:'m',type:'agentMessage',text:'fixture'}}],nextCursor:null};
          }
          if(v.method==='thread/read')result={thread:{turns:[{items:[{id:'m',type:'agentMessage',text:'fixture'}]}]}};
          process.stdout.write(JSON.stringify(error?{id:v.id,error}:{id:v.id,result})+'\\n');
        });
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL); try? FileManager.default.removeItem(at: logURL) }
        let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL))
        try await service.start(refreshImmediately: false, preferManagedDaemon: false)
        do {
            let page = try await service.history(.init(taskID: "fixture"))
            #expect(mode == "modern" || mode == "legacy")
            #expect(page.messages.map(\.text) == ["fixture"])
        } catch { #expect(mode == "denied" || mode == "malformed") }
        await service.stop()
        let calls = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        #expect(calls.filter { $0 == "thread/items/list" }.count == 1)
        #expect(calls.contains("thread/read") == (mode == "legacy"))
    }
}
