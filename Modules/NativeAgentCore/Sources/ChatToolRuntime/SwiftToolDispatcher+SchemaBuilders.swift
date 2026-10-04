import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution


// MARK: - Schema builders

extension SwiftToolDispatcher {
    /// NativeAgent's own MCP endpoint remains available to external MCP
    /// clients and the MCP UI, but advertising it back to NativeAgent's LLM
    /// duplicates native Swift tools and forces a needless self-protocol hop.
    func modelVisibleMCPTools() -> [MCPToolDescriptor] { Self.modelVisibleMCPTools(dataRoot: dataRoot) }

    static func modelVisibleMCPTools(dataRoot: URL) -> [MCPToolDescriptor] {
        // PRODUCTION TRIGGER for the MCP tools-cache refresh. `listMCPTools`
        // reads `mcp/cache/tools.json` and nothing else; before this, the only
        // callers of `refreshAllToolsCaches` were manual/UI actions, so a
        // configured stdio server with an empty cache contributed ZERO model
        // -visible tools forever with no error (gpt-5.5 NEEDS_FIX, 2026-08-02).
        // Fire-and-forget on purpose: the sweep spawns subprocesses, so it can
        // never sit in front of a chat turn. This build serves whatever is on
        // disk; the sweep stamps the cache for the next catalog build.
        MCPToolCatalogWarmer.shared.kickDetached(dataRoot: dataRoot)
        return MCPToolBridge.listMCPTools(dataRoot: dataRoot).filter {
            $0.serverId != "nativeagent-internal"
        }
    }

    func modelVisibleMCPToolNames() -> [String] {
        modelVisibleMCPTools().map(\.bridgedName)
    }

    func modelVisibleToolNames() async throws -> [String] {
        let all = try await listAvailableTools()
        let hidden = Set(
            MCPToolBridge.listMCPTools(dataRoot: dataRoot)
                .filter { $0.serverId == "nativeagent-internal" }
                .map(\.bridgedName)
        )
        // Subtract the four-verb cutover boundary and every hidden name here
        // too, so no manifest field derived from this list names a tool the
        // model never sees.
        return all.filter {
            !hidden.contains($0) && !Self.isModelHidden($0)
        }
    }

    func mcpToolSchemas() -> [LLMToolSchema] { Self.mountedMCPToolSchemas(dataRoot: dataRoot) }

    /// Each mounted MCP server's tools, also as the `app` door's generated
    /// `mcp.<server>.<tool>` actions: their args, label and description.
    package static func mountedMCPToolSchemas(dataRoot: URL) -> [LLMToolSchema] {
        // Permissive fallback for tools whose cache row carries no
        // inputSchema — the LLM has to guess argument names for those.
        let fallback = JSONValue.object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(true),
        ])
        let fallbackData = (try? fallback.serializedData(pretty: false)) ?? Data("{}".utf8)
        return modelVisibleMCPTools(dataRoot: dataRoot).map { tool in
            let paramsData = tool.inputSchema
                .flatMap { try? $0.serializedData(pretty: false) }
                ?? fallbackData
            return LLMToolSchema(
                name: tool.bridgedName,
                description: tool.description ?? "Call MCP tool \(tool.toolName) on server \(tool.serverId).",
                parametersJSON: paramsData
            )
        }
    }

    func builtInToolSchemas(
        includeFullMacFileTools: Bool = false,
        includeFullMacSystemTools: Bool = false,
        includeFullMacAccessibilityReadTools: Bool = false,
        includeFullMacAccessibilityInjectionTools: Bool = false,
        includeActivityQueryTool: Bool = false,
        requestedNames: Set<String>? = nil,
        standingBotMinimumInterval: TimeInterval
    ) -> [LLMToolSchema] {
        BuiltInToolSchemaFactory(
            requestedNames: requestedNames,
            standingBotMinimumInterval: standingBotMinimumInterval
        ).schemas(
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )
    }
}
