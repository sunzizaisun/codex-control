import Foundation
import Testing
@testable import CodexWatchCore

private func recoveryInput(now: Date = Date(timeIntervalSince1970: 1_000_000), prompt: String = "  e\u{301}水獭🦦  ") throws -> (BridgeEnvelope, Data) {
    let envelope = BridgeEnvelope(sentAt: now, kind: .taskCommand, senderDeviceID: "watch",
        taskCommand: .init(taskID: "original-owner", prompt: prompt, sentAt: now, deviceID: "watch"))
    return (envelope, try CodexWatchCoding.makeEncoder().encode(envelope))
}

@Test func missingReceiptRestoresExactDraftAndAcceptanceIsMonotonic() throws {
    let (original, data) = try recoveryInput()
    var draft = MessageDraft()
    let restored = draft.restore(.init(messageID: original.messageID, originalData: data))
    #expect(restored)
    #expect(draft.isUnconfirmed && draft.submissionID == original.messageID)
    #expect(draft.text.utf8.elementsEqual(original.taskCommand!.prompt.utf8))
    draft.apply(.unconfirmed("still unknown"))
    #expect(draft.submissionID == original.messageID)
    draft.apply(.accepted)
    #expect(draft.text.isEmpty && draft.submissionID == nil && !draft.isUnconfirmed)
    var receipts = CommandReceipts()
    receipts.record(.accepted, for: original.messageID)
    receipts.record(.unconfirmed("late timeout"), for: original.messageID)
    #expect(receipts.result(for: original.messageID) == .accepted)
}

@Test func restoreDoesNotOverwriteAnEditedDraftAndCorruptRecordsAreDiscardable() throws {
    let (original, data) = try recoveryInput()
    var draft = MessageDraft(); draft.text = "new unsent text"
    let overwrote = draft.restore(.init(messageID: original.messageID, originalData: data))
    #expect(!overwrote)
    #expect(draft.text == "new unsent text" && draft.submissionID == nil)
    draft.text = ""
    let recoveredCorrupt = draft.restore(.init(messageID: "corrupt-original", originalData: Data("bad".utf8)))
    #expect(recoveredCorrupt)
    #expect(draft.submissionID == "corrupt-original" && draft.isUnconfirmed)
    draft.discardLocalSubmission()
    #expect(draft.text.isEmpty && draft.submissionID == nil && !draft.isUnconfirmed)
    draft.restore(.init(messageID: original.messageID, originalData: data, taskID: "other-task"))
    #expect(draft.text.isEmpty && draft.isUnconfirmed)
}

@Test func acknowledgementWindowStopsReplayWithoutChangingOriginalDataOrLifetime() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (_, data) = try recoveryInput(now: now)
    #expect(!CommandRecovery.shouldPause(data, now: now.addingTimeInterval(89.999)))
    #expect(CommandRecovery.shouldPause(data, now: now.addingTimeInterval(90)))
    #expect(CommandRecovery.shouldPause(data, now: now.addingTimeInterval(24 * 3600)))
    #expect(CommandRecovery.shouldPause(Data()))
    #expect(CommandRecovery.original(data)?.deliveryExpiresAt == now.addingTimeInterval(24 * 3600))
}

@Test func readOnlyQueryRejectsUncorrelatedWrongOwnerOrOrdinarySnapshots() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (original, data) = try recoveryInput(now: now)
    var tracker = CommandStatusQueries()
    let pendingQuery = tracker.begin(originalData: data, replyMailbox: "watch", now: now)
    let query = try #require(pendingQuery)
    #expect(query.kind == .requestSnapshot && query.taskCommand == nil)
    #expect(query.commandStatusQuery?.originalEnvelope == data)
    #expect(tracker.begin(originalData: data, replyMailbox: "watch", now: now) == nil)
    let ordinary = BridgeEnvelope(kind: .snapshot, senderDeviceID: "mac", snapshot: .empty)
    #expect(tracker.receive(ordinary, now: now) == nil)
    var response = BridgeEnvelope(kind: .snapshot, senderDeviceID: "mac", acknowledgedMessageID: "wrong-query",
        commandStatusReceipt: .init(originalMessageID: original.messageID, state: .accepted, ownerThreadID: "original-owner"))
    #expect(tracker.receive(response, now: now) == nil)
    response.acknowledgedMessageID = query.messageID
    response.commandStatusReceipt = .init(originalMessageID: original.messageID, state: .accepted, ownerThreadID: "other-owner")
    #expect(tracker.receive(response, now: now) == nil)
    response.commandStatusReceipt = .init(originalMessageID: original.messageID, state: .accepted, ownerThreadID: "original-owner")
    #expect(tracker.receive(response, now: now)?.receipt == .accepted)
    #expect(tracker.checkingIDs.isEmpty)
    #expect(tracker.receive(response, now: now) == nil)
}

