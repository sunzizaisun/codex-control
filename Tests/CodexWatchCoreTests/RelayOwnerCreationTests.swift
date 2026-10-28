import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

enum OwnerCreationQAFailure: Error { case storage }

/// Memory persistence seam only. Separate iOS tests execute the actual
/// authoritative Keychain item; this is not durable-storage evidence.
@available(macOS 14.0, *)
final class OwnerCreationQAMemory: RelayOwnerCreationPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var material: Data?, exchange: Data?, attempted = false, qr: String?
    private var stageFailure = false, claimFailure = false, confirmFailure = false
    private var stageReturnClock: PairingQAClock?, confirmReturnClock: PairingQAClock?
    func loadCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64, now: Date) throws -> RelayOwnerCreationDraft? {
        lock.lock(); let exists = material != nil; lock.unlock()
        guard exists else { return nil }
        return try stageCreation(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
    }
    func stageCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64, now: Date) throws -> RelayOwnerCreationDraft {
        lock.lock(); defer { lock.unlock() }
        if stageFailure { throw OwnerCreationQAFailure.storage }
        if material == nil {
            let base = try RelayEnrollmentOffer(baseURL: configuration.baseURL, roomID: configuration.identity.roomID,
                keyID: configuration.identity.keyID, role: role, grantExpiresAt: grantExpiresAt,
                ownerID: configuration.identity.deviceID, ownerKey: configuration.signingKey, now: now)
            let secure = try RelaySecurePairingOffer(enrollment: base)
            let draft = RelayOwnerCreationDraft(offer: secure, attempted: false)
            try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
            material = try RelayEnrollmentInvitation.encoder().encode(RelayOwnerOfferMaterial(offer: secure)); exchange = secure.exchangeKey.rawRepresentation
        }
        let value = try JSONDecoder().decode(RelayOwnerOfferMaterial.self, from: material!)
        let draft = RelayOwnerCreationDraft(offer: try value.restore(signingKey: configuration.signingKey, exchangeKey: exchange!), attempted: attempted)
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
        stageReturnClock?.advance(120)
        return draft
    }
    func claimCreation(_ draft: RelayOwnerCreationDraft, configuration: RelayDeviceConfiguration, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimFailure { throw OwnerCreationQAFailure.storage }
        guard material == (try RelayEnrollmentInvitation.encoder().encode(RelayOwnerOfferMaterial(offer: draft.offer))) else { throw RelayKeyDeliveryError.identityConflict }
        guard !attempted else { return false }; attempted = true; return true
    }
    func confirmCreation(_ draft: RelayOwnerCreationDraft, serverResponse: Data, configuration: RelayDeviceConfiguration, now: Date) throws -> RelaySecurePairingInvitation {
        lock.lock(); defer { lock.unlock() }
        if confirmFailure { throw OwnerCreationQAFailure.storage }
        let value = try draft.offer.recoveredInvitation(from: serverResponse, now: now)
        let bytes = try value.qrPayload
        guard qr == nil || qr == bytes else { throw RelayKeyDeliveryError.identityConflict }
        qr = bytes; attempted = true; confirmReturnClock?.advance(120); return value
    }
    func isClaimed() -> Bool { lock.lock(); defer { lock.unlock() }; return attempted }
    func savedBytes() -> Data? { lock.lock(); defer { lock.unlock() }; return material }
    func failStage(_ value: Bool) { lock.lock(); defer { lock.unlock() }; stageFailure = value }
    func failClaim(_ value: Bool) { lock.lock(); defer { lock.unlock() }; claimFailure = value }
    func failConfirm(_ value: Bool) { lock.lock(); defer { lock.unlock() }; confirmFailure = value }
    func crossStageDeadline(_ clock: PairingQAClock) { lock.lock(); defer { lock.unlock() }; stageReturnClock = clock }
    func crossPromotionDeadline(_ clock: PairingQAClock) { lock.lock(); defer { lock.unlock() }; confirmReturnClock = clock }
}

