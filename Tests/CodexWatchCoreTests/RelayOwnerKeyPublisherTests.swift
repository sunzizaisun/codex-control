import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

private enum PublisherQAFailure: Error { case storage }

@available(macOS 14.0, *)
extension PairingQAFixture {
    var ownerConfiguration: RelayDeviceConfiguration {
        get throws { try .init(baseURL: secure.enrollment.baseURL, identity: owner(), owner: owner(), signingKey: ownerKey,
            accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 97, count: 32)), encryptionKey: aes,
            preparedPacketsURL: directory.appendingPathComponent("owner-packets.plist")) }
    }
    func publisher(_ store: any RelayOwnerPublicationPersistence, server: PairingQAServer) throws -> RelayOwnerKeyPublisher {
        let configuration = try ownerConfiguration
        let http = RelayDeviceHTTPClient(baseURL: configuration.baseURL, roomID: configuration.identity.roomID,
            keyID: configuration.identity.keyID, requestTimeout: 2, waitsForConnectivity: false,
            requestTransport: { try await server.handle($0) }, clock: { clock.now() })
        return .init(configuration: configuration, store: store, http: http, clock: { clock.now() })
    }
}

/// Only a memory seam; real owner Keychain and both native coordinators are
/// exercised separately below. The HTTP fixture never generates a response in
/// external-owner mode: it can only retain the publisher's original ciphertext.
@available(macOS 14.0, *)
private final class PublisherQAMemory: RelayOwnerPublicationPersistence, @unchecked Sendable {
    private let fixture: PairingQAFixture, lock = NSLock()
    private var saved: RelayOwnerKeyPublication?
    private var freezeFailure = false, claimFailure = false
    init(_ fixture: PairingQAFixture) { self.fixture = fixture }
    func publication(invitation: RelaySecurePairingInvitation, owner: RelayPeerIdentity, now: Date) throws -> RelayOwnerKeyPublication? {
        lock.lock(); defer { lock.unlock() }; return saved
    }
    func response(to request: RelayKeyDeliveryPacket, invitation: RelaySecurePairingInvitation, recipient: RelayPeerIdentity,
                  owner: RelayPeerIdentity, encryptionKey: Data, now: Date) throws -> RelayKeyDeliveryPacket {
        lock.lock(); defer { lock.unlock() }
        let candidate = try RelayKeyDeliveryOwner(invitation: invitation, exchangeKey: fixture.offer.exchangeKey.rawRepresentation)
            .makeResponse(request, peer: recipient, encryptionKey: encryptionKey, now: now)
        if let saved {
            guard saved.request == request else { throw RelayKeyDeliveryError.identityConflict }; return saved.response
        }
        if freezeFailure { throw PublisherQAFailure.storage }
        saved = .init(request: request, response: candidate, attempted: false); return candidate
    }
    func claimPublication(_ publication: RelayOwnerKeyPublication, invitation: RelaySecurePairingInvitation,
                          owner: RelayPeerIdentity, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let saved, saved.request == publication.request, saved.response == publication.response else {
            throw RelayKeyDeliveryError.identityConflict
        }
        if claimFailure { throw PublisherQAFailure.storage }
        guard !saved.attempted else { return false }
        self.saved = .init(request: saved.request, response: saved.response, attempted: true); return true
    }
    func failFreeze(_ value: Bool) { lock.lock(); defer { lock.unlock() }; freezeFailure = value }
    func failClaim(_ value: Bool) { lock.lock(); defer { lock.unlock() }; claimFailure = value }
}

private func requireResponseStored(_ value: RelayOwnerKeyUpdate, deviceID: String) throws {
    guard case .responseStored(let actual) = value, actual == deviceID else {
        Issue.record("owner response not confirmed stored"); throw RelayKeyDeliveryError.notReady
    }
}

@available(macOS 14.0, *)
@Test func twoNativePairingCoordinatorsDeliverRealHPKEWithoutServerGeneratedReply() async throws {
    for role in [RelayDeviceRole.phone, .watch] {
        let f = try PairingQAFixture(role: role); defer { f.cleanup() }
        let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
        guard case .awaitingOwner = try await f.client(mobile, server: server).advance() else { Issue.record("mobile did not wait"); return }
        try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
        guard case .ready(let configuration) = try await f.client(mobile, server: server).advance() else { Issue.record("mobile not ready"); return }
        #expect(configuration.encryptionKey == f.aes); #expect(configuration.identity.publicKey == f.pending.intent.signingKey.publicKey)
        for _ in 0..<4 {
            try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
            guard case .ready = try await f.client(mobile, server: server).advance() else { Issue.record("ready state regressed"); return }
        }
        #expect(await server.automaticReplyCount() == 0)
        #expect(await server.storedOwnerResponseCount() == 1)
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 3)
    }
}

