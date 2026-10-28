import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

private func statusFixture(now: Date = Date()) throws -> (BridgeEnvelope, BridgeEnvelope) {
    let command = TaskCommand(taskID: "fixture-owner", prompt: "只回复：水獭🦦", deviceID: "fixture-watch")
    let original = BridgeEnvelope(kind: .taskCommand, senderDeviceID: "fixture-watch", taskCommand: command)
    let query = BridgeEnvelope(sentAt: now, kind: .requestSnapshot, senderDeviceID: "fixture-watch",
        commandStatusQuery: CommandStatusQuery(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(original)))
    return (original, query)
}

private actor StatusOwnerLookup {
    private(set) var commands: [TaskCommand] = []
    func confirm(_ command: TaskCommand) -> Bool { commands.append(command); return true }
}

@Test func actionErrorsCarryTypedCertaintyRatherThanLocalizedStringGuesses() throws {
    for definiteRejection in [false, true] {
        let (original, _) = try statusFixture(), journal = BridgeMessageDeduplicator()
        #expect(MacReliableActionGate.begin(original, deduplicator: journal) == .started)
        if definiteRejection { journal.fail(original.messageID, message: "invalid input") }
        else { journal.markUnconfirmed(original.messageID) }
        let error = MacReliableActionGate.errorEnvelope(for: original, sender: "mac", version: 3,
            message: "different device language", deduplicator: journal)
        #expect(error.commandStatusReceipt?.state == (definiteRejection ? .rejected : .unconfirmed))
        let receipt = CommandRecovery.errorReceipt(error, originalData: try CodexWatchCoding.makeEncoder().encode(original))
        if definiteRejection { #expect(receipt == .failed("invalid input")) }
        else if case .unconfirmed = receipt { }
        else { Issue.record("Unknown execution was treated as rejected") }
    }
}

@Test func readOnlyStatusQueryNeverAsksAnOwnerToExecuteMissingWork() async throws {
    let (_, query) = try statusFixture(), journal = BridgeMessageDeduplicator(), lookup = StatusOwnerLookup()
    let result = await MacReliableActionGate.inspectCheckingOwner(query, deduplicator: journal,
        recoveryHandler: { await lookup.confirm($0) })
    #expect(result?.state == .notFound)
    #expect(await lookup.commands.isEmpty)
}

@Test func readOnlyQueryRecoversOnlyTheDurablyAssignedNewOwner() async throws {
    for bindOwner in [false, true] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json")
        let command = TaskCommand(taskID: TaskCommand.newChatTaskID, prompt: "完整原文🦦", deviceID: "fixture-watch")
        let original = BridgeEnvelope.taskCommand(command, sender: "fixture-watch")
        let query = BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: "fixture-watch",
            commandStatusQuery: .init(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(original)))
        var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
        #expect(MacReliableActionGate.begin(original, deduplicator: journal!) == .started)
        if bindOwner { try journal!.bindAssignedOwner(command, threadID: "assigned-owner-only") }
        journal = nil
        let restored = BridgeMessageDeduplicator(persistenceURL: file), lookup = StatusOwnerLookup()
        let result = await MacReliableActionGate.inspectCheckingOwner(query, deduplicator: restored,
            recoveryHandler: { await lookup.confirm($0) })
        #expect(result?.state == (bindOwner ? .accepted : .unconfirmed))
        #expect(result?.ownerThreadID == (bindOwner ? "assigned-owner-only" : nil))
        let reads = await lookup.commands
        #expect(reads.count == (bindOwner ? 1 : 0))
        if let read = reads.first {
            #expect(read.taskID == "assigned-owner-only")
            #expect(read.id == command.id)
            #expect(read.prompt.utf8.elementsEqual(command.prompt.utf8))
        }
        let again = await MacReliableActionGate.inspectCheckingOwner(query, deduplicator: restored,
            recoveryHandler: { await lookup.confirm($0) })
        #expect(again == result)
        #expect(await lookup.commands.count == reads.count)
    }
}

