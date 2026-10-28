import CryptoKit
import Foundation

/// Private ephemeral pairing material, not another root-credential store.
/// Root signing private key, owner access token and room AES key are absent.
struct RelayOwnerOfferMaterial: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    var debugDescription: String { "RelayOwnerOfferMaterial(<redacted>)" }
    let baseURL: String
    let roomID: String
    let keyID: String
    let role: RelayDeviceRole
    let invitationID: String
    let secret: String
    let createdAt: Int64
    let expiresAt: Int64
    let grantExpiresAt: Int64
    let ownerID: String
    let ownerKey: RelayDevicePublicKey
    let ownerExchangePublicKey: String
    let creationBody: Data
    let creationDigest: String
    let pairingSecret: Data

    init(offer: RelaySecurePairingOffer) {
        let value = offer.enrollment
        baseURL = value.baseURL.absoluteString; roomID = value.roomID; keyID = value.keyID; role = value.role
        invitationID = value.invitationID; secret = value.secret; createdAt = value.expiresAt - 120_000
        expiresAt = value.expiresAt; grantExpiresAt = value.grantExpiresAt
        ownerID = value.ownerID; ownerKey = value.ownerKey.publicKey
        ownerExchangePublicKey = RelayDeviceEncoding.base64URL(offer.exchangeKey.publicKey.rawRepresentation)
        creationBody = value.creationBody; creationDigest = value.creationDigest; pairingSecret = offer.pairingSecret
    }
    func validate() throws {
        guard let url = URL(string: baseURL), try RelayEnrollmentInvitation.origin(url).absoluteString == baseURL,
              [roomID, invitationID, ownerID].allSatisfy(RelayCredentials.validIdentifier),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              role == .phone || role == .watch,
              let capability = RelayDeviceEncoding.decodeBase64URL(secret), capability.count == 32, capability != ownerKey.rawRepresentation,
              createdAt >= 0, createdAt <= 9_007_199_254_620_991, expiresAt == createdAt + 120_000,
              grantExpiresAt > expiresAt, grantExpiresAt <= 9_007_199_254_740_991,
              creationBody.count <= 4096, creationDigest == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: creationBody))),
              creationBody == (try RelayEnrollmentOffer.creationBytes(invitationID: invitationID, role: role, secret: secret,
                expiresAt: expiresAt, grantExpiresAt: grantExpiresAt)),
              let exchangePublic = RelayDeviceEncoding.decodeBase64URL(ownerExchangePublicKey), exchangePublic.count == 32,
              pairingSecret.count == 32, pairingSecret != capability, pairingSecret != ownerKey.rawRepresentation,
              pairingSecret != exchangePublic else {
            throw RelayKeyDeliveryError.invalid
        }
    }
    func restore(signingKey: RelayDeviceSigningKey, exchangeKey: Data) throws -> RelaySecurePairingOffer {
        try validate()
        let exchange = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: exchangeKey)
        guard ownerKey == signingKey.publicKey, ownerExchangePublicKey == RelayDeviceEncoding.base64URL(exchange.publicKey.rawRepresentation) else {
            throw RelayKeyDeliveryError.identityConflict
        }
        return try .init(enrollment: RelayEnrollmentOffer(restoring: self, ownerKey: signingKey),
            exchangeKey: exchangeKey, pairingSecret: pairingSecret)
    }
    func matches(_ invitation: RelaySecurePairingInvitation) -> Bool {
        let value = invitation.enrollment
        return baseURL == value.baseURL.absoluteString && roomID == value.roomID && keyID == value.keyID && role == value.role
            && invitationID == value.invitationID && secret == value.secret && expiresAt == value.expiresAt
            && grantExpiresAt == value.grantExpiresAt && ownerID == value.ownerID && ownerKey == value.ownerKey
            && RelayDeviceEncoding.base64URL(pairingSecret) == invitation.pairingSecret && ownerExchangePublicKey == invitation.ownerExchangePublicKey
    }
}

struct RelayOwnerCreationDraft: Sendable, CustomDebugStringConvertible {
    let offer: RelaySecurePairingOffer
    let attempted: Bool
    var debugDescription: String { "RelayOwnerCreationDraft(<redacted>)" }
    func validate(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64, now: Date) throws {
        let value = offer.enrollment, owner = configuration.identity
        try owner.validate(now: now); try value.validateCreation(now: now)
        guard owner.role == .mac, owner == configuration.owner, value.baseURL == configuration.baseURL,
              value.roomID == owner.roomID, value.keyID == owner.keyID, value.ownerID == owner.deviceID,
              value.ownerKey.publicKey == owner.publicKey, value.role == role, value.grantExpiresAt == grantExpiresAt,
              grantExpiresAt <= (try RelayEnrollmentInvitation.milliseconds(owner.expiresAt)),
              let capability = RelayDeviceEncoding.decodeBase64URL(value.secret),
              let access = RelayDeviceEncoding.decodeBase64URL(configuration.accessToken),
              capability != access, capability != configuration.encryptionKey,
              capability != configuration.signingKey.storageRepresentation,
              offer.exchangeKey.rawRepresentation != access, offer.exchangeKey.rawRepresentation != configuration.encryptionKey,
              offer.pairingSecret != access, offer.pairingSecret != configuration.encryptionKey else {
            throw RelayKeyDeliveryError.identityConflict
        }
    }
}

protocol RelayOwnerCreationPersistence: Sendable {
    func loadCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64, now: Date) throws -> RelayOwnerCreationDraft?
    func stageCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64, now: Date) throws -> RelayOwnerCreationDraft
    func claimCreation(_ draft: RelayOwnerCreationDraft, configuration: RelayDeviceConfiguration, now: Date) throws -> Bool
    func confirmCreation(_ draft: RelayOwnerCreationDraft, serverResponse: Data, configuration: RelayDeviceConfiguration,
                         now: Date) throws -> RelaySecurePairingInvitation
}
