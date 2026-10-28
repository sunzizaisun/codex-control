#if os(macOS)
import Foundation
import CodexWatchCore

/// Normal owner setup must borrow the SAME durable journal lease used by
/// action ingress, not acquire a parallel "owner" lock. This strong reference
/// keeps that existing lease alive. Synchronous Keychain work only: no await,
/// network, server root registration or installed/default activation here.
public struct RelayOwnerSetup: Sendable {
    private let journal: BridgeMessageDeduplicator
    private let store: RelayOwnerCredentialStore
    public init(journal: BridgeMessageDeduplicator, store: RelayOwnerCredentialStore = .init()) throws {
        try journal.withExclusiveDurableOwnerLease {}
        self.journal = journal; self.store = store
    }
    public func load(baseURL: URL, roomID: String) throws -> RelayOwnerCredentials? {
        try journal.withExclusiveDurableOwnerLease { try store.load(baseURL: baseURL, roomID: roomID) }
    }
    public func begin(baseURL: URL, roomID: String, deviceID: String, expiresAtMilliseconds: Int64,
                      encryptionKey: Data? = nil, now: Date = Date()) throws -> RelayOwnerCredentials {
        try journal.withExclusiveDurableOwnerLease {
            try store.begin(baseURL: baseURL, roomID: roomID, deviceID: deviceID, expiresAtMilliseconds: expiresAtMilliseconds,
                encryptionKey: encryptionKey, now: now)
        }
    }
    public func serverRegistrationData(baseURL: URL, roomID: String, now: Date = Date()) throws -> Data {
        try journal.withExclusiveDurableOwnerLease {
            guard let credentials = try store.load(baseURL: baseURL, roomID: roomID) else { throw RelayOwnerCredentialError.missingOrExpired }
            return try credentials.serverRegistrationData(now: now)
        }
    }
    public func configuration(baseURL: URL, roomID: String, preparedPacketsURL: URL, now: Date = Date()) throws -> RelayDeviceConfiguration {
        try journal.withExclusiveDurableOwnerLease {
            guard let credentials = try store.load(baseURL: baseURL, roomID: roomID) else { throw RelayOwnerCredentialError.missingOrExpired }
            return try credentials.configuration(preparedPacketsURL: preparedPacketsURL, now: now)
        }
    }
}
#endif
