import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

private actor ReceiptFixture {
    var pages: [JSONValue]
    var calls: [(String, JSONValue)] = []
    init(_ pages: [JSONValue]) { self.pages = pages }
    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        calls.append((method, params))
        guard !pages.isEmpty else { throw AppServerClientError.invalidResponse }
        return pages.removeFirst()
    }
}
private actor RecoveryCounter {
    var count = 0
    func confirm() async -> Bool {
        count += 1
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }
}
private func ownerItem(_ id: String, clientID: JSONValue? = .string("client-original"), text: String = "原文🦦") -> JSONValue {
    var item: [String: JSONValue] = ["id": .string(id), "type": .string("userMessage"),
        "content": .array([.object(["type": .string("text"), "text": .string(text)])])]
    item["clientId"] = clientID
    return .object(["turnId": .string("owner-turn"), "item": .object(item)])
}
private func ownerPage(_ entries: [JSONValue], next: String? = nil) -> JSONValue {
    .object(["data": .array(entries), "nextCursor": next.map(JSONValue.string) ?? .null])
}
private func receiptCommand(text: String = "原文🦦", taskID: String = "original-task") -> TaskCommand {
    .init(id: "client-original", taskID: taskID, prompt: text, deviceID: "fixture-watch")
}

@Test func ownerLookupRequiresClientIDAndExactOriginalUTF8() async throws {
    for (item, expected) in [
        (ownerItem("canonical"), true),
        (ownerItem("canonical", clientID: nil), false),
        (ownerItem("canonical", clientID: .string("another-client")), false),
        (ownerItem("canonical", text: "different"), false),
        (ownerItem("canonical", text: "原文🦦 "), false)
    ] {
        let fixture = ReceiptFixture([ownerPage([item])])
        #expect(try await CommandReceiptLookup.confirms(receiptCommand()) { try await fixture.request($0, $1) } == expected)
        let calls = await fixture.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == "thread/items/list")
        #expect(calls.first?.1["threadId"]?.stringValue == "original-task")
    }
    let normalized = ReceiptFixture([ownerPage([ownerItem("m", text: "é")])])
    #expect(try await !CommandReceiptLookup.confirms(receiptCommand(text: "e\u{301}")) { try await normalized.request($0, $1) })
}

@Test func ownerLookupIsBoundedAndNeverScansOtherThreadsOrStartsTurns() async throws {
    let fixture = ReceiptFixture((1...3).map { ownerPage([], next: "opaque-\($0)") })
    #expect(try await !CommandReceiptLookup.confirms(receiptCommand()) { try await fixture.request($0, $1) })
    let calls = await fixture.calls
    #expect(calls.count == 3)
    #expect(calls.allSatisfy { $0.0 == "thread/items/list" && $0.1["threadId"] == .string("original-task") })
    #expect(calls[1].1["cursor"] == .string("opaque-1"))
    let skipped = ReceiptFixture([])
    for taskID in [TaskCommand.newChatTaskID, TaskCommand.legacyNewChatTaskID, "chatgpt-web:old"] {
        #expect(try await !CommandReceiptLookup.confirms(receiptCommand(taskID: taskID)) { try await skipped.request($0, $1) })
    }
    #expect(await skipped.calls.isEmpty)
}

@Test func malformedOwnerProofAndDuplicateIDsCannotBecomeAccepted() async {
    for page in [
        ownerPage([ownerItem("same"), ownerItem("same")]),
        ownerPage([ownerItem("a"), ownerItem("b")]),
        ownerPage([ownerItem("a", clientID: .integer(1))]),
        .object(["data": .array([ownerItem("a")]), "nextCursor": .integer(7)]),
        .object([:])
    ] {
        let fixture = ReceiptFixture([page])
        let accepted = (try? await CommandReceiptLookup.confirms(receiptCommand()) { try await fixture.request($0, $1) }) == true
        #expect(!accepted)
    }
}

