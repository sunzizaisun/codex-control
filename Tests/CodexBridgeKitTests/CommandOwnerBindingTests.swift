import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

@Test func inMemoryCommandIdentityAlsoSurvivesTransportRewrappingWithinTheProcess() throws {
    let command = TaskCommand(taskID: TaskCommand.newChatTaskID, prompt: "same input🦦", deviceID: "watch")
    let original = BridgeEnvelope.taskCommand(command, sender: "watch")
    for cancelled in [false, true] {
        let journal = BridgeMessageDeduplicator()
        #expect(MacReliableActionGate.begin(original, deduplicator: journal) == .started)
        try journal.bindAssignedOwner(command, threadID: "in-memory-owner")
        var wrapper = original; wrapper.messageID = UUID().uuidString
        #expect(MacReliableActionGate.begin(wrapper, deduplicator: journal) == .inFlight)
        if cancelled {
            journal.cancel(original.messageID)
            guard case .failed = MacReliableActionGate.begin(wrapper, deduplicator: journal) else {
                Issue.record("Cancelled input was admitted again in memory"); continue
            }
        } else {
            #expect(journal.finish(original.messageID))
            #expect(MacReliableActionGate.begin(wrapper, deduplicator: journal) == .completed(outcome: nil))
        }
    }
    let bounded = BridgeMessageDeduplicator(capacity: 1)
    #expect(MacReliableActionGate.begin(original, deduplicator: bounded) == .started)
    bounded.cancel(original.messageID)
    let next = BridgeEnvelope.taskCommand(.init(taskID: "other-owner", prompt: "different", deviceID: "watch"), sender: "watch")
    guard case .failed = MacReliableActionGate.begin(next, deduplicator: bounded) else {
        Issue.record("In-memory command journal exceeded its bound"); return
    }
}

private func newOwnerCommand(_ text: String = "新对话原文🦦") -> TaskCommand {
    .init(id: "new-client-original", taskID: TaskCommand.newChatTaskID, prompt: text, deviceID: "fixture-watch")
}
private func ownerTestDirectory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("codex-owner-binding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
    return value
}
private actor BoundLookupCapture {
    var commands: [TaskCommand] = []
    func confirms(_ command: TaskCommand) -> Bool { commands.append(command); return true }
}

@Test func assignedOwnerSurvivesRestartAndRecoveryUsesOnlyThatThread() async throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), command = newOwnerCommand()
    let envelope = BridgeEnvelope.taskCommand(command, sender: "watch")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
    try journal!.bindAssignedOwner(command, threadID: "server-assigned-owner")
    journal!.markUnconfirmed(envelope.messageID)
    journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: file), capture = BoundLookupCapture()
    let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: restored,
        recoveryHandler: { await capture.confirms($0) })
    #expect(result == .completed(outcome: nil))
    let lookup = try #require(await capture.commands.first)
    #expect(lookup.taskID == "server-assigned-owner")
    #expect(lookup.id == command.id && lookup.prompt.utf8.elementsEqual(command.prompt.utf8))
    #expect(lookup.options == command.options && lookup.sentAt == command.sentAt)
    let disk = try String(contentsOf: file, encoding: .utf8)
    #expect(!disk.contains(command.prompt))
    #expect(disk.contains("server-assigned-owner"))
}

@Test func newOwnerBindingIsImmutableAndCoversPromptAndModelOptions() throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), command = newOwnerCommand()
    let journal = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(MacReliableActionGate.begin(.taskCommand(command, sender: "watch"), deduplicator: journal) == .started)
    #expect(throws: CommandOwnerBindingError.self) { try journal.bindAssignedOwner(newOwnerCommand("changed"), threadID: "wrong") }
    let changed = TaskCommand(id: command.id, taskID: command.taskID, prompt: command.prompt,
        sentAt: command.sentAt, deviceID: command.deviceID, options: .init(model: "fixture-model", effort: "low"))
    #expect(throws: CommandOwnerBindingError.self) { try journal.bindAssignedOwner(changed, threadID: "wrong") }
    try journal.bindAssignedOwner(command, threadID: "original-owner")
    try journal.bindAssignedOwner(command, threadID: "original-owner")
    #expect(throws: CommandOwnerBindingError.self) { try journal.bindAssignedOwner(command, threadID: "another-owner") }
    let disk = try String(contentsOf: file, encoding: .utf8)
    #expect(disk.contains("original-owner") && !disk.contains("another-owner"))
}

