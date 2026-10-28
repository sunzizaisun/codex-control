#if os(macOS)
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
import CodexBridgeKit
@testable import CodexWatchCore

private let macRootQAOrigin = URL(string: "https://owner-qa.invalid")!
private struct MacOwnerQAFixture: Sendable {
    let id = UUID().uuidString
    let now = Date()
    let directory: URL
    var service: String { "qa.owner-root." + id }
    var roomID: String { "qa-root-" + id }
    var expiry: Int64 { get throws { try RelayEnrollmentInvitation.milliseconds(now) + 3_600_000 } }
    var store: RelayOwnerCredentialStore { .init(service: service) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-owner-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() {
        let prefix = "qa.owner-root."
        guard service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil else {
            Issue.record("unsafe root QA cleanup scope"); return
        }
        if let query = try? store.query(baseURL: macRootQAOrigin, roomID: roomID) {
            let status = SecItemDelete(query as CFDictionary)
            #expect(status == errSecSuccess || status == errSecItemNotFound)
        }
        try? FileManager.default.removeItem(at: directory)
    }
    func data() throws -> Data {
        var query = try store.query(baseURL: macRootQAOrigin, roomID: roomID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var raw: CFTypeRef?; try #require(SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess)
        return try #require(raw as? Data)
    }
    func countAndAttributes() throws -> [[String: Any]] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context
        var raw: CFTypeRef?; try #require(SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess)
        return try #require(raw as? [[String: Any]])
    }
}

@Test func macOwnerRootSetupSavesOneProtectedBundleAndPreservesExactOwnerKeyAndLifetime() throws {
    let f = try MacOwnerQAFixture(); defer { f.cleanup() }
    let journal = BridgeMessageDeduplicator(persistenceURL: f.directory.appendingPathComponent("receipts.json"))
    let setup = try RelayOwnerSetup(journal: journal, store: f.store), expiry = try f.expiry
    #expect(try setup.load(baseURL: macRootQAOrigin, roomID: f.roomID) == nil)
    let root = try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID, deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: f.now)
    let original = try f.data(), rebuilt = try RelayOwnerSetup(journal: journal, store: .init(service: f.service))
    let restored = try #require(try rebuilt.load(baseURL: macRootQAOrigin, roomID: f.roomID))
    #expect(try restored.storedData() == original)
    #expect(try rebuilt.serverRegistrationData(baseURL: macRootQAOrigin, roomID: f.roomID, now: f.now) == root.serverRegistrationData(now: f.now))
    #expect(restored.expiresAtMilliseconds == expiry && restored.publicKey == root.publicKey)
    let configuration = try rebuilt.configuration(baseURL: macRootQAOrigin, roomID: f.roomID,
        preparedPacketsURL: f.directory.appendingPathComponent("unused-outbox"), now: f.now)
    #expect(configuration.identity == configuration.owner && configuration.identity.role == .mac)
    let attributes = try f.countAndAttributes()
    #expect(attributes.count == 1)
    #expect(attributes.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(attributes.first?[kSecAttrSynchronizable as String] as? Bool == false)
    for (id, limit, key) in [("other-owner", expiry, nil as Data?), ("qa-owner", expiry + 1, nil), ("qa-owner", expiry, Data(repeating: 41, count: 32))] {
        #expect(throws: (any Error).self) { try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID,
            deviceID: id, expiresAtMilliseconds: limit, encryptionKey: key, now: f.now) }
        #expect(try f.data() == original)
    }
    #expect(throws: (any Error).self) { try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID,
        deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: root.expiresAt) }
    #expect(try f.data() == original)
}

@Test func macOwnerRootConcurrentBeginsShareOneSavedIdentityAndCompetingJournalCannotProvision() async throws {
    let f = try MacOwnerQAFixture(); defer { f.cleanup() }
    let file = f.directory.appendingPathComponent("receipts.json"), expiry = try f.expiry
    let journal = BridgeMessageDeduplicator(persistenceURL: file), setup = try RelayOwnerSetup(journal: journal, store: f.store)
    let documents = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<16 { group.addTask {
            let root = try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID, deviceID: "qa-owner",
                expiresAtMilliseconds: expiry, now: f.now)
            return try root.serverRegistrationData(now: f.now)
        } }
        var values: [Data] = []; for try await value in group { values.append(value) }; return values
    }
    #expect(Set(documents).count == 1)
    #expect(try f.countAndAttributes().count == 1)
    let original = try f.data(), duplicate = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(throws: (any Error).self) { try RelayOwnerSetup(journal: duplicate, store: f.store) }
    #expect(try f.data() == original)
}

