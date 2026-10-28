import Foundation
import Testing
@testable import CodexBridgeKit

private func ownerLeaseQADirectory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("owner-lease-qa-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
    return value
}

@Test func ownerLeaseBorrowingRequiresAHealthyCloseOnExecDurableJournal() throws {
    let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let journal = BridgeMessageDeduplicator(persistenceURL: directory.appendingPathComponent("receipts.json"))
    #expect(try journal.withExclusiveDurableOwnerLease { 42 } == 42)
    #expect(journal.begin("qa", fingerprint: "value") == .started)
    #expect(journal.finish("qa"))
}

@Test func ownerSetupRejectsPreviewAndCompetingOwnersBeforeAnyCredentialStoreAccess() throws {
    #expect(throws: (any Error).self) { try RelayOwnerSetup(journal: BridgeMessageDeduplicator()) }
    let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("receipts.json")
    let owner = BridgeMessageDeduplicator(persistenceURL: file)
    _ = try RelayOwnerSetup(journal: owner)
    let competing = BridgeMessageDeduplicator(persistenceURL: file)
    var accessed = false
    #expect(throws: (any Error).self) { try competing.withExclusiveDurableOwnerLease { accessed = true } }
    #expect(!accessed)
    #expect(throws: (any Error).self) { try RelayOwnerSetup(journal: competing) }
}

@Test func ownerSetupRetainsTheOriginalLeaseRatherThanCreatingAnotherOwnerLock() throws {
    let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("receipts.json")
    var journal: BridgeMessageDeduplicator? = .init(persistenceURL: file)
    var setup: RelayOwnerSetup? = try .init(journal: journal!)
    journal = nil
    #expect(setup != nil)
    let blocked = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(throws: (any Error).self) { try blocked.withExclusiveDurableOwnerLease {} }
    setup = nil
    let next = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(try next.withExclusiveDurableOwnerLease { true })
}

@Test func ownerSetupCannotBorrowCorruptJournalAuthority() throws {
    let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("receipts.json")
    try Data("not a journal".utf8).write(to: file)
    let journal = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(throws: (any Error).self) { try RelayOwnerSetup(journal: journal) }
    #expect(try Data(contentsOf: file) == Data("not a journal".utf8))
}

@Test func replacedOwnerLockClosesAdmissionAndStatusWithoutRepairingThePath() throws {
    let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("receipts.json"), lock = file.appendingPathExtension("lock")
    let journal = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(journal.begin("original", fingerprint: "input") == .started)
    try FileManager.default.removeItem(at: lock)
    try Data("replacement".utf8).write(to: lock)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
    #expect(throws: (any Error).self) { try journal.withExclusiveDurableOwnerLease {} }
    guard case .failed = journal.begin("new", fingerprint: "input") else { Issue.record("lost lease admitted action"); return }
    #expect(journal.inspect("original", fingerprint: "input").state == .unavailable)
    #expect(try Data(contentsOf: lock) == Data("replacement".utf8))
}

@Test func insecureOrMultiplyLinkedOwnerLeaseIsNotAutomaticallyReenabled() throws {
    for hardLink in [false, true] {
        let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json"), lock = file.appendingPathExtension("lock")
        let journal = BridgeMessageDeduplicator(persistenceURL: file)
        #expect(try journal.withExclusiveDurableOwnerLease { true })
        if hardLink { try FileManager.default.linkItem(at: lock, to: directory.appendingPathComponent("extra-link")) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path) }
        #expect(throws: (any Error).self) { try journal.withExclusiveDurableOwnerLease {} }
        if hardLink { try FileManager.default.removeItem(at: directory.appendingPathComponent("extra-link")) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }
        #expect(throws: (any Error).self) { try journal.withExclusiveDurableOwnerLease {} }
    }
}

@Test func lostOwnerLeaseCannotReplayACompletedReceiptOrBeginUncertainRecovery() throws {
    for completed in [true, false] {
        let directory = try ownerLeaseQADirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json"), lease = file.appendingPathExtension("lock")
        let journal = BridgeMessageDeduplicator(persistenceURL: file)
        #expect(journal.begin("original", fingerprint: "input") == .started)
        if completed { #expect(journal.finish("original", outcome: "accepted")) }
        else { journal.markUnconfirmed("original") }
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: lease)
        try Data("replacement".utf8).write(to: lease)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.path)
        if completed {
            guard case .failed = journal.begin("original", fingerprint: "input") else {
                Issue.record("unowned journal replayed a completed result"); continue
            }
        } else {
            #expect(journal.claimRecovery("original", fingerprint: "input") == nil)
        }
        #expect(try Data(contentsOf: file) == original)
    }
}
