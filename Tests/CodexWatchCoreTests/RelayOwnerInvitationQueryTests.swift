import Foundation
import Testing
@testable import CodexWatchCore

/// A request-boundary fixture, not a production relay or persistent Keychain.
/// It never sends a creation POST or creates/replies to any dot message.
@available(macOS 14.0, *)
private actor OwnerInvitationQueryServer {
    enum Mode { case found, missing, unavailable, oldServer, wrongDigest, challengeExpiry, responseExpiry, nonce }
    let fixture: PairingQAFixture
    let mode: Mode
    private var requests: [URLRequest] = []
    init(_ fixture: PairingQAFixture, mode: Mode) { self.fixture = fixture; self.mode = mode }
    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let offer = fixture.offer.enrollment
        let configuration = try fixture.ownerConfiguration
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url!.path == "/v3/rooms/\(offer.roomID)/devices/invitations/\(offer.invitationID)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + configuration.accessToken)
        var headers = ["X-Codex-Relay-Device-Protocol": "3"], status = 200
        var bytes = Data()
        let proof = request.value(forHTTPHeaderField: "DPoP")!.split(separator: ".")
        let claims = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(String(proof[1]))!) as! [String: Any]
        if (mode == .nonce || mode == .challengeExpiry) && requests.count == 1 {
            if mode == .challengeExpiry { fixture.clock.advance(120) }
            status = 401; headers["DPoP-Nonce"] = RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32))
            headers["WWW-Authenticate"] = "DPoP error=\"use_dpop_nonce\""
            bytes = Data("{\"error\":\"use_dpop_nonce\"}".utf8)
        } else if mode == .missing { status = 204 }
        else if mode == .unavailable { status = 503; bytes = Data("{\"error\":\"device_relay_unavailable\"}".utf8) }
        else if mode == .oldServer { status = 400; bytes = Data("{\"error\":\"invalid_device_route\"}".utf8) }
        else {
            if mode == .nonce { #expect(claims["nonce"] as? String == RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32))) }
            var value = try JSONSerialization.jsonObject(with: fixture.serverResponse) as! [String: Any]
            value["createDigest"] = mode == .wrongDigest ? String(repeating: "A", count: 43) : offer.creationDigest
            bytes = try JSONSerialization.data(withJSONObject: value)
            if mode == .responseExpiry { fixture.clock.advance(120) }
        }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func captured() -> [URLRequest] { requests }
}

@available(macOS 14.0, *)
private func queryClient(_ fixture: PairingQAFixture, server: OwnerInvitationQueryServer,
                         identity: RelayPeerIdentity? = nil, signingKey: RelayDeviceSigningKey? = nil) throws -> RelayDeviceRegistryClient {
    let c = try fixture.ownerConfiguration
    let http = RelayDeviceHTTPClient(baseURL: c.baseURL, roomID: c.identity.roomID, keyID: c.identity.keyID,
        requestTimeout: 2, waitsForConnectivity: false, requestTransport: { try await server.handle($0) }, clock: { fixture.clock.now() })
    return .init(baseURL: c.baseURL, identity: identity ?? c.identity, signingKey: signingKey ?? c.signingKey,
        accessToken: c.accessToken, http: http, clock: { fixture.clock.now() })
}

@available(macOS 14.0, *)
@Test func ownerQueryUsesOriginalIDAndReturnsOnlyAnExactDigestBoundPublicInvitation() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let server = OwnerInvitationQueryServer(f, mode: .found)
    for _ in 0..<4 {
        let restored = try await queryClient(f, server: server).ownerInvitation(for: f.offer.enrollment)
        #expect(restored == f.secure.enrollment)
    }
    #expect(await server.captured().count == 4)
}

@available(macOS 14.0, *)
@Test func ownerQueryMissingIsAbsenceNotPermissionToCreateAndFailuresNeverPOST() async throws {
    for mode in [OwnerInvitationQueryServer.Mode.missing, .unavailable, .oldServer, .wrongDigest] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let server = OwnerInvitationQueryServer(f, mode: mode)
        if mode == .missing { #expect(try await queryClient(f, server: server).ownerInvitation(for: f.offer.enrollment) == nil) }
        else { await #expect(throws: (any Error).self) { try await queryClient(f, server: server).ownerInvitation(for: f.offer.enrollment) } }
        #expect(await server.captured().count == 1)
        #expect(await server.captured().allSatisfy { $0.httpMethod == "GET" })
    }
}

@available(macOS 14.0, *)
@Test func ownerQuerySharesStrictNonceHandlingAndStopsAtOriginalDeadline() async throws {
    for mode in [OwnerInvitationQueryServer.Mode.nonce, .challengeExpiry, .responseExpiry] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let server = OwnerInvitationQueryServer(f, mode: mode)
        if mode == .nonce { #expect(try await queryClient(f, server: server).ownerInvitation(for: f.offer.enrollment) == f.secure.enrollment) }
        else { await #expect(throws: (any Error).self) { try await queryClient(f, server: server).ownerInvitation(for: f.offer.enrollment) } }
        #expect(await server.captured().count == (mode == .nonce ? 2 : 1))
    }
}

@available(macOS 14.0, *)
@Test func ownerQueryRefusesWrongRoleOwnerScopeOrSigningKeyBeforeIO() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let server = OwnerInvitationQueryServer(f, mode: .found)
    await #expect(throws: (any Error).self) {
        try await queryClient(f, server: server, identity: f.peer(f.pending), signingKey: f.pending.intent.signingKey)
            .ownerInvitation(for: f.offer.enrollment)
    }
    await #expect(throws: (any Error).self) {
        try await queryClient(f, server: server, signingKey: RelayDeviceSigningKey()).ownerInvitation(for: f.offer.enrollment)
    }
    let other = try RelayEnrollmentOffer(baseURL: f.offer.enrollment.baseURL, roomID: "other-room", keyID: f.offer.enrollment.keyID,
        role: .phone, grantExpiresAt: f.offer.enrollment.grantExpiresAt, ownerID: f.offer.enrollment.ownerID,
        ownerKey: f.ownerKey, now: f.clock.now())
    await #expect(throws: (any Error).self) { try await queryClient(f, server: server).ownerInvitation(for: other) }
    #expect(await server.captured().isEmpty)
}
