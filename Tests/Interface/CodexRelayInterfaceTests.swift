import XCTest
import XCUIAutomation

@MainActor
final class CodexRelayInterfaceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testOfflineSettingsNativeAutomationSmoke() throws {
        let app = try launchOffline("-PreviewSettings")
        defer { app.terminate() }
        let language = control(app, "settings.language")
        let appearance = control(app, "settings.appearance")
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Settings"].exists || app.navigationBars["Settings"].exists)
        capture(app, "QA-offline-settings-before-interaction")
        appearance.tap()
        capture(app, "QA-offline-appearance-picker")
        try choice(app, "Light")
    }

    func testAppearanceAndLanguageActuallyChangeOnTheMountedSettingsPage() throws {
        let app = try launchOffline("-PreviewSettings")
        defer { app.terminate() }
        let appearance = control(app, "settings.appearance")
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        appearance.tap()
        try choice(app, "Dark").tap()
        closeWatchPickerIfNeeded(app, root: appearance)
        assertSelection(appearance, contains: "Dark")
        capture(app, "QA-offline-settings-selected-dark")
        appearance.tap()
        try choice(app, "Light").tap()
        closeWatchPickerIfNeeded(app, root: appearance)
        assertSelection(appearance, contains: "Light")
        capture(app, "QA-offline-settings-selected-light")
        let language = control(app, "settings.language")
        language.tap()
        try choice(app, "简体中文").tap()
        closeWatchPickerIfNeeded(app, root: language)
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 5) || app.navigationBars["设置"].exists)
        capture(app, "QA-offline-settings-selected-Chinese")
        language.tap()
        try choice(app, "English").tap()
        closeWatchPickerIfNeeded(app, root: language)
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5) || app.navigationBars["Settings"].exists)
    }

    func testNativeComposerKeepsExactChineseAndEmojiWithoutSending() throws {
        let app = try launchOffline("-PreviewNewCodex")
        defer { app.terminate() }
        let input = control(app, "codex.messageInput")
        let send = control(app, "codex.send")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        #if os(watchOS)
        // Watch List virtualizes rows below the viewport; scroll the actual
        // list before asking whether its disabled Send row exists.
        for _ in 0..<4 where !send.exists { app.swipeUp() }
        #endif
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        input.tap()
        let original = "你是什么模型？🦦"
        #if os(watchOS)
        app.typeText(original)
        #else
        input.typeText(original)
        #endif
        #if os(watchOS)
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        else if app.buttons["完成"].firstMatch.exists { app.buttons["完成"].firstMatch.tap() }
        #endif
        let committed = NSPredicate(format: "value == %@", original)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: committed, object: input)], timeout: 10), .completed)
        let actual = try XCTUnwrap(input.value as? String)
        XCTAssertEqual(Array(actual.utf8), Array(original.utf8))
        capture(app, "QA-offline-native-input-Chinese-emoji-not-sent")
        // Deliberately no Send tap: this is a UI/keyboard test, not a cloud
        // conversation, execution, approval or real model-reply acceptance.
    }

    func testNewCodexModelAndReasoningChoicesAreIndependent() throws {
        let app = try launchOffline("-PreviewNewCodex")
        defer { app.terminate() }
        let model = control(app, "codex.model"), effort = control(app, "codex.effort")
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        model.tap()
        try choice(app, "GPT-5.6 Sol").tap()
        closeWatchPickerIfNeeded(app, root: model)
        assertSelection(model, contains: "GPT-5.6 Sol")
        XCTAssertTrue(effort.exists)
        effort.tap()
        try choice(app, "High").tap()
        closeWatchPickerIfNeeded(app, root: effort)
        assertSelection(effort, contains: "High")
        assertSelection(model, contains: "GPT-5.6 Sol")
        capture(app, "QA-offline-independent-model-and-effort")
    }

    func testTaskRowRightHandSideOpensTheOriginalTask() throws {
        let app = try launchOffline("-PreviewDashboard")
        defer { app.terminate() }
        capture(app, "QA-offline-dashboard-before-row-scroll")
        let row = control(app, "task.row.preview-recent")
        reveal(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        capture(app, "QA-offline-dashboard-before-row-tap")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "QA-offline-task-row-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(row.isHittable)
        // Exercise the right-hand area, not the old tiny leading status dot.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let input = control(app, "task.messageInput")
        reveal(input, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        capture(app, "QA-offline-whole-task-row-opens-detail")
    }

    func testDotComposerStaysCompactAndUsesNativeInputWithoutSending() throws {
        let app = try launchOffline("-PreviewDots")
        defer { app.terminate() }
        let input = control(app, "dot.messageInput"), send = control(app, "dot.send")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Offline preview must never send to the real dot")
        XCTAssertLessThan(input.frame.height, app.frame.height * 0.25)
        XCTAssertLessThan(send.frame.height, app.frame.height * 0.2)
        input.tap()
        let original = "同步测试🦦"
        #if os(watchOS)
        app.typeText(original)
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        else if app.buttons["完成"].firstMatch.exists { app.buttons["完成"].firstMatch.tap() }
        #else
        input.typeText(original)
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", original), object: input)], timeout: 10), .completed)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array(original.utf8))
        XCTAssertFalse(send.isEnabled)
        capture(app, "QA-offline-dot-compact-native-input-not-sent")
    }

    func testUnconfirmedNewCommandKeepsDraftAndRequiresExplicitLocalDiscard() throws {
        let app = try launchOffline("-PreviewNewCodex", unconfirmed: true)
        defer { app.terminate() }
        let input = control(app, "codex.messageInput"), send = control(app, "codex.send")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  原文水獭🦦  ".utf8))
        let check = control(app, "command.recovery.query"), discard = control(app, "command.recovery.discard")
        reveal(check, in: app)
        XCTAssertTrue(check.isHittable)
        XCTAssertGreaterThanOrEqual(check.frame.height, 44)
        check.tap() // offline guard: no relay request, execution or model call
        XCTAssertFalse(send.isEnabled)
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  原文水獭🦦  ".utf8))
        capture(app, "QA-offline-unconfirmed-draft-check-never-sends")
        reveal(discard, in: app)
        discard.tap()
        XCTAssertTrue(app.staticTexts["This only removes the local draft. It does not cancel a submitted action or send it again."].waitForExistence(timeout: 8))
        capture(app, "QA-offline-discard-alert-does-not-cancel-owner-action")
        let cancel = control(app, "command.recovery.cancel")
        if cancel.exists { cancel.tap() } else { app.buttons["Cancel"].firstMatch.tap() }
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  原文水獭🦦  ".utf8))
        reveal(discard, in: app)
        discard.tap()
        let confirm = control(app, "command.recovery.confirm")
        if confirm.exists { confirm.tap() }
        else {
            let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Discard local draft")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.identifier != "command.recovery.discard" }
            try XCTUnwrap(confirmations.last).tap()
        }
        XCTAssertFalse(check.exists)
        reveal(input, in: app)
        XCTAssertTrue(["", "Enter a message"].contains(try XCTUnwrap(input.value as? String)))
        XCTAssertFalse(send.isEnabled)
        capture(app, "QA-offline-explicit-local-draft-discard-no-cancellation")
    }

    func testExistingTaskRestoresUnconfirmedInputWithoutEnablingResend() throws {
        let app = try launchOffline("-PreviewTaskDetail", unconfirmed: true)
        defer { app.terminate() }
        let input = control(app, "task.messageInput"), send = control(app, "task.send")
        reveal(input, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  原文水獭🦦  ".utf8))
        let check = control(app, "command.recovery.query")
        reveal(check, in: app)
        XCTAssertTrue(check.isHittable)
        XCTAssertFalse(send.isEnabled)
        capture(app, "QA-offline-existing-task-unknown-input-is-not-resent")
    }

    func testMultipleStoppedActionsReviewOldestThenRevealNextWithoutReentering() throws {
        let app = try launchOffline("-PreviewNewCodex", unconfirmed: true, multiple: true)
        defer { app.terminate() }
        let input = control(app, "codex.messageInput"), send = control(app, "codex.send")
        for phrase in ["  原文水獭🦦  ", "  后续枫叶🍁  "] {
            reveal(input, in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array(phrase.utf8))
            reveal(send, in: app)
            XCTAssertTrue(send.exists)
            XCTAssertFalse(send.isEnabled)
            capture(app, "QA-offline-oldest-stopped-action-\(phrase.contains("水獭") ? "first" : "next")")
            let discard = control(app, "command.recovery.discard")
            reveal(discard, in: app)
            discard.tap()
            XCTAssertTrue(app.staticTexts["This only removes the local draft. It does not cancel a submitted action or send it again."].waitForExistence(timeout: 8))
            let confirm = control(app, "command.recovery.confirm")
            if confirm.exists { confirm.tap() }
            else {
                let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Discard local draft")).allElementsBoundByIndex
                    .filter { $0.isHittable && $0.identifier != "command.recovery.discard" }
                try XCTUnwrap(confirmations.last).tap()
            }
        }
        XCTAssertFalse(control(app, "command.recovery.query").exists)
        reveal(input, in: app)
        XCTAssertTrue(["", "Enter a message"].contains(try XCTUnwrap(input.value as? String)))
        reveal(send, in: app)
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
    }

    func testRealLocalQueueSurvivesFreshProcessesAndDiscardDoesNotResurrect() throws {
        let session = UUID(), expected = "  原文水獭🦦  "
        var app = try launchOffline("-PreviewNewCodex", unconfirmed: true, storageSession: session, seedStorage: true)
        var input = control(app, "codex.messageInput")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: input)], timeout: 10), .completed)
        app.terminate()

        // No seed/preview command on the second process. Only the isolated
        // per-test QA file can provide the original stopped command.
        app = try launchOffline("-PreviewNewCodex", storageSession: session)
        input = control(app, "codex.messageInput")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: input)], timeout: 10), .completed)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array(expected.utf8))
        capture(app, "QA-local-disk-restored-original-after-fresh-process")
        let send = control(app, "codex.send")
        reveal(send, in: app)
        XCTAssertTrue(send.exists); XCTAssertFalse(send.isEnabled)
        let discard = control(app, "command.recovery.discard")
        reveal(discard, in: app); discard.tap()
        XCTAssertTrue(app.staticTexts["This only removes the local draft. It does not cancel a submitted action or send it again."].waitForExistence(timeout: 8))
        let confirm = control(app, "command.recovery.confirm")
        if confirm.exists { confirm.tap() }
        else {
            let options = app.buttons.matching(NSPredicate(format: "label == %@", "Discard local draft")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.identifier != "command.recovery.discard" }
            try XCTUnwrap(options.last).tap()
        }
        app.terminate()

        // A third fresh process must keep the persisted empty queue empty.
        app = try launchOffline("-PreviewNewCodex", storageSession: session)
        defer { app.terminate() }
        input = control(app, "codex.messageInput")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertTrue(["", "Enter a message"].contains(try XCTUnwrap(input.value as? String)))
        XCTAssertFalse(control(app, "command.recovery.query").exists)
        reveal(control(app, "codex.send"), in: app)
        XCTAssertFalse(control(app, "codex.send").isEnabled)
        capture(app, "QA-local-disk-discard-stays-empty-after-third-process")
    }

    func testEditedDraftSurvivesIndependentReviewOfTwoOlderActions() throws {
        let app = try launchOffline("-PreviewNewCodex", unconfirmed: true, multiple: true, editedDraft: true)
        defer { app.terminate() }
        let input = control(app, "codex.messageInput"), send = control(app, "codex.send")
        for phrase in ["原文水獭🦦", "后续枫叶🍁"] {
            reveal(input, in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  新草稿海狸🦫  ".utf8))
            reveal(send, in: app); XCTAssertFalse(send.isEnabled)
            let open = control(app, "command.review.open")
            reveal(open, in: app); XCTAssertTrue(open.isHittable); open.tap()
            let original = control(app, "command.review.original")
            reveal(original, in: app)
            XCTAssertTrue(original.waitForExistence(timeout: 10))
            XCTAssertEqual(original.label.trimmingCharacters(in: .whitespacesAndNewlines), phrase)
            let check = control(app, "command.recovery.query")
            reveal(check, in: app); check.tap() // isolated preview, no transport
            capture(app, "QA-independent-review-original-not-current-composer")
            try discardReviewedOriginal(app)
            try closeOriginalReview(app)
        }
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  新草稿海狸🦫  ".utf8))
        reveal(send, in: app); XCTAssertTrue(send.isEnabled)
        capture(app, "QA-independent-review-kept-edited-draft-not-sent")
    }

    func testRejectedTaskDraftRemainsEditableWhileAnotherOriginalIsReviewed() throws {
        let app = try launchOffline("-PreviewTaskDetail", unconfirmed: true, rejectedDraft: true)
        defer { app.terminate() }
        let input = control(app, "task.messageInput"), send = control(app, "task.send")
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  被拒绝的草稿🦊  ".utf8))
        let open = control(app, "command.review.open")
        reveal(open, in: app); open.tap()
        try closeOriginalReview(app)
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  被拒绝的草稿🦊  ".utf8))
        reveal(send, in: app); XCTAssertFalse(send.isEnabled)
        reveal(open, in: app); open.tap()
        try discardReviewedOriginal(app)
        try closeOriginalReview(app)
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  被拒绝的草稿🦊  ".utf8))
        reveal(send, in: app); XCTAssertTrue(send.isEnabled)
        capture(app, "QA-independent-review-kept-rejected-task-draft-not-sent")
    }

    func testCorruptQAQueueIsBackedUpBeforeRepairAndTheEditedDraftIsPreserved() throws {
        let session = UUID()
        var app = try launchOffline("-PreviewNewCodex", storageSession: session, editedDraft: true, corruptStorage: true)
        let input = control(app, "codex.messageInput"), send = control(app, "codex.send")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  新草稿海狸🦫  ".utf8))
        reveal(send, in: app); XCTAssertFalse(send.isEnabled)
        let repair = control(app, "command.storage.repair")
        reveal(repair, in: app); XCTAssertTrue(repair.isHittable); repair.tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "label == %@",
            "The original file will be backed up first. Only recognizable records will be recovered; others stay in the backup. Submitted actions are not cancelled or sent again.")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        let confirm = control(app, "command.storage.repairConfirm")
        if confirm.exists { confirm.tap() } else { app.buttons["Back Up and Repair"].firstMatch.tap() }
        let result = control(app, "command.storage.repairResult")
        reveal(result, in: app); XCTAssertTrue(result.waitForExistence(timeout: 10))
        capture(app, "QA-corrupt-queue-backup-and-repair-result")
        reveal(input, in: app)
        XCTAssertEqual(Array(try XCTUnwrap(input.value as? String).utf8), Array("  新草稿海狸🦫  ".utf8))
        reveal(send, in: app); XCTAssertTrue(send.isEnabled)
        app.terminate()
        app = try launchOffline("-PreviewNewCodex", storageSession: session)
        defer { app.terminate() }
        let empty = control(app, "codex.messageInput")
        XCTAssertTrue(empty.waitForExistence(timeout: 15))
        XCTAssertTrue(["", "Enter a message"].contains(try XCTUnwrap(empty.value as? String)))
        XCTAssertFalse(control(app, "command.storage.repair").exists)
    }

    func testUnverifiableOriginalCannotQueryAnotherRecordButCanBeDiscardedLocally() throws {
        let app = try launchOffline("-PreviewNewCodex", unconfirmed: true, mismatchedOriginal: true)
        defer { app.terminate() }
        let open = control(app, "command.review.open")
        reveal(open, in: app); XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let query = control(app, "command.recovery.query")
        reveal(query, in: app)
        XCTAssertTrue(query.exists); XCTAssertFalse(query.isEnabled)
        XCTAssertFalse(control(app, "command.review.original").exists)
        capture(app, "QA-invalid-original-query-disabled-no-other-record-read")
        try discardReviewedOriginal(app)
        try closeOriginalReview(app)
        let input = control(app, "codex.messageInput")
        reveal(input, in: app)
        XCTAssertTrue(["", "Enter a message"].contains(try XCTUnwrap(input.value as? String)))
        XCTAssertFalse(control(app, "command.review.open").exists)
    }

    private func discardReviewedOriginal(_ app: XCUIApplication) throws {
        let discard = control(app, "command.recovery.discard")
        reveal(discard, in: app); discard.tap()
        XCTAssertTrue(app.staticTexts["This only removes the local draft. It does not cancel a submitted action or send it again."].waitForExistence(timeout: 10))
        let confirm = control(app, "command.recovery.confirm")
        if confirm.exists { confirm.tap() }
        else {
            let options = app.buttons.matching(NSPredicate(format: "label == %@", "Discard local draft")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.identifier != "command.recovery.discard" }
            try XCTUnwrap(options.last).tap()
        }
    }
    private func closeOriginalReview(_ app: XCUIApplication) throws {
        let close = control(app, "command.review.close")
        if close.waitForExistence(timeout: 5) { close.tap() }
        else { try choice(app, "Close").tap() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        #if os(watchOS)
        for step in 0..<40 {
            if element.exists, element.elementType == .textField { return }
            if element.exists, element.frame.minY >= 65, element.frame.maxY <= app.frame.maxY - 8, element.isHittable { return }
            let down = element.exists ? element.frame.midY < app.frame.midY : step >= 20
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.42 : 0.72))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.58 : 0.56)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        #else
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        #endif
    }

    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @discardableResult
    private func choice(_ app: XCUIApplication, _ title: String) throws -> XCUIElement {
        let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8), "Missing native choice: \(title)")
        return option
    }
    private func assertSelection(_ element: XCUIElement, contains value: String) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5), .completed)
    }
    private func closeWatchPickerIfNeeded(_ app: XCUIApplication, root: XCUIElement) {
        #if os(watchOS)
        if !root.isHittable {
            if app.buttons["Close"].firstMatch.exists { app.buttons["Close"].firstMatch.tap() }
            else if app.buttons["Dismiss"].firstMatch.exists { app.buttons["Dismiss"].firstMatch.tap() }
        }
        #endif
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func launchOffline(_ route: String, unconfirmed: Bool = false, multiple: Bool = false,
        storageSession: UUID? = nil, seedStorage: Bool = false, editedDraft: Bool = false,
        rejectedDraft: Bool = false, corruptStorage: Bool = false, mismatchedOriginal: Bool = false) throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        #if os(watchOS)
        let identifier = "com.sunzizai.codexwatch.relay.watchkitapp"
        let expectedSimulator = "37147111-8F9F-430E-92F1-E08D8CD8B617"
        #else
        let identifier = "com.sunzizai.codexwatch.relay"
        let expectedSimulator = "BF2EAE23-2D12-49FD-9CAE-990D87D818FE"
        #endif
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"]?.uppercased() == expectedSimulator else {
            XCTFail("Only the existing explicitly authorized QA simulator may run this test")
            throw NSError(domain: "CodexQA", code: 1)
        }
        guard ["-PreviewSettings", "-PreviewNewCodex", "-PreviewDashboard", "-PreviewDots", "-PreviewTaskDetail"].contains(route) else { throw NSError(domain: "CodexQA", code: 2) }
        let app = XCUIApplication(bundleIdentifier: identifier)
        app.launchArguments = ["-UIPreview", route, "-QAResetPreferences"]
        if unconfirmed { app.launchArguments.append("-PreviewUnconfirmedCommand") }
        if multiple { app.launchArguments.append("-PreviewMultipleUnconfirmedCommands") }
        if editedDraft { app.launchArguments.append("-PreviewEditedDraft") }
        if rejectedDraft { app.launchArguments.append("-PreviewRejectedDraft") }
        if mismatchedOriginal { app.launchArguments.append("-PreviewMismatchedOriginal") }
        if let storageSession {
            app.launchArguments += ["-CommandStorageQASession", storageSession.uuidString]
            if seedStorage { app.launchArguments.append("-SeedCommandStorageQA") }
            if corruptStorage { app.launchArguments.append("-SeedCorruptCommandStorageQA") }
        }
        app.launch()
        return app
        #else
        XCTFail("Physical-device UI acceptance is explicitly forbidden in this phase")
        throw NSError(domain: "CodexQA", code: 3)
        #endif
    }
}
