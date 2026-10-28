import Foundation

public enum UsagePresentation {
    /// Unknown is not exhausted. A real zero-percent window still shows 0%.
    public static func remainingText(_ window: UsageWindow?) -> String {
        guard let window, window.usedPercent.isFinite else { return "—" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    public static func remainingFraction(_ window: UsageWindow?) -> Double {
        guard let window, window.usedPercent.isFinite else { return 0 }
        return window.remainingPercent / 100
    }
}
