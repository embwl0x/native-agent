import CryptoKit
import Foundation

/// Wire contract mirrored by the phone. Only call open after transport and
/// paired-device signature verification. Never put decrypted fields in receipts.
enum SecretActionEnvelope {
    static let field = "sealed_payload"
    private static let label = "NativeAgent.iCloud.secret-action.v1"

    static func open(_ encoded: String, secret: Data, actionID: String, actionName: String) throws -> [String: String] {
        guard secret.count == 32, encoded.utf8.count <= 24_000,
              let combined = Data(base64Encoded: encoded) else { throw Failure.invalid }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: Data(label.utf8),
            info: Data("\(label).aes-256-gcm".utf8), outputByteCount: 32
        )
        let aad = try JSONEncoder().encode([label, actionID, actionName])
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
        return try JSONDecoder().decode([String: String].self, from: plaintext)
    }

    private enum Failure: Error { case invalid }
}
