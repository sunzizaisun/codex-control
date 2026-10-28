import XCTest
@testable import CodexWatchCore

#if os(iOS)
private typealias TestedRelayController = PhoneRelayController
#elseif os(watchOS)
private typealias TestedRelayController = WatchRelayController
#endif

@MainActor
final class ControllerCommandDeliveryTests: XCTestCase {
    private var environment: ControllerCommandFaultEnvironment!
    private var controller: TestedRelayController!

    private func prepare() throws {
        continueAfterFailure = false
        #if os(iOS)
        let expected = "BF2EAE23-2D12-49FD-9CAE-990D87D818FE"
        #else
        let expected = "37147111-8F9F-430E-92F1-E08D8CD8B617"
        #endif
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"]?.uppercased() == expected else {
            throw XCTSkip("Only the fixed existing QA simulator is authorized")
        }
        environment = try .init()
        ControllerCommandFaultEnvironment.current = environment
        controller = .init()
        XCTAssertTrue(controller.commandStorageAvailable)
    }

    private func cleanup() {
        XCTAssertEqual(environment?.fixture.errors() ?? [], [])
        controller = nil
        ControllerCommandFaultEnvironment.current = nil
        ControllerURLProtocol.registry.reset()
        environment = nil
        // Keep small UUID-scoped synthetic files for independent inspection.
    }

    func testQueueHTTPAcceptancePreservesExactDurableOriginalButIsNotMacAcceptance() async throws {
        try prepare(); defer { cleanup() }
        let prompt = "  cafe\u{0301} 水獭-627🦦\n中文与空格  "
        let id = try XCTUnwrap(controller.startCodexChat(prompt))
        try await waitForPosts(1)
        let post = try XCTUnwrap(environment.fixture.posted().first)
        XCTAssertEqual(post.envelope.messageID, id)
        XCTAssertEqual(Array(try XCTUnwrap(post.envelope.taskCommand?.prompt).utf8), Array(prompt.utf8))
        XCTAssertTrue(post.durableBeforeSend)
        XCTAssertNil(controller.commandReceipts.result(for: id))
        XCTAssertEqual(controller.faultCommandRecords.map(\.messageID), [id])
        XCTAssertTrue(environment.fixture.paths().allSatisfy { $0.contains("/mailbox/mac") })
    }

    func testStorageFailureBeforeAdmissionCannotReachHTTP() async throws {
        try prepare(); defer { cleanup() }
        let preserved = try obstructStoreDirectory()
        let id = try XCTUnwrap(controller.startCodexChat("保存失败🦦"))
        await settle()
        XCTAssertFalse(controller.commandStorageAvailable)
        XCTAssertEqual(environment.fixture.posted().count, 0)
        XCTAssertEqual(controller.faultCommandRecords.first?.messageID, id)
        XCTAssertEqual(controller.faultCommandRecords.first?.stopped, true)
        assertUnconfirmed(id)
        try restoreStoreDirectory(preserved)
        controller.retryCommandStorage()
        controller.faultFlush()
        await settle()
        XCTAssertTrue(controller.commandStorageAvailable)
        XCTAssertEqual(environment.fixture.posted().count, 0)
        XCTAssertEqual(try environment.store.load().first?.messageID, id)
    }

    func testStorageFailureAfterSchedulingAlsoVetoesTheEarlierEnqueue() async throws {
        try prepare(); defer { cleanup() }
        let first = try XCTUnwrap(controller.startCodexChat("第一条尚未进入传输🦦"))
        // Do not yield MainActor: its actual scheduled delivery task has not
        // run yet. A second real admission now encounters an IO failure.
        let preserved = try obstructStoreDirectory()
        let second = try XCTUnwrap(controller.startCodexChat("第二条保存失败🍁"))
        XCTAssertNotEqual(first, second)
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 0)
        XCTAssertEqual(Set(controller.faultCommandRecords.map(\.messageID)), Set([first, second]))
        XCTAssertTrue(controller.faultCommandRecords.allSatisfy { $0.stopped == true })
        try restoreStoreDirectory(preserved)
        controller.retryCommandStorage()
        controller.faultFlush()
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 0)
        XCTAssertEqual(try environment.store.load().count, 2)
    }

    func testRetryableHTTPFailureReusesTheExactPacketAndNeverClaimsOwnerAcceptance() async throws {
        try prepare(); defer { cleanup() }
        environment.fixture.failNextPosts(1)
        let id = try XCTUnwrap(controller.startCodexChat("原始重试编号🍁"))
        try await waitForPosts(2)
        let posts = environment.fixture.posted()
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.envelope.messageID == id && $0.durableBeforeSend })
        XCTAssertEqual(posts[0].body, posts[1].body)
        XCTAssertNil(controller.commandReceipts.result(for: id))
        XCTAssertEqual(controller.faultCommandRecords.count, 1)
    }

    func testExhaustedHTTPAttemptsRemainUnconfirmedAndPauseWithoutANewPost() async throws {
        try prepare(); defer { cleanup() }
        environment.fixture.failNextPosts(2)
        let id = try XCTUnwrap(controller.startCodexChat("中继暂时不可用🦦"))
        try await waitForPosts(2)
        await settle()
        let sentAt = try original(id).sentAt
        controller.faultPrune(now: sentAt.addingTimeInterval(91))
        controller.faultFlush()
        await settle()
        assertUnconfirmed(id)
        XCTAssertEqual(controller.faultCommandRecords.first?.stopped, true)
        XCTAssertEqual(environment.fixture.posted().count, 2)
    }

    func testDroppedAckAcrossReconstructionNeverAutomaticallyRepostsOriginal() async throws {
        try prepare(); defer { cleanup() }
        let id = try XCTUnwrap(controller.startCodexChat("重建控制器不能复发🦦"))
        try await waitForPosts(1)
        await settle()
        controller = .init()
        XCTAssertEqual(controller.faultCommandRecords.first?.messageID, id)
        XCTAssertEqual(controller.faultCommandRecords.first?.stopped, true)
        assertUnconfirmed(id)
        controller.faultFlush()
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 1)
        XCTAssertNil(controller.startCodexChat("不能替换待确认原稿"))
        XCTAssertEqual(environment.fixture.posted().count, 1)
    }

    func testLateAndDuplicateAckRetireOnlyTheOriginalAndDoNotDowngradeANewerCommand() async throws {
        try prepare(); defer { cleanup() }
        let first = try XCTUnwrap(controller.startCodexChat("等待迟到回执🍁"))
        try await waitForPosts(1)
        controller.faultPrune(now: try original(first).sentAt.addingTimeInterval(91))
        assertUnconfirmed(first)
        let ack = BridgeEnvelope.acknowledgement(for: first, sender: "synthetic-qa-owner")
        environment.fixture.deliver(ack)
        await controller.faultRefresh()
        XCTAssertEqual(controller.commandReceipts.result(for: first), .accepted)
        XCTAssertTrue(controller.faultCommandRecords.isEmpty)
        XCTAssertTrue(try environment.store.load().isEmpty)
        let second = try XCTUnwrap(controller.startCodexChat("新的原稿仍待确认🦦"))
        try await waitForPosts(2)
        controller.faultReceive(ack)
        controller.faultReceive(.acknowledgement(for: first, sender: "synthetic-qa-owner"))
        controller.faultReceive(.init(kind: .error, senderDeviceID: "synthetic-qa-owner",
            acknowledgedMessageID: first, message: "unrelated late failure"))
        XCTAssertEqual(controller.commandReceipts.result(for: first), .accepted)
        XCTAssertNil(controller.commandReceipts.result(for: second))
        XCTAssertEqual(controller.faultCommandRecords.map(\.messageID), [second])
        XCTAssertEqual(environment.fixture.posted().filter { $0.envelope.taskCommand != nil }.count, 2)
    }

    func testUntypedFailureStopsButCannotFalselyRejectOrEnableAReplacement() async throws {
        try prepare(); defer { cleanup() }
        let id = try XCTUnwrap(controller.startCodexChat("旧服务器错误不能当作拒绝🍁"))
        try await waitForPosts(1)
        controller.faultReceive(.init(kind: .error, senderDeviceID: "synthetic-qa-owner",
            acknowledgedMessageID: id, message: "arbitrary server text"))
        assertUnconfirmed(id)
        XCTAssertEqual(controller.faultCommandRecords.first?.stopped, true)
        XCTAssertNil(controller.startCodexChat("不应被送出"))
        controller.faultFlush()
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 1)
    }

    func testTypedRejectionIsDefiniteAndDoesNotChangeTaskToCompleted() async throws {
        try prepare(); defer { cleanup() }
        let task = try XCTUnwrap(controller.snapshot.tasks.first)
        let before = task.state
        let id = try XCTUnwrap(controller.sendCommand("明确拒绝的跟进🦦", to: task))
        try await waitForPosts(1)
        controller.faultReceive(.init(kind: .error, senderDeviceID: "synthetic-qa-owner",
            acknowledgedMessageID: id, message: "rejected",
            commandStatusReceipt: .init(originalMessageID: id, state: .rejected,
                ownerThreadID: task.id, message: "rejected")))
        XCTAssertEqual(controller.commandReceipts.result(for: id), .failed("rejected"))
        XCTAssertTrue(controller.faultCommandRecords.isEmpty)
        XCTAssertEqual(controller.task(id: task.id)?.state, before)
        XCTAssertTrue(try environment.store.load().isEmpty)
    }

    func testReadOnlyRecoveryIgnoresWrongOwnerAndAcceptsOnlyTheCorrelatedOriginal() async throws {
        try prepare(); defer { cleanup() }
        let task = try XCTUnwrap(controller.snapshot.tasks.first)
        let id = try XCTUnwrap(controller.sendCommand("只查原任务🦦", to: task))
        try await waitForPosts(1)
        controller.faultPrune(now: try original(id).sentAt.addingTimeInterval(91))
        controller.checkCommandStatus(id)
        try await waitForPosts(2)
        let query = try XCTUnwrap(environment.fixture.posted().last?.envelope)
        XCTAssertEqual(query.kind, .requestSnapshot)
        XCTAssertNil(query.taskCommand)
        XCTAssertEqual(query.commandStatusQuery?.originalEnvelope, controller.faultCommandRecords.first?.envelopeData)
        environment.fixture.deliver(.init(kind: .snapshot, senderDeviceID: "synthetic-qa-owner",
            acknowledgedMessageID: query.messageID,
            commandStatusReceipt: .init(originalMessageID: id, state: .accepted, ownerThreadID: "wrong-owner")))
        await controller.faultRefresh()
        assertUnconfirmed(id)
        XCTAssertTrue(controller.checkingCommandIDs.contains(id))
        environment.fixture.deliver(.init(kind: .snapshot, senderDeviceID: "synthetic-qa-owner",
            acknowledgedMessageID: query.messageID,
            commandStatusReceipt: .init(originalMessageID: id, state: .accepted, ownerThreadID: task.id)))
        await controller.faultRefresh()
        XCTAssertEqual(controller.commandReceipts.result(for: id), .accepted)
        XCTAssertTrue(controller.faultCommandRecords.isEmpty)
        XCTAssertTrue(controller.checkingCommandIDs.isEmpty)
        XCTAssertEqual(environment.fixture.posted().filter { $0.envelope.taskCommand != nil }.count, 1)
    }

    func testDiscardSaveFailureKeepsTheOriginalAndCannotReenableDelivery() async throws {
        try prepare(); defer { cleanup() }
        let id = try XCTUnwrap(controller.startCodexChat("丢弃必须先落盘🦦"))
        try await waitForPosts(1)
        await settle()
        controller.faultPrune(now: try original(id).sentAt.addingTimeInterval(91))
        let preserved = try obstructStoreDirectory()
        XCTAssertFalse(controller.discardUnconfirmedCommand(id))
        XCTAssertEqual(controller.faultCommandRecords.first?.messageID, id)
        controller.faultFlush()
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 1)
        try restoreStoreDirectory(preserved)
        controller.retryCommandStorage()
        XCTAssertTrue(controller.discardUnconfirmedCommand(id))
        XCTAssertTrue(try environment.store.load().isEmpty)
    }

    func testAckRemovalSaveFailureBlocksNewSendingAndRestartRestoresStoppedNotReplay() async throws {
        try prepare(); defer { cleanup() }
        let id = try XCTUnwrap(controller.startCodexChat("接受回执时存储失败🍁"))
        try await waitForPosts(1)
        await settle()
        let preserved = try obstructStoreDirectory()
        controller.faultReceive(.acknowledgement(for: id, sender: "synthetic-qa-owner"))
        XCTAssertEqual(controller.commandReceipts.result(for: id), .accepted)
        XCTAssertFalse(controller.commandStorageAvailable)
        XCTAssertNil(controller.startCodexChat("存储未恢复不能发"))
        try restoreStoreDirectory(preserved)
        controller = .init()
        XCTAssertEqual(controller.faultCommandRecords.first?.messageID, id)
        XCTAssertEqual(controller.faultCommandRecords.first?.stopped, true)
        controller.faultFlush()
        await settle()
        XCTAssertEqual(environment.fixture.posted().count, 1)
    }

    #if os(watchOS)
    func testWatchForegroundReentryDoesNotReplayAPausedCommand() async throws {
        try prepare(); defer { cleanup() }
        let id = try XCTUnwrap(controller.startCodexChat("重新抬腕不复发🦦"))
        try await waitForPosts(1)
        controller.faultPrune(now: try original(id).sentAt.addingTimeInterval(91))
        controller.setForegroundActive(false)
        controller.setForegroundActive(true)
        await settle()
        assertUnconfirmed(id)
        XCTAssertEqual(environment.fixture.posted().count, 1)
    }
    #endif

    private func original(_ id: String) throws -> BridgeEnvelope {
        let record = try XCTUnwrap(controller.faultCommandRecords.first { $0.messageID == id })
        return try XCTUnwrap(CommandRecovery.original(record.envelopeData))
    }
    private func assertUnconfirmed(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unconfirmed = controller.commandReceipts.result(for: id) else {
            XCTFail("Expected unconfirmed original, not success/rejection", file: file, line: line); return
        }
    }
    private func waitForPosts(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while environment.fixture.posted().count < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(environment.fixture.posted().count, count)
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
    private func obstructStoreDirectory() throws -> URL {
        let directory = environment.store.fileURL.deletingLastPathComponent()
        let preserved = environment.root.appendingPathComponent("preserved-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: preserved)
        try Data("synthetic IO obstruction".utf8).write(to: directory)
        return preserved
    }
    private func restoreStoreDirectory(_ preserved: URL) throws {
        let directory = environment.store.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: directory), Data("synthetic IO obstruction".utf8))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: preserved, to: directory)
    }
}
