// BridgeMessage.swift — shared wire format for iCloud chat channel
// Phase 14e-iCloud: HMAC-SHA256 signing.
// Moved from Mac Sources/NativeAgentApp/iCloudBridge.swift and
// iOS iOS/NativeAgentMobile/Sources/iCloudBridge.swift — both sides
// were byte-identical in logic (comments only differed).
import Foundation
import CryptoKit

// MARK: - Message model (shared wire format for outbox JSON files)

public struct BridgeMessage: Codable, Identifiable, Sendable {
    public let id: String           // UUID string
    public let sender: String       // "mac" | "ios"
    public let timestamp: Date
    public let text: String
    public let sessionID: String?
    /// Reply correlation. Mac replies set this to the original iOS message id
    /// so iOS updates the correct pending bubble even when replies arrive late
    /// or out of order.
    public let correlationID: String?
    /// Optional small string metadata for the remote surface. This is kept
    /// intentionally tiny so chat can carry controls without turning the
    /// iCloud message into a general-purpose config blob.
    public let metadata: [String: String]?
    /// Optional multimodal attachments for the chat turn. Used by the iOS
    /// companion to send camera-roll images through iCloud to the Mac daemon.
    public let attachments: [MultimodalAttachment]?
    /// Phase 14e-iCloud: HMAC-SHA256 (lowercase hex) over canonical JSON body
    /// (keys sorted, "signature" key excluded). Optional for backward-compat
    /// with older builds; receivers may reject unsigned messages once both sides
    /// are upgraded.
    public var signature: String?

    public static func make(
        id: String = UUID().uuidString,
        sender: String,
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [MultimodalAttachment]? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            id: id,
            sender: sender,
            timestamp: Date(),
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments,
            signature: nil
        )
    }

    /// Canonical JSON body used for HMAC computation: keys sorted, signature
    /// excluded. Identical on both Mac and iOS sides.
    public func canonicalBodyForSigning() throws -> Data {
        var body: [String: Any] = [
            "id":        id,
            "sender":    sender,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "text":      text,
        ]
        if let sessionID { body["sessionID"] = sessionID }
        if let correlationID { body["correlationID"] = correlationID }
        if let metadata, !metadata.isEmpty { body["metadata"] = metadata }
        if let attachments, !attachments.isEmpty {
            body["attachments"] = attachments.map { attachment in
                var item: [String: Any] = [
                    "id": attachment.id,
                    "type": attachment.type,
                    "base64": attachment.base64,
                    "mime": attachment.mime,
                    "byteSize": attachment.byteSize,
                ]
                if let name = attachment.name, !name.isEmpty {
                    item["name"] = name
                }
                if let path = attachment.path, !path.isEmpty {
                    item["path"] = path
                }
                return item
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Compute HMAC over canonical body using `secret`. Returns lowercase hex.
    public static func hmacHex(of canonical: Data, secret: Data) -> String {
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a copy of self with `signature` populated.
    public func signed(with secret: Data) throws -> BridgeMessage {
        let canonical = try canonicalBodyForSigning()
        var out = self
        out.signature = Self.hmacHex(of: canonical, secret: secret)
        return out
    }

    /// Verify that the embedded signature matches an HMAC computed from this
    /// message's canonical body. Returns false if the signature is missing
    /// or doesn't match (constant-time comparison).
    public func verifySignature(secret: Data) -> Bool {
        guard let sig = signature else { return false }
        do {
            let canonical = try canonicalBodyForSigning()
            let expected = Self.hmacHex(of: canonical, secret: secret)
            let a = Array(sig.utf8), b = Array(expected.utf8)
            guard a.count == b.count else { return false }
            var diff: UInt8 = 0
            for i in 0..<a.count { diff |= a[i] ^ b[i] }
            return diff == 0
        } catch {
            return false
        }
    }

    /// The only deliberately unsigned message accepted on the Mac→iOS wire.
    /// It is a pairing wake-up, never a command: the receiver may refresh the
    /// separately authenticated KVS material, but cannot infer an action,
    /// session, attachment, or arbitrary metadata from this envelope.
    public var isUnsignedResyncHint: Bool {
        let requiredKeys: Set<String> = [
            "kind",
            "rejectedMessageId",
            "publishedAt",
            "pairing_secret_version",
            "targetSourceKey",
        ]
        guard signature == nil,
              sender == "mac",
              text == "signature_invalid_resync",
              sessionID == nil,
              attachments?.isEmpty != false,
              let metadata,
              Set(metadata.keys) == requiredKeys,
              metadata["kind"] == "signature_invalid_resync",
              metadata["rejectedMessageId"] == (correlationID ?? ""),
              metadata["targetSourceKey"]?.isEmpty == false,
              let versionText = metadata["pairing_secret_version"],
              let version = Int(versionText),
              version >= 0
        else { return false }
        // `publishedAt` may be empty when the KVS timestamp has not reached
        // this Mac yet; the hint is still only a request to re-read KVS.
        return metadata["publishedAt"] != nil
    }
}

// MARK: - Durable iCloud action transactions

public struct ICloudTransactionRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var direction: String
    public var action: String
    public var state: String
    public var createdAt: String
    public var updatedAt: String
    public var attempts: Int
    public var lastError: String?
    public var response: [String: String]?
    /// 2026-09-06: `id` here is the phone-supplied TRANSACTION id, which is only
    /// defaulted to the message id — two unrelated actions can collide on it.
    /// These two fields bind the row to the exact envelope that reserved it, so
    /// a redelivery can tell "my action, already run" from "someone else's
    /// action wearing my id". Optional: rows written before this field existed
    /// decode with nil and are treated as unbound.
    public var msgId: String?
    /// SHA-256 over the action envelope's canonical body (sorted keys, the
    /// `signature` key removed) — the same bytes the inner HMAC covers.
    public var actionDigest: String?

    public init(
        id: String,
        direction: String,
        action: String,
        state: String,
        createdAt: String,
        updatedAt: String,
        attempts: Int = 0,
        lastError: String? = nil,
        response: [String: String]? = nil,
        msgId: String? = nil,
        actionDigest: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.action = action
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.lastError = lastError
        self.response = response
        self.msgId = msgId
        self.actionDigest = actionDigest
    }
}

// MARK: - Errors

public enum BridgeError: LocalizedError, Sendable {
    case containerUnavailable
    case missingPairingSecret

    public var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "iCloud container unavailable. Make sure iCloud Drive is enabled."
        case .missingPairingSecret:
            return "iCloud pairing key is missing. Re-pair this device from NativeAgent on the Mac."
        }
    }
}
