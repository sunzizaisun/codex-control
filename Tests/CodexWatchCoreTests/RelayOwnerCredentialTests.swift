import CryptoKit
import Foundation
import Testing
@testable import CodexWatchCore

private let ownerQAOrigin = URL(string: "https://owner-qa.invalid")!
private let ownerQANow = Date(timeIntervalSince1970: 1_790_000_000)
private let ownerQAExpiry: Int64 = 1_790_003_600_000
private func ownerQACredentials() throws -> RelayOwnerCredentials {
    try .create(baseURL: ownerQAOrigin, roomID: "qa-owner-room", deviceID: "qa-owner",
        expiresAtMilliseconds: ownerQAExpiry, encryptionKey: nil, now: ownerQANow)
}
private func ownerQAEncode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

@Test func ownerCredentialsPublicExportMatchesOnlyExistingRegistryFieldsWithoutPrivateBytes() throws {
    let value = try ownerQACredentials(), bytes = try value.storedData()
    let privateValue = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let exported = try value.serverRegistrationData(now: ownerQANow)
    let rows = try JSONSerialization.jsonObject(with: exported) as! [[String: Any]]
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(Set(row.keys) == ["roomID", "keyID", "deviceID", "role", "tokenHash", "jwk", "expiresAt"])
    #expect(row["role"] as? String == "mac" && row["deviceID"] as? String == value.deviceID)
    #expect(row["tokenHash"] as? String == RelayDeviceSigningKey.accessTokenHash(privateValue["accessToken"] as! String))
    #expect(Set((row["jwk"] as! [String: Any]).keys) == ["kty", "crv", "x"])
    let text = String(decoding: exported, as: UTF8.self)
    for field in ["accessToken", "signingKey", "encryptionKey"] {
        #expect(!text.contains(privateValue[field] as! String))
    }
    #expect(value.debugDescription.contains("<redacted>") && value.debugDescription.contains("unverified"))
}

@Test func ownerCredentialsRestoreExactlyPreservesPrivateMaterialPublicPinAndAbsoluteLifetime() throws {
    let value = try ownerQACredentials(), bytes = try value.storedData()
    let restored = try RelayOwnerCredentials(storedData: bytes, expectedBaseURL: ownerQAOrigin, roomID: value.roomID)
    #expect(try restored.storedData() == bytes)
    #expect(try restored.serverRegistrationData(now: ownerQANow) == value.serverRegistrationData(now: ownerQANow))
    #expect(restored.createdAt == value.createdAt && restored.expiresAt == value.expiresAt)
    let configuration = try restored.configuration(preparedPacketsURL: URL(fileURLWithPath: "/private/tmp/qa-unused-owner-journal"), now: ownerQANow)
    #expect(configuration.identity == configuration.owner && configuration.identity.role == .mac)
    #expect(configuration.identity.publicKey == value.publicKey && configuration.identity.keyID == value.keyID)
    #expect(configuration.encryptionKey == value.encryptionKey)
    #expect(Set([configuration.signingKey.storageRepresentation, configuration.signingKey.publicKey.rawRepresentation,
        configuration.encryptionKey, RelayDeviceEncoding.decodeBase64URL(configuration.accessToken)!]).count == 4)
}

@Test func ownerCredentialsRejectOtherOriginRoomAndInsecureEndpoints() throws {
    let value = try ownerQACredentials(), bytes = try value.storedData()
    #expect(throws: (any Error).self) { try RelayOwnerCredentials(storedData: bytes,
        expectedBaseURL: URL(string: "https://other.invalid")!, roomID: value.roomID) }
    #expect(throws: (any Error).self) { try RelayOwnerCredentials(storedData: bytes, expectedBaseURL: ownerQAOrigin, roomID: "other") }
    for url in ["http://owner-qa.invalid", "https://user:password@owner-qa.invalid", "https://owner-qa.invalid/path"] {
        #expect(throws: (any Error).self) { try RelayOwnerCredentials.create(baseURL: URL(string: url)!, roomID: value.roomID,
            deviceID: value.deviceID, expiresAtMilliseconds: value.expiresAtMilliseconds, encryptionKey: nil, now: ownerQANow) }
    }
}

@Test func ownerCredentialsRejectUnknownDuplicateOrNoncanonicalStorageWithoutIgnoringPrivateFields() throws {
    let value = try ownerQACredentials(), bytes = try value.storedData()
    var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    object["unexpectedPrivateField"] = "must-not-be-ignored"
    #expect(throws: (any Error).self) { try RelayOwnerCredentials(storedData: ownerQAEncode(object), expectedBaseURL: ownerQAOrigin, roomID: value.roomID) }
    let duplicate = Data((String(decoding: bytes.dropLast(), as: UTF8.self) + ",\"role\":\"mac\"}").utf8)
    for input in [Data(" ".utf8) + bytes, duplicate, Data(repeating: 32, count: 8_193)] {
        #expect(throws: (any Error).self) { try RelayOwnerCredentials(storedData: input, expectedBaseURL: ownerQAOrigin, roomID: value.roomID) }
    }
}

@Test func ownerCredentialsRejectKeyAliasWrongPinChangedEpochRoleVersionAndInvalidLifetime() throws {
    let value = try ownerQACredentials(), original = try JSONSerialization.jsonObject(with: value.storedData()) as! [String: Any]
    for mutation in 0..<8 {
        var object = original
        switch mutation {
        case 0: object["accessToken"] = RelayDeviceEncoding.base64URL(Data(base64Encoded: original["encryptionKey"] as! String)!)
        case 1: object["encryptionKey"] = original["signingKey"]
        case 2: object["publicKey"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RelayDeviceSigningKey().publicKey))
        case 3: object["keyID"] = String(repeating: "0", count: 32)
        case 4: object["role"] = "phone"
        case 5: object["version"] = 2
        case 6: object["expiresAt"] = object["createdAt"]
        default: object["createdAt"] = -1
        }
        #expect(throws: (any Error).self) { try RelayOwnerCredentials(storedData: ownerQAEncode(object), expectedBaseURL: ownerQAOrigin, roomID: value.roomID) }
    }
}

