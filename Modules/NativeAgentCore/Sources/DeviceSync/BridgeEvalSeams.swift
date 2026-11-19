import Foundation
import NativeAgentShared

// Blueprint: | `BridgeEvalSeams.swift` | Replay bounds and incoming admission. |

/// Durable replay bounds must agree across bridge lifecycles.
enum ICloudSeenIDDefaultsStore {
    static func load(defaults: UserDefaults, key: String, cap: Int) throws -> [String] {
        guard let value = defaults.object(forKey: key) else { return [] }
        guard let stored = value as? [String], stored == cappedUnique(stored, cap: cap) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return stored
    }

    static func save(_ ids: [String], defaults: UserDefaults, key: String, cap: Int) {
        defaults.set(cappedUnique(ids, cap: cap), forKey: key)
    }

    private static func cappedUnique(_ ids: [String], cap: Int) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        return Array(unique.suffix(max(0, cap)))
    }
}

enum ICloudIncomingMessageDisposition: Equatable, Sendable {
    case deliver
    case permanentlyRejected(reason: String)

    static func classify(_ message: BridgeMessage, secret: Data, now: Date) -> ICloudIncomingMessageDisposition {
        guard message.sender == "ios" else {
            return .permanentlyRejected(reason: "sender_invalid")
        }
        guard message.signature != nil, message.verifySignature(secret: secret) else {
            return .permanentlyRejected(reason: "signature_invalid")
        }
        let age = now.timeIntervalSince(message.timestamp)
        // A request expires so it is never acted on late; a sense reading is a dated fact, true at its own time however late it lands.
        let expires = message.metadata?["kind"] != PhoneSenseEvent.messageKind
        guard age >= -15 * 60, !expires || age <= 24 * 60 * 60 else {
            return .permanentlyRejected(reason: "stale_timestamp")
        }
        return .deliver
    }
}
