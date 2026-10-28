#if os(macOS)
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodexWatchCore

// This dedicated profile-signed host is never the normal app or an unhosted
// swift-test executable. Every SecItem query is limited to a fresh QA UUID;
// no production service, Keychain enumeration, iCloud sync or network is used.
private struct MacProtectedFixture {
    let configuration: RelayDeviceConfiguration
    let service = "qa.owner-mac." + UUID().uuidString
    let grantExpiresAt: Int64
    init() throws {
        let now = Date(), key = RelayDeviceSigningKey()
        let encryption = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let owner = try RelayPeerIdentity(roomID: "qa-mac-" + UUID().uuidString,
            keyID: RelayKeyDeliveryDevice.keyID(encryption), deviceID: "qa-owner", role: .mac,
            publicKey: key.publicKey, expiresAt: now.addingTimeInterval(3_600))
        configuration = try .init(baseURL: URL(string: "https://relay.invalid")!, identity: owner, owner: owner,
            signingKey: key, accessToken: RelayDeviceEncoding.base64URL(token), encryptionKey: encryption,
            preparedPacketsURL: FileManager.default.temporaryDirectory.appendingPathComponent("qa-unused-" + UUID().uuidString))
        grantExpiresAt = try RelayEnrollmentInvitation.milliseconds(now.addingTimeInterval(1_800))
    }
    func query() throws -> [String: Any] {
        let c = configuration, owner = c.identity
        return try RelayKeyDeliveryOwnerStore(service: service).roleQuery(baseURL: c.baseURL, roomID: owner.roomID,
            keyID: owner.keyID, role: .phone, ownerID: owner.deviceID, ownerKey: owner.publicKey)
    }
    func cleanup() {
        let prefix = "qa.owner-mac."
        guard service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil,
              let query = try? query() else { Issue.record("QA cleanup rejected unsafe scope"); return }
        let status = SecItemDelete(query as CFDictionary)
        #expect(status == errSecSuccess || status == errSecItemNotFound)
    }
}

@Test func macProtectedOwnerCreationUsesActualProfileBackedStoreWithoutClassicFallback() throws {
    let f = try MacProtectedFixture(); defer { f.cleanup() }
    let store = RelayKeyDeliveryOwnerStore(service: f.service), c = f.configuration
    let key = try f.query()
    #expect(key[kSecUseDataProtectionKeychain as String] as? Bool == true)
    var before = key
    before[kSecReturnData as String] = true; before[kSecMatchLimit as String] = kSecMatchLimitOne
    let authentication = LAContext(); authentication.interactionNotAllowed = true
    before[kSecUseAuthenticationContext as String] = authentication
    var absent: CFTypeRef?
    // Missing entitlement, locked session or an unauthorized host is a real
    // failure, not permission to run the rest against classic storage.
    try #require(SecItemCopyMatching(before as CFDictionary, &absent) == errSecItemNotFound)
    let draft = try store.stageCreation(configuration: c, role: .phone, grantExpiresAt: f.grantExpiresAt, now: Date())
    let rebuilt = RelayKeyDeliveryOwnerStore(service: f.service)
    let restored = try #require(try rebuilt.loadCreation(configuration: c, role: .phone,
        grantExpiresAt: f.grantExpiresAt, now: Date()))
    #expect(restored.offer.enrollment.creationBody == draft.offer.enrollment.creationBody)
    #expect(restored.offer.exchangeKey.rawRepresentation == draft.offer.exchangeKey.rawRepresentation)
    #expect(restored.offer.pairingSecret == draft.offer.pairingSecret && !restored.attempted)
    #expect(try store.claimCreation(draft, configuration: c, now: Date()))
    #expect(try !rebuilt.claimCreation(draft, configuration: c, now: Date()))

    var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: f.service, kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true, kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll, kSecUseAuthenticationContext as String: authentication]
    var rawAttributes: CFTypeRef?
    try #require(SecItemCopyMatching(attributes as CFDictionary, &rawAttributes) == errSecSuccess)
    let rows = try #require(rawAttributes as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(rows.first?[kSecAttrSynchronizable as String] as? Bool == false)
    // Omission is NOT a classic-only query: Apple's compatibility bridge may
    // search both stores. Explicit false restricts this negative read to the
    // classic database; it still targets only this fresh synthetic QA UUID.
    var classic = before; classic[kSecUseDataProtectionKeychain as String] = false
    var classicResult: CFTypeRef?
    #expect(SecItemCopyMatching(classic as CFDictionary, &classicResult) == errSecItemNotFound)
    #expect(classicResult == nil)

    let v = draft.offer.enrollment
    let receipt = try JSONSerialization.data(withJSONObject: ["authorized": true, "createDigest": v.creationDigest,
        "invitation": ["invitationID": v.invitationID, "role": v.role.rawValue,
            "nonce": RelayDeviceEncoding.base64URL(Data(repeating: 35, count: 32)), "expiresAt": v.expiresAt,
            "grantExpiresAt": v.grantExpiresAt, "ownerID": v.ownerID,
            "ownerThumbprint": v.ownerKey.publicKey.thumbprint, "consumed": false]])
    let invitation = try rebuilt.confirmCreation(draft, serverResponse: receipt, configuration: c, now: Date())
    #expect(try store.savedInvitation(baseURL: c.baseURL, roomID: c.identity.roomID, keyID: c.identity.keyID,
        role: .phone, ownerID: c.identity.deviceID, ownerKey: c.identity.publicKey,
        invitationID: v.invitationID) == invitation)
    rawAttributes = nil
    try #require(SecItemCopyMatching(attributes as CFDictionary, &rawAttributes) == errSecSuccess)
    #expect((rawAttributes as? [[String: Any]])?.count == 1)
    // Delete only this exact synthetic item, and prove continuation cannot add
    // it again. The defer permits an already missing item and no other scope.
    #expect(SecItemDelete(key as CFDictionary) == errSecSuccess)
    #expect(try rebuilt.loadCreation(configuration: c, role: .phone, grantExpiresAt: f.grantExpiresAt, now: Date()) == nil)
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    rawAttributes = nil
    #expect(SecItemCopyMatching(attributes as CFDictionary, &rawAttributes) == errSecItemNotFound)
}
#endif
