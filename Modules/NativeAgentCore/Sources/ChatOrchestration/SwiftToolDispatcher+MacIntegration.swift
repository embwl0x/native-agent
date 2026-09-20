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
        /// Capabilities this same request is KNOWN to need alongside
        /// `integration`. Supplying them folds a predictable chain into one
        /// grant instead of walking the person through two prompts.
        alsoNeeded: [String] = [],
        input: [String: JSONValue],
        run: (any MacIntegrationToolBridge, [String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let allowed = await macIntegrationPermissionStore.allows(integration, mode: mode)
        guard allowed else {
            // The permission is not granted. That is not a refusal to be
            // relayed as prose with a "fix" hint — it is the person's
            // decision, not yet made, and it gets asked where the work is.
            //
            // ASK ONCE (Agent): the checker knows here exactly which
            // capabilities this tool needs, so it raises ONE need listing all
            // of them and the person grants once. `alsoNeeded` is the rest of
            // a chain the caller could know in advance; step-by-step
            // escalation is reserved for the needs that genuinely cannot be
            // predicted.
            let chain = [integration] + alsoNeeded.filter { $0 != integration }
            var missing: [String] = []
            for capability in chain
            where await !macIntegrationPermissionStore.allows(capability, mode: mode) {
                missing.append(capability)
            }
            if let need = InlineInteractionRegistry.permission(
                missing.isEmpty ? [integration] : missing,
                why: fixHint,
                // The axis the blocked call wanted, so the grant covers that
                // and says so rather than handing over both.
                mode: mode == .read ? .read : .write
            ) {
                return InlineInteractionNeed.envelope(need)
            }
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
        let result = try await run(bridge, input)
        if integration == "mail", case .object(let object) = result,
           object["reason"] == .string("not_configured") {
            return InlineInteractionNeed.envelope(InlineInteractionRegistry.connector(
                "mail", why: "Add and enable a Mail account in Internet Accounts.", dataRoot: dataRoot
            ))
        }
        return result
    }
}
