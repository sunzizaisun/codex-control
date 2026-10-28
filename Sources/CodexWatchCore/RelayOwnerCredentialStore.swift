#if os(macOS)
import CryptoKit
import Foundation
import Security

/// One immutable protected-Keychain bundle per origin/room. No split private
/// key/token/AES records, mutable index, automatic legacy import or re-creation
/// after missing-state recovery. Root registration remains operator-authorized.
public struct RelayOwnerCredentialStore: Sendable {
    public let service: String
    public init(service: String = "com.sunzizai.codexwatch.owner-credentials.v3") { self.service = service }
    private static let lock = NSLock()

    /// Read-only, including expired metadata so UI can explain recovery. Using
    /// or exporting that value still requires a fresh live-time check.
    public func load(baseURL: URL, roomID: String) throws -> RelayOwnerCredentials? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read(baseURL: baseURL, roomID: roomID)
    }

    /// Explicit new-owner action ONLY. A pre-existing slot must match exactly;
    /// corruption, changed owner/expiry/key or expiration never overwrites it.
    /// Successful saving is not registered/online; later configuration/export
    /// and the existing own-grant HTTP check independently recheck validity.
    public func begin(baseURL: URL, roomID: String, deviceID: String, expiresAtMilliseconds: Int64,
                      encryptionKey: Data? = nil, now: Date = Date()) throws -> RelayOwnerCredentials {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let selection = try query(baseURL: baseURL, roomID: roomID)
        if let previous = try read(baseURL: baseURL, roomID: roomID) {
            guard previous.matches(deviceID: deviceID, expiresAtMilliseconds: expiresAtMilliseconds, encryptionKey: encryptionKey) else {
                throw RelayOwnerCredentialError.conflict
            }
            try previous.requireLive(now: now); return previous
        }
        let value = try RelayOwnerCredentials.create(baseURL: baseURL, roomID: roomID, deviceID: deviceID,
            expiresAtMilliseconds: expiresAtMilliseconds, encryptionKey: encryptionKey, now: now)
        var insertion = selection
        insertion[kSecValueData as String] = try value.storedData()
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem, let original = try read(baseURL: baseURL, roomID: roomID) {
            guard original.matches(deviceID: deviceID, expiresAtMilliseconds: expiresAtMilliseconds, encryptionKey: encryptionKey) else {
                throw RelayOwnerCredentialError.conflict
            }
            try original.requireLive(now: now); return original
        }
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return value
    }

    private func read(baseURL: URL, roomID: String) throws -> RelayOwnerCredentials? {
        var selection = try query(baseURL: baseURL, roomID: roomID)
        selection[kSecReturnData as String] = true; selection[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(selection as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw RelayEnrollmentError.storage(status) }
        return try .init(storedData: bytes, expectedBaseURL: baseURL, roomID: roomID)
    }
    // Internal only for scoped tests. All CRUD keeps this exact protected,
    // non-synchronizing selector; no fallback or global keychain enumeration.
    func query(baseURL: URL, roomID: String) throws -> [String: Any] {
        guard !service.isEmpty, service.utf8.count <= 160, service.utf8.allSatisfy({ (33...126).contains($0) }),
              RelayCredentials.validIdentifier(roomID) else { throw RelayOwnerCredentialError.invalid }
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        let scope = ["owner-credentials-v3", origin.absoluteString, roomID].joined(separator: "\n")
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8)))),
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }
}
#endif
