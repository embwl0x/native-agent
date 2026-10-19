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
    static func modelVisibleMCPTools(dataRoot: URL) -> [MCPToolDescriptor] {
        // Serve the checked cache now; warm live tools for the next catalog.
        MCPToolCatalogWarmer.shared.kickDetached(dataRoot: dataRoot)
        return MCPToolBridge.listMCPTools(dataRoot: dataRoot).filter {
            $0.serverId != "nativeagent-internal"
        }
    }

    /// Each mounted MCP server's tools, also as the `app` door's generated
    /// `mcp.<server>.<tool>` actions: their args, label and description.
    package static func mountedMCPToolSchemas(dataRoot: URL) -> [LLMToolSchema] {
        mcpToolSchemas(modelVisibleMCPTools(dataRoot: dataRoot))
    }

    static func mcpToolSchemas(_ tools: [MCPToolDescriptor]) -> [LLMToolSchema] {
        // Permissive fallback for tools whose cache row carries no
        // inputSchema — the LLM has to guess argument names for those.
        let fallback = JSONValue.object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(true),
        ])
        let fallbackData = (try? fallback.serializedData(pretty: false)) ?? Data("{}".utf8)
        return tools.map { tool in
            let paramsData = tool.inputSchema
                .flatMap { try? $0.serializedData(pretty: false) }
                ?? fallbackData
            // The server's own per-tool risk is the class this tool declares.
            return LLMToolSchema(
                name: tool.bridgedName,
                toolClass: MCPToolBridge.declaredClass(tool.effectiveRiskClass),
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
        standingBotMinimumInterval: TimeInterval,
        requestedNames: Set<String>? = nil
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
