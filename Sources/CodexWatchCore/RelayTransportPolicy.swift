import Foundation

/// Ordinary watchOS apps may use HTTPS, but not low-level WebSocket networking.
/// Keep this decision in the transport layer so another caller cannot silently
/// reintroduce a simulator-only connection path on a physical Watch.
public enum RelayTransportPolicy {
    public enum Platform: Sendable {
        case watchOS, iOS, macOS
    }

    public static func supportsMailboxWebSocket(on platform: Platform) -> Bool {
        platform != .watchOS
    }

    public static var supportsMailboxWebSocket: Bool {
        #if os(watchOS)
        supportsMailboxWebSocket(on: .watchOS)
        #elseif os(iOS)
        supportsMailboxWebSocket(on: .iOS)
        #else
        supportsMailboxWebSocket(on: .macOS)
        #endif
    }

    /// Cancelling a refresh to change cadence is not a network failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    /// Bound the complete radio/connection wait, not just inactivity between
    /// bytes. Shared sessions do not let a caller configure this deadline.
    static func watchSessionConfiguration(timeout: TimeInterval, waitsForConnectivity: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.timeoutIntervalForRequest = max(1, timeout)
        configuration.timeoutIntervalForResource = max(1, timeout)
        return configuration
    }
}
