import CryptoKit
import Foundation

/// The device ID is the fingerprint of its Ed25519 public key. The outer
/// transport HMAC covers this signature too; neither signature replaces it.
public enum DeviceApprovalSignature {
    public static func deviceID(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalBody(_ envelope: Data) throws -> Data {
        guard var body = try JSONSerialization.jsonObject(with: envelope) as? [String: Any] else {
            throw Failure.invalid
        }
        body.removeValue(forKey: "signature")
        body.removeValue(forKey: "deviceSignature")
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func verify(_ envelope: Data) throws -> (id: String, key: Data) {
        guard let body = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let id = body["clientId"] as? String,
              let encodedKey = body["devicePublicKey"] as? String,
              let key = Data(base64Encoded: encodedKey),
              let encodedSignature = body["deviceSignature"] as? String,
              let signature = Data(base64Encoded: encodedSignature),
              id == deviceID(publicKey: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              publicKey.isValidSignature(signature, for: try canonicalBody(envelope)) else {
            throw Failure.invalid
        }
        return (id, key)
    }

    public enum Failure: LocalizedError {
        case invalid
        public var errorDescription: String? {
            "I couldn’t verify this phone’s signature. Update the companion app and pair it on this Mac."
        }
    }
}