/// Stores only the actual received creation bytes and public receipt. It
/// never receives HPKE PSK/exchange private key and never creates a dot reply.
@available(macOS 14.0, *)
actor OwnerCreationQAServer {
    enum Mode: Equatable { case normal, lostACK, absentAfterLostACK, rejected, malformedACK, oldServer,
        unavailableQuery, wrongDigest, consumed, expiresDuringQuery, expiresDuringChallenge, rotatedNonce, cancelled, wrongOwner }
    let fixture: PairingQAFixture
    let mode: Mode
    private var requests: [URLRequest] = [], original: Data?, invitation: [String: Any]?
    private var proofIDs: Set<String> = [], nonce = RelayDeviceEncoding.base64URL(Data(repeating: 35, count: 32)), rotated = false
    private let beforePost: @Sendable () throws -> Bool
    init(_ fixture: PairingQAFixture, mode: Mode = .normal, beforePost: @escaping @Sendable () throws -> Bool) {
        self.fixture = fixture; self.mode = mode; self.beforePost = beforePost
    }
    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let configuration = try fixture.ownerConfiguration, path = request.url!.path
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + configuration.accessToken)
        #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == configuration.identity.keyID)
        let parts = try #require(request.value(forHTTPHeaderField: "DPoP")).split(separator: ".").map(String.init)
        let claims = try #require(JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(parts[1])!) as? [String: Any])
        #expect(claims["htu"] as? String == (try RelayDeviceSigningKey.targetURI(request.url!)))
        #expect(claims["htm"] as? String == request.httpMethod)
        #expect(claims["ath"] as? String == RelayDeviceSigningKey.accessTokenHash(configuration.accessToken))
        #expect(proofIDs.insert(try #require(claims["jti"] as? String)).inserted)
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: fixture.ownerKey.publicKey.rawRepresentation)
            .isValidSignature(RelayDeviceEncoding.decodeBase64URL(parts[2])!, for: Data((parts[0] + "." + parts[1]).utf8)))
        if let body = request.httpBody { #expect(claims["urn:codex-control:relay:v3:body-sha256"] as? String == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: body)))) }
        let creating = path.hasSuffix("/devices/invitations")
        if creating { #expect(try beforePost()); #expect(request.httpMethod == "POST") }
        if creating && (mode == .rotatedNonce || mode == .expiresDuringChallenge) && !rotated {
            rotated = true; nonce = RelayDeviceEncoding.base64URL(Data(repeating: 36, count: 32))
            if mode == .expiresDuringChallenge { fixture.clock.advance(120) }
            return challenge(request)
        }
        if claims["nonce"] as? String != nonce { return challenge(request) }
        if path.hasSuffix("/devices/me") {
            let owner = try fixture.owner()
            return json(request, ["authorized": true, "grant": ["roomID": owner.roomID, "keyID": owner.keyID,
                "deviceID": owner.deviceID, "role": "mac", "expiresAt": Int64(owner.expiresAt.timeIntervalSince1970 * 1000),
                "jwk": ["kty": "OKP", "crv": "Ed25519", "x": mode == .wrongOwner ? RelayDeviceSigningKey().publicKey.x : owner.publicKey.x]]])
        }
        if creating {
            if mode == .rejected { return json(request, ["error": "unavailable"], status: 503) }
            let body = try #require(request.httpBody), fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(fields.keys) == ["invitationID", "role", "secretHash", "expiresAt", "grantExpiresAt"])
            #expect(original == nil || original == body)
            if mode == .absentAfterLostACK { throw URLError(.networkConnectionLost) }
            original = body
            invitation = ["invitationID": fields["invitationID"]!, "role": fields["role"]!, "nonce": nonce,
                "expiresAt": fields["expiresAt"]!, "grantExpiresAt": fields["grantExpiresAt"]!,
                "ownerID": configuration.identity.deviceID, "ownerThumbprint": configuration.identity.publicKey.thumbprint, "consumed": false]
            if mode == .lostACK { throw URLError(.networkConnectionLost) }
            if mode == .cancelled { throw CancellationError() }
            if mode == .malformedACK { return json(request, ["authorized": true, "invitation": [:]]) }
            return json(request, ["authorized": true, "invitation": invitation!])
        }
        #expect(path.contains("/devices/invitations/")); #expect(request.httpMethod == "GET" && request.httpBody == nil)
        if mode == .oldServer { return json(request, ["error": "invalid_device_route"], status: 400) }
        if mode == .unavailableQuery { return json(request, ["error": "unavailable"], status: 503) }
        if mode == .expiresDuringQuery { fixture.clock.advance(120) }
        guard let original, var invitation else { return raw(request, nil) }
        #expect(path.hasSuffix("/" + (invitation["invitationID"] as! String)))
        if mode == .consumed { invitation["consumed"] = true }
        return json(request, ["authorized": true, "invitation": invitation,
            "createDigest": mode == .wrongDigest ? "bad-digest" : RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: original)))])
    }
    private func challenge(_ request: URLRequest) -> (Data, URLResponse) {
        json(request, ["error": "use_dpop_nonce"], status: 401,
            headers: ["DPoP-Nonce": nonce, "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""])
    }
    private func json(_ request: URLRequest, _ value: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> (Data, URLResponse) {
        raw(request, try! JSONSerialization.data(withJSONObject: value), status: status, headers: headers)
    }
    private func raw(_ request: URLRequest, _ data: Data?, status: Int? = nil, headers: [String: String] = [:]) -> (Data, URLResponse) {
        var headers = headers; headers["X-Codex-Relay-Device-Protocol"] = "3"
        return (data ?? Data(), HTTPURLResponse(url: request.url!, statusCode: status ?? (data == nil ? 204 : 200), httpVersion: nil, headerFields: headers)!)
    }
    func captured() -> [URLRequest] { requests }
}

@available(macOS 14.0, *)
func creationQAClient(_ f: PairingQAFixture, store: any RelayOwnerCreationPersistence, server: OwnerCreationQAServer) throws -> RelayOwnerPairingCreator {
    let c = try f.ownerConfiguration
    let http = RelayDeviceHTTPClient(baseURL: c.baseURL, roomID: c.identity.roomID, keyID: c.identity.keyID,
        requestTimeout: 2, waitsForConnectivity: false, requestTransport: { try await server.handle($0) }, clock: { f.clock.now() })
    return .init(configuration: c, store: store, http: http, clock: { f.clock.now() })
}

func creationQAInvitation(_ update: RelayOwnerPairingUpdate) throws -> RelaySecurePairingInvitation {
    guard case .invitationSaved(let invitation) = update else { Issue.record("creation not confirmed saved"); throw RelayKeyDeliveryError.notReady }
    return invitation
}

@available(macOS 14.0, *)
@Test func ownerCreationMaterialRestoresExactBodyDeadlineAndIndependentHPKEKeysWithoutRootSecrets() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let material = RelayOwnerOfferMaterial(offer: f.offer)
    let bytes = try RelayEnrollmentInvitation.encoder().encode(material), value = try JSONDecoder().decode(RelayOwnerOfferMaterial.self, from: bytes)
    let restored = try value.restore(signingKey: f.ownerKey, exchangeKey: f.offer.exchangeKey.rawRepresentation)
    #expect(restored.enrollment.creationBody == f.offer.enrollment.creationBody)
    #expect(restored.enrollment.secret == f.offer.enrollment.secret && restored.pairingSecret == f.offer.pairingSecret)
    #expect(restored.exchangeKey.rawRepresentation == f.offer.exchangeKey.rawRepresentation)
    #expect(try restored.invitation(from: f.serverResponse, now: f.clock.now()) == f.secure)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains(f.ownerKey.storageRepresentation.base64EncodedString()))
    #expect(!text.contains(try f.ownerConfiguration.accessToken))
    #expect(!text.contains(f.aes.base64EncodedString()))
    #expect(!String(reflecting: material).contains(material.secret))
    #expect(throws: (any Error).self) { try value.restore(signingKey: RelayDeviceSigningKey(), exchangeKey: f.offer.exchangeKey.rawRepresentation) }
    #expect(throws: (any Error).self) { try restored.enrollment.request(accessToken: f.ownerConfiguration.accessToken, now: f.clock.now().addingTimeInterval(120)) }
}

@available(macOS 14.0, *)
@Test func ownerCreationQuerySelectsPlatformProtectedNonICloudStorage() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let c = try f.ownerConfiguration
    let query = try RelayKeyDeliveryOwnerStore(service: "qa.query-only").roleQuery(baseURL: c.baseURL,
        roomID: c.identity.roomID, keyID: c.identity.keyID, role: .phone, ownerID: c.identity.deviceID, ownerKey: c.identity.publicKey)
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #if os(macOS)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #else
    #expect(query[kSecUseDataProtectionKeychain as String] == nil)
    #endif
}