@Test func repeatedOwnerCursorFailsClosed() async {
    let fixture = ReceiptFixture([ownerPage([], next: "same"), ownerPage([], next: "same")])
    do {
        _ = try await CommandReceiptLookup.confirms(receiptCommand()) { try await fixture.request($0, $1) }
        Issue.record("Repeated cursor was accepted")
    } catch { #expect(await fixture.calls.count == 2) }
}

@Test func serviceReceiptRecoveryUsesOnlyReadOnlyOwnerItemsAndNeverFallsBack() async throws {
    for mode in ["accepted", "different", "legacy", "malformed"] {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-receipt-\(UUID().uuidString)")
        let logURL = scriptURL.appendingPathExtension("calls")
        let log = String(data: try JSONEncoder().encode(logURL.path), encoding: .utf8)!
        let script = """
        #!/opt/homebrew/bin/node
        const fs=require('fs'),mode='\(mode)',log=\(log);
        require('readline').createInterface({input:process.stdin}).on('line',l=>{
          const v=JSON.parse(l);if(v.id===undefined)return;
          fs.appendFileSync(log,JSON.stringify({method:v.method,params:v.params})+'\\n');
          let result={},error;
          if(v.method==='thread/items/list'){
            if(mode==='legacy')error={code:-32601,message:'unknown method'};
            else if(mode!=='malformed')result={data:[{turnId:'t',item:{id:'canonical',type:'userMessage',
              clientId:mode==='accepted'?'client-original':'different',content:[{type:'text',text:'原文🦦'}]}}],nextCursor:null};
          }
          process.stdout.write(JSON.stringify(error?{id:v.id,error}:{id:v.id,result})+'\\n');
        });
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL); try? FileManager.default.removeItem(at: logURL) }
        let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL))
        try await service.start(refreshImmediately: false, preferManagedDaemon: false)
        #expect(await service.confirmsAcceptedCommand(receiptCommand()) == (mode == "accepted"))
        await service.stop()
        let calls = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let methods = calls.compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "thread/items/list" }.count == 1)
        #expect(!methods.contains("thread/read"))
        #expect(!methods.contains("thread/resume"))
        #expect(!methods.contains("turn/start"))
        #expect(!methods.contains("thread/list"))
    }
}

@Test func unknownRecoveryIsExclusiveThrottledAndFingerprintBound() {
    let journal = BridgeMessageDeduplicator()
    #expect(journal.begin("envelope", fingerprint: "original") == .started)
    journal.markUnconfirmed("envelope")
    let now = Date()
    #expect(journal.claimRecovery("envelope", fingerprint: "changed", now: now) == nil)
    let first = journal.claimRecovery("envelope", fingerprint: "original", now: now)
    #expect(first != nil)
    #expect(journal.claimRecovery("envelope", fingerprint: "original", now: now.addingTimeInterval(61)) == nil)
    #expect(!journal.finishRecovery(first!, accepted: false))
    #expect(journal.claimRecovery("envelope", fingerprint: "original", now: now.addingTimeInterval(59)) == nil)
    let second = journal.claimRecovery("envelope", fingerprint: "original", now: now.addingTimeInterval(60))
    #expect(second != nil)
    #expect(!journal.finishRecovery(first!, accepted: true))
    #expect(journal.finishRecovery(second!, accepted: true))
    #expect(journal.begin("envelope", fingerprint: "original") == .completed(outcome: nil))
}

@Test func originalUnknownReceiptCanBeRecoveredAfterRestartWithoutExecutingAgain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    let envelope = BridgeEnvelope.taskCommand(receiptCommand(), sender: "fixture-watch")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
    journal!.markUnconfirmed(envelope.messageID)
    journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: file)
    let fixture = ReceiptFixture([ownerPage([ownerItem("canonical")])])
    let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: restored, recoveryHandler: { command in
        (try? await CommandReceiptLookup.confirms(command) { try await fixture.request($0, $1) }) == true
    })
    #expect(result == .completed(outcome: nil))
    #expect(MacReliableActionGate.begin(envelope, deduplicator: restored) == .completed(outcome: nil))
    #expect(await fixture.calls.count == 1)
    let disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
    #expect(disk[envelope.messageID]?["state"] as? String == "succeeded")
}

@Test func newConversationApprovalAndChangedEnvelopeNeverEnterOwnerRecovery() async {
    let fixture = ReceiptFixture([])
    let envelopes = [
        BridgeEnvelope.taskCommand(receiptCommand(taskID: TaskCommand.newChatTaskID), sender: "watch"),
        BridgeEnvelope.usageReset(.init(creditID: "fixture", deviceID: "watch"), sender: "watch")
    ]
    for envelope in envelopes {
        let journal = BridgeMessageDeduplicator()
        #expect(MacReliableActionGate.begin(envelope, deduplicator: journal) == .started)
        journal.markUnconfirmed(envelope.messageID)
        let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: journal, recoveryHandler: { command in
            (try? await CommandReceiptLookup.confirms(command) { try await fixture.request($0, $1) }) == true
        })
        guard case .failed = result else { Issue.record("Unknown non-command became accepted"); continue }
    }
    let original = BridgeEnvelope.taskCommand(receiptCommand(), sender: "watch")
    let journal = BridgeMessageDeduplicator()
    #expect(MacReliableActionGate.begin(original, deduplicator: journal) == .started)
    journal.markUnconfirmed(original.messageID)
    var changed = original
    changed.taskCommand = receiptCommand(text: "changed")
    let result = await MacReliableActionGate.beginCheckingOwner(changed, deduplicator: journal, recoveryHandler: { command in
        (try? await CommandReceiptLookup.confirms(command) { try await fixture.request($0, $1) }) == true
    })
    guard case .failed = result else { Issue.record("Changed envelope was recovered"); return }
    #expect(await fixture.calls.isEmpty)
}

@Test func bothIngressRoutesShareOneOwnerRecoveryAndNeverStartAgain() async {
    let journal = BridgeMessageDeduplicator()
    let envelope = BridgeEnvelope.taskCommand(receiptCommand(), sender: "watch")
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal) == .started)
    journal.markUnconfirmed(envelope.messageID)
    let counter = RecoveryCounter()
    async let nearby = MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: journal,
        recoveryHandler: { _ in await counter.confirm() })
    async let remote = MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: journal,
        recoveryHandler: { _ in await counter.confirm() })
    let results = await [nearby, remote]
    #expect(await counter.count == 1)
    #expect(results.contains(.completed(outcome: nil)))
    #expect(!results.contains(.started))
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal) == .completed(outcome: nil))
}

@Test func anUnpersistedOwnerRecoveryCannotBeAcknowledgedAsAccepted() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-write-fail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    let journal = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(journal.begin("id", fingerprint: "fixture") == .started)
    journal.markUnconfirmed("id")
    let claim = try #require(journal.claimRecovery("id", fingerprint: "fixture"))
    // Replace only this test's own receipt file with an unwritable-as-file
    // directory. No production journal or user path is involved.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(!journal.finishRecovery(claim, accepted: true))
    guard case .failed = journal.begin("id", fingerprint: "fixture") else {
        Issue.record("An unpersisted proof became accepted"); return
    }
    guard case .failed = journal.begin("new-id") else { Issue.record("Broken storage admitted another action"); return }
}
