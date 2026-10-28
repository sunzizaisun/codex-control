#if os(iOS)
import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

private func creationQAItem(service: String, configuration: RelayDeviceConfiguration, role: RelayDeviceRole) -> [String: Any] {
    let owner = configuration.identity
    let scope = ["owner-offer-v2", configuration.baseURL.absoluteString, owner.roomID, owner.keyID,
        owner.deviceID, owner.publicKey.thumbprint, role.rawValue].joined(separator: "\n")
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8)))), kSecAttrSynchronizable as String: false]
}
private func creationQABytes(_ key: [String: Any]) throws -> Data {
    var key = key; key[kSecReturnData as String] = true; key[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; #expect(SecItemCopyMatching(key as CFDictionary, &result) == errSecSuccess)
    return try #require(result as? Data)
}
private func creationQACleanup(_ service: String) {
    let prefix = "qa.owner-creation."
    guard service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil else { Issue.record("QA-only cleanup scope rejected"); return }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
    let status = SecItemDelete(query as CFDictionary); #expect(status == errSecSuccess || status == errSecItemNotFound)
}
private func creationQAReceipt(_ draft: RelayOwnerCreationDraft) throws -> Data {
    let v = draft.offer.enrollment
    return try JSONSerialization.data(withJSONObject: ["authorized": true, "createDigest": v.creationDigest, "invitation": [
        "invitationID": v.invitationID, "role": v.role.rawValue, "nonce": RelayDeviceEncoding.base64URL(Data(repeating: 35, count: 32)),
        "expiresAt": v.expiresAt, "grantExpiresAt": v.grantExpiresAt, "ownerID": v.ownerID,
        "ownerThumbprint": v.ownerKey.publicKey.thumbprint, "consumed": false]])
}

@Test func ownerCreationKeychainStagesOneDeviceOnlyAtomicItemBeforeAnyNetworkOrQR() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), deadline = f.offer.enrollment.grantExpiresAt
    let first = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    let key = creationQAItem(service: service, configuration: configuration, role: .phone), bytes = try creationQABytes(key)
    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    #expect(object["version"] as? Int == 2 && object["creationAttempted"] as? Bool == false && object["qr"] == nil)
    #expect(!String(decoding: bytes, as: UTF8.self).contains(configuration.accessToken))
    #expect(!String(decoding: bytes, as: UTF8.self).contains(configuration.signingKey.storageRepresentation.base64EncodedString()))
    #expect(!String(decoding: bytes, as: UTF8.self).contains(configuration.encryptionKey.base64EncodedString()))
    let again = try RelayKeyDeliveryOwnerStore(service: service).stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    #expect(first.offer.enrollment.invitationID == again.offer.enrollment.invitationID)
    #expect(first.offer.enrollment.creationBody == again.offer.enrollment.creationBody)
    #expect(first.offer.exchangeKey.rawRepresentation == again.offer.exchangeKey.rawRepresentation && first.offer.pairingSecret == again.offer.pairingSecret)
    #expect(try creationQABytes(key) == bytes)
    #expect(try store.savedInvitation(baseURL: configuration.baseURL, roomID: configuration.identity.roomID, keyID: configuration.identity.keyID,
        role: .phone, ownerID: configuration.identity.deviceID, ownerKey: configuration.identity.publicKey,
        invitationID: first.offer.enrollment.invitationID) == nil)
    var attributesQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrSynchronizable as String: false, kSecMatchLimit as String: kSecMatchLimitAll]
    attributesQuery[kSecReturnAttributes as String] = true
    var attributes: CFTypeRef?; #expect(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes) == errSecSuccess)
    let rows = try #require(attributes as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0][kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
}

@Test func ownerCreationKeychainSixteenPreparationsAndClaimsKeepOneOriginalAndOneWriteAuthority() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let drafts = try await withThrowingTaskGroup(of: RelayOwnerCreationDraft.self) { group in
        for _ in 0..<16 { group.addTask { try RelayKeyDeliveryOwnerStore(service: service).stageCreation(configuration: configuration,
            role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt, now: f.clock.now()) } }
        var result: [RelayOwnerCreationDraft] = []; for try await value in group { result.append(value) }; return result
    }
    #expect(Set(drafts.map { $0.offer.enrollment.invitationID }).count == 1)
    #expect(Set(drafts.map { $0.offer.exchangeKey.rawRepresentation }).count == 1)
    let draft = try #require(drafts.first)
    let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 { group.addTask { try RelayKeyDeliveryOwnerStore(service: service).claimCreation(draft, configuration: configuration, now: f.clock.now()) } }
        var result: [Bool] = []; for try await value in group { result.append(value) }; return result
    }
    #expect(claims.filter { $0 }.count == 1)
    let recovered = try RelayKeyDeliveryOwnerStore(service: service).stageCreation(configuration: configuration, role: .phone,
        grantExpiresAt: f.offer.enrollment.grantExpiresAt, now: f.clock.now())
    #expect(recovered.attempted); #expect(recovered.offer.enrollment.creationBody == draft.offer.enrollment.creationBody)
}