@available(macOS 14.0, *)
@Test func ownerCreationMaterialRejectsChangedBodyDigestDeadlineAndAliasedExchangeKey() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let material = RelayOwnerOfferMaterial(offer: f.offer)
    let bytes = try RelayEnrollmentInvitation.encoder().encode(material)
    let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    for (field, value) in [("creationDigest", "wrong" as Any), ("expiresAt", material.expiresAt + 1),
        ("creationBody", Data("{}".utf8).base64EncodedString()), ("role", "mac"), ("baseURL", "https://relay.example/path")] {
        var changed = original; changed[field] = value
        let decoded = try JSONDecoder().decode(RelayOwnerOfferMaterial.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: (any Error).self) { try decoded.restore(signingKey: f.ownerKey, exchangeKey: f.offer.exchangeKey.rawRepresentation) }
    }
    #expect(throws: (any Error).self) { try material.restore(signingKey: f.ownerKey, exchangeKey: material.pairingSecret) }
}

@available(macOS 14.0, *)
@Test func ownerCreationRejectsPublicOrPrivateSigningBytesAsEnrollmentCapability() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let configuration = try f.ownerConfiguration
    let material = RelayOwnerOfferMaterial(offer: f.offer)
    let encoded = try RelayEnrollmentInvitation.encoder().encode(material)
    for forbidden in [f.ownerKey.publicKey.rawRepresentation, f.ownerKey.storageRepresentation] {
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let secret = RelayDeviceEncoding.base64URL(forbidden), body = try RelayEnrollmentOffer.creationBytes(invitationID: material.invitationID,
            role: material.role, secret: secret, expiresAt: material.expiresAt, grantExpiresAt: material.grantExpiresAt)
        object["secret"] = secret; object["creationBody"] = body.base64EncodedString()
        object["creationDigest"] = RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: body)))
        let changed = try JSONDecoder().decode(RelayOwnerOfferMaterial.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) {
            let restored = try changed.restore(signingKey: f.ownerKey, exchangeKey: f.offer.exchangeKey.rawRepresentation)
            try RelayOwnerCreationDraft(offer: restored, attempted: false).validate(configuration: configuration,
                role: material.role, grantExpiresAt: material.grantExpiresAt, now: f.clock.now())
        }
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationChangedExchangePrivateKeyCannotRewriteStagedIdentity() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let material = RelayOwnerOfferMaterial(offer: f.offer)
    #expect(throws: (any Error).self) { try material.restore(signingKey: f.ownerKey,
        exchangeKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation) }
}