@Test func everyNonAcceptanceStatusKeepsAnUncertainOriginalUnlessRejectionIsProven() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (original, data) = try recoveryInput(now: now)
    for status in [CommandStatusReceipt.State.notFound, .unavailable, .unconfirmed, .inFlight, .rejected] {
        var tracker = CommandStatusQueries()
        let pendingQuery = tracker.begin(originalData: data, replyMailbox: "phone", now: now)
        let query = try #require(pendingQuery)
        let response = BridgeEnvelope(kind: .snapshot, senderDeviceID: "mac", acknowledgedMessageID: query.messageID,
            commandStatusReceipt: .init(originalMessageID: original.messageID, state: status, message: "reason"))
        let resolution = tracker.receive(response, now: now)
        let result = try #require(resolution)
        #expect(result.originalMessageID == original.messageID)
        var draft = MessageDraft(); draft.restore(.init(messageID: original.messageID, originalData: data)); draft.apply(result.receipt)
        #expect(draft.text.utf8.elementsEqual(original.taskCommand!.prompt.utf8))
        #expect(draft.isUnconfirmed == (status != .rejected))
        #expect((draft.submissionID == original.messageID) == (status != .rejected))
    }
}

@Test func timeoutAndRelauchNeverRestoreAnOldQueryOrAllowStaleAcceptance() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (original, data) = try recoveryInput(now: now)
    var tracker = CommandStatusQueries()
    let pendingQuery = tracker.begin(originalData: data, replyMailbox: "watch", now: now)
    let query = try #require(pendingQuery)
    let response = BridgeEnvelope(kind: .snapshot, senderDeviceID: "mac", acknowledgedMessageID: query.messageID,
        commandStatusReceipt: .init(originalMessageID: original.messageID, state: .accepted))
    #expect(tracker.receive(response, now: now.addingTimeInterval(61)) == nil)
    #expect(tracker.expire(query.messageID, now: now.addingTimeInterval(61)) == original.messageID)
    #expect(tracker.checkingIDs.isEmpty)
    tracker = CommandStatusQueries()
    #expect(tracker.receive(response, now: now) == nil)
    #expect(tracker.begin(originalData: data, replyMailbox: "watch", now: now)?.messageID != query.messageID)
}

@Test func legacyAndMalformedErrorRepliesCannotProveNonDelivery() throws {
    let (original, data) = try recoveryInput()
    var error = BridgeEnvelope(kind: .error, senderDeviceID: "mac", acknowledgedMessageID: original.messageID, message: "error")
    guard case .unconfirmed = CommandRecovery.errorReceipt(error, originalData: data) else { Issue.record("Legacy error was treated as definitive"); return }
    error.commandStatusReceipt = .init(originalMessageID: original.messageID, state: .rejected, message: "invalid input")
    #expect(CommandRecovery.errorReceipt(error, originalData: data) == .failed("invalid input"))
    error.commandStatusReceipt = .init(originalMessageID: "other", state: .rejected)
    guard case .unconfirmed = CommandRecovery.errorReceipt(error, originalData: data) else { Issue.record("Wrong ID rejected a different command"); return }
}

@Test func querySizeAndForeignBrowserCommandsNeverFallbackToExecutableSend() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let (_, data) = try recoveryInput(now: now, prompt: String(repeating: "a", count: 33_000))
    #expect(CommandRecovery.original(data) != nil)
    var tracker = CommandStatusQueries()
    #expect(tracker.begin(originalData: data, replyMailbox: "watch", now: now) == nil)
    var (original, _) = try recoveryInput(now: now)
    original.senderDeviceID = "other"
    #expect(CommandRecovery.original(try CodexWatchCoding.makeEncoder().encode(original)) == nil)
    #expect(tracker.checkingIDs.isEmpty)
}

