import CryptoKit
import Foundation
import Security

/// Only authToken and the public keyID belong on the relay server. The
/// encryption key is held by the paired devices; it is never a bearer token.
public struct RelayCredentials: Codable, Sendable {
    public let authToken: String
    public let encryptionKey: Data
    public let keyID: String

    public init(authToken: String, encryptionKey: Data) throws {
        guard let authBytes = Data(base64Encoded: authToken), authBytes.count == 32,
              encryptionKey.count == 32, authBytes != encryptionKey else { throw RemoteRelayError.invalidPacket }
        self.authToken = authToken
        self.encryptionKey = encryptionKey
        self.keyID = SHA256.hash(data: encryptionKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func generate() throws -> Self {
        let auth = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let encryption = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try Self(authToken: auth.base64EncodedString(), encryptionKey: encryption)
    }

    /// Deterministic one-time migration lets already paired devices agree on
    /// v2 keys without uploading their existing private bootstrap secret.
    /// Neither output is the input to the other. A server holding the v1
    /// SHA256(secret) or the v2 auth token cannot derive the encryption key.
    public static func migrating(secret: String, roomID: String) throws -> Self {
        guard secret.utf8.count >= 32, Self.validIdentifier(roomID) else { throw RemoteRelayError.invalidPacket }
        let root = SymmetricKey(data: Data(secret.utf8))
        let salt = Data("codex-control/relay/v2/\(roomID)".utf8)
        func derive(_ context: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt,
                info: Data(context.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        }
        return try Self(authToken: derive("server-authentication").base64EncodedString(),
                        encryptionKey: derive("device-only-encryption"))
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Keychain is deliberately not synchronized through iCloud. On an existing
/// installation the private bootstrap seed supplies the migration once; fresh
/// provisioning can store independent random keys through the same interface.
public enum RelayCredentialStore {
    public static func load(roomID: String) throws -> RelayCredentials? {
        var query = baseQuery(roomID: roomID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteRelayError.authenticationFailed }
        let decoded = try JSONDecoder().decode(RelayCredentials.self, from: data)
        let validated = try RelayCredentials(authToken: decoded.authToken, encryptionKey: decoded.encryptionKey)
        guard validated.keyID == decoded.keyID else { throw RemoteRelayError.invalidPacket }
        return validated
    }

    public static func save(_ credentials: RelayCredentials, roomID: String) throws {
        guard RelayCredentials.validIdentifier(roomID) else { throw RemoteRelayError.invalidPacket }
        let validated = try RelayCredentials(authToken: credentials.authToken, encryptionKey: credentials.encryptionKey)
        guard validated.keyID == credentials.keyID else { throw RemoteRelayError.invalidPacket }
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(roomID: roomID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw RemoteRelayError.authenticationFailed }
        } else if status != errSecSuccess { throw RemoteRelayError.authenticationFailed }
    }

    public static func remove(roomID: String) throws {
        guard RelayCredentials.validIdentifier(roomID) else { throw RemoteRelayError.invalidPacket }
        let status = SecItemDelete(baseQuery(roomID: roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteRelayError.authenticationFailed }
    }

    private static func baseQuery(roomID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sunzizai.codexwatch.relay.v2",
         kSecAttrAccount as String: roomID,
         kSecAttrSynchronizable as String: false]
    }
}

struct RelaySealedPacket: Codable, Sendable {
    var version: Int
    var keyID: String
    var destination: String
    var id: String
    var sentAt: Int64
    var expiresAt: Int64
    var sealed: String
}

struct RelayPacketCipher: Sendable {
    let roomID: String
    let credentials: RelayCredentials

    func seal(_ envelope: BridgeEnvelope, destination: String) throws -> RelaySealedPacket {
        guard RelayCredentials.validIdentifier(envelope.messageID),
              let sent = Int64(exactly: (envelope.sentAt.timeIntervalSince1970 * 1000).rounded()),
              let expires = Int64(exactly: (envelope.deliveryExpiresAt.timeIntervalSince1970 * 1000).rounded()) else {
            throw RemoteRelayError.invalidPacket
        }
        var packet = RelaySealedPacket(version: 2, keyID: credentials.keyID, destination: destination,
            id: envelope.messageID, sentAt: sent, expiresAt: expires, sealed: "")
        let aad = try associatedData(packet, destination: destination)
        let plaintext = try CodexWatchCoding.makeEncoder().encode(envelope)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: credentials.encryptionKey), authenticating: aad)
        guard let combined = box.combined else { throw RemoteRelayError.invalidPacket }
        packet.sealed = combined.base64EncodedString()
        return packet
    }

    func open(_ packet: RelaySealedPacket, destination: String) throws -> BridgeEnvelope {
        let aad = try associatedData(packet, destination: destination)
        guard let data = Data(base64Encoded: packet.sealed) else { throw RemoteRelayError.invalidPacket }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data),
            using: SymmetricKey(data: credentials.encryptionKey), authenticating: aad)
        let envelope = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: plaintext)
        guard envelope.messageID == packet.id,
              RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: packet.sentAt, expiresAtMilliseconds: packet.expiresAt) else {
            throw RemoteRelayError.invalidPacket
        }
        return envelope
    }

    private func associatedData(_ packet: RelaySealedPacket, destination: String) throws -> Data {
        guard packet.version == 2, packet.keyID == credentials.keyID,
              packet.destination == destination,
              ["snapshot", "mac", "phone", "watch"].contains(destination),
              RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(packet.id),
              packet.sentAt >= 0, packet.expiresAt >= packet.sentAt else { throw RemoteRelayError.invalidPacket }
        return Data(["codex-control/relay", "2", packet.keyID, roomID, destination, packet.id,
                     String(packet.sentAt), String(packet.expiresAt)].joined(separator: "\n").utf8)
    }
}
