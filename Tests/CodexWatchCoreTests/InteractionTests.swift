import Foundation
import SwiftUI
import Testing
@testable import CodexWatchCore

@Test func questionsDecodeOptionalFlagsAndRetainExactLabels() throws {
    let params: JSONValue = .object(["questions": .array([.object([
        "id": .string("where"), "header": .string("位置"), "question": .string("选择哪一个？"),
        "options": .array([.object(["label": .string("加拿大🙂"), "description": .string("描述")])])
    ])])])
    let q = try UserInputValidation.questions(from: params)
    #expect(!q[0].isOther && !q[0].isSecret)
    try UserInputValidation.validate(["where": ["加拿大🙂"]], questions: q)
    #expect(throws: (any Error).self) { try UserInputValidation.validate(["where": ["Canada"]], questions: q) }
    #expect(throws: (any Error).self) { try UserInputValidation.validate(["other": ["加拿大🙂"]], questions: q) }
    #expect(throws: (any Error).self) { try UserInputValidation.validate(["where": []], questions: q) }
}
@Test func questionsAllowTypedOtherButNeverMissingOrExtraAnswers() throws {
    let q = [UserInputQuestion(id: "a", header: "", question: "One?", options: [.init(label: "A", description: "")], isOther: true),
             UserInputQuestion(id: "b", header: "", question: "Two?", isSecret: true)]
    try UserInputValidation.validate(["a": ["我的答案🙂"], "b": ["exact"]], questions: q)
    for answers in [["a": ["typed"]], ["a": ["typed"], "b": [" "]], ["a": ["typed"], "b": ["ok"], "extra": ["no"]]] {
        #expect(throws: (any Error).self) { try UserInputValidation.validate(answers, questions: q) }
    }
}
@Test func selectingAnOptionClearsAnEarlierTypedAnswer() throws {
    let questions = [UserInputQuestion(id: "route", header: "", question: "Which?",
        options: [.init(label: "保留设计🙂", description: "")], isOther: true)]
    var draft = UserInputFormState()
    draft.type("原先的自由回答", for: "route")
    draft.select("保留设计🙂", for: "route")
    #expect(draft.typed["route"] == nil)
    #expect(draft.selected["route"] == "保留设计🙂")
    #expect(draft.answers(for: questions) == ["route": ["保留设计🙂"]])
    try UserInputValidation.validate(draft.answers(for: questions), questions: questions)
}
@Test func typingAnAnswerClearsOnlyThatQuestionsOptionWithoutRewritingText() throws {
    let questions = [UserInputQuestion(id: "route", header: "", question: "Which?", isOther: true),
        UserInputQuestion(id: "scope", header: "", question: "Scope?", options: [.init(label: "Only this", description: "")])]
    var draft = UserInputFormState()
    #expect(draft.selected.isEmpty && draft.typed.isEmpty)
    #expect(throws: (any Error).self) { try UserInputValidation.validate(draft.answers(for: questions), questions: questions) }
    draft.select("First", for: "route")
    draft.select("Only this", for: "scope")
    draft.type("中文跟进🙂\nKeep punctuation.", for: "route")
    #expect(draft.selected["route"] == nil)
    #expect(draft.selected["scope"] == "Only this")
    #expect(draft.answers(for: questions) == ["route": ["中文跟进🙂\nKeep punctuation."], "scope": ["Only this"]])
    try UserInputValidation.validate(draft.answers(for: questions), questions: questions)
}
@Test func dotChatDoesNotJumpWhenReadingHistoryOrRefreshingReceipts() {
    var state = DotChatScrollState()
    let empty = state.update(ids: [], nearBottom: true)
    let first = state.update(ids: ["a", "b"], nearBottom: false)
    let unchanged = state.update(ids: ["a", "b"], nearBottom: true)
    let older = state.update(ids: ["older", "a", "b"], nearBottom: true)
    let reading = state.update(ids: ["older", "a", "b", "c"], nearBottom: false)
    let following = state.update(ids: ["older", "a", "b", "c", "d"], nearBottom: true)
    #expect([empty, first, unchanged, older, reading, following] == [false, true, false, false, false, true])
}
@Test func dotChatFollowsDelayedInitialHistoryButNotSubsequentHeartbeats() {
    var state = DotChatScrollState()
    let initial = state.update(ids: [], nearBottom: false)
    let stillLoading = state.update(ids: [], nearBottom: false)
    let loaded = state.update(ids: ["old-user", "old-reply", "latest-user", "latest-reply"], nearBottom: false)
    let heartbeat = state.update(ids: ["old-user", "old-reply", "latest-user", "latest-reply"], nearBottom: true)
    let olderPage = state.update(ids: ["older-page", "old-user", "old-reply", "latest-user", "latest-reply"], nearBottom: false)
    #expect([initial, stillLoading, loaded, heartbeat, olderPage] == [false, false, true, false, false])
}
@Test func absentLazyBottomMeasurementNeverMeansReaderIsAtBottom() {
    #expect(!DotChatScrollState.isNearBottom(bottomY: .infinity, viewportHeight: 300))
    #expect(!DotChatScrollState.isNearBottom(bottomY: .nan, viewportHeight: 300))
    #expect(!DotChatScrollState.isNearBottom(bottomY: 700, viewportHeight: 300))
    #expect(DotChatScrollState.isNearBottom(bottomY: 320, viewportHeight: 300))
}
@Test func dotChatRestoredBatchDoesNotConsumeInitialLatestTimelineAnchor() {
    var state = DotChatScrollState()
    let restored = state.update(ids: ["old-user", "old-reply"], nearBottom: false, initialLoadComplete: false)
    let loading = state.update(ids: ["old-user", "old-reply", "new-user", "new-reply"], nearBottom: false, initialLoadComplete: false)
    let ready = state.update(ids: ["old-user", "old-reply", "new-user", "new-reply"], nearBottom: false, initialLoadComplete: true)
    let same = state.update(ids: ["old-user", "old-reply", "new-user", "new-reply"], nearBottom: true)
    #expect([restored, loading, ready, same] == [false, false, true, false])
}
@Test func dotChatExplicitSendFollowsOnceEvenWhenPendingWasNotRendered() {
    var state = DotChatScrollState()
    let initial = state.update(ids: ["old"], nearBottom: false)
    state.requestFollowNextAppend()
    let older = state.update(ids: ["older", "old"], nearBottom: false)
    let own = state.update(ids: ["older", "old", "own-new"], nearBottom: false)
    let reading = state.update(ids: ["older", "old", "own-new", "another-turn"], nearBottom: false)
    #expect([initial, older, own, reading] == [true, false, true, false])
}
@Test func dotChatRejectedSendDoesNotPullReaderAwayFromHistory() {
    var state = DotChatScrollState()
    let initial = state.update(ids: ["old"], nearBottom: false)
    state.requestFollowNextAppend()
    state.cancelFollowRequest()
    let reading = state.update(ids: ["old", "other-reply"], nearBottom: false)
    #expect(initial && !reading)
}
@Test func interactionCopyCoversEverySupportedLanguage() {
    for language in AppLanguage.allCases where language != .system {
        for key in InteractionTranslations.keys {
            #expect(InteractionTranslations.text(key, language: language)?.isEmpty == false)
            if language == .english { #expect(!AppLocalizer.text(key, language: language).contains("等待")) }
        }
    }
}
@Test func watchQuestionNavigationTitleUsesCompactLocalizedCopy() {
    #expect(AppLocalizer.text("回答", language: .english) == "Answer")
    for language in AppLanguage.allCases where language != .system {
        let title = AppLocalizer.text("回答", language: language)
        #expect(!title.isEmpty && title.unicodeScalars.count < 14)
    }
}
@Test func appChromeUsesTheCurrentStoredLanguageRatherThanOldLocalizedStrings() {
    let keys = ["设置", "语言", "外观", "跟随系统", "浅色", "深色"]
    let english = ["Settings", "Language", "Appearance", "Follow System", "Light", "Dark"]
    for raw in ["simplifiedChinese", "english", "simplifiedChinese", "english"] {
        let language = AppLanguage(rawValue: raw) ?? .system
        #expect(keys.map { AppLocalizer.text($0, language: language) } == (language == .english ? english : keys))
    }
}
@Test func returningFromArabicToSystemRestoresTheUpstreamLayoutDirection() {
    #expect(AppLanguage.arabic.layoutDirection(following: .leftToRight) == .rightToLeft)
    #expect(AppLanguage.system.layoutDirection(following: .leftToRight) == .leftToRight)
    #expect(AppLanguage.system.layoutDirection(following: .rightToLeft) == .rightToLeft)
    for language in AppLanguage.allCases where language != .system && language != .arabic {
        #expect(language.layoutDirection(following: .rightToLeft) == .leftToRight)
    }
}
@Test func questionAnswerSurvivesEncryptedRelayEnvelopeCoding() throws {
    let decision = ApprovalDecision(requestID: "q1", requestDigest: "bound", choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: "nonce", origin: .watch, answers: ["language": ["中文🙂"]])
    let envelope = BridgeEnvelope.decision(decision, sender: "watch", replyMailbox: "watch")
    let decoded = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: CodexWatchCoding.makeEncoder().encode(envelope))
    #expect(decoded.decision?.answers == ["language": ["中文🙂"]])
    #expect(decoded.replyMailbox == "watch")
}

