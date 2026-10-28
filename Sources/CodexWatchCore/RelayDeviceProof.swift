import CryptoKit
import Foundation
import Security

public enum RelayDeviceRole: String, Codable, CaseIterable, Sendable { case mac, phone, watch }
public enum RelayDeviceProofError: Error { case invalidKey, invalidRequest, invalidToken, keychain(OSStatus) }

/// The public OKP JWK profile used by RFC 8037/9864. A public-key decoder must
/// reject private fields rather than silently discard them and appear safe.
public struct RelayDevicePublicKey: Codable, Equatable, Sendable {
    public let kty: String
    public let crv: String
    public let x: String
    private enum Keys: String, CodingKey { case kty, crv, x }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw RelayDeviceProofError.invalidKey }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation)
        kty = "OKP"; crv = "Ed25519"; x = RelayDeviceEncoding.base64URL(rawRepresentation)
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["kty", "crv", "x"] else { throw RelayDeviceProofError.invalidKey }
        let values = try decoder.container(keyedBy: Keys.self)
        guard try values.decode(String.self, forKey: .kty) == "OKP",
              try values.decode(String.self, forKey: .crv) == "Ed25519",
              let bytes = RelayDeviceEncoding.decodeBase64URL(try values.decode(String.self, forKey: .x)),
              bytes.count == 32 else { throw RelayDeviceProofError.invalidKey }
        try self.init(rawRepresentation: bytes)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(kty, forKey: .kty); try values.encode(crv, forKey: .crv); try values.encode(x, forKey: .x)
    }
    /// RFC 7638 hashes exactly these three public members, in lexicographic
    /// order. x is validated ASCII base64url, so no escaping ambiguity exists.
    public var thumbprint: String {
        let canonical = "{\"crv\":\"Ed25519\",\"kty\":\"OKP\",\"x\":\"\(x)\"}"
        return RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(canonical.utf8))))
    }
    public var rawRepresentation: Data { RelayDeviceEncoding.decodeBase64URL(x)! }
}

/// DPoP proof generation, not enrollment or device authentication by itself.
/// The server must bind this public key to an explicitly enrolled device and
/// access token; merely presenting a self-signed JWK does not grant access.
public struct RelayDeviceSigningKey: Sendable {
    private let key: Curve25519.Signing.PrivateKey
    public init() { key = .init() }
    public init(rawRepresentation: Data) throws { key = try .init(rawRepresentation: rawRepresentation) }
    public var publicKey: RelayDevicePublicKey { try! .init(rawRepresentation: key.publicKey.rawRepresentation) }
    // Internal storage codecs only; never part of a public/JWK/network API.
    var storageRepresentation: Data { key.rawRepresentation }
    // Internal only: typed message/proof profiles control domain separation.
    func signature(for bytes: Data) throws -> Data { try key.signature(for: bytes) }