@available(macOS 14.0, *)
@Test func ownerPublisherWaitingForRequestNeverInventsPairingOrWrites() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
    guard case .awaitingRequest = try await f.publisher(store, server: server).advance(invitation: f.secure) else { Issue.record("not waiting"); return }
    #expect(await server.snapshot().allSatisfy { $0.httpMethod == "GET" }); #expect(await server.automaticReplyCount() == 0)
}

@available(macOS 14.0, *)
@Test func ownerPublisherLostOrMalformedReceiptRecoversWhenRequestIsNoLongerListed() async throws {
    for mode in [PairingQAServer.Mode.ownerLostACK, .ownerMalformedReceipt] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: mode)
        _ = try await f.client(mobile, server: server).advance()
        guard case .publicationUnconfirmed = try await f.publisher(owner, server: server).advance(invitation: f.secure) else { Issue.record("not uncertain"); return }
        try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
        guard case .ready = try await f.client(mobile, server: server).advance() else { Issue.record("mobile key missing"); return }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
        #expect(await server.snapshot().filter { $0.url!.path.hasSuffix("devices/key-requests") }.count == 1)
        #expect(await server.automaticReplyCount() == 0)
    }
}

@available(macOS 14.0, *)
@Test func ownerPublisherAbsentResponseOr503AfterClaimNeverAuthorizesAnotherPOST() async throws {
    for mode in [PairingQAServer.Mode.ownerMissingAfterLostACK, .ownerRejected] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: mode)
        _ = try await f.client(mobile, server: server).advance()
        for _ in 0..<3 { guard case .publicationUnconfirmed = try await f.publisher(owner, server: server).advance(invitation: f.secure) else { Issue.record("uncertainty lost"); return } }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
    }
}

@available(macOS 14.0, *)
@Test func ownerPublisherExplicitNonceRetryRetainsTheSameFrozenCiphertext() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .ownerRotatedNonce)
    _ = try await f.client(mobile, server: server).advance()
    try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
    let posts = await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }
    #expect(posts.count == 2); #expect(posts[0].httpBody == posts[1].httpBody)
    #expect(posts[0].value(forHTTPHeaderField: "DPoP") != posts[1].value(forHTTPHeaderField: "DPoP"))
    #expect(await server.storedOwnerResponseCount() == 1)
    guard case .ready = try await f.client(mobile, server: server).advance() else { Issue.record("response failed decryption"); return }
}

@available(macOS 14.0, *)
@Test func ownerPublisherPacketDeadlineDuringNonceChallengeStopsBeforeSecondPOST() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f)
    let server = PairingQAServer(f, mode: .ownerExpiresDuringChallenge)
    _ = try await f.client(mobile, server: server).advance()
    let update = try await f.publisher(owner, server: server).advance(invitation: f.secure)
    if case .publicationUnconfirmed = update {} else { Issue.record("expired response was reported stored") }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
    #expect(await server.storedOwnerResponseCount() == 0)
}

@available(macOS 14.0, *)
@Test func ownerPublisherCancellationKeepsClaimAndRecoversOnlyByRead() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .ownerCancelled)
    _ = try await f.client(mobile, server: server).advance()
    await #expect(throws: CancellationError.self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
    try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerPublisherChangedRecipientKeyCannotReceiveFrozenResponse() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .ownerRejected)
    _ = try await f.client(mobile, server: server).advance(); _ = try await f.publisher(owner, server: server).advance(invitation: f.secure)
    await server.changeRecipientKey()
    await #expect(throws: (any Error).self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerPublisherRejectsStaleMalformedOrDuplicateRequestLists() async throws {
    for mode in [PairingQAServer.Mode.staleKeyRequests, .malformedKeyRequests, .duplicateKeyRequests, .wrongRecipientKey] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f)
        let server = PairingQAServer(f, mode: mode == .wrongRecipientKey ? .externalOwner : mode)
        _ = try await f.client(mobile, server: server).advance()
        if mode == .wrongRecipientKey { await server.changeRecipientKey() }
        await #expect(throws: (any Error).self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.isEmpty)
    }
}

