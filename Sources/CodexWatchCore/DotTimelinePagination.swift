import Foundation

/// Tracks the gap between successive latest pages separately from the user's
/// older-history frontier. These cursors page our stored cloud timeline only.
struct DotTimelinePagination {
    private var latestIDs: Set<String> = []
    private var loadedLatest = false
    private var olderCursor: String?
    private var gapAnchorIDs: Set<String> = []
    private(set) var gapCursor: String?
    var nextCursor: String? { gapCursor ?? olderCursor }

    mutating func applyLatest(_ page: DotMessagePage) {
        let ids = Set(page.messages.map(\.id))
        if !loadedLatest || latestIDs.isEmpty {
            olderCursor = page.nextCursor
        } else if !ids.isEmpty && ids.isDisjoint(with: latestIDs) {
            // Keep the original anchor if another disconnected interval occurs
            // before the previous gap has been fully filled.
            if gapAnchorIDs.isEmpty { gapAnchorIDs = latestIDs }
            gapCursor = page.nextCursor
            if gapCursor == nil { gapAnchorIDs = []; olderCursor = nil }
        }
        if !ids.isEmpty { latestIDs = ids }
        loadedLatest = true
    }

    mutating func applyOlder(_ page: DotMessagePage, requestedCursor: String) throws {
        guard page.nextCursor != requestedCursor else { throw DotsError("invalid_response") }
        if requestedCursor == gapCursor {
            if page.nextCursor == nil || !Set(page.messages.map(\.id)).isDisjoint(with: gapAnchorIDs) {
                gapCursor = nil
                gapAnchorIDs = []
            } else { gapCursor = page.nextCursor }
        } else { olderCursor = page.nextCursor }
    }
}