@Test func macOwnerRootCorruptionUnknownFieldsAndMissingRecoveryNeverOverwriteOrCreateCredentials() throws {
    let f = try MacOwnerQAFixture(); defer { f.cleanup() }
    let journal = BridgeMessageDeduplicator(persistenceURL: f.directory.appendingPathComponent("receipts.json"))
    let setup = try RelayOwnerSetup(journal: journal, store: f.store), expiry = try f.expiry
    _ = try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID, deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: f.now)
    var object = try JSONSerialization.jsonObject(with: f.data()) as! [String: Any]
    object["unknownPrivateMember"] = "do-not-ignore"
    let key = try f.store.query(baseURL: macRootQAOrigin, roomID: f.roomID)
    for bytes in [try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), Data("damaged".utf8)] {
        #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: bytes] as CFDictionary) == errSecSuccess)
        #expect(throws: (any Error).self) { try setup.load(baseURL: macRootQAOrigin, roomID: f.roomID) }
        #expect(throws: (any Error).self) { try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID,
            deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: f.now) }
        #expect(try f.data() == bytes)
    }
    #expect(SecItemDelete(key as CFDictionary) == errSecSuccess)
    #expect(try setup.load(baseURL: macRootQAOrigin, roomID: f.roomID) == nil)
    #expect(throws: (any Error).self) { try setup.serverRegistrationData(baseURL: macRootQAOrigin, roomID: f.roomID, now: f.now) }
    #expect(throws: (any Error).self) { try setup.configuration(baseURL: macRootQAOrigin, roomID: f.roomID,
        preparedPacketsURL: f.directory.appendingPathComponent("unused-outbox"), now: f.now) }
    #expect(try f.store.load(baseURL: macRootQAOrigin, roomID: f.roomID) == nil)
}

@Test func macOwnerRootSetupLosingJournalAuthorityStopsBeforeChangingSavedCredentials() throws {
    let f = try MacOwnerQAFixture(); defer { f.cleanup() }
    let file = f.directory.appendingPathComponent("receipts.json"), lock = file.appendingPathExtension("lock"), expiry = try f.expiry
    let journal = BridgeMessageDeduplicator(persistenceURL: file), setup = try RelayOwnerSetup(journal: journal, store: f.store)
    _ = try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID, deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: f.now)
    let original = try f.data()
    try FileManager.default.removeItem(at: lock)
    try Data("new-inode".utf8).write(to: lock)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
    #expect(throws: (any Error).self) { try setup.begin(baseURL: macRootQAOrigin, roomID: f.roomID,
        deviceID: "qa-owner", expiresAtMilliseconds: expiry, now: f.now) }
    #expect(throws: (any Error).self) { try setup.load(baseURL: macRootQAOrigin, roomID: f.roomID) }
    #expect(throws: (any Error).self) { try setup.serverRegistrationData(baseURL: macRootQAOrigin, roomID: f.roomID, now: f.now) }
    #expect(try f.data() == original)
}

private struct MacOwnerRestartMetadata: Codable {
    let version: Int; let runID: String; let expiresAt: Int64; let publicDigest: String; let probe: Data
    let createdByProcess: Int32
    let continuedByProcess: Int32?
}