@Test func ownerCredentialsCannotUseOrExportAnExpiredOriginalAndDoNotRenewIt() throws {
    let value = try ownerQACredentials(), bytes = try value.storedData()
    let restored = try RelayOwnerCredentials(storedData: bytes, expectedBaseURL: ownerQAOrigin, roomID: value.roomID)
    #expect(throws: (any Error).self) { try restored.serverRegistrationData(now: value.expiresAt) }
    #expect(throws: (any Error).self) { try restored.configuration(preparedPacketsURL: URL(fileURLWithPath: "/private/tmp/qa-unused-owner-journal"), now: value.expiresAt) }
    #expect(throws: (any Error).self) { try restored.requireLive(now: ownerQANow.addingTimeInterval(-61)) }
    #expect(try restored.storedData() == bytes)
}

@Test func ownerCredentialsExplicitEncryptionMigrationNeverReusesBearerOrSigningMaterial() throws {
    let encryption = Data(repeating: 9, count: 32)
    let value = try RelayOwnerCredentials.create(baseURL: ownerQAOrigin, roomID: "qa-room", deviceID: "qa-owner",
        expiresAtMilliseconds: ownerQAExpiry, encryptionKey: encryption, now: ownerQANow)
    #expect(value.encryptionKey == encryption && value.keyID == RelayKeyDeliveryDevice.keyID(encryption))
    #expect(value.matches(deviceID: value.deviceID, expiresAtMilliseconds: value.expiresAtMilliseconds, encryptionKey: encryption))
    #expect(!value.matches(deviceID: "different", expiresAtMilliseconds: value.expiresAtMilliseconds, encryptionKey: nil))
    #expect(!value.matches(deviceID: value.deviceID, expiresAtMilliseconds: value.expiresAtMilliseconds + 1, encryptionKey: nil))
    #expect(!value.matches(deviceID: value.deviceID, expiresAtMilliseconds: value.expiresAtMilliseconds, encryptionKey: Data(repeating: 10, count: 32)))
}

@Test func ownerCredentialsInvalidNewInputsNeverBecomeUsableMaterial() throws {
    for (room, device, expiry, key) in [("bad room", "qa-owner", ownerQAExpiry, Data(repeating: 9, count: 32)),
        ("qa-room", "bad owner", ownerQAExpiry, Data(repeating: 9, count: 32)),
        ("qa-room", "qa-owner", Int64(ownerQANow.timeIntervalSince1970 * 1000), Data(repeating: 9, count: 32)),
        ("qa-room", "qa-owner", ownerQAExpiry, Data(repeating: 9, count: 31))] {
        #expect(throws: (any Error).self) { try RelayOwnerCredentials.create(baseURL: ownerQAOrigin, roomID: room,
            deviceID: device, expiresAtMilliseconds: expiry, encryptionKey: key, now: ownerQANow) }
    }
}

@Test func ownerCredentialsKeepIntegerExpiryExactAcrossSubsecondRestoreAndRefuseOneMillisecondRenewal() throws {
    for offset in 0..<16 {
        let expiry = ownerQAExpiry + Int64(offset)
        let value = try RelayOwnerCredentials.create(baseURL: ownerQAOrigin, roomID: "qa-room", deviceID: "qa-owner",
            expiresAtMilliseconds: expiry, encryptionKey: nil, now: ownerQANow)
        let restored = try RelayOwnerCredentials(storedData: value.storedData(), expectedBaseURL: ownerQAOrigin, roomID: value.roomID)
        #expect(restored.expiresAtMilliseconds == expiry)
        #expect(restored.matches(deviceID: value.deviceID, expiresAtMilliseconds: expiry, encryptionKey: nil))
        #expect(!restored.matches(deviceID: value.deviceID, expiresAtMilliseconds: expiry + 1, encryptionKey: nil))
        #expect(throws: (any Error).self) { try restored.requireLive(now: restored.expiresAt) }
    }
}

@Test func ownerCredentialsPublicExportAndProofCanBeIndependentlyVerifiedWithoutExportingSecrets() throws {
    let value = try ownerQACredentials(), configuration = try value.configuration(
        preparedPacketsURL: URL(fileURLWithPath: "/private/tmp/qa-unused-owner-journal"), now: ownerQANow)
    var request = URLRequest(url: ownerQAOrigin.appendingPathComponent("v3/rooms/qa-owner-room/devices/me")); request.httpMethod = "GET"
    let proof = try configuration.signingKey.proof(for: request, accessToken: configuration.accessToken, now: ownerQANow)
    if let filename = ProcessInfo.processInfo.environment["CODEX_OWNER_REGISTRY_QA_OUTPUT"] {
        guard filename.hasPrefix("/private/tmp/owner-credentials-qa."), filename.hasSuffix("/owner-public-interop.json") else {
            Issue.record("unsafe public fixture output scope"); return
        }
        let record = try JSONSerialization.jsonObject(with: value.serverRegistrationData(now: ownerQANow))
        let data = try JSONSerialization.data(withJSONObject: ["registry": record, "proof": proof,
            "url": request.url!.absoluteString, "method": "GET", "nowSeconds": Int64(ownerQANow.timeIntervalSince1970)], options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: filename), options: .atomic)
    }
}
