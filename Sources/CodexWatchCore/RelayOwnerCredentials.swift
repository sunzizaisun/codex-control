import CryptoKit
import Foundation

public enum RelayOwnerCredentialError: Error { case invalid, conflict, missingOrExpired }

/// The one long-term owner bundle, not an enrollment receipt or online state.
/// Deliberately NOT Codable: only its public registry export may leave the
/// device. Private bytes are encoded solely by the internal storage codec.
public struct RelayOwnerCredentials: Sendable, CustomDebugStringConvertible {
    private struct Stored: Codable {
        let version: Int
        let baseURL: String
        let roomID: String
        let deviceID: String
        let role: RelayDeviceRole
        let keyID: String
        let signingKey: Data
        let publicKey: RelayDevicePublicKey
        let accessToken: String
        let encryptionKey: Data
        let createdAt: Int64
        let expiresAt: Int64
    }
    private let stored: Stored
    public var baseURL: URL { URL(string: stored.baseURL)! }
    public var roomID: String { stored.roomID }
    public var deviceID: String { stored.deviceID }
    public var keyID: String { stored.keyID }
    public var publicKey: RelayDevicePublicKey { stored.publicKey }
    public var expiresAtMilliseconds: Int64 { stored.expiresAt }
    public var createdAt: Date { Date(timeIntervalSince1970: Double(stored.createdAt) / 1000) }
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(stored.expiresAt) / 1000) }
    public var debugDescription: String { "RelayOwnerCredentials(credentials: <redacted>, registration: unverified)" }
    var encryptionKey: Data { stored.encryptionKey }

    /// Internal factory. The public Mac store saves the WHOLE value before
    /// returning it. Reconnect/load never calls this or renews the lifetime.
    static func create(baseURL: URL, roomID: String, deviceID: String, expiresAtMilliseconds: Int64,
                       encryptionKey: Data?, now: Date) throws -> Self {
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        let created = try RelayEnrollmentInvitation.milliseconds(now), expiry = expiresAtMilliseconds
        guard RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(deviceID),
              expiry > created, expiry <= 9_007_199_254_740_991,
              encryptionKey == nil || encryptionKey?.count == 32 else { throw RelayOwnerCredentialError.invalid }
        let signing = RelayDeviceSigningKey()
        let encryption = encryptionKey ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let token = RelayDeviceEncoding.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let record = Stored(version: 1, baseURL: origin.absoluteString, roomID: roomID, deviceID: deviceID,
            role: .mac, keyID: RelayKeyDeliveryDevice.keyID(encryption), signingKey: signing.storageRepresentation,
            publicKey: signing.publicKey, accessToken: token, encryptionKey: encryption, createdAt: created, expiresAt: expiry)
        return try .init(storedData: RelayEnrollmentInvitation.encoder().encode(record), expectedBaseURL: origin, roomID: roomID)
    }

    init(storedData bytes: Data, expectedBaseURL: URL, roomID: String) throws {
        guard !bytes.isEmpty, bytes.count <= 8_192 else { throw RelayOwnerCredentialError.invalid }
        let value = try JSONDecoder().decode(Stored.self, from: bytes)
        let origin = try RelayEnrollmentInvitation.origin(expectedBaseURL)
        let key = try RelayDeviceSigningKey(rawRepresentation: value.signingKey)
        guard value.version == 1, value.role == .mac, value.baseURL == origin.absoluteString, value.roomID == roomID,
              RelayCredentials.validIdentifier(value.roomID), RelayCredentials.validIdentifier(value.deviceID),
              value.publicKey == key.publicKey, value.encryptionKey.count == 32,
              value.keyID == RelayKeyDeliveryDevice.keyID(value.encryptionKey),
              let token = RelayDeviceEncoding.decodeBase64URL(value.accessToken), token.count == 32,
              Set([value.signingKey, value.publicKey.rawRepresentation, value.encryptionKey, token]).count == 4,
              value.createdAt >= 0, value.expiresAt > value.createdAt, value.expiresAt <= 9_007_199_254_740_991,
              bytes == (try RelayEnrollmentInvitation.encoder().encode(value)) else { throw RelayOwnerCredentialError.invalid }
        stored = value
    }
    func storedData() throws -> Data { try RelayEnrollmentInvitation.encoder().encode(stored) }
    func requireLive(now: Date) throws {
        let time = try RelayEnrollmentInvitation.milliseconds(now)
        guard stored.createdAt <= time + 60_000, time < stored.expiresAt, now < expiresAt else { throw RelayOwnerCredentialError.missingOrExpired }
    }
    func matches(deviceID: String, expiresAtMilliseconds: Int64, encryptionKey: Data?) -> Bool {
        stored.deviceID == deviceID && stored.expiresAt == expiresAtMilliseconds
            && (encryptionKey == nil || stored.encryptionKey == encryptionKey)
    }

    public func configuration(preparedPacketsURL: URL, now: Date = Date()) throws -> RelayDeviceConfiguration {
        try requireLive(now: now)
        let identity = try RelayPeerIdentity(roomID: roomID, keyID: keyID, deviceID: deviceID, role: .mac,
            publicKey: publicKey, expiresAt: expiresAt)
        return try .init(baseURL: baseURL, identity: identity, owner: identity,
            signingKey: RelayDeviceSigningKey(rawRepresentation: stored.signingKey), accessToken: stored.accessToken,
            encryptionKey: stored.encryptionKey, preparedPacketsURL: preparedPacketsURL)
    }

    /// Exact existing deviceRecords array profile. This is operator input,
    /// NOT self-registration or proof that the server admitted this owner.
    /// No access token, private signing key, AES key or QR capability is sent.
    public func serverRegistrationData(now: Date = Date()) throws -> Data {
        try requireLive(now: now)
        struct PublicRecord: Encodable {
            let roomID: String; let keyID: String; let deviceID: String; let role: RelayDeviceRole
            let tokenHash: String; let jwk: RelayDevicePublicKey; let expiresAt: Int64
        }
        return try RelayEnrollmentInvitation.encoder().encode([PublicRecord(roomID: roomID, keyID: keyID,
            deviceID: deviceID, role: .mac, tokenHash: RelayDeviceSigningKey.accessTokenHash(stored.accessToken),
            jwk: publicKey, expiresAt: stored.expiresAt)])
    }
}
