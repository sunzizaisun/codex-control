import Foundation

/// Reject ambiguous or expired pairing codes without trusting arbitrary QR
/// query parameters. The QR never grants access by itself; Mac verifies it.
public struct PairingQRCodePayload: Equatable, Sendable {
    public enum Failure: Error { case invalid, expired }
    public let code: String
    public let macName: String?

    public static func parse(_ payload: String, now: Date = Date()) throws -> Self {
        guard let components = URLComponents(string: payload),
              components.scheme == "codexcontrol", components.host == "pair" else { throw Failure.invalid }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values[item.name] == nil else { throw Failure.invalid }
            values[item.name] = value
        }
        guard let code = values["code"], code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) }),
              let expiryText = values["expires"], let expiry = TimeInterval(expiryText), expiry.isFinite else { throw Failure.invalid }
        guard now < Date(timeIntervalSince1970: expiry) else { throw Failure.expired }
        return Self(code: code, macName: values["mac"].flatMap { $0.isEmpty ? nil : $0 })
    }
}
