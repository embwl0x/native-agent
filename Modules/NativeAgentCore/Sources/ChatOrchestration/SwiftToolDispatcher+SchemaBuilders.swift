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
    /// W5 L1#13 (bash demotion): generic shell is the model's reflex reach even
    /// when a native tool answers the same question with structure, no approval
    /// queue, and no subprocess. Appended to the shell/bash schema DESCRIPTIONS
    /// only — dispatch, gating, and every other tool's behavior are unchanged.
    static let nativeToolPreferenceGuidance = "Best fits: session_search for past conversations; delegation_status for bridge progress; github_* for GitHub repositories, notifications, issues, and pull requests; git_status/git_log/git_diff for routine repo evidence; read_file/list_dir for direct file reads."

    /// NativeAgent's own MCP endpoint remains available to external MCP
    /// clients and the MCP UI, but advertising it back to NativeAgent's LLM
    /// duplicates native Swift tools and forces a needless self-protocol hop.
    func modelVisibleMCPTools() -> [MCPToolDescriptor] {
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

    func modelVisibleToolNames() async -> [String] {
        let all = (try? await listAvailableTools()) ?? Self.builtInToolNames
        let hidden = Set(
            MCPToolBridge.listMCPTools(dataRoot: dataRoot)
                .filter { $0.serverId == "nativeagent-internal" }
                .map(\.bridgedName)
        )
        // Subtract the four-verb cutover boundary here too. Every catalog field
        // derived from this list — `tool_groups` among them — was one table
        // entry away from advertising a name `tool_load` refuses; the callers
        // that re-filter through modelVisibleCatalogToolNames were carrying the
        // whole guarantee. Same set tool_load resolves against.
        return all.filter {
            !hidden.contains($0) && !Self.legacyMacModelToolNames.contains($0)
        }
    }

    func mcpToolSchemas() -> [LLMToolSchema] {
        // Permissive fallback for tools whose cache row carries no
        // inputSchema — the LLM has to guess argument names for those.
        let fallback = JSONValue.object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(true),
        ])
        let fallbackData = (try? fallback.serializedData(pretty: false)) ?? Data("{}".utf8)
        return modelVisibleMCPTools().map { tool in
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
        includeFullMacAppTools: Bool = false,
        includeFullMacAccessibilityReadTools: Bool = false,
        includeFullMacAccessibilityInjectionTools: Bool = false,
        includeActivityQueryTool: Bool = false,
        requestedNames: Set<String>? = nil
    ) -> [LLMToolSchema] {
        BuiltInToolSchemaFactory(requestedNames: requestedNames).schemas(
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAppTools: includeFullMacAppTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )
    }
}
