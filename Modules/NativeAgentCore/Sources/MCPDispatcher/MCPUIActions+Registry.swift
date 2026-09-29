import Foundation
import PersistenceCore

extension MCPUIActions {
    /// Project the core consent into the app record; permissions and extras have
    /// no app-side slot and are intentionally omitted.
    public static func mapConsent(_ c: MCPConsent) -> MCPConsentRecord {
        MCPConsentRecord(
            id: c.id,
            serverId: c.serverId,
            toolName: c.toolName,
            scope: c.scope,
            risk: c.risk,
            status: c.status,
            argumentSummary: c.argumentSummary,
            grantedAt: c.grantedAt,
            revokedAt: c.revokedAt,
            updatedAt: c.updatedAt
        )
    }

    /// Persist the current per-tool risk; a stale displayed risk requires review.
    public static func grantConsent(

        serverId: String,
        toolName: String,
        risk: String?,
        dispatcher: SwiftNativeMCPDispatcher,
        dataRoot: URL
    ) async throws -> MCPConsentRecord {
        let disp = dispatcher
        let servers = try await disp.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw NSError(domain: "NativeAgentMCP", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "MCP server not found: \(serverId)",
            ])
        }
        let resolvedRisk = MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            toolName: toolName,
            serverRiskClass: server.riskClass,
            dataRoot: dataRoot
        )
        if let risk, !risk.isEmpty, risk != resolvedRisk {
            throw NSError(domain: "NativeAgentMCP", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "MCP tool risk changed to \(resolvedRisk). Review the current risk and grant again.",
            ])
        }
        let grant = MCPConsentGrant(
            serverId: serverId,
            toolName: toolName,
            scope: "server_tool",
            risk: resolvedRisk
        )
        let rec = try await disp.grantConsent(grant)
        return Self.mapConsent(rec)
    }

    /// Core revocation returns no record, so reread the ledger for the app result.
    /// A concurrent regrant or prune must not change what this call reports:
    /// synthesize a revoked record unless the reread still shows revocation.
    public static func revokeConsent(

        serverId: String,
        toolName: String,
        dispatcher: SwiftNativeMCPDispatcher
    ) async throws -> MCPConsentRecord {
        let disp = dispatcher
        try await disp.revokeConsent(serverId: serverId, toolName: toolName)
        let key = "\(serverId):\(toolName)"
        let consents = try await disp.listConsents()
        if let revoked = consents.first(where: { $0.id == key && $0.status == "revoked" }) {
            return Self.mapConsent(revoked)
        }
        // Revoke succeeded but the re-read row is gone (concurrent prune) or has
        // been re-granted out from under us. Return a minimal revoked record so
        // the return reflects THIS call's revoke — never a granted row.
        return MCPConsentRecord(
            id: key,
            serverId: serverId,
            toolName: toolName,
            scope: "server_tool",
            risk: nil,
            status: "revoked",
            argumentSummary: nil,
            grantedAt: nil,
            revokedAt: nil,
            updatedAt: nil
        )
    }

    public static func warmMCPServer(serverId: String, dispatcher: SwiftNativeMCPDispatcher) async throws -> MCPSessionStatus {
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        return try await sessionStatus(serverId: serverId, dispatcher: dispatcher)
    }

    public static func restartMCPServer(serverId: String, dispatcher: SwiftNativeMCPDispatcher) async throws -> MCPSessionStatus {
        await dispatcher.stopSubprocess(serverId: serverId)
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        return try await sessionStatus(serverId: serverId, dispatcher: dispatcher)
    }

    public static func refreshMCPCache(serverId: String, dispatcher: SwiftNativeMCPDispatcher) async throws -> MCPSessionStatus {
        _ = try await dispatcher.listToolsLive(forServer: serverId, cached: false)
        _ = try? await dispatcher.listResourcesLive(forServer: serverId, cached: false)
        return try await sessionStatus(serverId: serverId, dispatcher: dispatcher)
    }

    private static func sessionStatus(serverId: String, dispatcher: SwiftNativeMCPDispatcher) async throws -> MCPSessionStatus {
        let rows = try await dispatcher.listSessions()
        if let row = rows.first(where: { $0.serverId == serverId }) {
            return row
        }
        return MCPSessionStatus(
            id: serverId,
            serverId: serverId,
            serverName: nil,
            transport: nil,
            status: "idle",
            healthStatus: "not_checked",
            toolCount: 0,
            resourceCount: 0,
            lastWarmedAt: nil,
            lastError: nil
        )
    }

    public static func revokeConsent(id: String, serverId: String?, toolName: String?, dispatcher: SwiftNativeMCPDispatcher) async throws -> MCPConsentRecord {
        // Revoke directly only when the supplied ID agrees with the server/tool key.
        if let serverId, !serverId.isEmpty,
           let toolName, !toolName.isEmpty,
           id == "\(serverId):\(toolName)" {
            return try await revokeConsent(serverId: serverId, toolName: toolName, dispatcher: dispatcher)
        }
        // Otherwise resolve the exact ID from the checked ledger before mutation.
        let disp = dispatcher
        let consents = try await disp.listConsents()
        guard let match = consents.first(where: { $0.id == id }),
              !match.serverId.isEmpty,
              !match.toolName.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -404,
                          userInfo: [NSLocalizedDescriptionKey: "revokeMCPConsent: consent id \(id) not found"])
        }
        return try await revokeConsent(serverId: match.serverId, toolName: match.toolName, dispatcher: dispatcher)
    }
}
