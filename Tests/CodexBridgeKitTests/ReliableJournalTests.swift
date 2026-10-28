import Foundation
import Testing
@testable import CodexBridgeKit

private func journalDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-journal-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Test func reliableActionReceiptSurvivesMacRestartAndRejectsChangedPayload() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    var first: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(first?.begin("one", fingerprint: "original") == .started)
    first?.finish("one", outcome: "reset confirmed")
    first = nil
    let restarted = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(restarted.begin("one", fingerprint: "original") == .completed(outcome: "reset confirmed"))
    guard case .failed = restarted.begin("one", fingerprint: "changed") else { Issue.record("Changed operation was replayed"); return }
}

@Test func crashAfterAdmissionDoesNotExecuteTheSameActionAgain() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    var original: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(original?.begin("uncertain", fingerprint: "payload") == .started)
    original = nil
    // Simulate a process dying after executing externally but before finish.
    var restarted: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    guard case .failed(let message) = restarted?.begin("uncertain", fingerprint: "payload") else {
        Issue.record("Uncertain execution must not restart"); return
    }
    #expect(!message.isEmpty)
    restarted = nil
    let again = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(again.begin("uncertain", fingerprint: "payload") == .failed(message: message))
}

@Test func persistentJournalRefusesCapacityPressureInsteadOfDroppingReceipts() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let journal = BridgeMessageDeduplicator(capacity: 1, persistenceURL: directory.appendingPathComponent("journal.json"))
    #expect(journal.begin("old") == .started); journal.finish("old")
    guard case .failed = journal.begin("new") else { Issue.record("Full journal must close admission"); return }
    #expect(journal.begin("old") == .completed(outcome: nil))
}

@Test func corruptOrUnwritableJournalCannotAdmitSideEffects() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let corrupt = directory.appendingPathComponent("bad.json")
    try Data("broken".utf8).write(to: corrupt)
    let corrupted = BridgeMessageDeduplicator(persistenceURL: corrupt)
    guard case .failed = corrupted.begin("one") else { Issue.record("Corruption allowed execution"); return }
    let blocked = BridgeMessageDeduplicator(persistenceURL: corrupt.appendingPathComponent("child.json"))
    guard case .failed = blocked.begin("two") else { Issue.record("Failed write allowed execution"); return }
}

@Test func reliableFailureAndCancellationRemainUncertainAcrossRestart() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    var journal: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(journal?.begin("failed") == .started); journal?.fail("failed", message: "timeout")
    #expect(journal?.begin("cancelled") == .started); journal?.cancel("cancelled")
    journal = nil
    let restarted = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(restarted.begin("failed") == .failed(message: "timeout"))
    guard case .failed = restarted.begin("cancelled") else { Issue.record("Cancellation restarted uncertain work"); return }
}

@Test func aSecondMacBridgeCannotRaceTheSamePersistentJournal() throws {
    let directory = try journalDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journal.json")
    var first: BridgeMessageDeduplicator? = BridgeMessageDeduplicator(persistenceURL: file)
    #expect(first?.begin("one") == .started)
    let duplicateProcess = BridgeMessageDeduplicator(persistenceURL: file)
    guard case .failed = duplicateProcess.begin("another") else { Issue.record("Second bridge raced the journal"); return }
    first = nil
    let recovered = BridgeMessageDeduplicator(persistenceURL: file)
    guard case .failed = recovered.begin("one") else { Issue.record("Unknown work restarted"); return }
    #expect(recovered.begin("fresh") == .started)
}