@Test func ownerCreationKeychainMissingFlagIsUncertainAndCorruptMaterialIsPreserved() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), deadline = f.offer.enrollment.grantExpiresAt
    let initial = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    let key = creationQAItem(service: service, configuration: configuration, role: .phone)
    var object = try JSONSerialization.jsonObject(with: creationQABytes(key)) as! [String: Any]; object["creationAttempted"] = nil
    let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: old] as CFDictionary) == errSecSuccess)
    let recovered = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    #expect(recovered.attempted); #expect(try !store.claimCreation(initial, configuration: configuration, now: f.clock.now()))
    #expect(try creationQABytes(key) == old)
    var material = object["creation"] as! [String: Any]; material["creationDigest"] = "corrupt"
    object["creation"] = material
    let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: corrupt] as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now()) }
    #expect(try creationQABytes(key) == corrupt)
}

@Test func ownerCreationKeychainCannotChangeGrantOrReplaceAnExpiredOriginal() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), deadline = f.offer.enrollment.grantExpiresAt
    _ = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    let key = creationQAItem(service: service, configuration: configuration, role: .phone), original = try creationQABytes(key)
    #expect(throws: (any Error).self) { try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline + 1, now: f.clock.now()) }
    f.clock.advance(120)
    #expect(throws: (any Error).self) { try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now()) }
    #expect(try creationQABytes(key) == original)
}

@Test func ownerCreationKeychainRejectsUnknownFieldsAlteredExchangeAndCrossRoleCopies() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), deadline = f.offer.enrollment.grantExpiresAt
    _ = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now())
    let key = creationQAItem(service: service, configuration: configuration, role: .phone), original = try creationQABytes(key)
    let value = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    for unknown in [true, false] {
        var changed = value
        if unknown { changed["ownerAccessToken"] = "unknown-private-field-must-not-be-ignored" }
        else { changed["exchangeKey"] = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString() }
        let corrupt = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: corrupt] as CFDictionary) == errSecSuccess)
        #expect(throws: (any Error).self) { try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: deadline, now: f.clock.now()) }
        #expect(try creationQABytes(key) == corrupt)
    }
    let watchKey = creationQAItem(service: service, configuration: configuration, role: .watch)
    var insertion = watchKey; insertion[kSecValueData as String] = original
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #expect(SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.stageCreation(configuration: configuration, role: .watch, grantExpiresAt: deadline, now: f.clock.now()) }
    #expect(try creationQABytes(watchKey) == original)
}

@Test func ownerCreationPublicConstructorLostACKRebuildsAndPromotesSameSingleKeychainItem() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let key = creationQAItem(service: service, configuration: configuration, role: .phone)
    let server = OwnerCreationQAServer(f, mode: .lostACK, beforePost: {
        let selection = creationQAItem(service: service, configuration: configuration, role: .phone)
        let value = try JSONSerialization.jsonObject(with: creationQABytes(selection)) as! [String: Any]
        return value["creationAttempted"] as? Bool == true
    })
    func client() throws -> RelayOwnerPairingCreator { try .init(ownerConfiguration: configuration, store: .init(service: service), requestTransport: { try await server.handle($0) }) }
    guard case .creationUnconfirmed(let id) = try await client().begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) else { Issue.record("lost ACK not retained"); return }
    let before = try JSONSerialization.jsonObject(with: creationQABytes(key)) as! [String: Any]
    #expect(before["qr"] == nil)
    let invitation = try creationQAInvitation(await client().advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
    #expect(invitation.enrollment.invitationID == id)
    let after = try JSONSerialization.jsonObject(with: creationQABytes(key)) as! [String: Any]
    #expect(after["qr"] as? String == (try invitation.qrPayload))
    #expect(try JSONSerialization.data(withJSONObject: before["creation"]!, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: after["creation"]!, options: [.sortedKeys]))
    #expect(before["exchangeKey"] as? String == after["exchangeKey"] as? String)
    #expect(try creationQAInvitation(await client().advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt)) == invitation)
    #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
    #expect(try RelayKeyDeliveryOwnerStore(service: service).savedInvitation(baseURL: configuration.baseURL, roomID: configuration.identity.roomID,
        keyID: configuration.identity.keyID, role: .phone, ownerID: configuration.identity.deviceID, ownerKey: configuration.identity.publicKey,
        invitationID: id) == invitation)
}

