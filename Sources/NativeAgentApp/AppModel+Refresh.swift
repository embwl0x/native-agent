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
    /// Render-cost audit F11 — equality gate.
    ///
    /// Swift Observation fires on *write*, not on *change*: assigning a
    /// byte-identical value still invalidates every view that read the field.
    /// `refreshAll` re-fetches ~60 payloads and the overwhelmingly common case
    /// is that nothing changed (Cmd+R on an idle system, or one of the ~30
    /// post-mutation call sites where a single collection moved). Routing every
    /// bulk assignment through here turns "refresh with identical data" into
    /// zero writes and therefore zero render passes.
    ///
    /// Fields whose payload type is not `Equatable` are assigned directly and
    /// are listed in the wave report.
    /// Internal rather than fileprivate so `RefreshEqualityGateTests` can drive
    /// it directly under `@testable import`.
    @inline(__always)
    func setIfChanged<V: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppModel, V>,
        _ value: V
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

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
        setIfChanged(\.lastRefreshError, nil)
        // Render-cost audit F11 — batching.
        //
        // Every `await` between two assignments lands them in *different*
        // MainActor turns, which SwiftUI cannot coalesce: 73 sequential writes
        // meant up to 73 render passes rippling through the observing views.
        // Each block below now fetches its whole group into locals and then
        // applies the group with no `await` in between, so the group collapses
        // into a single MainActor turn / single render pass — and with
        // `setIfChanged` an unchanged group produces no write at all.
        //
        // The grouping deliberately follows the sections that already existed
        // here rather than collapsing the whole function into one trailing
        // hop. A single end-of-function batch would defer *every* visible
        // update until the last fetch returned: it would erase the interim
        // "Swift runtime unavailable" message below, blank the whole UI for
        // the duration of a cold refresh, and widen the window in which a
        // concurrent user mutation gets clobbered by an older fetched value
        // from ~one section to the entire pass. Those are timing-visible
        // regressions; per-section batching gets the coalescing without them.
        setIfChanged(\.health, try? await api.getHealth())
        if health == nil {
            // Interim message, deliberately written before the retry await so
            // it is on screen while the retry is in flight.
            setIfChanged(\.statusText, "Swift runtime unavailable")
            setIfChanged(\.health, try? await api.getHealth())
        }

        let fetchedRuns = await decodeLogged("getRuns", default: []) { try await api.getRuns() }
        let fetchedActivity = await decodeLogged("getActivity", default: []) { try await api.getActivity() }
        let fetchedExecutions = await decodeLogged("getWorkshopExecutions", default: []) { try await api.getWorkshopExecutions() }
        let fetchedMemories = await decodeLogged("getMemories", default: []) { try await api.getMemories() }
        let fetchedPersonality = await decodeLogged("getPersonality") { try await api.getPersonality() }
        let fetchedPersonalityDocs = await decodeLogged("getPersonalityDocs", { try await api.getPersonalityDocs() })
        let fetchedSkills = await decodeLogged("getSkills", default: []) { try await api.getSkills() }
        let fetchedTools = await decodeLogged("getTools", default: []) { try await api.getTools() }
        let fetchedCapabilitySummary = await decodeLogged("getCapabilities") { try await api.getCapabilities() }
        let fetchedCapabilityFoundry = await decodeLogged("getCapabilityFoundry") { try await api.getCapabilityFoundry() }
        let fetchedWorkflows = await decodeLogged("getWorkflows", default: []) { try await api.getWorkflows() }
        let fetchedWorkflowRuns = await decodeLogged("getWorkflowRuns", default: []) { try await api.getWorkflowRuns() }
        let fetchedApprovals = await decodeLogged("getApprovals", { try await api.getApprovals() })
        let fetchedInboxItems = await decodeLogged("getInboxItems", default: []) { try await api.getInboxItems(unreadOnly: false) }
        let fetchedMCPServers = await decodeLogged("getMCPServers", default: []) { try await api.getMCPServers() }
        let fetchedMCPSessions = await decodeLogged("getMCPSessions", default: []) { try await api.getMCPSessions() }
        let fetchedMCPConsent = await decodeLogged("getMCPConsent", default: []) { try await api.getMCPConsent() }
        // No `await` from here to the end of the block: one MainActor turn.
        setIfChanged(\.runs, fetchedRuns)
        setIfChanged(\.activityEvents, fetchedActivity)
        setIfChanged(\.executions, fetchedExecutions)
        setIfChanged(\.memories, fetchedMemories)
        setIfChanged(\.personality, fetchedPersonality)
        if let docsResponse = fetchedPersonalityDocs {
            setIfChanged(\.personalityDocs, docsResponse.docs)
        }
        setIfChanged(\.skills, fetchedSkills)
        setIfChanged(\.tools, fetchedTools)
        setIfChanged(\.capabilitySummary, fetchedCapabilitySummary)
        setIfChanged(\.capabilityFoundry, fetchedCapabilityFoundry)
        setIfChanged(\.workflows, fetchedWorkflows)
        setIfChanged(\.workflowRuns, fetchedWorkflowRuns)
        if let freshApprovals = fetchedApprovals {
            setIfChanged(\.approvals, freshApprovals)
        }
        setIfChanged(\.inboxItems, fetchedInboxItems)
        setIfChanged(\.mcpServers, fetchedMCPServers)
        setIfChanged(\.mcpSessions, fetchedMCPSessions)
        setIfChanged(\.mcpConsent, fetchedMCPConsent)
        // gpt-5.5 review-2 race-safety: late-arrival guard for tools/
        // resources here too. refreshAll is invoked by long-lived polling
        // and by post-mutation refreshes — both can interleave with a user
        // tapping a different server mid-flight. Clear on invalid-selection,
        // capture pendingId, guard on still-selected before adopting.
        let previousSelection = selectedMCPServerId
        if selectedMCPServerId == nil || !mcpServers.contains(where: { $0.id == selectedMCPServerId }) {
            setIfChanged(\.selectedMCPServerId, mcpServers.first?.id)
        }
        if selectedMCPServerId != previousSelection {
            setIfChanged(\.mcpTools, [])
            setIfChanged(\.mcpResources, [])
        }
        if mcpServers.isEmpty {
            setIfChanged(\.mcpTools, [])
            setIfChanged(\.mcpResources, [])
        }
        if let server = selectedMCPServer {
            let pendingId = server.id
            let fetchedTools: [MCPToolRecord]? = try? await api.getMCPTools(serverId: pendingId).tools
            let fetchedResources: [MCPResourceRecord]? = try? await api.getMCPResources(serverId: pendingId).resources
            if selectedMCPServerId == pendingId {
                if let t = fetchedTools { setIfChanged(\.mcpTools, t) }
                if let r = fetchedResources { setIfChanged(\.mcpResources, r) }
            }
        }

        let fetchedResearchLabRuns = await decodeLogged("getResearchLabRuns", default: []) { try await api.getResearchLabRuns() }
        let fetchedTraces = await decodeLogged("getTraces", default: []) { try await api.getTraces() }
        let fetchedAgentGraph = await decodeLogged("getAgentGraph") { try await api.getAgentGraph() }
        let fetchedGraphEntities = await decodeLogged("getGraphEntities", default: []) { try await api.getGraphEntities() }
        let fetchedGraphStatus = await decodeLogged("getGraphStatus") { try await api.getGraphStatus() }
        let fetchedAutonomyKernel = await decodeLogged("getAutonomyKernel") { try await api.getAutonomyKernel() }
        let fetchedPersonalOS = await decodeLogged("getPersonalOS") { try await api.getPersonalOS() }
        let fetchedCapabilityCatalog = await decodeLogged("getCapabilityCatalog", default: []) { try await api.getCapabilityCatalog() }
        let fetchedCapabilityCatalogSources = await decodeLogged("getCapabilityCatalogSources", default: []) { try await api.getCapabilityCatalogSources() }
        let fetchedCapabilityPackInstalls = await decodeLogged("getCapabilityPackInstalls", default: []) { try await api.getCapabilityPackInstalls() }
        let fetchedCapabilityTrust = await decodeLogged("getCapabilityTrust") { try await api.getCapabilityTrust() }
        let fetchedNextGenPhases = await decodeLogged("getNextGenPhases", default: []) { try await api.getNextGenPhases() }
        let fetchedPersonalityGrowth = await decodeLogged("getPersonalityGrowth") { try await api.getPersonalityGrowth() }
        let fetchedNativePower = await decodeLogged("getNativePower") { try await api.getNativePower() }
        let fetchedNativeActions = await decodeLogged("getNativeActionRegistry", default: []) { try await api.getNativeActionRegistry().actions }
        let fetchedNativeActionReceipts = await decodeLogged("getNativeActionReceipts", default: []) { try await api.getNativeActionReceipts() }
        let fetchedNotificationStatus = await decodeLogged("getNotificationStatus") { try await api.getNotificationStatus() }
        let fetchedBrowserRuntimeStatus = await decodeLogged("getBrowserStatus") { try await api.getBrowserStatus() }
        let fetchedMemoryVectorStatus = await decodeLogged("getMemoryVectorStatus") { try await api.getMemoryVectorStatus() }
        let fetchedMemoryV2Status = await decodeLogged("getMemoryV2Status") { try await api.getMemoryV2Status() }
        let fetchedConnectorActionRegistry = await decodeLogged("getConnectorActions") { try await api.getConnectorActions() }
        let fetchedImprovementGauntletStatus = await decodeLogged("getImprovementGauntlet") { try await api.getImprovementGauntlet() }
        let fetchedProductionHardening = await decodeLogged("getProductionHardening") { try await api.getProductionHardening() }
        let fetchedProductionExports = await decodeLogged("getProductionExports", default: []) { try await api.getProductionExports() }
        let fetchedTrustPolicy = await decodeLogged("getTrustPolicy") { try await api.getTrustPolicy() }
        let fetchedBackups = await decodeLogged("getBackups", default: []) { try await api.getBackups() }
        let fetchedConnectors = await decodeLogged("getConnectors", default: []) { try await api.getConnectors() }
        let fetchedWorkspaces = await decodeLogged("getWorkspaces", default: []) { try await api.getWorkspaces() }
        let fetchedEvals = await decodeLogged("getEvals", default: []) { try await api.getEvals() }
        let fetchedReleaseChecklist = await decodeLogged("getReleaseChecklist") { try await api.getReleaseChecklist() }
        let fetchedWatchdogStatus = await decodeLogged("getWatchdog") { try await api.getWatchdog() }
        let fetchedTrainingArtifacts = await decodeLogged("getTrainingArtifacts", default: []) { try await api.getTrainingArtifacts() }
        let fetchedJobs = await decodeLogged("getJobs", default: []) { try await api.getJobs() }
        let fetchedImprovementSummary = await decodeLogged("getImprovementSummary") { try await api.getImprovementSummary() }
        let fetchedImprovements = await decodeLogged("getImprovements", default: []) { try await api.getImprovements() }
        let fetchedTrainingRuns = await decodeLogged("getTrainingRuns", default: []) { try await api.getTrainingRuns() }
        let fetchedTrainingProposals = await decodeLogged("getTrainingProposals", default: []) { try await api.getTrainingProposals() }
        let fetchedPromotionCandidates = await decodeLogged("getPromotionCandidates", default: []) { try await api.getPromotionCandidates() }
        let fetchedTelegramStatus = await decodeLogged("getTelegramStatus") { try await api.getTelegramStatus() }
        // No `await` from here to the end of the block: one MainActor turn.
        setIfChanged(\.researchLabRuns, fetchedResearchLabRuns)
        setIfChanged(\.traces, fetchedTraces)
        setIfChanged(\.agentGraph, fetchedAgentGraph)
        setIfChanged(\.graphEntities, fetchedGraphEntities)
        setIfChanged(\.graphStatus, fetchedGraphStatus)
        setIfChanged(\.autonomyKernel, fetchedAutonomyKernel)
        setIfChanged(\.personalOS, fetchedPersonalOS)
        setIfChanged(\.capabilityCatalog, fetchedCapabilityCatalog)
        setIfChanged(\.capabilityCatalogSources, fetchedCapabilityCatalogSources)
        setIfChanged(\.capabilityPackInstalls, fetchedCapabilityPackInstalls)
        setIfChanged(\.capabilityTrust, fetchedCapabilityTrust)
        // DAEMON-KILL refreshAll: /v1/nextgen/summary + /v1/nextgen/receipts retired.
        // nextGenPhases reads <dataRoot>/runtime/nextgen_phases.json natively; keep it.
        setIfChanged(\.nextGenSummary, nil)
        setIfChanged(\.nextGenPhases, fetchedNextGenPhases)
        setIfChanged(\.nextGenReceipts, [])
        setIfChanged(\.personalityGrowth, fetchedPersonalityGrowth)
        setIfChanged(\.nativePower, fetchedNativePower)
        // DAEMON-KILL refreshAll: /v1/native-actions retired; the Swift
        // registry below exposes only dispatcher actions that have live native
        // handlers wired through this app.
        setIfChanged(\.nativeActions, fetchedNativeActions)
        setIfChanged(\.nativeActionReceipts, fetchedNativeActionReceipts)
        // DAEMON-KILL refreshAll: /v1/native/intents retired.
        setIfChanged(\.nativeIntentRegistry, nil)
        setIfChanged(\.notificationStatus, fetchedNotificationStatus)
        setIfChanged(\.browserRuntimeStatus, fetchedBrowserRuntimeStatus)
        setIfChanged(\.memoryVectorStatus, fetchedMemoryVectorStatus)
        setIfChanged(\.memoryV2Status, fetchedMemoryV2Status)
        setIfChanged(\.connectorActionRegistry, fetchedConnectorActionRegistry)
        setIfChanged(\.improvementGauntletStatus, fetchedImprovementGauntletStatus)
        setIfChanged(\.productionHardening, fetchedProductionHardening)
        setIfChanged(\.productionExports, fetchedProductionExports)
        // NOT gated: `trustPolicy` has a `didSet` that re-syncs `chatFileAccess`
        // from the policy (AppModel.swift:370-378). Skipping the write on an
        // unchanged policy would also skip that re-sync, so a `chatFileAccess`
        // changed elsewhere would stop being snapped back to the policy value.
        // That is a security-adjacent behavior change, not a render saving.
        trustPolicy = fetchedTrustPolicy
        setIfChanged(\.backups, fetchedBackups)
        // DAEMON-DEAD PORT: read the Swift-owned connector registry directly;
        // leaving this empty makes the Connectors tab race broad refreshes.
        setIfChanged(\.connectors, fetchedConnectors)
        setIfChanged(\.workspaces, fetchedWorkspaces)
        setIfChanged(\.evals, fetchedEvals)
        setIfChanged(\.releaseChecklist, fetchedReleaseChecklist)
        setIfChanged(\.watchdogStatus, fetchedWatchdogStatus)
        setIfChanged(\.trainingArtifacts, fetchedTrainingArtifacts)
        setIfChanged(\.jobs, fetchedJobs)
        setIfChanged(\.improvementSummary, fetchedImprovementSummary)
        setIfChanged(\.improvements, fetchedImprovements)
        // Perf wave 2: the three that wave 1 had to leave ungated for a type
        // reason are gated now — `TrainingRunSummary`,
        // `TrainingProposalSummary` and `PromotionCandidateSummary` gained
        // synthesized `Equatable` (Models/ConfigProviderDoctorModels.swift).
        // `trainingProposals` and `promotionCandidates` matter most: both feed
        // `pendingActivityCount`, which the root `ContentView` reads, and both
        // now carry a `didSet` that recomputes that badge scalar — so an
        // unchanged fetch here is zero writes AND zero badge recomputes.
        setIfChanged(\.trainingRuns, fetchedTrainingRuns)
        setIfChanged(\.trainingProposals, fetchedTrainingProposals)
        setIfChanged(\.promotionCandidates, fetchedPromotionCandidates)
        // DAEMON-KILL refreshAll: GET /v1/setup/questions retired.
        setIfChanged(\.setupQuestions, [])
        setIfChanged(\.telegramStatus, fetchedTelegramStatus)
        if let st = telegramStatus {
            // Swift-native cutover: drive the UI vars straight from the native status
            // so the Bot-token-configured badge + allowed list don't depend on
            // the legacy config.json[telegram] overlay path decoding cleanly.
            setIfChanged(\.telegramTokenConfigured, st.tokenConfigured)
            setIfChanged(\.telegramEnabled, st.enabled)
            // NOT gated (here and in the config block below): every one of
            // these settings fields carries a `didSet` that persists it to
            // UserDefaults (AppModel.swift:88-139). Skipping the in-memory
            // write also skips the persistence side effect, which matters on
            // the first run when the defaults key does not exist yet — and
            // `chatModel`/`telegramModel` gate their own re-seed on exactly
            // that key being nil. These are a handful of writes inside
            // already-conditional blocks; they are not the render cost.
            if !st.allowedChatIds.isEmpty || !st.allowedUserIds.isEmpty || st.tokenConfigured {
                telegramAllowedChats = st.allowedChatIds.joined(separator: ",")
                telegramAllowedUsers = st.allowedUserIds.joined(separator: ",")
                telegramRequireMention = st.requireMention
            }
        }
        setIfChanged(\.modelCatalog, await decodeLogged("getModelCatalog") { try await api.getModelCatalog(refresh: false) })
        // PATCH-2026-05-07: chat-provider-picker Populate providers list at
        // app startup so the chat brain bar's Provider dropdown isn't
        // empty on first render. The bar's own .task also calls this, but
        // that doesn't help when the chat surface mounts before the
        // providers fetch completes.
        await loadProvidersForChat()
        await loadChatState(api: api)
        let fetchedCompiledPersonality = await decodeLogged("getCompiledPersonality") { try await api.getCompiledPersonality(surface: "chat") }
        // The map's names, paths, and export policy are cheap and sufficient
        // for a global/status refresh. Recursive file counts are intentionally
        // lazy: Trust and Settings request them when those surfaces open, while
        // launch Doctor no longer walks every data subtree during refreshAll.
        let fetchedPrivacyMap = await decodeLogged("getPrivacyMap") {
            try await api.getPrivacyMap(includeInventory: false)
        }
        let fetchedConfig = await decodeLogged("getConfig", { try await api.getConfig() })
        // No `await` from here to the end of the function: one MainActor turn.
        setIfChanged(\.compiledPersonality, fetchedCompiledPersonality)
        setIfChanged(\.privacyMap, fetchedPrivacyMap)
        if let config = fetchedConfig {
            setIfChanged(\.codexAuthStatus, config.codexAuth)
            // Not gated: `didSet`-persisted settings field (see above).
            if let base = config.searxngBaseURL, !base.isEmpty {
                searxngBaseURL = base
            }
            if let telegram = config.telegram {
                setIfChanged(\.telegramTokenConfigured, telegram.tokenConfigured ?? false)
                setIfChanged(\.telegramEnabled, telegram.enabled ?? false)
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
                // Not gated: these are the `didSet`-persisted fields whose own
                // `neverPicked` latch reads the UserDefaults key the `didSet`
                // writes. Gating them would leave the latch permanently unset.
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
        setIfChanged(\.statusText, health?.ok == true ? "Native runtime online" : "Native runtime unavailable")
    }
}
