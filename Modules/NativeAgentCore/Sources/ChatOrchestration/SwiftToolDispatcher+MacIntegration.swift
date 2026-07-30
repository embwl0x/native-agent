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
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {
    // MARK: - Mac integration dispatch helper
    //
    // Shared shape for all 5 Mac integration tools:
    //   1. Ask MacIntegrationPermissionStore — returns a structured `denied`
    //      envelope (NOT an exception) so the LLM sees a clean refusal with a
    //      "fix" hint it can relay to the user.
    //   2. If the bridge isn't wired (headless / app forgot to inject),
    //      return a `bridge_not_wired` envelope — same rationale: don't tear
    //      down the turn, let the LLM explain it.
    //   3. Otherwise forward to the bridge.
    func dispatchMacIntegrationTool(
        integration: String,
        mode: MacIntegrationPermissionMode,
        fixHint: String,
        input: [String: JSONValue],
        run: (any MacIntegrationToolBridge, [String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let allowed = await MacIntegrationPermissionStore.shared.allows(integration, mode: mode)
        guard allowed else {
            return .object([
                "status": .string("denied"),
                "reason": .string("integration_permission_denied"),
                "integration": .string(integration),
                "mode": .string(mode.rawValue),
                "fix": .string(fixHint),
            ])
        }
        guard let bridge = macIntegrationBridge else {
            return .object([
                "status": .string("failed"),
                "reason": .string("bridge_not_wired"),
                "integration": .string(integration),
                "fix": .string("App-side MacIntegrationToolBridge not injected; restart the app."),
            ])
        }
        return try await run(bridge, input)
    }
}
