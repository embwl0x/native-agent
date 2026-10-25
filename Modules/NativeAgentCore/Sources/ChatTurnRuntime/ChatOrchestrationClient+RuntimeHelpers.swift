import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `contextFingerprint`, `iso8601` |

extension SwiftNativeChatOrchestrationClient {
    nonisolated static func contextFingerprint(recalledIds: [String]) -> String? {
        guard !recalledIds.isEmpty else { return nil }
        // Digest, not a raw join (gpt-5.5 MED, packet-provenance 2026-07-11):
        // recalledIds now carries ContextFlow packet memory record identity,
        // and this value leaves the cognitive-metadata path on ChatResponse —
        // a fingerprint must compare context, never disclose it. Same idiom
        // as the shared persona fingerprint.
        let joined = recalledIds.sorted().joined(separator: ",")
        guard let bytes = joined.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: bytes)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    nonisolated static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