@available(macOS 14.0, *)
@Test func ownerPublisherConflictingStoredCiphertextIsNotSuccessOrPermissionToOverwrite() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
    _ = try await f.client(mobile, server: server).advance(); _ = try await f.publisher(owner, server: server).advance(invitation: f.secure)
    await server.conflictResponse()
    await #expect(throws: (any Error).self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerPublisherFailedFreezeOrClaimVetoesPublicationAndKeepsRecoverableState() async throws {
    for freeze in [true, false] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
        _ = try await f.client(mobile, server: server).advance()
        if freeze { owner.failFreeze(true) } else { owner.failClaim(true) }
        await #expect(throws: PublisherQAFailure.self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.isEmpty)
        owner.failFreeze(false); owner.failClaim(false)
        try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
        #expect(await server.storedOwnerResponseCount() == 1)
    }
}

@available(macOS 14.0, *)
@Test func ownerPublisherConcurrentInstancesShareOneClaimAndOneResponseUpload() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let mobile = PairingQAMemory(f), owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
    _ = try await f.client(mobile, server: server).advance()
    await withTaskGroup(of: Void.self) { group in for _ in 0..<8 { group.addTask { _ = try? await f.publisher(owner, server: server).advance(invitation: f.secure) } } }
    try requireResponseStored(await f.publisher(owner, server: server).advance(invitation: f.secure), deviceID: f.pending.intent.deviceID)
    #expect(await server.storedOwnerResponseCount() == 1)
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.contains("/key-responses/") }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerPublisherExpiredPairingVetoesReadsAndWrites() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let owner = PublisherQAMemory(f), server = PairingQAServer(f, mode: .externalOwner)
    f.clock.advance(421)
    await #expect(throws: (any Error).self) { try await f.publisher(owner, server: server).advance(invitation: f.secure) }
    #expect(await server.snapshot().isEmpty)
}

@available(macOS 14.0, *)
@Test func ownerPublisherRejectsMobileAuthorityAndAnotherOwnersInvitationBeforeIO() async throws {
    let f = try PairingQAFixture(), other = try PairingQAFixture(); defer { f.cleanup(); other.cleanup() }
    let phone = try RelayDeviceConfiguration(baseURL: f.secure.enrollment.baseURL, identity: f.peer(f.pending), owner: f.owner(),
        signingKey: f.pending.intent.signingKey, accessToken: f.pending.intent.accessToken, encryptionKey: f.aes,
        preparedPacketsURL: f.directory.appendingPathComponent("phone.plist"))
    #expect(throws: (any Error).self) { try RelayOwnerKeyPublisher(ownerConfiguration: phone) }
    let server = PairingQAServer(f, mode: .externalOwner), owner = PublisherQAMemory(f)
    await #expect(throws: (any Error).self) { try await f.publisher(owner, server: server).advance(invitation: other.secure) }
    #expect(await server.snapshot().isEmpty)
}

#if os(iOS)
@Test func ownerAndMobileRealKeychainsCompleteTheTwoNativeCoordinatorLoop() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let base = f.secure.enrollment
    let ownerStore = RelayKeyDeliveryOwnerStore(service: "qa.owner-loop." + UUID().uuidString)
    let mobileStore = RelayEnrollmentKeychain(service: "qa.mobile-loop." + UUID().uuidString)
    let invitation = try ownerStore.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now())
    defer { try? ownerStore.remove(invitation); try? mobileStore.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let pending = try mobileStore.prepareSecure(invitation, now: f.clock.now()), server = PairingQAServer(f, mode: .ownerLostACK, pending: pending)
    func mobile() -> RelayPairingCoordinator { .init(keychain: mobileStore, baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID,
        role: base.role, preparedPacketsURL: f.directory.appendingPathComponent("mobile.plist"), requestTransport: { try await server.handle($0) }) }
    func owner() throws -> RelayOwnerKeyPublisher { try .init(ownerConfiguration: f.ownerConfiguration, store: ownerStore, requestTransport: { try await server.handle($0) }) }
    guard case .awaitingOwner = try await mobile().advance() else { Issue.record("did not wait for real publisher"); return }
    guard case .publicationUnconfirmed = try await owner().advance(invitation: invitation) else { Issue.record("lost receipt not uncertain"); return }
    let savedInvitation = try ownerStore.savedInvitation(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID,
        role: base.role, ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID)
    let recovered = try #require(savedInvitation)
    try requireResponseStored(await owner().advance(invitation: recovered), deviceID: pending.intent.deviceID)
    guard case .ready(let configuration) = try await mobile().advance() else { Issue.record("mobile did not save key"); return }
    #expect(configuration.encryptionKey == f.aes); #expect(configuration.identity.publicKey == pending.intent.signingKey.publicKey)
    #expect(await server.automaticReplyCount() == 0); #expect(await server.storedOwnerResponseCount() == 1)
}