@Test func commandRecoveryChromeHasAllSupportedLanguageTranslations() {
    for language in AppLanguage.allCases where language != .system {
        for key in CommandRecoveryTranslations.keys {
            let text = CommandRecoveryTranslations.text(key, language: language)
            #expect(text?.isEmpty == false)
            #expect(AppLocalizer.text(key, language: language) == text)
            if language != .simplifiedChinese { #expect(text != key) }
        }
    }
}

@Test func readOnlyRecoveryRoundTripsEncryptedPacketsForPhoneAndWatch() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (original, data) = try recoveryInput(now: now)
    let credentials = try RelayCredentials.migrating(secret: String(repeating: "recovery-fixture-only-", count: 4), roomID: "qa-recovery")
    let cipher = RelayPacketCipher(roomID: "qa-recovery", credentials: credentials)
    for mailbox in ["phone", "watch"] {
        var tracker = CommandStatusQueries()
        let pendingQuery = tracker.begin(originalData: data, replyMailbox: mailbox, now: now)
        let query = try #require(pendingQuery)
        let packet = try cipher.seal(query, destination: "mac")
        let received = try cipher.open(packet, destination: "mac")
        #expect(received.kind == .requestSnapshot && received.taskCommand == nil)
        #expect(received.commandStatusQuery?.validatedOriginal(for: received, now: now) == original)
        let response = BridgeEnvelope(sentAt: now, kind: .snapshot, senderDeviceID: "fixture-mac",
            acknowledgedMessageID: received.messageID,
            commandStatusReceipt: .init(originalMessageID: original.messageID, state: .accepted, ownerThreadID: "original-owner"))
        let answer = try cipher.open(cipher.seal(response, destination: mailbox), destination: mailbox)
        #expect(tracker.receive(answer, now: now)?.receipt == .accepted)
    }
}

@Test func phoneTracksOnlyTheExactKnownWatchQueryAndSharesItsAcceptedResult() throws {
    let now = Date(timeIntervalSince1970: 1_000_000), (original, data) = try recoveryInput(now: now)
    var watch = CommandStatusQueries(), phone = CommandStatusQueries()
    let pending = watch.begin(originalData: data, replyMailbox: "watch", now: now)
    let query = try #require(pending)
    let wrongOriginal = phone.trackForwarded(query, expectedOriginalData: Data("other".utf8), now: now)
    #expect(!wrongOriginal && phone.checkingIDs.isEmpty)
    let forwarded = phone.trackForwarded(query, expectedOriginalData: data, now: now)
    #expect(forwarded && phone.checkingIDs == [original.messageID])
    let again = phone.trackForwarded(query, expectedOriginalData: data, now: now)
    #expect(!again)
    let result = BridgeEnvelope(sentAt: now, kind: .snapshot, senderDeviceID: "mac", acknowledgedMessageID: query.messageID,
        commandStatusReceipt: .init(originalMessageID: original.messageID, state: .accepted, ownerThreadID: "original-owner"))
    #expect(phone.receive(result, now: now)?.receipt == .accepted)
    #expect(watch.receive(result, now: now)?.receipt == .accepted)
    #expect(phone.checkingIDs.isEmpty && watch.checkingIDs.isEmpty)
}

@Test func phoneShadowDraftDoesNotVetoANewExplicitWatchAction() {
    #expect(CommandRecovery.requiresLocalReview(senderDeviceID: "phone", localDeviceID: "phone", hasStoppedTask: true))
    #expect(!CommandRecovery.requiresLocalReview(senderDeviceID: "watch", localDeviceID: "phone", hasStoppedTask: true))
    #expect(!CommandRecovery.requiresLocalReview(senderDeviceID: "phone", localDeviceID: "phone", hasStoppedTask: false))
}

