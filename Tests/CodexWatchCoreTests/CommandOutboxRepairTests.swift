import Foundation
import Testing
import CryptoKit
@testable import CodexWatchCore

private func repairDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexRepair-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
private func repairRecord(_ id: String, prompt: String = "  原始e\u{301}水獭🦦  ") throws -> StoredCommandRecord {
    var envelope = BridgeEnvelope.taskCommand(.init(taskID: "qa-owner", prompt: prompt, deviceID: "qa-phone"), sender: "qa-phone")
    envelope.messageID = id
    return .init(messageID: id, taskID: "qa-owner", envelopeData: try CodexWatchCoding.makeEncoder().encode(envelope), stopped: false)
}
private func plistRow(_ record: StoredCommandRecord) throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(record), format: nil) as? [String: Any])
}

@Test func repairArchivesExactCorruptBytesBeforeRebuildingAnEmptyStoppedQueue() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist"))
    let original = Data("QA_CORRUPT_QUEUE".utf8); try original.write(to: store.fileURL)
    let receipt = try store.quarantineAndRebuild()
    #expect(receipt.recoveredCommands == 0 && receipt.originalEntryCount == nil)
    #expect(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("original-current.plist")) == original)
    #expect(receipt.originalSHA256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
    #expect(try store.load().isEmpty)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt.backupDirectory.appendingPathComponent("manifest.json"))) as? [String: Any]
    #expect(manifest?["replacementConfirmed"] as? Bool == true)
}

@Test func partialRepairPreservesExactRecognizableOriginalsAndArchivesEveryBadRow() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist")), record = try repairRecord("same")
    let rows: [Any] = [try plistRow(record), try plistRow(record), ["messageID": 7]]
    let raw = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0); try raw.write(to: store.fileURL)
    let result = try store.quarantineAndRebuild(), recovered = try store.load()
    #expect(result.originalEntryCount == 3 && result.recoveredCommands == 1)
    #expect(recovered.first?.stopped == true && recovered.first?.envelopeData == record.envelopeData)
    #expect(try Data(contentsOf: result.backupDirectory.appendingPathComponent("original-current.plist")) == raw)
}

@Test func repairNeverSelectsOneOfTwoConflictingOriginalsWithTheSameID() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist"))
    let rows = try [repairRecord("conflict", prompt: "a"), repairRecord("conflict", prompt: "b"), repairRecord("safe")].map(plistRow)
    try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0).write(to: store.fileURL)
    let result = try store.quarantineAndRebuild()
    #expect(result.recoveredCommands == 1 && result.originalEntryCount == 3)
    #expect(try store.load().map(\.messageID) == ["safe"])
}

@Test func aMalformedDuplicateIDCannotMakeTheReadableSiblingLookUnambiguous() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist"))
    let rows: [Any] = [try plistRow(repairRecord("ambiguous")), ["messageID": "ambiguous", "taskID": "qa-owner", "envelopeData": Data("damaged".utf8)]]
    try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0).write(to: store.fileURL)
    let receipt = try store.quarantineAndRebuild()
    #expect(receipt.originalEntryCount == 2 && receipt.recoveredCommands == 0)
    #expect(try store.load().isEmpty)
    let canonical = try repairRecord("canonical")
    let alias: [String: Any] = ["messageID": "different-metadata-id", "taskID": canonical.taskID, "envelopeData": canonical.envelopeData]
    let aliasedRows: [Any] = [try plistRow(canonical), alias, ["messageID": 7]]
    try PropertyListSerialization.data(fromPropertyList: aliasedRows, format: .binary, options: 0).write(to: store.fileURL)
    #expect(throws: (any Error).self) { try store.load() }
    let aliased = try store.quarantineAndRebuild()
    #expect(aliased.recoveredCommands == 0)
    #expect(try store.load().isEmpty)
}

@Test func anArchiveWriteFailureCannotReplaceTheDamagedOriginal() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist")), raw = Data("broken".utf8)
    try raw.write(to: store.fileURL)
    try Data("do not alter".utf8).write(to: dir.appendingPathComponent("CommandQueueBackups"))
    #expect(throws: (any Error).self) { try store.quarantineAndRebuild() }
    #expect(try Data(contentsOf: store.fileURL) == raw)
}

@Test func interveningSourceReplacementFailsClosedAfterTheOriginalWasBackedUp() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist"))
    let raw = Data("old damaged source".utf8), changed = Data("new independently changed source".utf8)
    try raw.write(to: store.fileURL)
    #expect(throws: CommandOutboxRepairError.self) {
        try store.rebuildForReview(legacyData: nil, beforeCommit: { try changed.write(to: store.fileURL, options: .atomic) })
    }
    #expect(try Data(contentsOf: store.fileURL) == changed)
    let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("CommandQueueBackups"), includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0].appendingPathComponent("original-current.plist")) == raw)
}

@Test func repairCanArchiveOldPreferencesButDoesNotRebuildAHealthyQueue() throws {
    let dir = try repairDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = CommandOutboxFileStore(fileURL: dir.appendingPathComponent("commands.plist"))
    let legacy = Data("damaged old preferences".utf8)
    let receipt = try store.quarantineAndRebuild(legacyData: legacy)
    #expect(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("original-legacy.plist")) == legacy)
    #expect(try store.load(legacyData: legacy).isEmpty)
    let before = try Data(contentsOf: store.fileURL)
    #expect(throws: CommandOutboxRepairError.self) { try store.quarantineAndRebuild(legacyData: legacy) }
    #expect(try Data(contentsOf: store.fileURL) == before)
}
