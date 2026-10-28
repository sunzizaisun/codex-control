import Foundation

/// WatchConnectivity reply blocks may be invoked from a background queue.
/// Keep that API block outside actor isolation and let a deadline race a
/// network response without ever invoking the same reply twice.
public final class RelayDataReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?

    public init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        lock.lock()
        let callback = handler
        handler = nil
        lock.unlock()
        guard let callback else { return false }
        callback(data)
        return true
    }
}