@Test func missingOrLegacyNewOwnerBindingNeverQueriesTheSentinelOrCreatesAnotherThread() async throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for legacy in [false, true] {
        let file = directory.appendingPathComponent("\(legacy).json")
        var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
        let envelope = BridgeEnvelope.taskCommand(newOwnerCommand(), sender: "watch")
        #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
        journal!.markUnconfirmed(envelope.messageID)
        if legacy {
            // An older receipt has the same envelope fingerprint but no
            // assigned-owner metadata. It must remain recoverably unknown.
            journal = nil
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
            records[envelope.messageID]?.removeValue(forKey: "ownerBinding")
            try JSONSerialization.data(withJSONObject: records).write(to: file)
            journal = BridgeMessageDeduplicator(persistenceURL: file)
            #expect(journal!.begin("legacy-load-is-valid") == .started)
            journal!.cancel("legacy-load-is-valid")
        }
        let capture = BoundLookupCapture()
        let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: journal!,
            recoveryHandler: { await capture.confirms($0) })
        guard case .failed = result else { Issue.record("Missing owner became accepted"); continue }
        #expect(await capture.commands.isEmpty)
    }
}

@Test func rewrappedCommandsCannotExecuteAgainAfterAProcessRestart() throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), command = newOwnerCommand()
    let original = BridgeEnvelope.taskCommand(command, sender: "watch")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(original, deduplicator: journal!) == .started)
    var rewrapped = original; rewrapped.messageID = UUID().uuidString
    #expect(MacReliableActionGate.begin(rewrapped, deduplicator: journal!) == .inFlight)
    journal!.markUnconfirmed(original.messageID); journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: file)
    guard case .failed = MacReliableActionGate.begin(rewrapped, deduplicator: restored) else {
        Issue.record("Rewrapped unknown command executed again"); return
    }
    var changed = rewrapped; changed.taskCommand = newOwnerCommand("changed")
    guard case .failed = MacReliableActionGate.begin(changed, deduplicator: restored) else { Issue.record("Reused command ID changed payload"); return }
}

@Test func bindingMetadataCannotBeAdmittedWithoutAnEnvelopeFingerprint() {
    let journal = BridgeMessageDeduplicator()
    guard case .failed = journal.begin("id", command: newOwnerCommand()) else {
        Issue.record("Binding without envelope fingerprint was admitted"); return
    }
}

@Test func corruptAssignedOwnerMetadataFailsClosedOnRestore() throws {
    for badOwner in ["", "other task", TaskCommand.newChatTaskID, "chatgpt-web:retired"] {
        let directory = try ownerTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json"), envelope = BridgeEnvelope.taskCommand(newOwnerCommand(), sender: "watch")
        var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
        #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
        journal = nil
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        var binding = try #require(records[envelope.messageID]?["ownerBinding"] as? [String: Any])
        binding["ownerThreadID"] = badOwner; records[envelope.messageID]?["ownerBinding"] = binding
        try JSONSerialization.data(withJSONObject: records).write(to: file)
        let restored = BridgeMessageDeduplicator(persistenceURL: file)
        guard case .failed = restored.begin("different-id") else { Issue.record("Corrupt owner admitted new work"); continue }
    }
}

@Test func duplicateCommandBindingsFailClosedInsteadOfChoosingAnArbitraryOwner() throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), envelope = BridgeEnvelope.taskCommand(newOwnerCommand(), sender: "watch")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
    journal = nil
    var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
    records["duplicate-record"] = records[envelope.messageID]
    try JSONSerialization.data(withJSONObject: records).write(to: file)
    let restored = BridgeMessageDeduplicator(persistenceURL: file)
    guard case .failed = restored.begin("new-id") else { Issue.record("Duplicate command identities admitted more work"); return }
}

