import Foundation
import Testing
@testable import CodexWatchCore

@Test func pairingClockStartsOnceAndStopsWhenItsLastSurfaceCloses() {
    var visibility = PairingVisibility()
    let id = UUID()
    #expect(!visibility.shouldTick)
    let first = visibility.setVisible(true, observerID: id)
    let duplicate = visibility.setVisible(true, observerID: id)
    #expect(first)
    #expect(!duplicate)
    #expect(visibility.shouldTick)
    let last = visibility.setVisible(false, observerID: id)
    let duplicateClose = visibility.setVisible(false, observerID: id)
    #expect(last)
    #expect(!duplicateClose)
    #expect(!visibility.shouldTick)
}

@Test func closingOneMacPanelCannotStopAnotherVisiblePairingPanel() {
    var visibility = PairingVisibility()
    let window = UUID(), menu = UUID()
    visibility.setVisible(true, observerID: window)
    let second = visibility.setVisible(true, observerID: menu)
    let closeWindow = visibility.setVisible(false, observerID: window)
    #expect(!second)
    #expect(!closeWindow)
    #expect(visibility.shouldTick)
    let closeMenu = visibility.setVisible(false, observerID: menu)
    #expect(closeMenu)
    #expect(!visibility.shouldTick)
}

@Test func anUnknownDisappearCannotStopTheClockAndReopeningRestartsIt() {
    var visibility = PairingVisibility()
    let id = UUID()
    visibility.setVisible(true, observerID: id)
    let unrelated = visibility.setVisible(false, observerID: UUID())
    #expect(!unrelated)
    #expect(visibility.shouldTick)
    visibility.setVisible(false, observerID: id)
    let reopened = visibility.setVisible(true, observerID: id)
    #expect(reopened)
    #expect(visibility.shouldTick)
}
