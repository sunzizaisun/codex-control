import Foundation

/// Public registry shape shared by pairing and encrypted transport. Private
/// registry fields or unknown metadata cannot become trusted peer identities.
struct RelayDeviceGrant: Codable, Sendable {
    let roomID: String; let keyID: String; let deviceID: String; let role: RelayDeviceRole
    let jwk: RelayDevicePublicKey; let expiresAt: Int64; let revokedAt: Int64?
    private enum Keys: String, CodingKey { case roomID, keyID, deviceID, role, jwk, expiresAt, revokedAt }
    private struct AnyKey: CodingKey {
        let stringValue: String; let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self), names = Set(raw.allKeys.map(\.stringValue))
        let required: Set<String> = ["roomID", "keyID", "deviceID", "role", "jwk", "expiresAt"]
        guard names == required || names == required.union(["revokedAt"]) else { throw RelayDeviceTransportError.invalidPeer }
        let values = try decoder.container(keyedBy: Keys.self)
        roomID = try values.decode(String.self, forKey: .roomID); keyID = try values.decode(String.self, forKey: .keyID)
        deviceID = try values.decode(String.self, forKey: .deviceID); role = try values.decode(RelayDeviceRole.self, forKey: .role)
        jwk = try values.decode(RelayDevicePublicKey.self, forKey: .jwk); expiresAt = try values.decode(Int64.self, forKey: .expiresAt)
        revokedAt = try values.decodeIfPresent(Int64.self, forKey: .revokedAt)
    }
    func peer(now: Date) throws -> RelayPeerIdentity {
        guard expiresAt > 0, expiresAt <= 9_007_199_254_740_991,
              revokedAt == nil || (revokedAt! >= 0 && revokedAt! <= 9_007_199_254_740_991) else {
            throw RelayDeviceTransportError.invalidPeer
        }
        let result = try RelayPeerIdentity(roomID: roomID, keyID: keyID, deviceID: deviceID, role: role,
            publicKey: jwk, expiresAt: Date(timeIntervalSince1970: Double(expiresAt) / 1000),
            revokedAt: revokedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        try result.validate(now: now); return result
    }
}