@Test func stoppedActionsUseOriginalSubmissionOrderAndKeepCorruptEntriesVisible() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var (older, _) = try recoveryInput(now: now)
    var (newer, _) = try recoveryInput(now: now.addingTimeInterval(30))
    older.messageID = "z-older"; newer.messageID = "a-newer"
    let first = RecoverableCommandDraft(messageID: older.messageID, originalData: try CodexWatchCoding.makeEncoder().encode(older))
    let second = RecoverableCommandDraft(messageID: newer.messageID, originalData: try CodexWatchCoding.makeEncoder().encode(newer))
    #expect(CommandRecovery.earliest([second, first]) == first)
    #expect(CommandRecovery.earliest([first, second]) == first)
    #expect(CommandRecovery.earliest([second]) == second)
    #expect(CommandRecovery.earliest([]) == nil)
    let corrupt = RecoverableCommandDraft(messageID: "corrupt", originalData: Data())
    #expect(CommandRecovery.earliest([first, corrupt, second]) == corrupt)
}

@Test func recoveryNoticeCanChangeLanguageWithoutRewritingErrorOrUserText() throws {
    let (original, bytes) = try recoveryInput()
    var draft = MessageDraft()
    draft.restore(.init(messageID: original.messageID, originalData: bytes))
    let stored = draft.errorMessage, text = Array(draft.text.utf8)
    for language in AppLanguage.allCases where language != .system {
        #expect(draft.displayedError(language: language) == AppLocalizer.text("上次操作结果未确认，请先检查原任务。", language: language))
    }
    #expect(draft.errorMessage == stored && Array(draft.text.utf8) == text)
    draft.apply(.failed("owner supplied error: 水獭🦦"))
    #expect(draft.displayedError(language: .arabic) == "owner supplied error: 水獭🦦")
    #expect(draft.text.utf8.elementsEqual(original.taskCommand!.prompt.utf8))
}

@Test func reviewingConsecutiveStoppedActionsNeverOverwritesAnEditedDraft() throws {
    let (first, bytes) = try recoveryInput()
    let (second, nextBytes) = try recoveryInput(now: first.sentAt.addingTimeInterval(10), prompt: "  后续枫叶🍁  ")
    let next = RecoverableCommandDraft(messageID: second.messageID, originalData: nextBytes)
    var draft = MessageDraft()
    draft.restore(.init(messageID: first.messageID, originalData: bytes))
    draft.discardLocalSubmission()
    let handover = draft.restore(next)
    #expect(handover && draft.submissionID == second.messageID && draft.text == "  后续枫叶🍁  ")
    draft.text = "new unsent draft"
    draft.apply(.accepted)
    let overwritten = draft.restore(.init(messageID: first.messageID, originalData: bytes))
    #expect(!overwritten && draft.text == "new unsent draft" && draft.submissionID == nil)
}

@Test func discardingOnlyThePendingOriginalKeepsAnEditedComposer() throws {
    let (original, data) = try recoveryInput()
    var draft = MessageDraft(); draft.restore(.init(messageID: original.messageID, originalData: data))
    #expect(!draft.needsSeparateReview(.init(messageID: original.messageID, originalData: data)))
    draft.text = "  新草稿海狸🦫  "
    #expect(draft.needsSeparateReview(.init(messageID: original.messageID, originalData: data)))
    draft.discardPendingOriginal()
    #expect(draft.text.utf8.elementsEqual("  新草稿海狸🦫  ".utf8))
    #expect(draft.submissionID == nil && !draft.isUnconfirmed)
    draft.submitted("second"); draft.discardPendingOriginal()
    #expect(draft.text.isEmpty)
}

@Test func independentReviewExposesOnlyAVerifiedOriginalAndNeverMutatesTheComposer() throws {
    let (original, data) = try recoveryInput()
    let saved = RecoverableCommandDraft(messageID: original.messageID, originalData: data, taskID: "original-owner")
    #expect(saved.verifiedPrompt?.utf8.elementsEqual(original.taskCommand!.prompt.utf8) == true)
    #expect(RecoverableCommandDraft(messageID: "wrong", originalData: data).verifiedPrompt == nil)
    #expect(RecoverableCommandDraft(messageID: original.messageID, originalData: data, taskID: "other-owner").verifiedPrompt == nil)
    var draft = MessageDraft(); draft.text = "a failed command draft"; draft.submitted("rejected"); draft.apply(.failed("Rejected"))
    let before = draft
    let review = CommandReviewState(receipt: .unconfirmed("Unknown"), isPending: true, isChecking: false)
    #expect(review.isPending && saved.id == original.messageID && draft == before)
}
