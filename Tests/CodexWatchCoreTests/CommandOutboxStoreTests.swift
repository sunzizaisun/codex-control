import Foundation
import Testing
@testable import CodexWatchCore

private func storageDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCommandStore-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
private func storedFixture() throws -> StoredCommandRecord {
    let command = TaskCommand(taskID: "qa-original-owner", prompt: "  e\u{301}水獭-428🦦\n ", deviceID: "qa-watch")
    let envelope = BridgeEnvelope.taskCommand(command, sender: "qa-watch")
    return .init(messageID: envelope.messageID, taskID: command.taskID,
        envelopeData: try CodexWatchCoding.makeEncoder().encode(envelope), stopped: false)
}

@Test func realOutboxFileRestoresStoppedWithExactBytesAndRestrictivePermissions() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("private/commands.plist"), original = try storedFixture()
    try CommandOutboxFileStore(fileURL: url).save([original])
    let restarted = CommandOutboxFileStore(fileURL: url)
    let records = try restarted.load()
    #expect(records.count == 1 && records[0].stopped == true)
    #expect(records[0].envelopeData == original.envelopeData && records[0].messageID == original.messageID)
    #expect(CommandRecovery.original(records[0].envelopeData)?.taskCommand?.prompt.utf8.elementsEqual("  e\u{301}水獭-428🦦\n ".utf8) == true)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func bothLegacyPreferenceSchemasMigrateWithoutResurrectingAnEmptyNewFile() throws {
    struct OldWatch: Encodable { let messageID: String; let taskID: String; let data: Data }
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let original = try storedFixture(), store = CommandOutboxFileStore(fileURL: directory.appendingPathComponent("commands.plist"))
    let legacy = try PropertyListEncoder().encode([OldWatch(messageID: original.messageID, taskID: original.taskID, data: original.envelopeData)])
    let oldPhone = try PropertyListEncoder().encode([original])
    #expect(try store.load(legacyData: legacy).first?.envelopeData == original.envelopeData)
    #expect(try store.load(legacyData: oldPhone).first?.envelopeData == original.envelopeData)
    let migrated = try store.load(legacyData: legacy)
    try store.save(migrated)
    #expect(try store.load(legacyData: Data("invalid old preferences".utf8)) == migrated)
    try store.save([])
    #expect(try store.load(legacyData: legacy).isEmpty)
    #expect(try PropertyListDecoder().decode([StoredCommandRecord].self, from: legacy).first?.envelopeData == original.envelopeData)
}

@Test func invalidNewOutboxRecordsCannotReplaceTheLastGoodFile() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let original = try storedFixture(), store = CommandOutboxFileStore(fileURL: directory.appendingPathComponent("commands.plist"))
    try store.save([original]); let before = try Data(contentsOf: store.fileURL)
    #expect(throws: CommandOutboxStorageError.self) { try store.save([original, original]) }
    #expect(throws: CommandOutboxStorageError.self) { try store.save(Array(repeating: original, count: 65)) }
    #expect(throws: CommandOutboxStorageError.self) { try store.save([.init(messageID: "", taskID: original.taskID, data: original.envelopeData)]) }
    let oversized = Data(repeating: 42, count: CommandRecovery.maximumStoredBytes + 1)
    #expect(CommandRecovery.original(oversized) == nil)
    #expect(throws: CommandOutboxStorageError.self) { try store.save([.init(messageID: "oversized", taskID: original.taskID, data: oversized)]) }
    #expect(try Data(contentsOf: store.fileURL) == before)
}

@Test func actualFilesystemWriteFailureDoesNotPretendTheQueueWasSaved() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appendingPathComponent("not-a-directory")
    try Data("keep this".utf8).write(to: blocker)
    let store = CommandOutboxFileStore(fileURL: blocker.appendingPathComponent("commands.plist"))
    #expect(throws: (any Error).self) { try store.save([storedFixture()]) }
    #expect(try Data(contentsOf: blocker) == Data("keep this".utf8))
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
}

@Test func corruptedOrOversizedFileDoesNotFallBackToOldPreferences() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let store = CommandOutboxFileStore(fileURL: directory.appendingPathComponent("commands.plist"))
    let legacy = try PropertyListEncoder().encode([storedFixture()])
    let corrupted = Data("broken current queue".utf8)
    try corrupted.write(to: store.fileURL)
    #expect(throws: (any Error).self) { try store.load(legacyData: legacy) }
    #expect(try Data(contentsOf: store.fileURL) == corrupted)
    try Data(repeating: 42, count: CommandOutboxFileStore.maximumBytes + 1).write(to: store.fileURL)
    #expect(throws: CommandOutboxStorageError.self) { try store.load(legacyData: legacy) }
}

@Test func unsafeOutboxLinksNeverReadOrOverwriteTheirTarget() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target.plist"), link = directory.appendingPathComponent("link.plist")
    let bytes = Data("target must stay unchanged".utf8); try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = CommandOutboxFileStore(fileURL: link)
    #expect(throws: CommandOutboxStorageError.self) { try store.load() }
    #expect(throws: CommandOutboxStorageError.self) { try store.save([]) }
    #expect(try Data(contentsOf: target) == bytes)
    let dangling = directory.appendingPathComponent("dangling.plist")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("missing.plist"))
    #expect(throws: CommandOutboxStorageError.self) { try CommandOutboxFileStore(fileURL: dangling).load(legacyData: PropertyListEncoder().encode([storedFixture()])) }
}

@Test func twoDifferentEnvelopeFieldsCannotMasqueradeAsOneOriginal() throws {
    struct Ambiguous: Encodable { let messageID: String; let taskID: String; let data: Data; let envelopeData: Data }
    let bytes = try PropertyListEncoder().encode([Ambiguous(messageID: "original", taskID: "owner", data: Data("a".utf8), envelopeData: Data("b".utf8))])
    #expect(throws: (any Error).self) { try PropertyListDecoder().decode([StoredCommandRecord].self, from: bytes) }
}

@Test func undecodableOriginalPayloadIsRetainedStoppedForExplicitReview() throws {
    let directory = try storageDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let store = CommandOutboxFileStore(fileURL: directory.appendingPathComponent("commands.plist"))
    let record = StoredCommandRecord(messageID: "broken-original", taskID: "owner", data: Data("broken envelope".utf8))
    try store.save([record])
    let recovered = try #require(store.load().first)
    #expect(recovered.stopped == true && recovered.envelopeData == record.envelopeData)
    #expect(CommandRecovery.original(recovered.envelopeData) == nil)
    var draft = MessageDraft(); draft.restore(.init(messageID: recovered.messageID, originalData: recovered.envelopeData, taskID: recovered.taskID))
    #expect(draft.isUnconfirmed && draft.submissionID == record.messageID)
}
