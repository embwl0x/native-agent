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

// 2026-09-01: `WorkflowLifecycleAction`, `WorkflowLifecycleActionOutcome`, and
// `WorkflowLifecycleButtonPresentation` were retired with the workflow run
// engine (User authorized). They existed only to drive Resume / Cancel /
// Rollback on a run.

@MainActor
extension AppModel {
    @MainActor
    func search(_ query: String) async -> Result<[ResearchSearchResult], ResearchSearchFailure> {
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
        using operation: (String) async throws -> [ResearchSearchResult]
    ) async -> Result<[ResearchSearchResult], ResearchSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankQuery) }
        do {
            return .success(try await operation(trimmed))
        } catch {
            setFailureStatus(error, action: "run that research")
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    @MainActor
    func routeIntent(_ message: String) async {
        let client = client
        let didRoute = await routeIntent(message, using: { message in
            try await client.planRoute(message: message)
        })
        guard didRoute else { return }
        let traceTimeline = client.getCapabilityTraceTimeline()
        capabilityTraceTimeline = traceTimeline
        traces = traceTimeline.traces
    }

    /// The UI owns visible route state while the injected planner remains the
    /// real router boundary. The overload makes the successful-empty and
    /// failed paths executable without a source-text proxy.
    @MainActor
    @discardableResult
    func routeIntent(
        _ message: String,
        using planner: (String) async throws -> IntentRoutePlan
    ) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            routePlan = nil
            routePresentation = .failed("Enter a task before planning a route.")
            statusText = "Router needs a task to plan."
            return false
        }
        routePlan = nil
        routePresentation = .planning
        do {
            let plan = try await planner(trimmed)
            routePlan = plan
            routePresentation = .plan(plan)
            statusText = "Route planned: \(plan.goalType)"
            return true
        } catch {
            let failure = IntentRoutePresentation.boundedFailure(error)
            routePlan = nil
            routePresentation = .failed(failure)
            statusText = "Router failed: \(failure)"
            return false
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
    func resolveApproval(_ approval: ApprovalRecord, decision: String) async {
        let result = await resolveApprovalOnce(id: approval.id, decision: decision)
        switch result {
        case .applied:
            statusText = result.visibleMessage
            await refreshAll()
        case .noOpAlreadyResolved:
            statusText = result.visibleMessage
            await refreshAll()
        case .noOpInFlight, .unavailable:
            statusText = result.visibleMessage
        }
    }

    /// Coalesce simultaneous decisions from the full Approvals screen and
    /// any mounted inline control. The second
    /// caller is deliberately typed as a no-op rather than issuing another
    /// resolve request whose post-resolution effect could run twice.
    @MainActor
    func resolveApprovalOnce(id: String, decision: String) async -> CapabilitiesApprovalInboxResolution {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return .unavailable("The approval request has no identifier.")
        }
        guard approvalResolutionTasks[trimmedID] == nil else {
            return .noOpInFlight(id: trimmedID)
        }

        do {
            return .applied(try await resolveApproval(id: trimmedID, decision: decision))
        } catch let ApprovalInboxError.alreadyResolved(id: resolvedID, status: status) {
            return .noOpAlreadyResolved(id: resolvedID, status: status)
        } catch {
            return .unavailable(CapabilitiesApprovalInboxResolution.boundedUnavailable(error))
        }
    }

    @MainActor
    func isResolvingApproval(id: String) -> Bool {
        approvalResolutionInFlightIDs.contains(id)
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
        mcpToolReadState = .loading
        mcpResources = []
        mcpResourceReadState = .loading
        let pendingId = server.id
        do {
            let toolsResult = try await client.getMCPTools(serverId: pendingId).tools
            let resourcesResult = try await client.getMCPResources(serverId: pendingId).resources
            // Late-arrival guard: discard if user has moved on.
            guard selectedMCPServerId == pendingId else { return }
            mcpTools = toolsResult
            mcpToolReadState = .current
            mcpResources = resourcesResult
            mcpResourceReadState = .current
            statusText = "Loaded MCP details for \(server.name)"
        } catch {
            guard selectedMCPServerId == pendingId else { return }
            mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
            mcpResources = []
            mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
            setFailureStatus(error, action: "load MCP details")
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
            let fetchedSessions = (try? await engine.tools.listMCPSessions())
            if selectedMCPServerId == pendingId {
                mcpToolReadState = .loading
            }
            let fetchedTools: [MCPToolRecord]?
            do {
                fetchedTools = try await client.getMCPTools(serverId: pendingId).tools
            } catch {
                fetchedTools = nil
                if selectedMCPServerId == pendingId {
                    mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
                }
            }
            if selectedMCPServerId == pendingId {
                mcpResourceReadState = .loading
            }
            let fetchedResources: [MCPResourceRecord]?
            do {
                fetchedResources = try await client.getMCPResources(serverId: pendingId).resources
            } catch {
                fetchedResources = nil
                if selectedMCPServerId == pendingId {
                    mcpResources = []
                    mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
                }
            }
            // Sessions are server-list-wide, safe to apply unconditionally.
            if let s = fetchedSessions { engine.tools.mcpSessions = s }
            // Tools / resources are server-scoped — guard on still-selected.
            if selectedMCPServerId == pendingId {
                if let t = fetchedTools { mcpTools = t }
                if fetchedTools != nil { mcpToolReadState = .current }
                if let r = fetchedResources {
                    mcpResources = r
                    mcpResourceReadState = .current
                }
            }
            if selectedMCPServerId == pendingId {
                disabledFeature = nil
                if case .current = mcpResourceReadState {
                    statusText = "MCP warmed and details refreshed: \(server.name)"
                } else {
                    statusText = "MCP warmed, but details could not refresh: \(server.name)"
                }
            }
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            guard selectedMCPServerId == pendingId else { return }
            disabledFeature = AppModel.disabledBadge(for: "MCP warm", error: err)
            statusText = disabledFeature ?? "MCP warm disabled"
        } catch {
            guard selectedMCPServerId == pendingId else { return }
            setFailureStatus("Warming the MCP server failed. " + UserFacingError.cause(error, action: "warm the MCP server"), cause: error)
        }
    }

    @MainActor
    func restartMCPServer(_ server: MCPServerRecord) async {
        let pendingId = server.id
        do {
            selectedMCPServerId = pendingId
            _ = try await client.restartMCPServer(serverId: pendingId)
            engine.tools.mcpSessions = (try? await engine.tools.listMCPSessions()) ?? engine.tools.mcpSessions
            // Restart replaces the live child. Refresh the selected inventory
            // through the same owner before declaring completion; otherwise
            // the Hub can show tools/resources from the pre-restart session.
            guard selectedMCPServerId == pendingId else { return }
            await loadMCPDetails(server)
            guard selectedMCPServerId == pendingId else { return }
            if case .current = mcpResourceReadState {
                statusText = "MCP restarted and details refreshed: \(server.name)"
            } else {
                statusText = "MCP restarted, but details could not refresh: \(server.name)"
            }
        } catch {
            guard selectedMCPServerId == pendingId else { return }
            setFailureStatus("Restarting the MCP server failed. " + UserFacingError.cause(error, action: "restart the MCP server"), cause: error)
        }
    }

    @MainActor
    func refreshMCPCache(_ server: MCPServerRecord) async {
        let pendingId = server.id
        selectedMCPServerId = pendingId
        mcpTools = []
        mcpToolReadState = .loading
        mcpResources = []
        mcpResourceReadState = .loading
        do {
            _ = try await client.refreshMCPCache(serverId: pendingId)
            engine.tools.mcpSessions = (try? await engine.tools.listMCPSessions()) ?? engine.tools.mcpSessions
            guard selectedMCPServerId == pendingId else { return }
            await loadMCPDetails(server)
            guard selectedMCPServerId == pendingId else { return }
            disabledFeature = nil
            if case .current = mcpToolReadState, case .current = mcpResourceReadState {
                statusText = "MCP cache and details refreshed: \(server.name)"
            } else {
                statusText = "MCP cache refreshed, but details could not refresh: \(server.name)"
            }
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            guard selectedMCPServerId == pendingId else { return }
            mcpToolReadState = .unavailable(UserFacingError.cause(err, action: "read the MCP tools"))
            mcpResourceReadState = .unavailable(UserFacingError.cause(err, action: "read the MCP resources"))
            disabledFeature = AppModel.disabledBadge(for: "MCP cache refresh", error: err)
            statusText = disabledFeature ?? "MCP cache refresh disabled"
        } catch {
            guard selectedMCPServerId == pendingId else { return }
            mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
            mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
            setFailureStatus("Refreshing the MCP cache failed. " + UserFacingError.cause(error, action: "refresh the MCP cache"), cause: error)
        }
    }

    @MainActor
    func mcpConsentRisk(server: MCPServerRecord, toolName: String) -> String {
        MCPToolBridge.effectiveRiskClass(
            serverId: server.id,
            toolName: toolName,
            serverRiskClass: server.riskClass ?? "network_read",
            dataRoot: client.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    @MainActor
    func grantMCPConsent(server: MCPServerRecord, toolName: String, risk: String? = nil) async {
        do {
            let granted = try await client.grantMCPConsent(
                serverId: server.id, toolName: toolName,
                risk: risk ?? mcpConsentRisk(server: server, toolName: toolName)
            )
            mcpConsent = (try? await client.getMCPConsent()) ?? mcpConsent
            statusText = "MCP consent granted (\(granted.risk ?? "unknown"))"
        } catch {
            setFailureStatus(error, action: "grant that MCP consent")
        }
    }

    @MainActor
    func revokeMCPConsent(_ consent: MCPConsentRecord) async {
        do {
            _ = try await client.revokeMCPConsent(id: consent.id, serverId: consent.serverId, toolName: consent.toolName)
            mcpConsent = (try? await client.getMCPConsent()) ?? mcpConsent
            statusText = "MCP consent revoked"
        } catch {
            setFailureStatus("Revoking MCP consent failed. " + UserFacingError.cause(error, action: "revoke MCP consent"), cause: error)
        }
    }

    @MainActor
    func callMCPTool(server: MCPServerRecord, tool: MCPToolRecord, query: String) async {
        do {
            latestMCPCall = try await client.callMCPTool(serverId: server.id, toolName: tool.name, input: ["query": query])
            if latestMCPCall?.evidenceStatus == "recorded" {
                refreshMCPHubRecentCall()
            } else if let latestMCPCall {
                mcpRecentCallState = .sessionOnly(latestMCPCall)
            }
            statusText = "MCP \(tool.name): \(latestMCPCall?.status ?? "done")"
            await refreshAll()
        } catch {
            mcpRecentCallState = .latestAttemptFailed(UserFacingError.cause(error, action: "call that MCP tool"))
            setFailureStatus(error, action: "call that MCP tool")
        }
    }

    @MainActor
    func callMCPToolWithInput(server: MCPServerRecord, tool: MCPToolRecord, input: [String: JSONValue]) async {
        if let validation = MCPInputSchemaForm.validationMessage(
            schema: tool.inputSchema,
            values: input
        ) {
            statusText = "MCP input refused: \(validation)"
            return
        }
        do {
            // Mirror the shape of the v1 callMCPTool(server:tool:query:) above:
            // convert and await on the main actor. The original v1 path passes
            // a [String: Any] dict to client.callMCPTool synchronously without
            // a detached Task; the gpt-5.5 review correctly flagged the
            // first-cut Task.detached wrapper as over-structured.
            let foundationInput = MCPInputSchemaForm.toFoundationDict(input)
            latestMCPCall = try await client.callMCPTool(serverId: server.id, toolName: tool.name, input: foundationInput)
            if latestMCPCall?.evidenceStatus == "recorded" {
                refreshMCPHubRecentCall()
            } else if let latestMCPCall {
                mcpRecentCallState = .sessionOnly(latestMCPCall)
            }
            statusText = "MCP \(tool.name): \(latestMCPCall?.status ?? "done")"
            await refreshAll()
        } catch {
            mcpRecentCallState = .latestAttemptFailed(UserFacingError.cause(error, action: "call that MCP tool"))
            setFailureStatus(error, action: "call that MCP tool")
        }
    }

}
