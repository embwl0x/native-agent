import Foundation
import PersistenceCore

extension MCPUIActions {
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
}
