import Testing
@testable import CodexWatchCore

@Test func lateErrorsCannotRevokeAnAcceptedCommandReceipt() {
    var receipts = CommandReceipts()
    receipts.record(.accepted, for: "original")
    receipts.record(.failed("late other-route timeout"), for: "original")
    #expect(receipts.result(for: "original") == .accepted)
    receipts.record(.failed("unconfirmed"), for: "other")
    receipts.record(.accepted, for: "other")
    #expect(receipts.result(for: "other") == .accepted)
}

@Test func aNormalizedButByteChangedDraftIsNotErasedByTheOldAcceptance() {
    var draft = MessageDraft()
    draft.text = "e\u{301}🦦"
    draft.submitted("original")
    draft.text = "é🦦"
    draft.apply(.accepted)
    #expect(draft.text.utf8.elementsEqual("é🦦".utf8))
    #expect(draft.submissionID == nil)
    draft.submitted("next")
    draft.apply(.accepted)
    #expect(draft.text.isEmpty)
}