@Test func ownerKeychainPublicationClaimIsMonotonicAcrossReconstructionAndConcurrency() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let service = "qa.owner-claim." + UUID().uuidString
    let store = RelayKeyDeliveryOwnerStore(service: service), invitation = try store.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now())
    defer { try? store.remove(invitation) }
    _ = try store.response(to: f.pending.keyRequest, invitation: invitation, recipient: f.peer(f.pending), owner: f.owner(), encryptionKey: f.aes, now: f.clock.now())
    let initialPublication = try store.publication(invitation: invitation, owner: f.owner(), now: f.clock.now())
    let publication = try #require(initialPublication)
    #expect(!publication.attempted)
    let results = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 { group.addTask { try RelayKeyDeliveryOwnerStore(service: service).claimPublication(publication,
            invitation: invitation, owner: f.owner(), now: f.clock.now()) } }
        var values: [Bool] = []; for try await value in group { values.append(value) }; return values
    }
    #expect(results.filter { $0 }.count == 1)
    let reloadedPublication = try RelayKeyDeliveryOwnerStore(service: service).publication(invitation: invitation, owner: f.owner(), now: f.clock.now())
    let reconstructed = try #require(reloadedPublication)
    #expect(reconstructed.attempted && reconstructed.response == publication.response && reconstructed.request == publication.request)
}

@Test func ownerSavedInvitationLookupIsExactScopedAndDoesNotGenerateAnotherOffer() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let base = f.secure.enrollment
    let store = RelayKeyDeliveryOwnerStore(service: "qa.owner-scope." + UUID().uuidString)
    let invitation = try store.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now()); defer { try? store.remove(invitation) }
    #expect(try store.savedInvitation(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role,
        ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID) == invitation)
    #expect(try store.savedInvitation(baseURL: URL(string: "https://different.example")!, roomID: base.roomID, keyID: base.keyID, role: base.role,
        ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID) == nil)
    #expect(throws: (any Error).self) { try store.savedInvitation(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: .watch,
        ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID) }
}

@Test func ownerOldPublicationWithoutAttemptFlagIsUncertainAndMissingRequestIsPreserved() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let service = "qa.owner-old." + UUID().uuidString
    let store = RelayKeyDeliveryOwnerStore(service: service), invitation = try store.prepare(f.offer, serverResponse: f.serverResponse, now: f.clock.now())
    defer { try? store.remove(invitation) }
    _ = try store.response(to: f.pending.keyRequest, invitation: invitation, recipient: f.peer(f.pending), owner: f.owner(), encryptionKey: f.aes, now: f.clock.now())
    let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
    func bytes() throws -> Data { var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess); return try #require(result as? Data) }
    var object = try JSONSerialization.jsonObject(with: bytes()) as! [String: Any]; object.removeValue(forKey: "publicationAttempted")
    var old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: old] as CFDictionary) == errSecSuccess)
    let loadedPublication = try store.publication(invitation: invitation, owner: f.owner(), now: f.clock.now())
    let publication = try #require(loadedPublication)
    #expect(publication.attempted); #expect(try !store.claimPublication(publication, invitation: invitation, owner: f.owner(), now: f.clock.now()))
    object.removeValue(forKey: "request"); old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(SecItemUpdate(key as CFDictionary, [kSecValueData as String: old] as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.publication(invitation: invitation, owner: f.owner(), now: f.clock.now()) }
    #expect(try bytes() == old)
}
#endif