@Test func statusQueryDoesNotCreateOrExecuteMissingCommands() throws {
    let (original, query) = try statusFixture(), journal = BridgeMessageDeduplicator()
    for _ in 0..<3 {
        #expect(MacReliableActionGate.inspect(query, deduplicator: journal)?.state == .notFound)
    }
    // A query did not call begin, consume capacity or acquire an execution lease.
    #expect(MacReliableActionGate.begin(original, deduplicator: journal) == .started)
    #expect(MacReliableActionGate.inspect(query, deduplicator: journal)?.state == .inFlight)
    journal.finish(original.messageID)
    #expect(MacReliableActionGate.inspect(query, deduplicator: journal)?.state == .accepted)
}

@Test func statusQueryDoesNotRestartOrRecoverUnknownCommands() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("receipts.json")
    let (original, query) = try statusFixture()
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(original, deduplicator: journal!) == .started)
    journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: file)
    let before = try Data(contentsOf: file)
    for _ in 0..<3 { #expect(MacReliableActionGate.inspect(query, deduplicator: restored)?.state == .unconfirmed) }
    #expect(try Data(contentsOf: file) == before)
    guard case .failed = MacReliableActionGate.begin(original, deduplicator: restored) else {
        Issue.record("Read-only inspection revived the execution"); return
    }
}

@Test func alteredOrCrossDeviceStatusQueryCannotRevealAnotherReceipt() throws {
    let (original, query) = try statusFixture(), journal = BridgeMessageDeduplicator()
    #expect(MacReliableActionGate.begin(original, deduplicator: journal) == .started)
    journal.finish(original.messageID)
    var crossDevice = query; crossDevice.senderDeviceID = "other-phone"
    #expect(MacReliableActionGate.inspect(crossDevice, deduplicator: journal) == nil)
    var changed = original
    let command = try #require(original.taskCommand)
    changed.taskCommand = TaskCommand(id: command.id, taskID: command.taskID, prompt: "changed",
        activeTurnID: command.activeTurnID, sentAt: command.sentAt, deviceID: command.deviceID,
        executionTarget: command.executionTarget, options: command.options)
    var alteredQuery = query
    alteredQuery.commandStatusQuery = .init(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(changed))
    #expect(MacReliableActionGate.inspect(alteredQuery, deduplicator: journal)?.state == .unavailable)
    var disguised = original; disguised.commandStatusQuery = query.commandStatusQuery
    guard case .failed = MacReliableActionGate.begin(disguised, deduplicator: journal) else {
        Issue.record("A query was admitted as an action"); return
    }
}

@Test func statusQueryCanInspectExpiredInputButNeverAdmitIt() throws {
    var (original, query) = try statusFixture()
    let journal = BridgeMessageDeduplicator()
    original.sentAt = Date().addingTimeInterval(-26 * 3600)
    query.commandStatusQuery = .init(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(original))
    #expect(MacReliableActionGate.inspect(query, deduplicator: journal)?.state == .notFound)
    guard case .failed = MacReliableActionGate.begin(original, deduplicator: journal) else {
        Issue.record("An expired original was executed"); return
    }
    #expect(MacReliableActionGate.inspect(query, deduplicator: journal)?.state == .rejected)
}

@Test func failedDurableSuccessWriteNeverAcknowledgesAnAction() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let displaced = directory.appendingPathExtension("backup")
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: displaced) }
    let file = directory.appendingPathComponent("receipts.json")
    let (original, query) = try statusFixture()
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    #expect(MacReliableActionGate.begin(original, deduplicator: journal!) == .started)
    // Preserve the on-disk running receipt, then make its old parent unwritable
    // by replacing that test-owned directory path with a regular file.
    try FileManager.default.moveItem(at: directory, to: displaced)
    try Data("fixture".utf8).write(to: directory)
    var acknowledgements = 0
    #expect(!MacReliableActionGate.finish(original, deduplicator: journal!) { acknowledgements += 1 })
    #expect(acknowledgements == 0)
    #expect(MacReliableActionGate.inspect(query, deduplicator: journal!)?.state == .unavailable)
    guard case .failed = MacReliableActionGate.begin(original, deduplicator: journal!) else {
        Issue.record("Failed persistence permitted replay"); return
    }
    journal = nil
    let restored = BridgeMessageDeduplicator(persistenceURL: displaced.appendingPathComponent("receipts.json"))
    #expect(MacReliableActionGate.inspect(query, deduplicator: restored)?.state == .unconfirmed)
}
