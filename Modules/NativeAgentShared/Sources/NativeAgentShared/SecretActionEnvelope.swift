import CryptoKit
import Foundation
// Blueprint: | `SecretActionEnvelope.swift` | `SecretActionEnvelope`: shared seal/open wire contract for authenticated secret actions |

/// Seal before persistence or transport. Only call open after transport and
/// paired-device signature verification. Never put decrypted fields in receipts.
public enum SecretActionEnvelope {
    public static let field = "sealed_payload"
    private static let label = "NativeAgent.iCloud.secret-action.v1"

    public static func seal(_ fields: [String: String], secret: Data, actionID: String, actionName: String) throws -> String {
        let plaintext = try JSONEncoder().encode(fields)
        guard secret.count == 32, plaintext.count <= 16_000 else { throw Failure.invalid }
        let (key, aad) = try material(secret: secret, actionID: actionID, actionName: actionName)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw Failure.invalid }
        return combined.base64EncodedString()
    }

    public static func open(_ encoded: String, secret: Data, actionID: String, actionName: String) throws -> [String: String] {
        guard secret.count == 32, encoded.utf8.count <= 24_000,
              let combined = Data(base64Encoded: encoded) else { throw Failure.invalid }
        let (key, aad) = try material(secret: secret, actionID: actionID, actionName: actionName)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
        return try JSONDecoder().decode([String: String].self, from: plaintext)
    }

    private static func material(secret: Data, actionID: String, actionName: String) throws -> (SymmetricKey, Data) {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: Data(label.utf8),
            info: Data("\(label).aes-256-gcm".utf8), outputByteCount: 32
        )
        return (key, try JSONEncoder().encode([label, actionID, actionName]))
    }

    private enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Could not encrypt the credential. Check pairing and try again." }
    }
}
