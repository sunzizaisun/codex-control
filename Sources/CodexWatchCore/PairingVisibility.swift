import Foundation

/// The window, menu-bar panel and pairing sheet may coexist. Tick the code
/// only while at least one visible pairing surface actually needs it.
public struct PairingVisibility: Sendable {
    private var observers: Set<UUID> = []
    public init() {}
    public var shouldTick: Bool { !observers.isEmpty }

    /// Returns true only when the shared timer should start or stop.
    @discardableResult
    public mutating func setVisible(_ visible: Bool, observerID: UUID) -> Bool {
        let previous = shouldTick
        if visible { observers.insert(observerID) }
        else { observers.remove(observerID) }
        return previous != shouldTick
    }
}
