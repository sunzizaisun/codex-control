import Foundation

/// Do not scroll on heartbeat, receipt changes, or loading older pages.
/// Follow newly appended replies only if the reader is already near the end.
public struct DotChatScrollState {
    private var lastID: String?
    private var followRequested = false
    public init() {}
    public var hasAnchoredContent: Bool { lastID != nil }
    public mutating func requestFollowNextAppend() { followRequested = true }
    public mutating func cancelFollowRequest() { followRequested = false }
    static func isNearBottom(bottomY: CGFloat, viewportHeight: CGFloat) -> Bool {
        bottomY.isFinite && bottomY < viewportHeight + 65
    }
    public mutating func update(ids: [String], nearBottom: Bool, initialLoadComplete: Bool = true) -> Bool {
        // Restoring a completed import can publish an older batch before the
        // latest timeline GET returns. Do not consume the first-load anchor.
        guard initialLoadComplete else { return false }
        let next = ids.last
        defer { lastID = next }
        guard next != nil && next != lastID else { return false }
        let follow = lastID == nil || nearBottom || followRequested
        if follow { followRequested = false }
        return follow
    }
}
