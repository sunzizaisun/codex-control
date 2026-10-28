import Foundation

/// One schema for both app containers. The old Watch preferences used `data`;
/// decoding accepts that spelling without changing any original envelope.
public struct StoredCommandRecord: Codable, Equatable, Sendable {
    public let messageID: String
    public let taskID: String
    public let envelopeData: Data
    public var stopped: Bool?
    public var data: Data { envelopeData }

    public init(messageID: String, taskID: String, envelopeData: Data, stopped: Bool? = nil) {
        self.messageID = messageID; self.taskID = taskID; self.envelopeData = envelopeData; self.stopped = stopped
    }
    public init(messageID: String, taskID: String, data: Data, stopped: Bool? = nil) {
        self.init(messageID: messageID, taskID: taskID, envelopeData: data, stopped: stopped)
    }
    private enum CodingKeys: String, CodingKey { case messageID, taskID, envelopeData, data, stopped }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try values.decode(String.self, forKey: .messageID)
        taskID = try values.decode(String.self, forKey: .taskID)
        let modern = try values.decodeIfPresent(Data.self, forKey: .envelopeData)
        let legacy = try values.decodeIfPresent(Data.self, forKey: .data)
        if let modern, let legacy, modern != legacy { throw CommandOutboxStorageError.invalidRecords }
        guard let bytes = modern ?? legacy else { throw CommandOutboxStorageError.invalidRecords }
        envelopeData = bytes
        stopped = try values.decodeIfPresent(Bool.self, forKey: .stopped)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(messageID, forKey: .messageID)
        try values.encode(taskID, forKey: .taskID)
        try values.encode(envelopeData, forKey: .envelopeData)
        try values.encodeIfPresent(stopped, forKey: .stopped)
    }
}

public enum CommandOutboxStorageError: Error { case invalidRecords, tooLarge, unsafePath }

/// Called serially by each app's main-actor controller, in its own sandbox.
/// Atomic Foundation replacement is the same existing project pattern as the
/// Mac receipt journal. Write/read errors are surfaced, never swallowed.
/// A failed post-replacement sync may leave the new file: callers must remain
/// stopped, not infer that an unacknowledged operation definitely never ran.
public struct CommandOutboxFileStore: Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public static func applicationURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexControl", isDirectory: true)
            .appendingPathComponent("command-outbox-v1.plist")
    }
    public func load(legacyData: Data? = nil) throws -> [StoredCommandRecord] {
        guard fileURL.isFileURL else { throw CommandOutboxStorageError.unsafePath }
        if let parent = try? FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path) {
            guard parent[.type] as? FileAttributeType == .typeDirectory else { throw CommandOutboxStorageError.unsafePath }
        }
        let bytes: Data
        if FileManager.default.fileExists(atPath: fileURL.path)
            || (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil {
            try requireRegularFile()
            let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
            guard let size, size.intValue <= Self.maximumBytes else { throw CommandOutboxStorageError.tooLarge }
            bytes = try Data(contentsOf: fileURL)
        } else if let legacyData { bytes = legacyData }
        else { return [] }
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw CommandOutboxStorageError.tooLarge }
        let records = try PropertyListDecoder().decode([StoredCommandRecord].self, from: bytes)
        try Self.validate(records)
        return records.map { record in
            var stopped = record; stopped.stopped = true
            return stopped
        }
    }
    public func save(_ records: [StoredCommandRecord]) throws {
        try Self.validate(records)
        let data = try PropertyListEncoder().encode(records)
        guard data.count <= Self.maximumBytes else { throw CommandOutboxStorageError.tooLarge }
        guard fileURL.isFileURL else { throw CommandOutboxStorageError.unsafePath }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directoryType = try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
        guard directoryType == .typeDirectory else { throw CommandOutboxStorageError.unsafePath }
        if FileManager.default.fileExists(atPath: fileURL.path)
            || (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil { try requireRegularFile() }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func requireRegularFile() throws {
        guard fileURL.isFileURL,
              try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CommandOutboxStorageError.unsafePath
        }
    }
    private static func validate(_ records: [StoredCommandRecord]) throws {
        guard records.count <= 64, Set(records.map(\.messageID)).count == records.count,
              records.allSatisfy({ !$0.messageID.isEmpty && $0.messageID.utf8.count <= 160
                  && !$0.taskID.isEmpty && $0.taskID.utf8.count <= 160
                  && $0.envelopeData.count <= CommandRecovery.maximumStoredBytes }) else {
            throw CommandOutboxStorageError.invalidRecords
        }
    }
}