    public func proof(for request: URLRequest, accessToken: String, nonce: String? = nil,
                      now: Date = Date(), requestID: UUID = UUID()) throws -> String {
        guard let url = request.url, let method = request.httpMethod,
              request.httpBodyStream == nil,
              ["GET", "POST", "PUT", "DELETE", "HEAD"].contains(method),
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 < 9_007_199_254_740_991,
              nonce == nil || nonce.map({ RelayDeviceEncoding.validASCII($0, maximum: 160) && !$0.isEmpty }) == true
        else { throw RelayDeviceProofError.invalidRequest }
        guard let bytes = RelayDeviceEncoding.decodeBase64URL(accessToken), bytes.count == 32 else {
            throw RelayDeviceProofError.invalidToken
        }
        struct Header: Encodable { let alg = "Ed25519"; let typ = "dpop+jwt"; let jwk: RelayDevicePublicKey }
        struct Claims: Encodable {
            let htm: String; let htu: String; let iat: Int64; let jti: String; let ath: String; let nonce: String?; let bodyHash: String?
            enum CodingKeys: String, CodingKey {
                case htm, htu, iat, jti, ath, nonce
                case bodyHash = "urn:codex-control:relay:v3:body-sha256"
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(Header(jwk: publicKey))
        let claims = try encoder.encode(Claims(htm: method, htu: Self.targetURI(url),
            iat: Int64(now.timeIntervalSince1970.rounded(.down)), jti: requestID.uuidString,
            ath: Self.accessTokenHash(accessToken), nonce: nonce,
            bodyHash: request.httpBody.map { RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: $0))) }))
        let signingInput = RelayDeviceEncoding.base64URL(header) + "." + RelayDeviceEncoding.base64URL(claims)
        return signingInput + "." + RelayDeviceEncoding.base64URL(try key.signature(for: Data(signingInput.utf8)))
    }

    /// RFC 9449 excludes query/fragment. Normalize scheme, host, default port
    /// and an empty path; no userinfo or insecure-HTTP exception is permitted.
    public static func targetURI(_ url: URL) throws -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty else { throw RelayDeviceProofError.invalidRequest }
        parts.scheme = "https"; parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        parts.query = nil; parts.fragment = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let result = parts.string else { throw RelayDeviceProofError.invalidRequest }
        return result
    }
    public static func accessTokenHash(_ token: String) -> String {
        RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(token.utf8))))
    }
}

enum RelayDeviceEncoding {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ value: String, maximumEncodedBytes: Int = 16_384) -> Data? {
        guard !value.isEmpty, value.utf8.count <= maximumEncodedBytes, validASCII(value, maximum: maximumEncodedBytes) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let result = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)),
              base64URL(result) == value else { return nil }
        return result
    }
    static func validASCII(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// An independent signing key, never the room encryption key or bearer token.
/// Raw Curve25519 keys are Keychain-protected, not claimed Secure-Enclave
/// non-extractable keys. After-first-unlock permits background synchronization;
/// approval-specific user presence remains a separate authorization gate.
public struct RelayDeviceIdentityKeychain: Sendable {
    public let service: String
    public init(service: String = "com.sunzizai.codexwatch.device-identity.v3") { self.service = service }
    private struct Stored: Codable { let version: Int; let key: Data; let thumbprint: String }
    public func load(roomID: String, role: RelayDeviceRole) throws -> RelayDeviceSigningKey? {
        var query = try baseQuery(roomID, role)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw RelayDeviceProofError.keychain(status) }
        let record = try JSONDecoder().decode(Stored.self, from: bytes)
        let key = try RelayDeviceSigningKey(rawRepresentation: record.key)
        guard record.version == 1, record.thumbprint == key.publicKey.thumbprint else { throw RelayDeviceProofError.invalidKey }
        return key
    }
    public func loadOrCreate(roomID: String, role: RelayDeviceRole) throws -> RelayDeviceSigningKey {
        if let existing = try load(roomID: roomID, role: role) { return existing }
        let key = RelayDeviceSigningKey()
        var insertion = try baseQuery(roomID, role)
        insertion[kSecValueData as String] = try JSONEncoder().encode(Stored(version: 1,
            key: key.storageRepresentation, thumbprint: key.publicKey.thumbprint))
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load(roomID: roomID, role: role) { return existing }
        guard status == errSecSuccess else { throw RelayDeviceProofError.keychain(status) }
        return key
    }
    public func remove(roomID: String, role: RelayDeviceRole) throws {
        let status = SecItemDelete(try baseQuery(roomID, role) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayDeviceProofError.keychain(status) }
    }
    private func baseQuery(_ room: String, _ role: RelayDeviceRole) throws -> [String: Any] {
        guard RelayCredentials.validIdentifier(room), !service.isEmpty, service.utf8.count <= 160 else { throw RelayDeviceProofError.invalidKey }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: room + ":" + role.rawValue, kSecAttrSynchronizable as String: false]
    }
}