@available(macOS 14.0, *)
@Test func ownerCreationRecoveryWithMissingDraftMustNotGenerateNewAuthorizationOrUseNetwork() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() })
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.savedBytes() == nil)
    #expect(await server.captured().isEmpty)
}

@available(macOS 14.0, *)
@Test func ownerCreationPersistsBeforeIOConfirmsByQueryAndReconstructsWithoutAnotherPOST() async throws {
    for role in [RelayDeviceRole.phone, .watch] {
        let f = try PairingQAFixture(role: role); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() })
        let first = try creationQAInvitation(await creationQAClient(f, store: store, server: server).begin(role: role, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
        for _ in 0..<4 {
            let next = try creationQAInvitation(await creationQAClient(f, store: store, server: server).advance(role: role, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
            #expect(next == first)
        }
        let requests = await server.captured()
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(requests.first!.url!.path.hasSuffix("/devices/me"))
        #expect(requests.filter { $0.url!.path.contains("/devices/invitations/") }.count >= 6)
        #expect(store.savedBytes() != nil)
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationLostOrMalformedACKRecoversOnlyTheSameIDAndOriginalKeys() async throws {
    for mode in [OwnerCreationQAServer.Mode.lostACK, .malformedACK] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, mode: mode, beforePost: { store.isClaimed() })
        guard case .creationUnconfirmed(let id) = try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) else { Issue.record("lost ACK not uncertain"); return }
        let saved = store.savedBytes()
        let recovered = try creationQAInvitation(await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
        #expect(recovered.enrollment.invitationID == id); #expect(store.savedBytes() == saved)
        #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationMissingOrRejectedAfterAttemptNeverResubmitsOrReplacesTheOffer() async throws {
    for mode in [OwnerCreationQAServer.Mode.absentAfterLostACK, .rejected] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, mode: mode, beforePost: { store.isClaimed() }); var IDs: [String] = []
        for round in 0..<4 {
            let client = try creationQAClient(f, store: store, server: server)
            let update = try await (round == 0 ? client.begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt)
                : client.advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
            guard case .creationUnconfirmed(let id) = update else { Issue.record("uncertainty was reset"); return }
            IDs.append(id)
        }
        #expect(Set(IDs).count == 1); #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationPreflightFailureOrWrongOwnerCannotMintAnInvitation() async throws {
    for mode in [OwnerCreationQAServer.Mode.oldServer, .unavailableQuery, .wrongOwner, .expiresDuringQuery] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, mode: mode, beforePost: { store.isClaimed() })
        await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
        #expect(!store.isClaimed()); #expect(await server.captured().allSatisfy { $0.httpMethod == "GET" })
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationStorageFailuresVetoIOOrPOSTAndFailedPromotionCannotClaimSaved() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() }); store.failStage(true)
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(await server.captured().isEmpty)
    store.failStage(false); store.failClaim(true)
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(await server.captured().allSatisfy { $0.httpMethod == "GET" })
    store.failClaim(false); store.failConfirm(true)
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.isClaimed()); store.failConfirm(false)
    _ = try creationQAInvitation(await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt))
    #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerCreationStageReturningAfterDeadlineStopsBeforeAnyIOWithoutReplacingSavedMaterial() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    store.crossStageDeadline(f.clock)
    let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() })
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    let original = try #require(store.savedBytes())
    #expect(await server.captured().isEmpty && !store.isClaimed())
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.savedBytes() == original)
}

