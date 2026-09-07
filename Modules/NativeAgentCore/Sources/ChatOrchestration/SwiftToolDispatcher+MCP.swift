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

    /// Remove chat-only routing metadata before a strict remote MCP schema sees
    /// the arguments. Kept as a pure production seam so this boundary can be
    /// proved without starting a server or touching the user's MCP config.
    static func forwardedMCPArguments(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var forwarded = input
        forwarded["__session_id"] = nil
        return forwarded
    }

    func impl_mcp_tool(
        serverId: String,
        toolName: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let dispatcher = SwiftNativeMCPDispatcher(root: dataRoot)
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw AutonomyGateError.toolDenied(reason: "MCP server not found: \(serverId)")
        }
        let consents = try await dispatcher.listConsents()
        // 2026-09-06: do not silently auto-renew an unresolved/legacy grant.
        if consents.contains(where: {
            $0.serverId == serverId && $0.toolName == toolName && $0.unpinned
                && $0.status.lowercased() == "granted"
        }) {
            throw AutonomyGateError.toolDenied(
                reason: "MCP tool '\(serverId)/\(toolName)' has unpinned consent; resolve/pin its implementation and explicitly grant consent again"
            )
        }
        if consents.contains(where: {
            $0.serverId == serverId && $0.toolName == toolName
                && $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "revoked"
        }) {
            throw AutonomyGateError.toolDenied(
                reason: "MCP tool '\(serverId)/\(toolName)' consent was revoked; explicitly grant consent before execution"
            )
        }
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
            let bridgedTool = "mcp__\(serverId)__\(toolName)"
            let yoloAdmitted = await fullMacYoloAdmitted(tool: bridgedTool, surface: surface)
            if MCPToolBridge.riskRequiresApproval(effectiveRisk), !yoloAdmitted {
                throw AutonomyGateError.toolDenied(
                    reason: "MCP tool '\(serverId)/\(toolName)' requires approval before Swift execution (risk=\(effectiveRisk))"
                )
            }
            if !MCPToolBridge.riskRequiresApproval(effectiveRisk) {
                let grant = try await dispatcher.grantConsent(MCPConsentGrant(
                    serverId: serverId,
                    toolName: toolName,
                    risk: effectiveRisk,
                    argumentSummary: "Auto-granted low-risk Swift chat MCP call."
                ))
                guard !grant.unpinned else {
                    throw AutonomyGateError.toolDenied(reason: "MCP server '\(serverId)' could not be pinned; resolve its implementation and explicitly grant consent again")
                }
            }
        }
        // Strip the chat-surface session marker before forwarding: it's
        // injected into EVERY tool input for the lazy-load gate, and remote
        // MCP servers with strict schemas (additionalProperties: false)
        // reject calls carrying unknown keys.
        let forwarded = Self.forwardedMCPArguments(input)
        return try await dispatcher.callToolLive(
            forServer: serverId,
            toolName: toolName,
            arguments: .object(forwarded)
        )
    }

    func fullMacYoloAdmitted(tool: String, surface: String) async -> Bool {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let remoteSurfaces: Set<String> = [
            "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile", "watch", "remote",
        ]
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            tool: tool,
            origin: SecurityOriginContext(
                surface: surface,
                sessionId: ChatToolSessionContext.verifiedSessionId,
                userId: ChatToolSessionContext.verifiedUserId,
                chatId: ChatToolSessionContext.verifiedChatId,
                deviceId: nil,
                source: "swift_tool_dispatcher",
                isRemote: remoteSurfaces.contains(normalized),
                commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified
            )
        )
        return authority.admitted
    }

}
