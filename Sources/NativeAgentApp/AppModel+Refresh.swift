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
import CapabilityFoundry

@MainActor
extension AppModel {
    func refreshAll() async {
        if refreshAllInFlight {
            refreshAllQueued = true
            return
        }
        refreshAllInFlight = true
        defer {
            refreshAllInFlight = false
            if refreshAllQueued {
                refreshAllQueued = false
                Task { @MainActor in
                    await self.refreshAll()
                }
            }
        }

        let api = client
        // FIX: reset before this pass so lastRefreshError reflects only the
        // current refresh; each swallowed failure below now logs + records.
        lastRefreshError = nil
        health = try? await api.getHealth()
        if health == nil {
            statusText = "Swift runtime unavailable"
            health = try? await api.getHealth()
        }
        runs = await decodeLogged("getRuns", default: []) { try await api.getRuns() }
        activityEvents = await decodeLogged("getActivity", default: []) { try await api.getActivity() }
        executions = await decodeLogged("getWorkshopExecutions", default: []) { try await api.getWorkshopExecutions() }
        memories = await decodeLogged("getMemories", default: []) { try await api.getMemories() }
        personality = await decodeLogged("getPersonality") { try await api.getPersonality() }
        if let docsResponse = await decodeLogged("getPersonalityDocs", { try await api.getPersonalityDocs() }) {
            personalityDocs = docsResponse.docs
        }
        skills = await decodeLogged("getSkills", default: []) { try await api.getSkills() }
        tools = await decodeLogged("getTools", default: []) { try await api.getTools() }
        capabilitySummary = await decodeLogged("getCapabilities") { try await api.getCapabilities() }
        capabilityFoundry = await decodeLogged("getCapabilityFoundry") { try await api.getCapabilityFoundry() }
        workflows = await decodeLogged("getWorkflows", default: []) { try await api.getWorkflows() }
        workflowRuns = await decodeLogged("getWorkflowRuns", default: []) { try await api.getWorkflowRuns() }
        if let freshApprovals = await decodeLogged("getApprovals", { try await api.getApprovals() }) {
            approvals = freshApprovals
        }
        inboxItems = await decodeLogged("getInboxItems", default: []) { try await api.getInboxItems(unreadOnly: false) }
        mcpServers = await decodeLogged("getMCPServers", default: []) { try await api.getMCPServers() }
        mcpSessions = await decodeLogged("getMCPSessions", default: []) { try await api.getMCPSessions() }
        mcpConsent = await decodeLogged("getMCPConsent", default: []) { try await api.getMCPConsent() }
        // gpt-5.5 review-2 race-safety: late-arrival guard for tools/
        // resources here too. refreshAll is invoked by long-lived polling
        // and by post-mutation refreshes — both can interleave with a user
        // tapping a different server mid-flight. Clear on invalid-selection,
        // capture pendingId, guard on still-selected before adopting.
        let previousSelection = selectedMCPServerId
        if selectedMCPServerId == nil || !mcpServers.contains(where: { $0.id == selectedMCPServerId }) {
            selectedMCPServerId = mcpServers.first?.id
        }
        if selectedMCPServerId != previousSelection {
            mcpTools = []
            mcpResources = []
        }
        if mcpServers.isEmpty {
            mcpTools = []
            mcpResources = []
        }
        if let server = selectedMCPServer {
            let pendingId = server.id
            let fetchedTools: [MCPToolRecord]? = try? await api.getMCPTools(serverId: pendingId).tools
            let fetchedResources: [MCPResourceRecord]? = try? await api.getMCPResources(serverId: pendingId).resources
            if selectedMCPServerId == pendingId {
                if let t = fetchedTools { mcpTools = t }
                if let r = fetchedResources { mcpResources = r }
            }
        }
        researchLabRuns = await decodeLogged("getResearchLabRuns", default: []) { try await api.getResearchLabRuns() }
        traces = await decodeLogged("getTraces", default: []) { try await api.getTraces() }
        agentGraph = await decodeLogged("getAgentGraph") { try await api.getAgentGraph() }
        graphEntities = await decodeLogged("getGraphEntities", default: []) { try await api.getGraphEntities() }
        graphStatus = await decodeLogged("getGraphStatus") { try await api.getGraphStatus() }
        autonomyKernel = await decodeLogged("getAutonomyKernel") { try await api.getAutonomyKernel() }
        personalOS = await decodeLogged("getPersonalOS") { try await api.getPersonalOS() }
        capabilityCatalog = await decodeLogged("getCapabilityCatalog", default: []) { try await api.getCapabilityCatalog() }
        capabilityCatalogSources = await decodeLogged("getCapabilityCatalogSources", default: []) { try await api.getCapabilityCatalogSources() }
        capabilityPackInstalls = await decodeLogged("getCapabilityPackInstalls", default: []) { try await api.getCapabilityPackInstalls() }
        capabilityTrust = await decodeLogged("getCapabilityTrust") { try await api.getCapabilityTrust() }
        // DAEMON-KILL refreshAll: /v1/nextgen/summary + /v1/nextgen/receipts retired.
        // nextGenPhases reads <dataRoot>/runtime/nextgen_phases.json natively; keep it.
        nextGenSummary = nil
        nextGenPhases = await decodeLogged("getNextGenPhases", default: []) { try await api.getNextGenPhases() }
        nextGenReceipts = []
        personalityGrowth = await decodeLogged("getPersonalityGrowth") { try await api.getPersonalityGrowth() }
        nativePower = await decodeLogged("getNativePower") { try await api.getNativePower() }
        // DAEMON-KILL refreshAll: /v1/native-actions retired; the Swift
        // registry below exposes only dispatcher actions that have live native
        // handlers wired through this app.
        nativeActions = await decodeLogged("getNativeActionRegistry", default: []) { try await api.getNativeActionRegistry().actions }
        nativeActionReceipts = await decodeLogged("getNativeActionReceipts", default: []) { try await api.getNativeActionReceipts() }
        // DAEMON-KILL refreshAll: /v1/native/intents retired.
        nativeIntentRegistry = nil
        notificationStatus = await decodeLogged("getNotificationStatus") { try await api.getNotificationStatus() }
        browserRuntimeStatus = await decodeLogged("getBrowserStatus") { try await api.getBrowserStatus() }
        memoryVectorStatus = await decodeLogged("getMemoryVectorStatus") { try await api.getMemoryVectorStatus() }
        memoryV2Status = await decodeLogged("getMemoryV2Status") { try await api.getMemoryV2Status() }
        connectorActionRegistry = await decodeLogged("getConnectorActions") { try await api.getConnectorActions() }
        improvementGauntletStatus = await decodeLogged("getImprovementGauntlet") { try await api.getImprovementGauntlet() }
        productionHardening = await decodeLogged("getProductionHardening") { try await api.getProductionHardening() }
        productionExports = await decodeLogged("getProductionExports", default: []) { try await api.getProductionExports() }
        trustPolicy = await decodeLogged("getTrustPolicy") { try await api.getTrustPolicy() }
        backups = await decodeLogged("getBackups", default: []) { try await api.getBackups() }
        // DAEMON-DEAD PORT: read the Swift-owned connector registry directly;
        // leaving this empty makes the Connectors tab race broad refreshes.
        connectors = await decodeLogged("getConnectors", default: []) { try await api.getConnectors() }
        workspaces = await decodeLogged("getWorkspaces", default: []) { try await api.getWorkspaces() }
        evals = await decodeLogged("getEvals", default: []) { try await api.getEvals() }
        releaseChecklist = await decodeLogged("getReleaseChecklist") { try await api.getReleaseChecklist() }
        watchdogStatus = await decodeLogged("getWatchdog") { try await api.getWatchdog() }
        trainingArtifacts = await decodeLogged("getTrainingArtifacts", default: []) { try await api.getTrainingArtifacts() }
        jobs = await decodeLogged("getJobs", default: []) { try await api.getJobs() }
        improvementSummary = await decodeLogged("getImprovementSummary") { try await api.getImprovementSummary() }
        improvements = await decodeLogged("getImprovements", default: []) { try await api.getImprovements() }
        trainingRuns = await decodeLogged("getTrainingRuns", default: []) { try await api.getTrainingRuns() }
        trainingProposals = await decodeLogged("getTrainingProposals", default: []) { try await api.getTrainingProposals() }
        promotionCandidates = await decodeLogged("getPromotionCandidates", default: []) { try await api.getPromotionCandidates() }
        // DAEMON-KILL refreshAll: GET /v1/setup/questions retired.
        setupQuestions = []
        telegramStatus = await decodeLogged("getTelegramStatus") { try await api.getTelegramStatus() }
        if let st = telegramStatus {
            // Swift-native cutover: drive the UI vars straight from the native status
            // so the Bot-token-configured badge + allowed list don't depend on
            // the legacy config.json[telegram] overlay path decoding cleanly.
            telegramTokenConfigured = st.tokenConfigured
            telegramEnabled = st.enabled
            if !st.allowedChatIds.isEmpty || !st.allowedUserIds.isEmpty || st.tokenConfigured {
                telegramAllowedChats = st.allowedChatIds.joined(separator: ",")
                telegramAllowedUsers = st.allowedUserIds.joined(separator: ",")
                telegramRequireMention = st.requireMention
            }
        }
        modelCatalog = await decodeLogged("getModelCatalog") { try await api.getModelCatalog(refresh: false) }
        // PATCH-2026-05-07: chat-provider-picker Populate providers list at
        // app startup so the chat brain bar's Provider dropdown isn't
        // empty on first render. The bar's own .task also calls this, but
        // that doesn't help when the chat surface mounts before the
        // providers fetch completes.
        await loadProvidersForChat()
        await loadChatState(api: api)
        compiledPersonality = await decodeLogged("getCompiledPersonality") { try await api.getCompiledPersonality(surface: "chat") }
        privacyMap = await decodeLogged("getPrivacyMap") { try await api.getPrivacyMap() }
        if let config = await decodeLogged("getConfig", { try await api.getConfig() }) {
            codexAuthStatus = config.codexAuth
            if let base = config.searxngBaseURL, !base.isEmpty {
                searxngBaseURL = base
            }
            if let telegram = config.telegram {
                telegramTokenConfigured = telegram.tokenConfigured ?? false
                telegramEnabled = telegram.enabled ?? false
                telegramAllowedChats = (telegram.allowedChatIds ?? []).joined(separator: ",")
                telegramAllowedUsers = (telegram.allowedUserIds ?? []).joined(separator: ",")
                telegramRequireMention = telegram.requireMention ?? true
                telegramModel = telegram.model ?? telegramModel
                telegramReasoningEffort = telegram.reasoningEffort ?? telegramReasoningEffort
            }
            if let routing = config.modelRouting {
                // PATCH-2026-05-07: model-autosave Don't clobber the user's
                // picker selection on every refresh. The picker auto-saves
                // to daemon now (onChange → saveChatBrainDefaults), so the
                // saved config follows the picker — not the other way
                // around. Only seed chatModel from saved config if the
                // user hasn't picked anything yet (still on the initial
                // UserDefaults primary-model default).
                let neverPicked = UserDefaults.standard.string(forKey: "chatModel") == nil
                if neverPicked {
                    chatModel = routing.current.chat.model
                    chatReasoningEffort = routing.current.chat.reasoningEffort
                    chatFastMode = routing.current.chat.serviceTier == "priority"
                }
                let neverPickedTg = UserDefaults.standard.string(forKey: "telegramModel") == nil
                if neverPickedTg {
                    telegramModel = routing.current.telegram.model
                    telegramReasoningEffort = routing.current.telegram.reasoningEffort
                }
            }
        }
        statusText = health?.ok == true ? "Native runtime online" : "Native runtime unavailable"
    }
}
