import Foundation
import CryptoKit

public struct CommandOutboxRepairReceipt: Equatable, Sendable {
    public let backupDirectory: URL
    public let originalSHA256: String
    public let recoveredCommands: Int
    public let originalEntryCount: Int?
}

public enum CommandOutboxRepairError: Error { case notNeeded, sourceChanged, oversizedBackup, unsafeSource, backupVerificationFailed }

public extension CommandOutboxFileStore {
    static func canRepair(_ error: any Error) -> Bool {
        if error is DecodingError { return true }
        guard let storage = error as? CommandOutboxStorageError else { return false }
        switch storage {
        case .invalidRecords, .tooLarge: return true
        case .unsafePath: return false
        }
    }

    /// Explicitly confirmed local repair only. The original is archived and
    /// checked before replacement. Recognizable originals remain stopped;
    /// unrecognizable bytes stay in the backup, never silently auto-sent.
    func quarantineAndRebuild(legacyData: Data? = nil) throws -> CommandOutboxRepairReceipt {
        try rebuildForReview(legacyData: legacyData, beforeCommit: nil)
    }
}

extension CommandOutboxFileStore {
    // The internal hook injects a concurrent-source replacement in tests.
    // Production callers cannot supply code at the pre-commit boundary.
    func rebuildForReview(legacyData: Data?, beforeCommit: (() throws -> Void)?) throws -> CommandOutboxRepairReceipt {
        do {
            _ = try load(legacyData: legacyData)
        } catch {
            guard Self.canRepair(error) else { throw error }
            return try archiveAndRebuild(legacyData: legacyData, beforeCommit: beforeCommit)
        }
        throw CommandOutboxRepairError.notNeeded
    }

    private func archiveAndRebuild(legacyData: Data?, beforeCommit: (() throws -> Void)?) throws -> CommandOutboxRepairReceipt {
        let originalIsFile = FileManager.default.fileExists(atPath: fileURL.path)
        let original: Data
        if originalIsFile { original = try readRepairSource(fileURL) }
        else {
            guard let legacyData, legacyData.count <= 8 * 1024 * 1024 else { throw CommandOutboxRepairError.oversizedBackup }
            original = legacyData
        }
        let (records, count) = try recoverRecognizable(original)
        let backupRoot = fileURL.deletingLastPathComponent().appendingPathComponent("CommandQueueBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: backupRoot.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CommandOutboxRepairError.unsafeSource
        }
        let directory = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let backup = directory.appendingPathComponent(originalIsFile ? "original-current.plist" : "original-legacy.plist")
        try writePrivateRepairFile(original, to: backup)
        guard try readRepairSource(backup) == original else { throw CommandOutboxRepairError.backupVerificationFailed }
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let receipt = CommandOutboxRepairReceipt(backupDirectory: directory, originalSHA256: digest,
            recoveredCommands: records.count, originalEntryCount: count)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = RepairManifest(originalSHA256: digest, originalBytes: original.count,
            originalEntryCount: count, recoveredCommands: records.count, sourceWasLegacy: !originalIsFile, replacementConfirmed: false)
        try writePrivateRepairFile(JSONEncoder().encode(manifest), to: manifestURL)
        try beforeCommit?()
        if originalIsFile {
            guard try readRepairSource(fileURL) == original else { throw CommandOutboxRepairError.sourceChanged }
        } else if FileManager.default.fileExists(atPath: fileURL.path)
                    || (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil {
            throw CommandOutboxRepairError.sourceChanged
        }
        try save(records)
        var complete = manifest; complete.replacementConfirmed = true
        try writePrivateRepairFile(JSONEncoder().encode(complete), to: manifestURL)
        return receipt
    }

    private struct RepairManifest: Codable {
        let originalSHA256: String
        let originalBytes: Int
        let originalEntryCount: Int?
        let recoveredCommands: Int
        let sourceWasLegacy: Bool
        var replacementConfirmed: Bool
    }
    private func readRepairSource(_ url: URL) throws -> Data {
        guard url.isFileURL,
              try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CommandOutboxRepairError.unsafeSource
        }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw CommandOutboxRepairError.unsafeSource }
        guard let size = before[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw CommandOutboxRepairError.oversizedBackup }
        let bytes = try Data(contentsOf: url), after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard bytes.count == size.intValue, before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw CommandOutboxRepairError.sourceChanged }
        return bytes
    }
    private func writePrivateRepairFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func recoverRecognizable(_ bytes: Data) throws -> ([StoredCommandRecord], Int?) {
        guard let rows = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [Any] else { return ([], nil) }
        guard rows.count <= 512 else { throw CommandOutboxStorageError.invalidRecords }
        var groups: [String: [StoredCommandRecord]] = [:]
        var ambiguousIDs = Set<String>()
        func retainAmbiguousClaims(_ item: [String: Any]) {
            if let claimed = item["messageID"] as? String, claimed.utf8.count <= 160 { ambiguousIDs.insert(claimed) }
            for key in ["envelopeData", "data"] {
                if let data = item[key] as? Data, let envelope = CommandRecovery.original(data) {
                    ambiguousIDs.insert(envelope.messageID)
                }
            }
        }
        for row in rows {
            guard let item = row as? [String: Any] else { continue }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: [item], format: .binary, options: 0),
                  let record = try? PropertyListDecoder().decode([StoredCommandRecord].self, from: data).first,
                  let envelope = CommandRecovery.original(record.envelopeData),
                  envelope.messageID == record.messageID, envelope.taskCommand?.taskID == record.taskID else {
                retainAmbiguousClaims(item)
                continue
            }
            groups[record.messageID, default: []].append(record)
        }
        let recovered = groups.values.compactMap { group -> StoredCommandRecord? in
            guard var first = group.first,
                  !ambiguousIDs.contains(first.messageID),
                  group.allSatisfy({ $0.envelopeData == first.envelopeData && $0.taskID == first.taskID }) else { return nil }
            first.stopped = true
            return first
        }.sorted { $0.messageID < $1.messageID }
        guard recovered.count <= 64 else { throw CommandOutboxStorageError.invalidRecords }
        return (recovered, rows.count)
    }
}