@Test func changedOwnerBindingDigestCannotRecoverAnOtherwiseMatchingEnvelope() async throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json"), envelope = BridgeEnvelope.taskCommand(newOwnerCommand(), sender: "watch")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal!) == .started)
    try journal!.bindAssignedOwner(envelope.taskCommand!, threadID: "owner-original")
    journal!.markUnconfirmed(envelope.messageID); journal = nil
    var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
    var binding = try #require(records[envelope.messageID]?["ownerBinding"] as? [String: Any])
    binding["commandFingerprint"] = String(repeating: "a", count: 64)
    records[envelope.messageID]?["ownerBinding"] = binding
    try JSONSerialization.data(withJSONObject: records).write(to: file)
    let restored = BridgeMessageDeduplicator(persistenceURL: file), capture = BoundLookupCapture()
    let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: restored,
        recoveryHandler: { await capture.confirms($0) })
    guard case .failed = result else { Issue.record("Changed command binding was recovered"); return }
    #expect(await capture.commands.isEmpty)
}

@Test func failedOwnerBindingPreventsTheFirstTurnFromBeingSubmitted() async throws {
    try await exerciseOwnerBoundService(bindingFails: true)
}
@Test func lostStartResponseRecoversTheOriginalNewOwnerWithoutStartingAnotherTurn() async throws {
    try await exerciseOwnerBoundService(bindingFails: false)
}

private func exerciseOwnerBoundService(bindingFails: Bool) async throws {
    let directory = try ownerTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scriptURL = directory.appendingPathComponent("server"), logURL = directory.appendingPathComponent("calls.jsonl")
    let file = directory.appendingPathComponent("journal.json"), command = newOwnerCommand()
    func json(_ value: String) throws -> String { String(data: try JSONEncoder().encode(value), encoding: .utf8)! }
    let script = """
    #!/opt/homebrew/bin/node
    const fs=require('fs'),log=\(try json(logURL.path)),journal=\(try json(file.path));let received;
    require('readline').createInterface({input:process.stdin}).on('line',l=>{
      const v=JSON.parse(l);if(v.id===undefined)return;
      const row={method:v.method,params:v.params};let result={},error;
      if(v.method==='thread/start')result={thread:{id:'owner-new',status:{type:'idle'}}};
      if(v.method==='turn/start'){
        row.bindingBeforeTurn=Object.values(JSON.parse(fs.readFileSync(journal,'utf8'))).some(r=>r.ownerBinding?.ownerThreadID==='owner-new'&&r.state==='running');
        received={clientId:v.params.clientUserMessageId,text:v.params.input[0].text};
        error={code:-32603,message:'ambiguous fixture response'};
      }
      if(v.method==='thread/items/list')result={data:received?[{turnId:'owner-turn',item:{id:'canonical-input',type:'userMessage',clientId:received.clientId,content:[{type:'text',text:received.text}]}}]:[],nextCursor:null};
      fs.appendFileSync(log,JSON.stringify(row)+'\\n');
      process.stdout.write(JSON.stringify(error?{id:v.id,error}:{id:v.id,result})+'\\n');
    });
    """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)
    let journal = BridgeMessageDeduplicator(persistenceURL: file)
    let envelope = BridgeEnvelope.taskCommand(command, sender: "watch")
    #expect(MacReliableActionGate.begin(envelope, deduplicator: journal) == .started)
    if bindingFails {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    }
    let service = CodexBridgeService(client: AppServerClient(executableURL: scriptURL), isolateCommandSessions: false,
        ownerBindingRecorder: { try journal.bindAssignedOwner($0, threadID: $1) })
    try await service.start(refreshImmediately: false, preferManagedDaemon: false)
    do { try await service.send(command); Issue.record("Fixture should fail before a successful response") }
    catch { _ = MacActionFailure.record(error, messageID: envelope.messageID, in: journal) }
    if !bindingFails {
        let result = await MacReliableActionGate.beginCheckingOwner(envelope, deduplicator: journal,
            recoveryHandler: { await service.confirmsAcceptedCommand($0) })
        #expect(result == .completed(outcome: nil))
        #expect(await service.task(threadID: "owner-new")?.state == .unknown)
    }
    await service.stop()
    let calls = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    #expect(calls.filter { $0["method"] as? String == "thread/start" }.count == 1)
    let starts = calls.filter { $0["method"] as? String == "turn/start" }
    #expect(starts.count == (bindingFails ? 0 : 1))
    if !bindingFails { #expect(starts.first?["bindingBeforeTurn"] as? Bool == true) }
    #expect(!calls.contains { ["thread/read", "thread/list", "thread/resume"].contains($0["method"] as? String ?? "") })
}
