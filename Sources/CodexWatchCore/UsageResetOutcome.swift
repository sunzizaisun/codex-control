import Foundation

/// Exact outcomes from the installed app-server schema. An ACK without one
/// cannot prove that a reset was redeemed; never default a missing result to
/// `reset` or infer consumption from a disappearing card.
public enum UsageResetOutcome: String, Codable, CaseIterable, Sendable {
    case reset, nothingToReset, noCredit, alreadyRedeemed
    public var confirmsConsumption: Bool { self == .reset || self == .alreadyRedeemed }
    public static func confirmedResponse(_ raw: String?) -> String {
        guard let raw, let outcome = Self(rawValue: raw) else {
            return AppLocalizer.text("上次操作结果未确认，请先检查原任务。")
        }
        return outcome.rawValue
    }
}
