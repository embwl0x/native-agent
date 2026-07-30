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
    static func parseMCPToolName(_ bridged: String) -> (serverId: String, toolName: String)? {
        guard bridged.hasPrefix("mcp__") else { return nil }
        let rest = String(bridged.dropFirst("mcp__".count))
        guard let sep = rest.range(of: "__") else { return nil }
        let serverId = String(rest[..<sep.lowerBound])
        let toolName = String(rest[sep.upperBound...])
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }

    func impl_mcp_tool(
        serverId: String,
        toolName: String,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        let dispatcher = SwiftNativeMCPDispatcher(root: dataRoot)
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw AutonomyGateError.toolDenied(reason: "MCP server not found: \(serverId)")
        }
        let consents = try await dispatcher.listConsents()
        let effectiveRisk = MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            toolName: toolName,
            serverRiskClass: server.riskClass,
            dataRoot: dataRoot
        )
        let hasConsent = consents.contains {
            $0.serverId == serverId
                && $0.toolName == toolName
                && MCPToolBridge.consent($0, matchesCurrentEffectiveRisk: effectiveRisk)
        }
        if !hasConsent {
            if MCPToolBridge.riskRequiresApproval(effectiveRisk) {
                throw AutonomyGateError.toolDenied(
                    reason: "MCP tool '\(serverId)/\(toolName)' requires approval before Swift execution (risk=\(effectiveRisk))"
                )
            }
            _ = try await dispatcher.grantConsent(MCPConsentGrant(
                serverId: serverId,
                toolName: toolName,
                risk: effectiveRisk,
                argumentSummary: "Auto-granted low-risk Swift chat MCP call."
            ))
        }
        // Strip the chat-surface session marker before forwarding: it's
        // injected into EVERY tool input for the lazy-load gate, and remote
        // MCP servers with strict schemas (additionalProperties: false)
        // reject calls carrying unknown keys.
        var forwarded = input
        forwarded["__session_id"] = nil
        return try await dispatcher.callToolLive(
            forServer: serverId,
            toolName: toolName,
            arguments: .object(forwarded)
        )
    }

}