@Test func ownerCreationAndBothKeyCoordinatorsComposeThroughRealIsolatedKeychainsWithoutServerCryptoReply() async throws {
    for role in [RelayDeviceRole.phone, .watch] {
        let f = try PairingQAFixture(role: role); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
        let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
        let ownerStore = RelayKeyDeliveryOwnerStore(service: service), mobileStore = RelayEnrollmentKeychain(service: service + ".mobile")
        let server = OwnerCreationQAServer(f, beforePost: {
            let key = creationQAItem(service: service, configuration: configuration, role: role)
            return (try JSONSerialization.jsonObject(with: creationQABytes(key)) as! [String: Any])["creationAttempted"] as? Bool == true
        })
        let creator = try RelayOwnerPairingCreator(ownerConfiguration: configuration, store: ownerStore, requestTransport: { try await server.handle($0) })
        let invitation = try creationQAInvitation(await creator.begin(role: role, grantExpiresAt: f.offer.enrollment.grantExpiresAt)), base = invitation.enrollment
        defer { try? mobileStore.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: role) }
        let pending = try mobileStore.prepareSecure(invitation), relay = PairingQAServer(f, mode: .ownerLostACK, pending: pending)
        func mobile() -> RelayPairingCoordinator { .init(keychain: mobileStore, baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID,
            role: role, preparedPacketsURL: f.directory.appendingPathComponent("created-mobile.plist"), requestTransport: { try await relay.handle($0) }) }
        func owner() throws -> RelayOwnerKeyPublisher { try .init(ownerConfiguration: configuration, store: ownerStore, requestTransport: { try await relay.handle($0) }) }
        guard case .awaitingOwner = try await mobile().advance() else { Issue.record("new mobile not waiting"); return }
        guard case .publicationUnconfirmed = try await owner().advance(invitation: invitation) else { Issue.record("lost owner ACK not uncertain"); return }
        guard case .responseStored = try await owner().advance(invitation: invitation) else { Issue.record("original response missing"); return }
        guard case .ready(let ready) = try await mobile().advance() else { Issue.record("mobile key not saved"); return }
        #expect(ready.encryptionKey == f.aes && ready.identity.publicKey == pending.intent.signingKey.publicKey)
        for _ in 0..<4 {
            guard case .responseStored = try await owner().advance(invitation: invitation) else { Issue.record("stored response regressed"); return }
            guard case .ready = try await mobile().advance() else { Issue.record("key ready regressed"); return }
        }
        let automaticReplies = await relay.automaticReplyCount(), storedReplies = await relay.storedOwnerResponseCount()
        #expect(automaticReplies == 0 && storedReplies == 1)
        #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await relay.snapshot().filter { $0.httpMethod == "POST" }.count == 3)
    }
}

@Test func ownerCreationV2SlotPreservesLegacyKnownIDLookupWithoutAllowingLegacyBypass() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), old = try store.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now())
    let draft = try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt, now: f.clock.now())
    #expect(draft.offer.enrollment.invitationID != old.enrollment.invitationID)
    let base = old.enrollment
    #expect(try store.savedInvitation(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: .phone,
        ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID) == old)
    #expect(throws: (any Error).self) { try store.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now()) }
    #expect(try store.stageCreation(configuration: configuration, role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt,
        now: f.clock.now()).offer.enrollment.invitationID == draft.offer.enrollment.invitationID)
}

@Test func ownerCreationMissingAuthoritativeItemCannotBeReaddedByClaimPromotionOrRecovery() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let service = "qa.owner-creation." + UUID().uuidString; defer { creationQACleanup(service) }
    let store = RelayKeyDeliveryOwnerStore(service: service), draft = try store.stageCreation(configuration: configuration,
        role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt, now: f.clock.now())
    let key = creationQAItem(service: service, configuration: configuration, role: .phone)
    #expect(SecItemDelete(key as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.claimCreation(draft, configuration: configuration, now: f.clock.now()) }
    #expect(throws: (any Error).self) { try store.confirmCreation(draft, serverResponse: creationQAReceipt(draft), configuration: configuration, now: f.clock.now()) }
    let server = OwnerCreationQAServer(f, beforePost: { false })
    let creator = try RelayOwnerPairingCreator(ownerConfiguration: configuration, store: store, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { try await creator.advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(await server.captured().isEmpty)
    var result: CFTypeRef?; #expect(SecItemCopyMatching(key as CFDictionary, &result) == errSecItemNotFound)
}
#endif
