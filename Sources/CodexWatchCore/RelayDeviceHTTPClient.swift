import Foundation

/// Shared by encrypted transport and pre-key pairing. Every invocation freezes
/// one request body; only a proved same-origin nonce denial permits one retry.
/// This client never retries network errors/5xx or follows a redirect.
actor RelayDeviceHTTPClient {
    struct Reply: Sendable { let data: Data; let status: Int }
    private let baseURL: URL
    private let roomID: String
    private let keyID: String
    private let timeout: TimeInterval
    private let session: URLSession
    private let requestTransport: RemoteRelayClient.RequestTransport?
    private let clock: @Sendable () -> Date
    private var nonces: [String: String] = [:]

    init(baseURL: URL, roomID: String, keyID: String, requestTimeout: TimeInterval,
         waitsForConnectivity: Bool, requestTransport: RemoteRelayClient.RequestTransport?,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL; self.roomID = roomID; self.keyID = keyID
        timeout = max(1, requestTimeout.isFinite ? requestTimeout : 10)
        self.requestTransport = requestTransport; self.clock = clock
        #if os(watchOS)
        let config = RelayTransportPolicy.watchSessionConfiguration(timeout: timeout, waitsForConnectivity: waitsForConnectivity)
        #else
        _ = waitsForConnectivity
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        #endif
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }

    func send(_ original: URLRequest, signingKey: RelayDeviceSigningKey, accessToken: String,
              expiresAt: Date, maximumResponseBytes: Int = 4_100_000, fixedNonce: String? = nil) async throws -> Reply {
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        guard RelayCredentials.validIdentifier(roomID), keyID.count == 32,
              keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let url = original.url, url.fragment == nil,
              let normalized = URLComponents(string: try RelayDeviceSigningKey.targetURI(url)),
              let trusted = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              normalized.scheme == trusted.scheme, normalized.host == trusted.host, normalized.port == trusted.port,
              normalized.percentEncodedPath.hasPrefix("/v3/rooms/\(roomID)/"),
              normalized.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ RelayCredentials.validIdentifier(String($0)) }),
              ["GET", "POST", "PUT", "DELETE"].contains(original.httpMethod ?? "GET"),
              original.httpBodyStream == nil, (original.httpBody?.count ?? 0) <= 4_100_000,
              RelayDeviceEncoding.decodeBase64URL(accessToken)?.count == 32,
              maximumResponseBytes > 0, maximumResponseBytes <= 4_100_000,
              fixedNonce == nil || RelayDeviceEncoding.decodeBase64URL(fixedNonce!)?.count == 32 else {
            throw RelayDeviceTransportError.unsafeResponse
        }
        let scope = signingKey.publicKey.thumbprint + ":" + RelayDeviceSigningKey.accessTokenHash(accessToken)
        for attempt in 0..<(fixedNonce == nil ? 2 : 1) {
            try Task.checkCancellation()
            guard expiresAt > clock() else { throw RemoteRelayError.authenticationFailed }
            var request = original
            request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
            request.setValue(keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
            request.setValue(try signingKey.proof(for: request, accessToken: accessToken,
                nonce: fixedNonce ?? nonces[scope], now: clock()), forHTTPHeaderField: "DPoP")
            let data: Data, response: URLResponse
            if let requestTransport { (data, response) = try await requestTransport(request) }
            else { (data, response) = try await session.data(for: request, delegate: RelayNoRedirectDelegate.shared) }
            guard let http = response as? HTTPURLResponse, let responseURL = http.url,
                  try RelayDeviceSigningKey.targetURI(responseURL) == RelayDeviceSigningKey.targetURI(url),
                  URLComponents(url: responseURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                    == URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                  responseURL.fragment == nil,
                  http.value(forHTTPHeaderField: "X-Codex-Relay-Device-Protocol") == "3",
                  data.count <= max(256, maximumResponseBytes), expiresAt > clock() else {
                throw RelayDeviceTransportError.unsafeResponse
            }
            if http.statusCode == 401 {
                if fixedNonce == nil, attempt == 0, data.count <= 256,
                   let error = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   error == ["error": "use_dpop_nonce"],
                   http.value(forHTTPHeaderField: "WWW-Authenticate") == "DPoP error=\"use_dpop_nonce\"",
                   let value = http.value(forHTTPHeaderField: "DPoP-Nonce"),
                   RelayDeviceEncoding.decodeBase64URL(value)?.count == 32 {
                    nonces[scope] = value; continue
                }
                throw RemoteRelayError.authenticationFailed
            }
            guard (200..<300).contains(http.statusCode) else { throw RemoteRelayError.server(http.statusCode) }
            guard data.count <= maximumResponseBytes, http.statusCode != 204 || data.isEmpty else {
                throw RelayDeviceTransportError.unsafeResponse
            }
            return Reply(data: data, status: http.statusCode)
        }
        throw RemoteRelayError.authenticationFailed
    }
}
