import Testing
@testable import CodexWatchCore

@Test func resetReceiptRequiresAnExactKnownServerOutcome() {
    for raw in [nil, "", "success", "RESET", " reset", "reset "] as [String?] {
        #expect(UsageResetOutcome.confirmedResponse(raw) != "reset")
        #expect(raw.flatMap(UsageResetOutcome.init(rawValue:)) == nil)
    }
    for outcome in UsageResetOutcome.allCases {
        #expect(UsageResetOutcome.confirmedResponse(outcome.rawValue) == outcome.rawValue)
        #expect(outcome.confirmsConsumption == [.reset, .alreadyRedeemed].contains(outcome))
    }
}
