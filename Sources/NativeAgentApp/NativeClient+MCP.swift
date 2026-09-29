import Foundation
import NativeAgentShared
import PersistenceCore
import MCPDispatcher
import TrustCenter
import EngineRuntime

extension NativeClient {
    static func evaluateMCPUIAdmission(
        serverId: String, toolName: String, arguments: [String: JSONValue], dataRoot: URL
    ) async -> SecurityToolEnvelope {
        await MCPUIActions.evaluateMCPUIAdmission(
            serverId: serverId, toolName: toolName, arguments: arguments, dataRoot: dataRoot
        )
    }

    func callMCPTool(serverId: String, toolName: String, input: [String: Any]) async throws -> MCPCallResult {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return try await MCPUIActions.callMCPTool(
            serverId: serverId, toolName: toolName, input: input,
            dataRoot: root, authority: .runtime(dataRoot: root)
        )
    }

    func warmMCPServer(serverId: String) async throws -> MCPSessionStatus {
        try await MCPUIActions.warmMCPServer(serverId: serverId, dispatcher: mcpDispatcherForClientRoot())
    }

    func restartMCPServer(serverId: String) async throws -> MCPSessionStatus {
        try await MCPUIActions.restartMCPServer(serverId: serverId, dispatcher: mcpDispatcherForClientRoot())
    }

    func refreshMCPCache(serverId: String) async throws -> MCPSessionStatus {
        try await MCPUIActions.refreshMCPCache(serverId: serverId, dispatcher: mcpDispatcherForClientRoot())
    }

    func grantMCPConsent(serverId: String, toolName: String, risk: String?) async throws -> MCPConsentRecord {
        try await swiftGrantMCPConsent(serverId: serverId, toolName: toolName, risk: risk)
    }

    func revokeMCPConsent(id: String, serverId: String?, toolName: String?) async throws -> MCPConsentRecord {
        try await MCPUIActions.revokeConsent(
            id: id, serverId: serverId, toolName: toolName, dispatcher: mcpDispatcherForClientRoot()
        )
    }
}
