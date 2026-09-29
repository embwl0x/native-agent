import CryptoKit
import Foundation

/// Wire contract mirrored by the Mac. Seal before handing an action to any
/// transport, pending-action store, signature, or transaction ledger.
enum SecretActionEnvelope {
    static let field = "sealed_payload"
    private static let label = "NativeAgent.iCloud.secret-action.v1"

    static func seal(_ fields: [String: String], secret: Data, actionID: String, actionName: String) throws -> String {
        let plaintext = try JSONEncoder().encode(fields)
        guard secret.count == 32, plaintext.count <= 16_000 else { throw Failure.invalid }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: Data(label.utf8),
            info: Data("\(label).aes-256-gcm".utf8), outputByteCount: 32
        )
        let aad = try JSONEncoder().encode([label, actionID, actionName])
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw Failure.invalid }
        return combined.base64EncodedString()
    }

    private enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Could not encrypt the credential. Check pairing and try again." }
    }
}