// The documented xctestrun EnvironmentVariables field supplies ONE public UUID
// and phases1/2/3. Metadata is restricted to this QA app's own container and
// contains only a public-registry hash and synthetic encrypted probe, not keys.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_OWNER_QA_RESTART_PHASE"] != nil))
func macOwnerRootSurvivesActualHostTerminationAndRetainsPublicContextAndEncryption() throws {
    let environment = ProcessInfo.processInfo.environment
    let runID = try #require(environment["CODEX_OWNER_QA_RESTART_ID"])
    try #require(UUID(uuidString: runID) != nil)
    let phase = try #require(environment["CODEX_OWNER_QA_RESTART_PHASE"])
    try #require(["1", "2", "3"].contains(phase))
    let service = "qa.owner-root-restart." + runID, roomID = "qa-root-restart-" + runID
    let store = RelayOwnerCredentialStore(service: service)
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OwnerCredentialRestartQA", isDirectory: true)
    let metadataURL = directory.appendingPathComponent(runID + ".json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let journal = BridgeMessageDeduplicator(persistenceURL: directory.appendingPathComponent(runID + "-receipts.json"))
    let setup = try RelayOwnerSetup(journal: journal, store: store)
    let plaintext = Data(("QA owner restart " + runID).utf8)
    if phase == "1" {
        try #require(!FileManager.default.fileExists(atPath: metadataURL.path))
        try #require(try setup.load(baseURL: macRootQAOrigin, roomID: roomID) == nil)
        let expiry = try RelayEnrollmentInvitation.milliseconds(Date()) + 3_600_000
        let root = try setup.begin(baseURL: macRootQAOrigin, roomID: roomID, deviceID: "qa-restart-owner", expiresAtMilliseconds: expiry)
        let document = try root.serverRegistrationData()
        let cipher = try #require(try AES.GCM.seal(plaintext, using: SymmetricKey(data: root.encryptionKey)).combined)
        let metadata = MacOwnerRestartMetadata(version: 1, runID: runID, expiresAt: expiry,
            publicDigest: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: document))), probe: cipher,
            createdByProcess: ProcessInfo.processInfo.processIdentifier, continuedByProcess: nil)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        return // intentionally retain this exact synthetic item for process2
    }
    let bytes = try Data(contentsOf: metadataURL); try #require(bytes.count <= 4_096)
    let metadata = try JSONDecoder().decode(MacOwnerRestartMetadata.self, from: bytes)
    try #require(metadata.version == 1 && metadata.runID == runID)
    try #require(ProcessInfo.processInfo.processIdentifier != metadata.createdByProcess)
    let root = try #require(try setup.load(baseURL: macRootQAOrigin, roomID: roomID))
    #expect(root.expiresAtMilliseconds == metadata.expiresAt)
    #expect(try RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: root.serverRegistrationData()))) == metadata.publicDigest)
    #expect(try AES.GCM.open(AES.GCM.SealedBox(combined: metadata.probe), using: SymmetricKey(data: root.encryptionKey)) == plaintext)
    if phase == "2" {
        let same = try setup.begin(baseURL: macRootQAOrigin, roomID: roomID, deviceID: "qa-restart-owner", expiresAtMilliseconds: metadata.expiresAt)
        #expect(try same.storedData() == root.storedData())
        let continuation = MacOwnerRestartMetadata(version: metadata.version, runID: metadata.runID,
            expiresAt: metadata.expiresAt, publicDigest: metadata.publicDigest, probe: metadata.probe,
            createdByProcess: metadata.createdByProcess, continuedByProcess: ProcessInfo.processInfo.processIdentifier)
        try JSONEncoder().encode(continuation).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        return // process3 must still see the original key/token/lifetime
    }
    let continuedByProcess = try #require(metadata.continuedByProcess)
    try #require(ProcessInfo.processInfo.processIdentifier != continuedByProcess)
    #expect(throws: (any Error).self) { try setup.begin(baseURL: macRootQAOrigin, roomID: roomID,
        deviceID: "qa-restart-owner", expiresAtMilliseconds: metadata.expiresAt + 1) }
    #expect(throws: (any Error).self) { try root.serverRegistrationData(now: root.expiresAt) }
    let key = try store.query(baseURL: macRootQAOrigin, roomID: roomID)
    #expect(SecItemDelete(key as CFDictionary) == errSecSuccess)
    #expect(try setup.load(baseURL: macRootQAOrigin, roomID: roomID) == nil)
    #expect(throws: (any Error).self) { try setup.serverRegistrationData(baseURL: macRootQAOrigin, roomID: roomID) }
    #expect(try store.load(baseURL: macRootQAOrigin, roomID: roomID) == nil)
    try FileManager.default.removeItem(at: metadataURL)
    // Do not unlink an active lease. Its exact QA lock file is harmless and
    // remains in this app's container; release occurs when the host exits.
}
#endif