@available(macOS 14.0, *)
@Test func ownerCreationPromotionReturningAfterDeadlineCannotExposeExpiredQRCodeOrRepost() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    store.crossPromotionDeadline(f.clock)
    let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() })
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.isClaimed()); let original = store.savedBytes()
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.savedBytes() == original); #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerCreationExplicitNonceRetryKeepsBodyButExpiryChallengeStopsBeforeRetry() async throws {
    for mode in [OwnerCreationQAServer.Mode.rotatedNonce, .expiresDuringChallenge] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, mode: mode, beforePost: { store.isClaimed() })
        let update = try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt)
        let posts = await server.captured().filter { $0.httpMethod == "POST" }
        if mode == .rotatedNonce {
            _ = try creationQAInvitation(update); #expect(posts.count == 2)
            #expect(posts[0].httpBody == posts[1].httpBody); #expect(posts[0].value(forHTTPHeaderField: "DPoP") != posts[1].value(forHTTPHeaderField: "DPoP"))
        } else {
            guard case .creationUnconfirmed = update else { Issue.record("expired request was confirmed"); return }
            #expect(posts.count == 1)
        }
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationWrongDigestOrConsumedResultNeverShowsOrRecreatesQRCode() async throws {
    for mode in [OwnerCreationQAServer.Mode.wrongDigest, .consumed] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
        let server = OwnerCreationQAServer(f, mode: mode, beforePost: { store.isClaimed() })
        guard case .creationUnconfirmed = try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) else { Issue.record("bad recovery result shown"); return }
        await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
        #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }
}

@available(macOS 14.0, *)
@Test func ownerCreationCancellationKeepsClaimAndExpiredRestorationCannotRenew() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    let server = OwnerCreationQAServer(f, mode: .cancelled, beforePost: { store.isClaimed() })
    await #expect(throws: CancellationError.self) { try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.isClaimed()); let original = store.savedBytes(); f.clock.advance(120)
    await #expect(throws: (any Error).self) { try await creationQAClient(f, store: store, server: server).advance(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt) }
    #expect(store.savedBytes() == original); #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
}

@available(macOS 14.0, *)
@Test func ownerCreationConcurrentCoordinatorsShareOneOriginalAndOneMutationClaim() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = OwnerCreationQAMemory()
    let server = OwnerCreationQAServer(f, beforePost: { store.isClaimed() })
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<16 { group.addTask {
            let update = try await creationQAClient(f, store: store, server: server).begin(role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt)
            switch update { case .invitationSaved(let v): return v.enrollment.invitationID; case .creationUnconfirmed(let id): return id }
        } }
        var result: [String] = []; for try await value in group { result.append(value) }; return result
    }
    #expect(Set(ids).count == 1); #expect(await server.captured().filter { $0.httpMethod == "POST" }.count == 1)
}