@Test func failedNotificationSubmissionKeepsTheOriginalPendingQuestionReachable() throws {
    let request = try #require(DashboardSnapshot.uiPreview(questions: true).pendingApprovals.first)
    #expect(InteractionDestination.resolve(requestID: request.id, pending: [request], receipt: .failed("Offline")) == .request(request))
    #expect(InteractionDestination.resolve(requestID: request.id, pending: [request], receipt: nil) == .request(request))
    #expect(InteractionDestination.resolve(requestID: "unrelated", pending: [request], receipt: nil) == .unavailable)
}
@Test func confirmedOrExpiredNotificationDoesNotOfferAnotherDecision() throws {
    let request = try #require(DashboardSnapshot.uiPreview(questions: true).pendingApprovals.first)
    #expect(InteractionDestination.resolve(requestID: request.id, pending: [request], receipt: .accepted) == .receipt(.accepted))
    #expect(InteractionDestination.resolve(requestID: request.id, pending: [request], receipt: nil, now: request.expiresAt) == .unavailable)
    #expect(InteractionDestination.resolve(requestID: request.id, pending: [], receipt: .failed("Not confirmed")) == .receipt(.failed("Not confirmed")))
}

@Test func missingPhoneApprovalCacheIsNeverConfirmationFromMac() throws {
    let request = try #require(DashboardSnapshot.uiPreview().pendingApprovals.first)
    let decision = ApprovalDecision(requestID: request.id, requestDigest: request.requestDigest, choice: .allowOnce,
        decidedAt: Date(), deviceID: "watch", nonce: request.nonce, origin: .watch)
    #expect(try ApprovalReviewValidation.forwardingAction(decision: decision, cached: nil, macConfirmed: false) == .forwardToMac)
    #expect(try ApprovalReviewValidation.forwardingAction(decision: decision, cached: nil, macConfirmed: true) == .replayConfirmed)
    #expect(try ApprovalReviewValidation.forwardingAction(decision: decision, cached: request, macConfirmed: false) == .forwardToMac)
    #expect(throws: ApprovalReviewValidation.Failure.expired) {
        try ApprovalReviewValidation.forwardingAction(decision: decision, cached: request, macConfirmed: false, now: request.expiresAt)
    }
}
