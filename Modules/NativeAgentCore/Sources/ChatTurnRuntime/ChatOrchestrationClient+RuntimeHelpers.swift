import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftNativeChatOrchestrationClient {
    // MARK: persona fingerprint

    /// Stable short fingerprint of the active persona profile. First 16 hex
    /// chars of sha256(profile.name + "|" + profile.personaKind). Returns nil
    /// if PersonaCompiler can't load a profile (degraded paths).
    nonisolated static func personaFingerprint(dataRoot: URL) -> String? {
        let profile = PersonaCompiler.loadProfile(dataRoot: dataRoot)
        let seed = profile.name + "|" + profile.personaKind
        guard let bytes = seed.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    nonisolated static func contextFingerprint(recalledIds: [String]) -> String? {
        guard !recalledIds.isEmpty else { return nil }
        // Digest, not a raw join (gpt-5.5 MED, packet-provenance 2026-07-11):
        // recalledIds now carries ContextFlow packet memory record identity,
        // and this value leaves the cognitive-metadata path on ChatResponse —
        // a fingerprint must compare context, never disclose it. Same idiom
        // as personaFingerprint above.
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

    func toolLoopMaxIterations(for surface: String) -> Int {
        ToolLoopBudget.resolve(surface: surface, requested: toolLoopMaxIterationsOverride)
    }

    nonisolated static func inputWithSessionIfNeeded(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        ChatToolSessionInjection.apply(toolName: toolName, input: input, sessionId: sessionId)
    }
}
