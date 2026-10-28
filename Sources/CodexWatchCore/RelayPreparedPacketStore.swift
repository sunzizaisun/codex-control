import Foundation

/// Only encrypted bytes and public identifiers are persisted here. This is
/// a transport journal, NOT the owner's command/execution receipt journal.
struct RelayPreparedPacketStore: Sendable {
    enum State: String, Codable { case prepared, attempted, accepted }
    struct Record: Codable {
        let id: String
        let destination: RelaySignedDestination
        let originalSHA256: String
        let body: Data
        let expiresAt: Date
        var state: State
    }
    private struct Journal: Codable { let version: Int; let scope: String; var records: [Record] }
    static let maximumBytes = 12 * 1024 * 1024
    let fileURL: URL
    let scope: String
    // A single app container can construct more than one client. Serialize
    // its read-modify-write; different apps do not share this file/container.
    private static let lock = NSLock()

    func record(id: String, destination: RelaySignedDestination) throws -> Record? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load().records.first { $0.id == id && $0.destination == destination }
    }
    func insert(_ record: Record, now: Date) throws -> Record {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var journal = try load()
        if let prior = journal.records.first(where: { $0.id == record.id && $0.destination == record.destination }) {
            guard prior.originalSHA256 == record.originalSHA256 else { throw RelayDeviceTransportError.conflictingMessage }
            return prior
        }
        journal.records.removeAll { $0.expiresAt <= now }
        guard journal.records.count < 64 else { throw CommandOutboxStorageError.tooLarge }
        journal.records.append(record)
        try save(journal)
        return record
    }
    func transition(id: String, destination: RelaySignedDestination, from: State, to: State) throws -> Record {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard (from == .prepared && to == .attempted) || (from == .attempted && to == .accepted) else {
            throw CommandOutboxStorageError.invalidRecords
        }
        var journal = try load()
        guard let index = journal.records.firstIndex(where: { $0.id == id && $0.destination == destination }),
              journal.records[index].state == from else { throw RelayDeviceTransportError.deliveryUncertain }
        journal.records[index].state = to
        try save(journal)
        return journal.records[index]
    }
    private func load() throws -> Journal {
        try requirePath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            // A missing file is the only empty state. Permission/IO failures
            // must not silently reset the journal.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                let directory = fileURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: directory.path) {
                    _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                }
                return Journal(version: 1, scope: scope, records: [])
            }
            throw CommandOutboxStorageError.invalidRecords
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CommandOutboxStorageError.unsafePath }
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= Self.maximumBytes else {
            throw CommandOutboxStorageError.tooLarge
        }
        let bytes = try Data(contentsOf: fileURL)
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw CommandOutboxStorageError.tooLarge }
        let journal = try PropertyListDecoder().decode(Journal.self, from: bytes)
        try validate(journal)
        return journal
    }
    private func validate(_ journal: Journal) throws {
        guard journal.version == 1, journal.scope == scope, journal.records.count <= 64,
              Set(journal.records.map { $0.destination.rawValue + ":" + $0.id }).count == journal.records.count,
              journal.records.allSatisfy({ RelayCredentials.validIdentifier($0.id)
                  && $0.body.count > 0 && $0.body.count <= 1_902_048
                  && $0.originalSHA256.utf8.count == 64 && $0.originalSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                  && $0.expiresAt.timeIntervalSince1970.isFinite && $0.expiresAt.timeIntervalSince1970 > 0 }) else {
            throw CommandOutboxStorageError.invalidRecords
        }
    }
    private func requirePath() throws {
        guard fileURL.isFileURL, !scope.isEmpty else { throw CommandOutboxStorageError.unsafePath }
        let parent = fileURL.deletingLastPathComponent()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CommandOutboxStorageError.unsafePath }
        }
    }
    private func save(_ journal: Journal) throws {
        try validate(journal); try requirePath()
        let bytes = try PropertyListEncoder().encode(journal)
        guard bytes.count <= Self.maximumBytes else { throw CommandOutboxStorageError.tooLarge }
        // Follow the app's existing atomic outbox-file pattern. The caller's
        // dedicated sandbox directory is private; no shared temporary file.
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try requirePath()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw CommandOutboxStorageError.unsafePath }
        try bytes.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
