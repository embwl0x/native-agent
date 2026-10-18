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

    /// Live tool list for a server (the shared stdio pool on demand, cached
    /// 60 s). The input schema rides through so the Hub can build its form.
    public static func listTools(serverId: String, dispatcher: SwiftNativeMCPDispatcher, cached: Bool = true) async throws -> [MCPTool] {
        try await dispatcher.listToolsLive(forServer: serverId, cached: cached).compactMap { entry in
            guard case .object(let obj) = entry, case .string(let name) = obj["name"] ?? .null else { return nil }
            var desc: String? = nil
            if case .string(let s) = obj["description"] ?? .null { desc = s }
            var schema: JSONValue? = nil
            if let s = obj["inputSchema"], case .object = s { schema = s }
            return MCPTool(serverId: serverId, name: name, description: desc, inputSchema: schema)
        }
    }

    /// Live resource list for a server — the same caching contract as `listTools`.
    public static func listResources(serverId: String, dispatcher: SwiftNativeMCPDispatcher, cached: Bool = true) async throws -> [MCPResource] {
        try await dispatcher.listResourcesLive(forServer: serverId, cached: cached).compactMap { entry in
            guard case .object(let obj) = entry, case .string(let uri) = obj["uri"] ?? .null else { return nil }
            var name: String? = nil
            if case .string(let s) = obj["name"] ?? .null { name = s }
            var mime: String? = nil
            if case .string(let s) = obj["mimeType"] ?? .null { mime = s }
            return MCPResource(uri: uri, name: name, mimeType: mime)
        }
    }

    public enum ServerCommand: String, Sendable { case warm, restart, refresh }

    public struct ServerCommandResult: Sendable {
        public let server: MCPServer
        public let command: ServerCommand
        public let tools: [MCPTool]
        public let resources: Result<[MCPResource], Error>
        public let sessions: Result<[MCPSessionStatus], Error>

        public var detail: String {
            let completed: String
            switch command {
            case .warm: completed = "MCP warmed"
            case .restart: completed = "MCP restarted"
            case .refresh: completed = "MCP cache refreshed"
            }
            if case .success = resources, case .success = sessions {
                let refreshed = command == .refresh ? "MCP cache" : completed
                return "\(refreshed) and details refreshed: \(server.name)"
            }
            return "\(completed), but details could not refresh: \(server.name)"
        }

        public var toolResult: JSONValue {
            var errors: [String: JSONValue] = [:]
            if case .failure(let error) = resources { errors["resources"] = .string(error.localizedDescription) }
            if case .failure(let error) = sessions { errors["sessions"] = .string(error.localizedDescription) }
            return .object([
                "server_id": .string(server.id), "command": .string(command.rawValue), "detail": .string(detail),
                "status": .string(errors.isEmpty ? "ok" : "partial"),
                "command_completed": .bool(true), "inventory_errors": .object(errors)
            ])
        }
    }

    /// Command completion and inventory reads remain distinct, independent of UI selection.
    public static func runServerCommand(_ command: ServerCommand, server: MCPServer, dispatcher: SwiftNativeMCPDispatcher) async throws -> ServerCommandResult {
        let serverId = server.id
        if command == .restart { await dispatcher.stopSubprocess(serverId: serverId) }
        let tools = try await listTools(serverId: serverId, dispatcher: dispatcher, cached: false)
        let resources: Result<[MCPResource], Error>
        do { resources = .success(try await listResources(serverId: serverId, dispatcher: dispatcher, cached: command != .refresh)) }
        catch { resources = .failure(error) }
        let sessions: Result<[MCPSessionStatus], Error>
        do { sessions = .success(try await dispatcher.listSessions()) }
        catch { sessions = .failure(error) }
        return ServerCommandResult(server: server, command: command, tools: tools, resources: resources, sessions: sessions)
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
