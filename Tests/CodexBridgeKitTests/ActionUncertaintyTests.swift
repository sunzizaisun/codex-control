import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

@Test func handlerTimeoutAndLostResolutionAreNotDefinitiveRejections() {
    #expect(MacActionFailure.isUnconfirmed(AppServerClientError.timedOut(method: "turn/start")))
    #expect(MacActionFailure.isUnconfirmed(AppServerClientError.processExited))
    #expect(MacActionFailure.isUnconfirmed(AppServerClientError.invalidResponse))
    #expect(MacActionFailure.isUnconfirmed(RequestResolutionTracker.Failure.unconfirmed))
    #expect(MacActionFailure.isUnconfirmed(CancellationError()))
    #expect(MacActionFailure.isUnconfirmed(NSError(domain: "fixture", code: 1)))
    #expect(!MacActionFailure.isUnconfirmed(AppServerClientError.notRunning))
    #expect(!MacActionFailure.isUnconfirmed(AppServerClientError.server(code: -32600, message: "rejected")))
    #expect(MacActionFailure.isUnconfirmed(AppServerClientError.server(code: -32603, message: "internal")))
    #expect(MacActionFailure.isUnconfirmed(AppServerClientError.server(code: nil, message: "unknown")))
    #expect(!MacActionFailure.isUnconfirmed(ApprovalBrokerError.requestChanged))
}

@Test func internalStartErrorDoesNotInventAnAtomicRejectedTurn() async throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-internal-start-\(UUID().uuidString)")
    let script = """
    #!/opt/homebrew/bin/node
    require('readline').createInterface({input:process.stdin}).on('line',l=>{
      const v=JSON.parse(l);if(v.id===undefined)return;
      let result={};
      if(v.method==='thread/start')result={thread:{id:'uncertain-seed',preview:'fixture',status:{type:'idle'}}};
      const reply=v.method==='turn/start'?{id:v.id,error:{code:-32603,message:'internal fixture failure'}}:{id:v.id,result};
      process.stdout.write(JSON.stringify(reply)+'\\n');
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL))
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    do {
        _ = try await service.startCodexConversation(prompt: "Fixture only", messageID: "original-client-id")
        Issue.record("The fixture should reject its RPC")
    } catch { #expect(MacActionFailure.isUnconfirmed(error)) }
    #expect(await service.task(threadID: "uncertain-seed")?.state == .unknown)
    #expect(await service.task(threadID: "uncertain-seed")?.messages.first?.text == "Fixture only")
    await service.stop()
}

@Test func uncertainHandlerResultPersistsAcrossRestartWithoutAnotherExecution() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-uncertain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), fingerprint = String(repeating: "a", count: 64)
    var journal: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(journal?.begin("original-id", fingerprint: fingerprint) == .started)
    let message = MacActionFailure.record(AppServerClientError.timedOut(method: "turn/start"),
        messageID: "original-id", in: journal!)
    #expect(message == AppLocalizer.text("上次操作结果未确认，请先检查原任务。"))
    journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(restored.begin("original-id", fingerprint: fingerprint) == .failed(message: message))
    guard case .failed = restored.begin("original-id", fingerprint: String(repeating: "b", count: 64)) else {
        Issue.record("Changed payload was accepted"); return
    }
    let disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
    #expect(disk["original-id"]?["state"] as? String == "unknown")
}

@Test func definitiveRejectionRetainsItsSpecificMessageAndNeverBecomesAccepted() {
    let journal = BridgeMessageDeduplicator()
    #expect(journal.begin("id") == .started)
    let error = ApprovalBrokerError.requestChanged
    let message = MacActionFailure.record(error, messageID: "id", in: journal)
    #expect(message == error.localizedDescription)
    #expect(journal.begin("id") == .failed(message: message))
}

@Test func anUncertainCleanupCannotEraseAnAlreadyPersistedSuccess() {
    let journal = BridgeMessageDeduplicator()
    #expect(journal.begin("id") == .started)
    journal.finish("id", outcome: "confirmed")
    journal.markUnconfirmed("id")
    #expect(journal.begin("id") == .completed(outcome: "confirmed"))
}

@Test func malformedReceiptStateCannotForgeAnAcceptedOutcome() throws {
    for state in ["failed", "running", "unknown", "succeeded", "failed-without-error"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bad-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        var record: [String: Any] = ["state": state, "outcome": "forged-success", "updatedAt": Date().timeIntervalSinceReferenceDate]
        if state == "succeeded" { record["failure"] = "inconsistent rejection" }
        if state == "failed-without-error" {
            record["state"] = "failed"
            record.removeValue(forKey: "outcome")
        }
        try JSONSerialization.data(withJSONObject: ["id": record]).write(to: file)
        let journal = BridgeMessageDeduplicator(persistenceURL: file)
        guard case .failed = journal.begin("id") else {
            Issue.record("Invalid receipt was reused as accepted"); continue
        }
        guard case .failed = journal.begin("different-id") else {
            Issue.record("Corrupt journal admitted new work"); continue
        }
    }
}
