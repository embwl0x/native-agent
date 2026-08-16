import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

enum ResearchSearchFailure: Error, Equatable {
    case blankQuery
    case requestFailed(String)

    var message: String {
        switch self {
        case .blankQuery:
            return "Enter a research query."
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
extension AppModel {
    @MainActor
    func search(_ query: String) async -> Result<[ResearchResult], ResearchSearchFailure> {
        let configuredBaseURL = searxngBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return await search(query) { [client] trimmed in
            if !configuredBaseURL.isEmpty {
                try await client.configureSearXNG(baseURL: configuredBaseURL)
            }
            return try await client.search(query: trimmed)
        }
    }

    @MainActor
    func search(
        _ query: String,
        using operation: (String) async throws -> [ResearchResult]
    ) async -> Result<[ResearchResult], ResearchSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankQuery) }
        do {
            let results = try await operation(trimmed)
            researchResults = results
            return .success(results)
        } catch {
            statusText = "Research failed: \(error.localizedDescription)"
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    @MainActor
    func routeIntent(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            routePlan = try await client.planRoute(message: trimmed)
            traces = (try? await client.getTraces()) ?? traces
            statusText = "Route planned: \(routePlan?.goalType ?? "unknown")"
        } catch {
            statusText = "Router failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runWorkflow(_ workflow: WorkflowRecord, objective: String) async {
        do {
            _ = try await client.runWorkflow(id: workflow.id, objective: objective, execute: true)
            disabledFeature = nil
            statusText = "Workflow execution recorded"
            await refreshAll()
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "Workflow run", error: err)
            statusText = disabledFeature ?? "Workflow run disabled"
        } catch {
            statusText = "Workflow run failed: \(error.localizedDescription)"
        }
    }

    /// W3: returns true if an NSError thrown by the NativeClient layer is a
    /// `notImplemented` envelope (panelDisabled feature, unavailable Swift impl).
    static func isNotImplemented(_ err: NSError) -> Bool {
        return (err.userInfo["code"] as? String) == "not_implemented"
            || (err.userInfo["panelDisabled"] as? Bool) == true
    }

    /// W3: format a user-facing "feature disabled" string from the
    /// `notImplemented` envelope, including the followup link if present.
    static func disabledBadge(for label: String, error err: NSError) -> String {
        let reason = (err.userInfo["reason"] as? String) ?? "unavailable in the Swift runtime"
        var msg = "\(label) disabled — \(reason)"
        if let followup = err.userInfo["followup"] as? String, !followup.isEmpty {
            msg += " (see: \(followup))"
        }
        return msg
    }

    @MainActor
    func resumeWorkflowRun(_ run: WorkflowRun) async {
        do {
            _ = try await client.resumeWorkflowRun(id: run.id)
            statusText = "Workflow resumed"
            await refreshAll()
        } catch {
            statusText = "Workflow resume failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func cancelWorkflowRun(_ run: WorkflowRun) async {
        do {
            _ = try await client.cancelWorkflowRun(id: run.id)
            statusText = "Workflow canceled"
            await refreshAll()
        } catch {
            statusText = "Workflow cancel failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func rollbackWorkflowRun(_ run: WorkflowRun) async {
        do {
            _ = try await client.rollbackWorkflowRun(id: run.id)
            statusText = "Workflow rolled back"
            await refreshAll()
        } catch {
            statusText = "Workflow rollback failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func resolveApproval(_ approval: ApprovalRequest, decision: String) async {
        do {
            _ = try await client.resolveApproval(id: approval.id, decision: decision)
            statusText = "Approval \(decision)"
            await refreshAll()
        } catch {
            statusText = "Approval update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func loadMCPDetails(_ server: MCPServerRecord) async {
        // gpt-5.5 review: race-safe load. User can tap server A then tap
        // server B before A's fetch returns; without this check, A's late
        // result would overwrite B's. Tag the request with the target id
        // and only adopt the result if the user is still on it.
        selectedMCPServerId = server.id
        // Clear stale inventories immediately so the UI doesn't show the
        // previous server's tools under the new server's name during fetch.
        mcpTools = []
        mcpResources = []
        let pendingId = server.id
        do {
            let toolsResult = try await client.getMCPTools(serverId: pendingId).tools
            let resourcesResult = try await client.getMCPResources(serverId: pendingId).resources
            // Late-arrival guard: discard if user has moved on.
            guard selectedMCPServerId == pendingId else { return }
            mcpTools = toolsResult
            mcpResources = resourcesResult
            statusText = "Loaded MCP details for \(server.name)"
        } catch {
            statusText = "MCP details failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func warmMCPServer(_ server: MCPServerRecord) async {
        // gpt-5.5 review-2 race-safety: same late-arrival guard as
        // loadMCPDetails. Warm A then tap B before A's awaits return would
        // otherwise overwrite B's inventories with A's. Capture pendingId
        // up-front and only adopt fetched arrays when the user is still on
        // this server.
        let pendingId = server.id
        do {
            selectedMCPServerId = pendingId
            _ = try await client.warmMCPServer(serverId: pendingId)
            let fetchedSessions = (try? await client.getMCPSessions())
            let fetchedTools = (try? await client.getMCPTools(serverId: pendingId).tools)
            let fetchedResources = (try? await client.getMCPResources(serverId: pendingId).resources)
            // Sessions are server-list-wide, safe to apply unconditionally.
            if let s = fetchedSessions { mcpSessions = s }
            // Tools / resources are server-scoped — guard on still-selected.
            if selectedMCPServerId == pendingId {
                if let t = fetchedTools { mcpTools = t }
                if let r = fetchedResources { mcpResources = r }
            }
            disabledFeature = nil
            statusText = "MCP warmed: \(server.name)"
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "MCP warm", error: err)
            statusText = disabledFeature ?? "MCP warm disabled"
        } catch {
            statusText = "MCP warm failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func restartMCPServer(_ server: MCPServerRecord) async {
        do {
            selectedMCPServerId = server.id
            _ = try await client.restartMCPServer(serverId: server.id)
            mcpSessions = (try? await client.getMCPSessions()) ?? mcpSessions
            statusText = "MCP restarted: \(server.name)"
        } catch {
            statusText = "MCP restart failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func refreshMCPCache(_ server: MCPServerRecord) async {
        do {
            selectedMCPServerId = server.id
            _ = try await client.refreshMCPCache(serverId: server.id)
            mcpSessions = (try? await client.getMCPSessions()) ?? mcpSessions
            disabledFeature = nil
            statusText = "MCP cache refreshed: \(server.name)"
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "MCP cache refresh", error: err)
            statusText = disabledFeature ?? "MCP cache refresh disabled"
        } catch {
            statusText = "MCP cache refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func grantMCPConsent(server: MCPServerRecord, toolName: String) async {
        do {
            _ = try await client.grantMCPConsent(serverId: server.id, toolName: toolName, risk: server.riskClass)
            mcpConsent = (try? await client.getMCPConsent()) ?? mcpConsent
            statusText = "MCP consent granted"
        } catch {
            statusText = "MCP consent failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func revokeMCPConsent(_ consent: MCPConsentRecord) async {
        do {
            _ = try await client.revokeMCPConsent(id: consent.id, serverId: consent.serverId, toolName: consent.toolName)
            mcpConsent = (try? await client.getMCPConsent()) ?? mcpConsent
            statusText = "MCP consent revoked"
        } catch {
            statusText = "MCP revoke failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func callMCPTool(server: MCPServerRecord, tool: MCPToolRecord, query: String) async {
        do {
            latestMCPCall = try await client.callMCPTool(serverId: server.id, toolName: tool.name, input: ["query": query])
            statusText = "MCP \(tool.name): \(latestMCPCall?.status ?? "done")"
            await refreshAll()
        } catch {
            statusText = "MCP call failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func callMCPToolWithInput(server: MCPServerRecord, tool: MCPToolRecord, input: [String: JSONValue]) async {
        do {
            // Mirror the shape of the v1 callMCPTool(server:tool:query:) above:
            // convert and await on the main actor. The original v1 path passes
            // a [String: Any] dict to client.callMCPTool synchronously without
            // a detached Task; the gpt-5.5 review correctly flagged the
            // first-cut Task.detached wrapper as over-structured.
            let foundationInput = MCPInputSchemaForm.toFoundationDict(input)
            latestMCPCall = try await client.callMCPTool(serverId: server.id, toolName: tool.name, input: foundationInput)
            statusText = "MCP \(tool.name): \(latestMCPCall?.status ?? "done")"
            await refreshAll()
        } catch {
            statusText = "MCP call failed: \(error.localizedDescription)"
        }
    }

}
