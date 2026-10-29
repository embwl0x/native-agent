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
        // Hash recalled memory identities so ChatResponse can compare context without disclosing it.
        let joined = recalledIds.sorted().joined(separator: ",")
        guard let bytes = joined.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: bytes)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

}
