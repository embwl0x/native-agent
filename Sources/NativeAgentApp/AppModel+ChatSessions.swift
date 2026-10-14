import EngineRuntime
import AppToolRuntime
import Privacy
import TurnTrace
import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import Transcripts
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
import DeviceSync

extension Notification.Name {
    /// See `AppModel.flushLiveChatDrafts()`. Posted before a chat surface
    /// reads a stored draft; every mounted composer commits its live text.
    static let chatFlushLiveDrafts = Notification.Name("nativeagent.chat.flushLiveDrafts")
    /// A turn's user-visible notice (retry, timeout, advisory); ChatView
    /// places it in the turn's lane or as a toast.
    static let nativeAgentTurnNotice = Notification.Name("nativeagent.turn.notice")
}

@MainActor
extension AppModel: MacChatSessionSelectionPort {
    func loadChatState() async {
        // Idempotent; the earliest post-construction entry point AppModel owns.
        // Keeps the UserDefaults-backed settings block live so a bridge or
        // out-of-process write is picked up without a relaunch.
        installDefaultsBackedSettingsObserver()
        await reloadChatState()
    }

    // S.1: prune stale drafts/attachments for sessions that no longer exist,
    // drop empty drafts immediately, and cap to 50 most-recently-used entries.
    @MainActor
    private func pruneChatDrafts() {
        let activeIds = Set(engine.transcripts.sessions.map(\.id))
        // Drop sessions that no longer exist
        chatDrafts = chatDrafts.filter { activeIds.contains($0.key) }
        chatPendingAttachments = chatPendingAttachments.filter { activeIds.contains($0.key) }
        chatDraftLastTouched = chatDraftLastTouched.filter { activeIds.contains($0.key) }
        // The edit stamp outlives an empty draft on purpose — it is what stops
        // an older composer from re-filing text a newer one just cleared — so
        // it is pruned by session lifetime only (2026-09-06).
        chatDraftLastEdited = chatDraftLastEdited.filter { activeIds.contains($0.key) }
        // PATCH-2026-05-08: review-fix-r5 Collect empty keys first then remove
        // (was mutating dict while iterating it).
        let emptyKeys = chatDrafts.compactMap { $0.value.isEmpty ? $0.key : nil }
        for key in emptyKeys {
            chatDrafts.removeValue(forKey: key)
            chatDraftLastTouched.removeValue(forKey: key)
        }
        // S.6: Cap at 50 most-recently-used, but prefer evicting drafts not touched
        // in the last 5 minutes before evicting recently-active ones.
        let cap = 50
        if chatDrafts.count > cap {
            let now = Date()
            let recentKeys = Set(chatDraftLastTouched.filter { now.timeIntervalSince($0.value) < 300 }.keys)
            // Prefer evicting old (non-recent) drafts first, then fall back to LRU across all
            let candidates = chatDraftLastTouched
                .filter { !recentKeys.contains($0.key) }
                .sorted { $0.value < $1.value }
            let fallback = chatDraftLastTouched
                .filter { recentKeys.contains($0.key) }
                .sorted { $0.value < $1.value }
            let evictionOrder = candidates + fallback
            let overflow = chatDrafts.count - cap
            for entry in evictionOrder.prefix(overflow) {
                chatDrafts.removeValue(forKey: entry.key)
                chatDraftLastTouched.removeValue(forKey: entry.key)
            }
        }
    }

    @MainActor
    private func migrateEmptySessionChatState(to sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if let draft = chatDrafts.removeValue(forKey: ""), !draft.isEmpty {
            if chatDrafts[sessionId, default: ""].isEmpty {
                chatDrafts[sessionId] = draft
            }
            chatDraftLastTouched[sessionId] = Date()
        }
        chatDraftLastTouched.removeValue(forKey: "")
        if let pending = chatPendingAttachments.removeValue(forKey: ""), !pending.isEmpty {
            var existing = chatPendingAttachments[sessionId] ?? []
            existing.append(contentsOf: pending)
            chatPendingAttachments[sessionId] = existing
        }
    }

    // M12 (2026-07-09): every `try? await <read>() ?? existingValue` below
    // silently substitutes the LAST-KNOWN value when the backend is down, so a
    // dead runtime renders a full, confident-looking panel of stale data.
    // `fresh(_:_:)` records which endpoints came back nil; `recordPanelRefresh`
    // stores that per panel, and `panelStaleNotice(for:)` lets the UI say
    // "showing last-known data" instead of quietly lying. This mirrors
    // InboxView.load's catch → errorText pattern, but per-endpoint: one dead
    // endpoint should not blank a panel whose other fetches succeeded.
    @MainActor
    @discardableResult
    func refreshForSidebarItem(_ item: SidebarItem) async -> PanelRefreshStatus {
        panelRefreshCounts[item, default: 0] += 1
        defer {
            let remaining = panelRefreshCounts[item, default: 1] - 1
            if remaining == 0 { panelRefreshCounts.removeValue(forKey: item) }
            else { panelRefreshCounts[item] = remaining }
        }
        let persona = personaEngine
        let memory = engine.memory
        let approvalStore = engine.approvals
        let inbox = engine.inbox
        let toolStore = engine.tools
        let desk = engine.desk
        var failedEndpoints: [String] = []
        // Branches that perform no read must not claim refreshed data.
        var performedRead = true
        /// Returns `value`, recording `endpoint` as failed when it is nil.
        /// Callers keep their `?? existingValue` fallback — the value on screen
        /// is unchanged, but now the UI knows it is carried over, not fetched.
        func fresh<T>(_ endpoint: String, _ value: T?) -> T? {
            if value == nil { failedEndpoints.append(endpoint) }
            return value
        }

        // User, 2026-09-13 (speed): this used to await `getHealth` (twice on a
        // cold runtime) and then the full health card BEFORE fetching the
        // page's own data — on every arrival, for every page, including ones
        // whose branch below does nothing. Click-to-content waited on work
        // the page did not ask for.
        //
        // Health is not dropped, it just stops riding the navigation path:
        // `refreshAll` owns the periodic read, `performLoadChatState` re-reads
        // it when chat opens on a runtime that is not ok, and the chat header's
        // runtime chrome owns the health card's poll (its other consumers —
        // approvals, the inline approval card, the preview cards — each call
        // `loadHealthCard` themselves).
        switch item {
        case .chat:
            if !(await loadProvidersForChat()) { failedEndpoints.append("providers") }
            engine.providers.catalog = fresh("model catalog", try? await engine.providers.modelCatalog(refresh: false))
            await reloadChatState()
            if chatStateLoadFailed { failedEndpoints.append("chat messages") }
            compiledPersonality = fresh("personality", try? await PersonaCompiler(engine: persona).compiledPacket(surface: "chat"))
            // The chat header, composer placeholder, and turn cards all read
            // `agentDisplayName`, which resolves from `personality?.name`
            // first. That profile was only ever loaded by the Memory and
            // Personality screens, so a fresh launch straight into chat
            // labelled the agent with the app's fallback name until one of
            // those screens had been visited. Load it once here; the name is
            // the profile's, never a literal.
            if personality == nil {
                if let next = fresh("personality profile", try? await SwiftNativePersonaEngine.readPersonality(dataRoot: engine.dataRoot)), next != personality { personality = next }
                teachMemoryHygieneName()
            }
        case .legacyWorkshop:
            // 2026-06-06 sidebar-fix v3: removed the approvals side-effect
            // refresh. It was causing the sidebar to scroll on Executions click:
            // updating BOTH appModel.executions AND the approvals in the
            // same render cycle changed TWO sidebar badge counts at once
            // (Executions running-count + Activity pending-count), triggering
            // a double re-layout that shifted the scroll position. Approvals
            // have their own refresh in the .activity case and the sidebar's
            // own 30s poll; they don't need to ride along with the execution lane.
            runs = fresh("runs", await RuntimeReadProjection.runs(dataRoot: engine.dataRoot) ?? []) ?? runs
        case .desk, .workshop, .work, .command, .bots:
            // Nothing is read here, so nothing is said about freshness below.
            performedRead = false
            // DeskPageView, SchedulerView, and ResearchView own their bounded reads.
            // `.command` and `.workshop` are retired aliases → Desk
            // 2026-07-23); its old command-summary fetch went with the view.
            break
        case .memory, .memories, .knowledge:
            async let nextMemories = try? memory.activeMemories()
            async let nextMemoryProposals = try? memory.proposals(status: "pending")
            async let nextVectorStatus = try? MemoryStatusProjection.getMemoryVectorStatus(dataRoot: engine.dataRoot)
            async let nextMemoryV2Status = try? MemoryStatusProjection.getMemoryV2Status(dataRoot: engine.dataRoot)
            async let nextGraph = try? memory.graphView()
            async let nextPersonality = try? PersonaCompiler.compileProfile(dataRoot: engine.dataRoot).sharedProfile
            async let nextTrustPolicy = try? engine.trust.load()
            let (memoryRows, proposalRows, vectorRow, memoryV2Row, graphRow, personalityRow, trustRow) = await (
                nextMemories,
                nextMemoryProposals,
                nextVectorStatus,
                nextMemoryV2Status,
                nextGraph,
                nextPersonality,
                nextTrustPolicy
            )
            memory.memories = fresh("memories", memoryRows) ?? memory.memories
            if memoryRows != nil, let query = memory.searchResultQuery, query.count >= 3 {
                // Even an unchanged newest-200 list can hide a changed older
                // search hit. Begin a new generation on every successful read.
                await memory.search(query: query)
            }
            memory.proposals = fresh("memory proposals", proposalRows) ?? memory.proposals
            memoryVectorStatus = fresh("vector status", vectorRow) ?? memoryVectorStatus
            memoryV2Status = fresh("memory v2 status", memoryV2Row) ?? memoryV2Status
            agentGraph = fresh("agent graph", graphRow?.agentGraph) ?? agentGraph
            graphEntities = fresh("graph entities", graphRow?.entities) ?? graphEntities
            graphStatus = fresh("graph status", graphRow?.status) ?? graphStatus
            if let next = fresh("personality", personalityRow), next != personality { personality = next }
            teachMemoryHygieneName()
            if let next = fresh("trust policy", trustRow), next != engine.trust.policy { engine.trust.policy = next }
        case .connectors:
            workspaces = fresh("shared folders", try? await ConnectorRegistryActions.listWorkspaces(root: engine.dataRoot)) ?? workspaces
        case .settingsHub, .settings, .providers, .telegram, .inboxPolicy, .macIntegration:
            async let nextConfig = try? RuntimeReadProjection.configuration(dataRoot: engine.dataRoot)
            async let nextTelegramStatus = try? engine.telegram.load(manager: backgroundLoopsManager)
            async let nextConnectors = try? ConnectorStatusProjection.readConnectorRecords(root: engine.dataRoot, platform: AppConnectorStatusPlatform())
            let (configRow, telegramRow, connectorRows) = await (
                nextConfig,
                nextTelegramStatus,
                nextConnectors
            )
            if let config = fresh("config", configRow) {
                engine.providers.codexAuth = config.codexAuth
                applyRefreshedSearXNGBaseURL(config.searxngBaseURL)
            }
            engine.telegram.status = fresh("telegram status", telegramRow) ?? engine.telegram.status
            connectors = fresh("connectors", connectorRows) ?? connectors
        case .approvals, .activity:
            async let nextApprovals = try? approvalStore.list()
            async let nextInbox = try? inbox.list()
            async let nextMemoryProposals = try? memory.proposals(status: "pending")
            async let nextMisses = MemoryStatusProjection.recentMisses(dataRoot: engine.dataRoot)
            let (approvalRows, inboxRows, proposalRows) = await (
                nextApprovals,
                nextInbox,
                nextMemoryProposals
            )
            if let next = fresh("approvals", approvalRows), next != approvalStore.records { approvalStore.records = next }
            inbox.items = fresh("inbox", inboxRows) ?? inbox.items
            memory.proposals = fresh("memory proposals", proposalRows) ?? memory.proposals
            missLessons = fresh("misses", await nextMisses) ?? missLessons
        case .capabilities:
            async let nextSkills = try? RuntimeReadProjection.skills(dataRoot: engine.dataRoot)
            async let nextTools = try? toolStore.listAuthored()
            async let nextCapabilitySummary = try? engine.trust.loadCapabilities()
            async let nextApprovals = try? approvalStore.list()
            async let nextWorkflows = try? SwiftNativeWorkflowOrchestrationClient(root: engine.dataRoot).listWorkflowRecords()
            async let nextMCPServers = try? engine.tools.mcp.listServers()
            // The compact MCP Builder is mounted in Capabilities too. Its
            // server controls render live session and consent evidence, so
            // refresh all three authorities together rather than leaving
            // those rows stale/empty until someone opens the separate MCP tab.
            async let nextMCPSessions = try? engine.tools.listMCPSessions()
            async let nextMCPConsent = try? engine.tools.mcp.listConsents().map(MCPUIActions.mapConsent)
            // Native macOS Power is part of the Capabilities hardening view.
            // Refresh each live tile and action registry here so that view
            // never inherits a stale launch snapshot from another surface.
            async let nextNotificationStatus = try? RuntimeReadProjection.getNotificationStatus(dataRoot: engine.dataRoot)
            async let nextBrowserRuntimeStatus = try? RuntimeReadProjection.getBrowserStatus(dataRoot: engine.dataRoot)
            async let nextMemoryVectorStatus = try? MemoryStatusProjection.getMemoryVectorStatus(dataRoot: engine.dataRoot)
            async let nextNativeActions = NativeActionRoutes.swiftNativeActionRecords()
            async let nextNativeActionReceipts: [NativeActionReceipt] = RuntimeReadProjection.tailJSONL(
                path: NativeActionRoutes.nativeActionReceiptsPath(dataRoot: engine.dataRoot), limit: 50)
            async let nextConnectorActionRegistry = try? ConnectorActionRegistry.read(dataRoot: engine.dataRoot, platform: AppConnectorStatusPlatform())
            async let nextImprovementGauntletStatus = try? RuntimeReadProjection.swiftImprovementGauntlet(dataRoot: engine.dataRoot)
            async let nextCatalog = try? engine.trust.catalog()
            async let nextCatalogSources = try? engine.trust.catalogSources()
            async let nextPackInstalls = try? engine.trust.packInstalls()
            async let nextCapabilityTrust = try? engine.trust.loadCapabilityNetwork()
            async let nextGenSnapshot = decodeLogged("nextgen snapshot") {
                try await NextGenStatusProjection(dataRoot: engine.dataRoot).snapshot()
            }
            async let nextGraph = try? engine.memory.graphView()
            let (
                skillRows,
                toolRows,
                capabilityRow,
                approvalRows,
                workflowRows,
                mcpRows,
                mcpSessionRows,
                mcpConsentRows,
                notificationStatusRow,
                browserRuntimeStatusRow,
                memoryVectorStatusRow,
                nativeActionRows,
                nativeActionReceiptRows,
                connectorActionRegistryRow,
                improvementGauntletStatusRow,
                catalogRows,
                sourceRows,
                installRows,
                trustRow,
                nextGenRow,
                graphRow
            ) = await (
                nextSkills,
                nextTools,
                nextCapabilitySummary,
                nextApprovals,
                nextWorkflows,
                nextMCPServers,
                nextMCPSessions,
                nextMCPConsent,
                nextNotificationStatus,
                nextBrowserRuntimeStatus,
                nextMemoryVectorStatus,
                nextNativeActions,
                nextNativeActionReceipts,
                nextConnectorActionRegistry,
                nextImprovementGauntletStatus,
                nextCatalog,
                nextCatalogSources,
                nextPackInstalls,
                nextCapabilityTrust,
                nextGenSnapshot,
                nextGraph
            )
            skills = fresh("skills", skillRows) ?? skills
            toolStore.authored = fresh("tools", toolRows) ?? toolStore.authored
            engine.trust.capabilitySummary = fresh("capability summary", capabilityRow) ?? engine.trust.capabilitySummary
            if let next = fresh("approvals", approvalRows), next != approvalStore.records { approvalStore.records = next }
            workflows = fresh("workflows", workflowRows) ?? workflows
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            engine.tools.mcpSessions = fresh("mcp sessions", mcpSessionRows) ?? engine.tools.mcpSessions
            mcpConsent = fresh("mcp consent", mcpConsentRows) ?? mcpConsent
            notificationStatus = fresh("notification status", notificationStatusRow) ?? notificationStatus
            browserRuntimeStatus = fresh("browser status", browserRuntimeStatusRow) ?? browserRuntimeStatus
            memoryVectorStatus = fresh("memory vector status", memoryVectorStatusRow) ?? memoryVectorStatus
            nativeActions = fresh("native actions", nativeActionRows) ?? nativeActions
            nativeActionReceipts = fresh("native action receipts", nativeActionReceiptRows) ?? nativeActionReceipts
            connectorActionRegistry = fresh("connector actions", connectorActionRegistryRow) ?? connectorActionRegistry
            improvementGauntletStatus = fresh("improvement gauntlet", improvementGauntletStatusRow) ?? improvementGauntletStatus
            // The Builder renders the selected server's tools inline. Never
            // leave those tools attached to a server which the same refresh
            // proved absent, or an empty registry would still expose callable
            // rows from the previous selection.
            let previousMCPSelection = selectedMCPServerId
            if selectedMCPServerId == nil || !mcpServers.contains(where: { $0.id == selectedMCPServerId }) {
                selectedMCPServerId = mcpServers.first?.id
            }
            if selectedMCPServerId != previousMCPSelection || mcpServers.isEmpty {
                mcpTools = []
                mcpToolReadState = .notLoaded
                mcpResources = []
            }
            capabilityCatalog = fresh("capability catalog", catalogRows) ?? capabilityCatalog
            capabilityCatalogSources = fresh("catalog sources", sourceRows) ?? capabilityCatalogSources
            capabilityPackInstalls = fresh("pack installs", installRows) ?? capabilityPackInstalls
            engine.trust.capabilityNetwork = fresh("capability trust", trustRow) ?? engine.trust.capabilityNetwork
            if let snapshot = fresh("nextgen snapshot", nextGenRow) {
                nextGenSummary = snapshot.summary
                nextGenPhases = snapshot.phases
                nextGenReceipts = snapshot.receipts
            }
            agentGraph = fresh("skill memory graph", graphRow?.agentGraph) ?? agentGraph
            graphEntities = fresh("skill memory graph entities", graphRow?.entities) ?? graphEntities
            graphStatus = fresh("skill memory graph status", graphRow?.status) ?? graphStatus
            if graphRow != nil {
                graphLoadError = nil
            } else {
                graphLoadError = "The graph could not be loaded for Capabilities. Refresh Graph to retry."
            }
        case .autoImprovement:
            // The weekly pass reads its digest directly.
            async let nextJobs = try? desk.listJobs()
            desk.jobs = fresh("jobs", await nextJobs) ?? desk.jobs
        case .dreams:
            // The Dreams tab fetches its diary itself; refresh the trust policy
            // here so the REM toggle (trainingPolicy.rem_cycle_enabled) reflects
            // current state on tab entry.
            if let next = fresh("trust policy", try? await engine.trust.load()), next != engine.trust.policy { engine.trust.policy = next }
        case .cognition:
            performedRead = false
        case .skills, .skillLifecycle:
            skills = fresh("skills", try? await RuntimeReadProjection.skills(dataRoot: engine.dataRoot)) ?? skills
        case .diagnostics:
            // B2.1 (2026-07-23): the Diagnostics tab is now only Doctor / Status /
            // Runs (DiagnosticsView). Its views read exactly activityEvents, runs,
            // and watchdogStatus (StatusView) plus health (fetched unconditionally
            // above) and the Doctor report (DoctorView fetches its own). The other
            // fetches this case used to fire were Panels-tab residue — dead network
            // work on every Diagnostics visit. Verified at HEAD, each removed fetch
            // is either unread by any view (getReleaseChecklist, getEvals,
            // getTrainingArtifacts, getNativePower — a P1 daemon-kill stub) or read
            // only by another tab that refreshes it itself: getNotificationStatus +
            // getBrowserStatus + getProductionHardening (CapabilitiesView). All of
            // them are also refreshed by refreshAll() (launch + post-action), so no
            // consumer is starved. See prerelease-upgrade-campaign.md B2.1 [W7#1].
            async let nextActivity = try? RuntimeReadProjection.getActivity(root: engine.dataRoot)
            async let nextRuns = RuntimeReadProjection.runs(dataRoot: engine.dataRoot)
            async let nextWatchdog = engine.doctor.readWatchdog(manager: backgroundLoopsManager)
            // Health used to be fetched unconditionally for every page above;
            // Status is the page that actually reads it, so it reads it here.
            let healthRow = engine.doctor.readHealth()
            let (activityRows, runRows, watchdogRow) = await (
                nextActivity,
                nextRuns,
                nextWatchdog
            )
            activityEvents = fresh("activity", activityRows) ?? activityEvents
            runs = fresh("runs", runRows) ?? runs
            engine.doctor.watchdog = fresh("watchdog", watchdogRow) ?? engine.doctor.watchdog
            engine.doctor.health = healthRow
        case .personality:
            async let nextPersonality = try? PersonaCompiler.compileProfile(dataRoot: engine.dataRoot).sharedProfile
            async let nextDocs = try? persona.listPersonaDocSpecs()
            async let nextCompiled = try? PersonaCompiler(engine: persona).compiledPacket(surface: "chat")
            async let nextGrowth = try? RuntimeReadProjection.swiftPersonalityGrowth(runtime: NativeAgentEngine.liveCognition)
            let (personalityRow, docsResponse, compiledRow, growthRow) = await (
                nextPersonality,
                nextDocs,
                nextCompiled,
                nextGrowth
            )
            if let next = fresh("personality", personalityRow), next != personality { personality = next }
            teachMemoryHygieneName()
            if let docsResponse = fresh("personality docs", docsResponse) {
                personalityDocs = docsResponse.docs
            }
            compiledPersonality = fresh("compiled personality", compiledRow) ?? compiledPersonality
            personalityGrowth = fresh("personality growth", growthRow) ?? personalityGrowth
        case .trust:
            async let nextTrust = try? engine.trust.load()
            async let nextConnectors = try? ConnectorStatusProjection.readConnectorRecords(root: engine.dataRoot, platform: AppConnectorStatusPlatform())
            async let nextWorkspaces = try? ConnectorRegistryActions.listWorkspaces(root: engine.dataRoot)
            async let nextBackups = try? engine.trust.listBackups()
            let (trustRow, connectorRows, workspaceRows, backupRows) = await (
                nextTrust,
                nextConnectors,
                nextWorkspaces,
                nextBackups
            )
            if let next = fresh("trust policy", trustRow), next != engine.trust.policy { engine.trust.policy = next }
            connectors = fresh("connectors", connectorRows) ?? connectors
            workspaces = fresh("workspaces", workspaceRows) ?? workspaces
            engine.trust.backups = fresh("backups", backupRows) ?? engine.trust.backups
        case .panels:
            async let nextSkills = try? RuntimeReadProjection.skills(dataRoot: engine.dataRoot)
            async let nextTools = try? toolStore.listAuthored()
            let (skillRows, toolRows) = await (nextSkills, nextTools)
            skills = fresh("skills", skillRows) ?? skills
            toolStore.authored = fresh("tools", toolRows) ?? toolStore.authored
        case .tools:
            async let nextTools = try? toolStore.listAuthored()
            async let nextConnectorActions = try? ConnectorActionRegistry.read(dataRoot: engine.dataRoot, platform: AppConnectorStatusPlatform())
            async let nextMCPServers = try? engine.tools.mcp.listServers()
            // Tools renders the current catalog *and* its Full Mac lifecycle
            // explanation. Refresh the Trust policy in the same pass so an
            // expired/unreadable window is never flattened into "off".
            async let nextTrustPolicy = try? engine.trust.load()
            let (toolRows, connectorRows, mcpRows, trustPolicyRow) = await (
                nextTools,
                nextConnectorActions,
                nextMCPServers,
                nextTrustPolicy
            )
            toolStore.authored = fresh("tools", toolRows) ?? toolStore.authored
            connectorActionRegistry = fresh("connector actions", connectorRows) ?? connectorActionRegistry
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            if let next = fresh("trust policy", trustPolicyRow), next != engine.trust.policy { engine.trust.policy = next }
            if !(await toolStore.refreshCatalog()) {
                failedEndpoints.append("tool catalog")
            }
        case .mcp:
            async let nextMCPServers = try? engine.tools.mcp.listServers()
            async let nextMCPSessions = try? engine.tools.listMCPSessions()
            async let nextMCPConsent = try? engine.tools.mcp.listConsents().map(MCPUIActions.mapConsent)
            let (mcpRows, sessionRows, consentRows) = await (nextMCPServers, nextMCPSessions, nextMCPConsent)
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            engine.tools.mcpSessions = fresh("mcp sessions", sessionRows) ?? engine.tools.mcpSessions
            mcpConsent = fresh("mcp consent", consentRows) ?? mcpConsent
            // gpt-5.5 review: clear stale inventories when selection becomes
            // invalid OR the server list is empty. Without this, the UI shows
            // the old server's tools under the new server's name after the
            // user removes a server or the daemon drops one.
            let previousSelection = selectedMCPServerId
            if selectedMCPServerId == nil || !mcpServers.contains(where: { $0.id == selectedMCPServerId }) {
                selectedMCPServerId = mcpServers.first?.id
            }
            if selectedMCPServerId != previousSelection {
                mcpTools = []
                mcpToolReadState = .notLoaded
                mcpResources = []
                mcpResourceReadState = .notLoaded
            }
            if mcpServers.isEmpty {
                mcpTools = []
                mcpToolReadState = .notLoaded
                mcpResources = []
                mcpResourceReadState = .notLoaded
            }
            if let server = selectedMCPServer {
                // Race-safe apply: only adopt fetched tools/resources if the
                // user's selection didn't change while we were awaiting.
                let pendingId = server.id
                mcpToolReadState = .loading
                let fetchedTools: [MCPTool]?
                do {
                    fetchedTools = try await MCPUIActions.listTools(serverId: pendingId, dispatcher: engine.tools.mcp)
                } catch {
                    fetchedTools = nil
                    failedEndpoints.append("mcp tools")
                    if selectedMCPServerId == pendingId {
                        mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
                    }
                }
                if selectedMCPServerId == pendingId {
                    mcpResourceReadState = .loading
                }
                let fetchedResources: [MCPResource]?
                do {
                    fetchedResources = try await MCPUIActions.listResources(serverId: pendingId, dispatcher: engine.tools.mcp)
                } catch {
                    fetchedResources = nil
                    failedEndpoints.append("mcp resources")
                    if selectedMCPServerId == pendingId {
                        mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
                    }
                }
                if selectedMCPServerId == pendingId {
                    if let t = fetchedTools {
                        mcpTools = t
                        mcpToolReadState = .current
                    }
                    if let r = fetchedResources {
                        mcpResources = r
                        mcpResourceReadState = .current
                    }
                }
            }
            refreshMCPHubRecentCall()
        case .inspector:
            // Turn Inspector (W3) owns its own data: it subscribes to the
            // in-process TurnTraceBus for live events and reads the persisted
            // turn_traces JSONL for replay. No daemon refresh on tab select.
            performedRead = false
        }
        let receipt = recordPanelRefresh(item, failedEndpoints: failedEndpoints)
        if item.normalized == .activity {
            // The Activity page owns a complete five-queue read, while the
            // sidebar badge deliberately tracks only its three compact
            // sources. Reuse this completed fetch for the badge receipt so
            // entering Activity does not leave the sidebar's stale marker
            // behind or issue a second set of reads.
            let badgeEndpoints: Set<String> = ["approvals", "inbox", "memory proposals"]
            let badgeFailures = failedEndpoints.filter { badgeEndpoints.contains($0) }
            if let nextStatus = Self.staleFlagOnlyStatusToStore(
                previous: sidebarActivityRefreshStatus,
                failedEndpoints: badgeFailures,
                at: receipt.lastAttemptAt
            ) {
                sidebarActivityRefreshStatus = nextStatus
            }
        }
        // A page refresh reads THAT page's endpoints; it does not probe the
        // runtime. Only `.diagnostics` re-reads health above, so only it may
        // say "online"/"unavailable" — every other page says what its own read
        // did. Announcing cached health here claimed a probe that never ran.
        //
        if item.normalized == .diagnostics {
            statusText = engine.doctor.health?.ok == true ? "I'm online" : "I'm unavailable"
        } else if !performedRead {
            statusText = "\(item.normalized.rawValue) opened"
        } else if receipt.failedEndpoints.isEmpty {
            statusText = "\(item.normalized.rawValue) up to date"
        } else {
            statusText = "\(item.normalized.rawValue) partly unavailable: "
                + receipt.failedEndpoints.joined(separator: ", ")
        }
        return receipt
    }

    // MARK: - Panel staleness (M12)

    @MainActor
    @discardableResult
    func recordPanelRefresh(_ item: SidebarItem, failedEndpoints: [String]) -> PanelRefreshStatus {
        let now = Date()
        let status = Self.nextRefreshStatus(
            previous: panelRefreshStatus[item],
            failedEndpoints: failedEndpoints,
            at: now
        )
        panelRefreshStatus[item] = status
        return status
    }

    static func nextRefreshStatus(
        previous: PanelRefreshStatus?,
        failedEndpoints: [String],
        at now: Date
    ) -> PanelRefreshStatus {
        PanelRefreshStatus(
            lastAttemptAt: now,
            lastSuccessAt: failedEndpoints.isEmpty ? now : previous?.lastSuccessAt,
            failedEndpoints: failedEndpoints
        )
    }

    /// Render-cost audit F14. `nextRefreshStatus` stamps `lastAttemptAt: now`
    /// on every call, so the `Equatable` struct can never equal its
    /// predecessor. Observation fires on *write*, not on *change*, so every
    /// poll of an idle, fully-successful system invalidated every reader of
    /// the status — including the root `ContentView`, which reads
    /// `sidebarActivityRefreshStatus`.
    ///
    /// This returns nil when the fresh status does not need to be stored.
    ///
    /// **Only valid for a status whose sole rendered projection is `isStale`**
    /// (equivalently: `failedEndpoints.isEmpty`). Verified reader set for
    /// `sidebarActivityRefreshStatus` at the time of writing:
    /// `ContentView.swift:103` and `:115`, both `?.isStale == true`. Nothing
    /// renders its `lastAttemptAt` or `lastSuccessAt`, so carrying the old
    /// timestamps forward is unobservable.
    ///
    /// It is deliberately NOT used for `panelRefreshStatus`, whose timestamps
    /// *are* rendered — `panelStaleNotice(for:)` feeds both of them into
    /// `approximateAgeDescription`, and that string has to keep aging.
    static func staleFlagOnlyStatusToStore(
        previous: PanelRefreshStatus?,
        failedEndpoints: [String],
        at now: Date
    ) -> PanelRefreshStatus? {
        // A first-ever status is always stored: `nil` vs non-nil is itself a
        // rendered distinction (`compactReadPresentationState` treats nil as
        // "loading").
        guard let previous else {
            return nextRefreshStatus(previous: nil, failedEndpoints: failedEndpoints, at: now)
        }
        // Compare the whole failure list, not just `isStale`: a different set
        // of failed endpoints is a different outcome even when both are
        // non-empty, and this keeps the helper honest if a future reader ever
        // renders the list.
        guard previous.failedEndpoints == failedEndpoints else {
            return nextRefreshStatus(previous: previous, failedEndpoints: failedEndpoints, at: now)
        }
        return nil
    }

    static func keepingLastGood<Value>(_ previous: Value, fetched: Value?) -> Value {
        fetched ?? previous
    }

    /// The privacy map, walked now off the main actor (seconds for a whole
    /// data root). Trust asks for it whenever it shows the map.
    func refreshPrivacyMap() async {
        let root = engine.dataRoot
        privacyMap = await Task.detached(priority: .utility) {
            PrivacyMap(dataRoot: root, generatedAt: SwiftNativeManifestSigner.isoTimestamp(Date()))
        }.value
    }

    /// One user-facing sentence naming what could not be reached and how old
    /// the displayed data is, or nil when the last refresh was clean.
    @MainActor
    func panelStaleNotice(for item: SidebarItem) -> String? {
        guard let status = panelRefreshStatus[item], status.isStale else { return nil }
        // Endpoint names are internal vocabulary; the user-facing sentence
        // stays plain (same rule as DetachedChatLoadFailureCopy).
        guard let lastSuccess = status.lastSuccessAt else {
            // The provider reads failing with none connected is that cause;
            // anything else failed for its own reason, which is not named here.
            return Set(status.failedEndpoints).isSubset(of: ["providers", "model catalog"]) && !SwiftNativeProviderRouting(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()).hasUsableCredentials()
                ? "Nothing has loaded yet this session: no AI provider is connected. Connect one in Providers."
                : "Nothing has loaded yet this session: the last read failed."
        }
        let age = Self.approximateAgeDescription(since: lastSuccess, now: status.lastAttemptAt)
        return "Showing data from \(age) — some information couldn't be refreshed."
    }

    /// Coarse, dependency-free relative age. Deliberately vague: the point is
    /// "this is not current", not a precise duration.
    static func approximateAgeDescription(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "moments ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    @MainActor
    @discardableResult
    func refreshSidebarActivityBadge() async -> PanelRefreshStatus {
        let approvalStore = engine.approvals
        let inbox = engine.inbox
        let memory = engine.memory
        async let nextApprovals = try? approvalStore.list()
        async let nextInbox = try? inbox.list()
        async let nextMemoryProposals = try? memory.proposals(status: "pending")
        let (approvalRows, inboxRows, proposalRows) = await (
            nextApprovals,
            nextInbox,
            nextMemoryProposals
        )
        // Render-cost audit F13/F14: this is a file-watch-driven refresh
        // (`ContentView.swift:130-143`), so it fires on any touch of the
        // approvals/inbox/memory files — including SQLite WAL churn that
        // changed nothing. Each of these four writes invalidates the root
        // `ContentView` (it reads `pendingActivityCount`, which fans out to
        // these collections). Observation fires on write, not on change, so
        // gate every one: an unchanged badge refresh now performs zero writes
        // and triggers zero render passes.
        let nextApprovalRows = Self.keepingLastGood(approvalStore.records, fetched: approvalRows)
        if approvalStore.records != nextApprovalRows { approvalStore.records = nextApprovalRows }
        let nextInboxRows = Self.keepingLastGood(inbox.items, fetched: inboxRows)
        if inbox.items != nextInboxRows { inbox.items = nextInboxRows }
        let nextProposalRows = Self.keepingLastGood(memory.proposals, fetched: proposalRows)
        if memory.proposals != nextProposalRows { memory.proposals = nextProposalRows }
        var failed: [String] = []
        if approvalRows == nil { failed.append("approvals") }
        if inboxRows == nil { failed.append("inbox") }
        if proposalRows == nil { failed.append("memory proposals") }
        let attemptedAt = Date()
        let receipt = PanelRefreshStatus(
            lastAttemptAt: attemptedAt,
            lastSuccessAt: failed.isEmpty ? attemptedAt : sidebarActivityRefreshStatus?.lastSuccessAt,
            failedEndpoints: failed
        )
        if let nextStatus = Self.staleFlagOnlyStatusToStore(
            previous: sidebarActivityRefreshStatus,
            failedEndpoints: failed,
            at: attemptedAt
        ) {
            sidebarActivityRefreshStatus = nextStatus
        }
        await publishWorkStatus()
        return receipt
    }

    // S.1: touch a draft key to mark it recently used; call on every chatDrafts write.
    @MainActor
    func touchChatDraft(sessionId: String) {
        chatDraftLastTouched[sessionId] = Date()
    }

    // MARK: - Chat draft commit / inject (H5)
    //
    // The composer holds in-progress text in view-local @State. These two
    // entry points are the ONLY ways `chatDrafts` changes from outside it.
    //
    // - `commitChatDraft` persists the composer's text so it survives a tab
    //   change or session switch. It does NOT bump the injection generation:
    //   the composer already has this text, and re-broadcasting it would echo
    //   straight back into the field it came from.
    // - `injectChatDraft` writes text the composer has never seen (skill-build
    //   starter, suggestion chip) and bumps the generation so the composer
    //   pulls it. Rare by construction — never on the keystroke path.

    /// 2026-09-06: the main composer and every detached panel hold their
    /// in-progress text in view-local `@State` (H5), so `chatDrafts` lags what
    /// is actually on screen. A surface about to ADOPT a draft posts this
    /// first; the notification is delivered synchronously, so every live
    /// composer has written its text through by the time the read happens.
    /// Without it, opening a detached panel on the conversation the main
    /// window is being typed into showed the last commit, not the typing.
    @MainActor
    func flushLiveChatDrafts() {
        NotificationCenter.default.post(name: .chatFlushLiveDrafts, object: nil)
    }

    /// `editedAt` is when the committing composer's text was last typed. The
    /// flush broadcast makes every dirty composer write inside one
    /// notification with no order between them, so the newest edit wins and an
    /// older one is dropped rather than overwriting it (2026-09-06). Callers
    /// acting on a fresh user action (a send that clears the box) leave it at
    /// the default and are treated as the newest write.
    /// 2026-09-06: returns whether the write actually landed. A commit rejected
    /// as older than the stored draft used to be reported as success, so the
    /// panel marked its unsent text committed and dropped it on close.
    @MainActor
    @discardableResult
    func commitChatDraft(_ text: String, sessionId: String, editedAt: Date = Date()) -> Bool {
        guard !sessionId.isEmpty else { return false }
        if let lastEdited = chatDraftLastEdited[sessionId], editedAt < lastEdited { return false }
        chatDraftLastEdited[sessionId] = editedAt
        if text.isEmpty {
            // Mirrors pruneChatDrafts' empty-draft rule: an empty draft is an
            // absent draft, and leaving the key behind would keep a dead
            // session pinned in the 50-entry LRU.
            chatDrafts.removeValue(forKey: sessionId)
            chatDraftLastTouched.removeValue(forKey: sessionId)
            return true
        }
        guard chatDrafts[sessionId] != text else { return true }
        chatDrafts[sessionId] = text
        touchChatDraft(sessionId: sessionId)
        return true
    }

    /// Clear the draft a composer just SENT.
    ///
    /// 2026-09-06: this used to be `commitChatDraft("")` with a fresh
    /// timestamp, so sending older text from one window outranked — and
    /// deleted — a newer, still-unsent edit made in another window on the same
    /// conversation. A send speaks only for the snapshot it sent: when the
    /// stored draft is that snapshot it goes away without claiming a new edit
    /// time (so the other composer's later commit still wins), and when the
    /// stored draft is something else the clear must win on the sent
    /// snapshot's own edit time or not at all.
    @MainActor
    func clearChatDraftAfterSend(_ sent: String, sessionId: String, editedAt: Date) {
        guard !sessionId.isEmpty else { return }
        if chatDrafts[sessionId] == sent {
            chatDrafts.removeValue(forKey: sessionId)
            chatDraftLastTouched.removeValue(forKey: sessionId)
            return
        }
        commitChatDraft("", sessionId: sessionId, editedAt: editedAt)
    }

    @MainActor
    func injectChatDraft(_ text: String, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        chatDrafts[sessionId] = text
        touchChatDraft(sessionId: sessionId)
        bumpChatDraftInjectionGeneration()
    }

    @MainActor
    func chatDraft(for sessionId: String) -> String {
        chatDrafts[sessionId] ?? ""
    }

    /// Prepare the actual composer draft before routing to Chat. A
    /// notification-only handoff can select Chat before its first session
    /// exists and silently lose the requested starter; an existing draft is
    /// intentionally preserved.
    @MainActor
    @discardableResult
    func requestSkillBuild(starter: String = "Create a skill from this conversation: ") -> SkillLifecycleActionPresentation.Build {
        let sessionID = activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = SkillLifecycleActionPresentation.build(
            activeSessionID: sessionID,
            existingDraft: sessionID.isEmpty ? "" : chatDraft(for: sessionID)
        )
        if case .draftPrepared = outcome {
            injectChatDraft(starter, sessionId: sessionID)
        }
        NotificationCenter.default.post(name: .skillBuildRequest, object: starter)
        return outcome
    }

    @MainActor
    func reloadChatState() async {
        await engine.transcripts.sessionTransactions.load { await performLoadChatState() }
    }

    /// Lightweight live refresh for session-backed Mac read models.
    ///
    /// Bridge, iOS, Slack, Telegram, and other app-owned chat paths all mutate
    /// the canonical `chat/sessions.json` index. The view's file-event task
    /// calls this after those mutations so a newly created or retitled session
    /// appears in Chat, detached-window titles, Status, command search, and
    /// project/session lineage without navigation. This deliberately does not
    /// reload the active transcript, providers, health, trust policy, or context
    /// receipt; those retain their existing owners.
    @MainActor
    func refreshChatSessionIndex() async {
        await refreshChatSessionIndex { [transcripts = engine.transcripts] in
            try await transcripts.listForPresentation()
        }
    }

    /// Injectable seam for the bridge-created-session regression. A failed
    /// read preserves the last proven list; an equal read performs no observed
    /// write, so duplicate vnode edges cannot relayout Chat.
    @MainActor
    func refreshChatSessionIndex(
        load: @escaping @MainActor @Sendable () async throws -> [ChatSession]
    ) async {
        do {
            let refreshed = try await load()
            if chatSessionIndexRefreshFailed {
                chatSessionIndexRefreshFailed = false
            }
            let knownSessionIds = Set(refreshed.map(\.id))
            if !chatTurnLifecycleRepairCompleted {
                await repairChatTurnLifecyclesIfNeeded(
                    knownSessionIds: knownSessionIds
                ) { identity in
                    await self.readCanonicalChatTurnTerminalProof(identity: identity)
                }
            }
            guard refreshed != engine.transcripts.sessions else { return }
            engine.transcripts.sessions = refreshed
            pruneChatDrafts()
            pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
            if !activeChatSessionId.isEmpty, !knownSessionIds.contains(activeChatSessionId) {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                persistActiveChatSessionID(nil)
                if let replacement = refreshed.first(where: { $0.archived != true }) {
                    await selectChatSession(replacement)
                }
            }
        } catch {
            if !chatSessionIndexRefreshFailed {
                chatSessionIndexRefreshFailed = true
            }
        }
    }

    /// Simple has no conversation list, so it follows the conversation User is
    /// in: when the anchor MOVES (he sent from another door) the window moves
    /// with it. A chat he opened here stays until the anchor moves again.
    @MainActor
    func followMovedAnchorInSimple() async {
        guard SimpleViewMode.isShowing,
              let anchorId = ConversationAnchor.currentSessionId(),
              anchorId != MacChatSelectionIntent.lastSeenAnchorSessionId else { return }
        MacChatSelectionIntent.lastSeenAnchorSessionId = anchorId
        guard anchorId != activeChatSessionId else { return }
        if !engine.transcripts.sessions.contains(where: { $0.id == anchorId }) {
            do { engine.transcripts.sessions = try await engine.transcripts.listForPresentation() } catch { return }
        }
        guard let session = engine.transcripts.sessions.first(where: { $0.id == anchorId && $0.archived != true })
        else { return }
        await selectChatSession(session)
    }

    @MainActor
    private func performLoadChatState() async {
        let activeAtStart = activeChatSessionId
        let selectionGenerationAtStart = chatSelectionGeneration
        do {
            if engine.doctor.health?.ok != true {
                engine.doctor.health = engine.doctor.readHealth()
            }
            if let policy = try? await engine.trust.load() {
                engine.trust.policy = policy
            }
            let fetchedSessions = try await engine.transcripts.listForPresentation()
            chatSessionIndexRefreshFailed = false
            engine.transcripts.sessions = fetchedSessions
            // Simple owns its current thread. Advanced may default to the
            // remote conversation anchor — but only until the human
            // picks something. `shouldAdoptAnchor` owns that rule and also
            // refuses an anchor that names no live session, so a stale pin can
            // never blank the window. Surface-agnostic: nothing here knows or
            // cares which adapter published the anchor.
            if !SimpleViewMode.isShowing, ConversationAnchor.shouldAdoptAnchor(
                anchorSessionId: ConversationAnchor.currentSessionId(),
                currentSelection: activeChatSessionId,
                userChoseThisLaunch: MacChatSelectionIntent.userChoseThisLaunch,
                liveSessionIds: Set(engine.transcripts.sessions.filter { $0.archived != true }.map(\.id))
            ), let anchorId = ConversationAnchor.currentSessionId() {
                activeChatSessionId = anchorId
                persistActiveChatSessionID(activeChatSessionId)
            }
            if activeChatSessionId.isEmpty || !engine.transcripts.sessions.contains(where: { $0.id == activeChatSessionId }) {
                if !activeAtStart.isEmpty,
                   (activeChatSessionId != activeAtStart || chatSelectionGeneration != selectionGenerationAtStart) {
                    return
                }
                let reconciled = try await engine.transcripts.sessionTransactions.reconcileStartupSession(store: engine.transcripts)
                activeChatSessionId = reconciled.session.id
                if reconciled.created {
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
                UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
            }
            migrateEmptySessionChatState(to: activeChatSessionId)
            let knownSessionIds = Set(engine.transcripts.sessions.map(\.id))
            await repairChatTurnLifecyclesIfNeeded(
                knownSessionIds: knownSessionIds
            ) { identity in
                await self.readCanonicalChatTurnTerminalProof(identity: identity)
            }
            pruneChatDrafts()
            // 2026-07-21 audit fix: prune per-session message caches
            // for sessions the list no longer reports — mirrors the stale-draft
            // prune above, same low-frequency hook.
            pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
            let targetSessionId = activeChatSessionId
            let lifecycleAtLoadStart = engine.turns.lifecycle(for: targetSessionId)
            let messages = try await engine.transcripts.loadMessages(sessionId: targetSessionId, cached: true)
            guard activeChatSessionId == targetSessionId else { return }
            guard !engine.turns.streamingSessions.contains(targetSessionId),
                  engine.turns.lifecycle(for: targetSessionId) == lifecycleAtLoadStart,
                  engine.turns.activeTurnIDsBySession[targetSessionId] == nil else {
                // A live turn owns this slot. Disk is necessarily behind its
                // optimistic bubble/deltas, so a full Chat reload must not
                // replace the stream's exact message identity mid-turn.
                markChatSidebarLoadSucceeded()
                return
            }
            engine.transcripts.applyLoadedMessages(messages, for: targetSessionId)
            markChatSidebarLoadSucceeded()
        } catch {
            chatStateLoadFailed = true
            setFailureStatus(error, action: "load your chats")
        }
    }

    func refreshChatMessagesAfterTurn(sessionId: String, messagesAlreadyRefreshed: Bool = false) async {
        await engine.refreshChatMessagesAfterTurn(
            sessionId: sessionId, messagesAlreadyRefreshed: messagesAlreadyRefreshed,
            activeSession: { activeChatSessionId },
            failure: { setFailureStatus($0, action: "refresh your chats") }
        )
    }

    func refreshDetachedChatMessagesAfterTurn(sessionId: String, messagesAlreadyRefreshed: Bool = false) async {
        await engine.refreshDetachedChatMessagesAfterTurn(
            sessionId: sessionId, messagesAlreadyRefreshed: messagesAlreadyRefreshed,
            isDetached: { DetachedChatWindowController.shared.isDetached(sessionId) },
            finished: { failures in
                detachedChatRefreshStatus[sessionId] = Self.nextRefreshStatus(
                    previous: detachedChatRefreshStatus[sessionId],
                    failedEndpoints: failures, at: Date()
                )
            }
        )
    }

    struct ChatSessionLoadSnapshot {
        let messages: [ChatMessage]
    }

    @MainActor
    func selectChatSession(_ session: ChatSession) async {
        await selectChatSession(session, persistSelection: true) { [transcripts = engine.transcripts, agents = engine.agents] requestedId in
            let pulledDot = await agents.refreshDotSession(requestedId)
            let messages = try await transcripts.loadMessages(sessionId: requestedId, cached: !pulledDot)
            return ChatSessionLoadSnapshot(messages: messages)
        }
    }

    /// Transactional selection seam. An uncached session does not become active
    /// until its transcript has loaded; a cached session can switch immediately
    /// and refresh in place. Tests inject a controllable loader to pin ordering.
    @MainActor
    func selectChatSession(
        _ session: ChatSession,
        persistSelection: Bool,
        load: (String) async throws -> ChatSessionLoadSnapshot
    ) async {
        await engine.transcripts.sessionTransactions.select(
            session.id, persistSelection: persistSelection, port: self,
            store: engine.transcripts, runtime: engine.turns.runtime,
            presentStatus: { statusText = $0 }, load: load
        )
    }

    @MainActor
    func commitChatSessionSelection(
        _ requestedId: String,
        snapshot: ChatSessionLoadSnapshot?,
        persistSelection: Bool
    ) {
        if let snapshot {
            // A live stream owns its populated slot. An empty slot may still be
            // seeded from disk, then the optimistic rows are re-injected below.
            let isStreamingThisSession = engine.turns.streamingSessions.contains(requestedId)
            let inMemoryEmpty = (engine.transcripts.messagesBySession[requestedId] ?? []).isEmpty
            if !isStreamingThisSession || inMemoryEmpty {
                engine.transcripts.applyLoadedMessages(snapshot.messages, for: requestedId)
            }
        }

        // Publish the identity only after the requested transcript slot is
        // ready. This keeps the previous conversation visible through an
        // uncached load and leaves it untouched when that load fails.
        activeChatSessionId = requestedId
        if persistSelection {
            UserDefaults.standard.set(requestedId, forKey: "activeChatSessionId")
        }

        engine.transcripts.sessionTransactions.restoreLiveRows(
            messages: { engine.transcripts.messages(for: requestedId) },
            streaming: engine.turns.streamingSessions.contains(requestedId),
            userTurnId: engine.turns.streamingUserTurnIds[requestedId],
            bubbleId: engine.turns.streamingBubbleIds[requestedId],
            makeUser: { userTurnId in
                let userText = engine.turns.streamingUserTurnTexts[requestedId] ?? ""
                var userBubble = ChatMessage(sessionId: requestedId, role: "user", content: userText)
                userBubble.id = userTurnId
                return userBubble
            },
            makeAssistant: { bubbleId in
                let liveText = engine.turns.streamingTexts[requestedId] ?? ""
                var liveBubble = ChatMessage(sessionId: requestedId, role: "assistant", content: liveText)
                liveBubble.id = bubbleId
                var liveMetadata = ChatMessageMetadata()
                liveMetadata.turnTraceId = engine.turns.activeTurnIDsBySession[requestedId]
                liveBubble.metadata = liveMetadata
                return liveBubble
            },
            append: { appendChatMessage($0, to: requestedId) }
        )
    }

    @MainActor
    func newChatSession() async {
        do {
            let session = try await engine.transcripts.sessionTransactions.create(store: engine.transcripts)
            MacChatSelectionIntent.noteUserChoice()
            chatSelectionGeneration += 1
            // Seed before publishing the session: the next await lets its
            // composer start a turn, which must retain ownership of these rows.
            engine.transcripts.setMessages([], for: session.id)
            activeChatSessionId = session.id
            persistActiveChatSessionID(activeChatSessionId)
            engine.transcripts.sessions = try await engine.transcripts.listForPresentation()
            migrateEmptySessionChatState(to: activeChatSessionId)
            pruneChatDrafts()
            // 2026-07-21 audit fix: prune per-session message caches
            // for sessions the list no longer reports — mirrors the stale-draft
            // prune above, same low-frequency hook.
            pruneStaleSessionChatState(knownSessionIds: Set(engine.transcripts.sessions.map(\.id)))
            statusText = "New chat session ready"
            publishChatSnapshot()
        } catch {
            setFailureStatus(error, action: "start a new chat")
        }
    }

    @MainActor
    func renameChatSession(id sessionId: String, title: String) async {
        await engine.transcripts.sessionTransactions.rename(id: sessionId, title: title, store: engine.transcripts) { [self] status, publish in
            statusText = status
            if publish { publishChatSnapshot() }
        }
    }
}

extension AppModel: QuietChatSessionCommandPort {
    var chatSessionTransactions: MacChatSessionTransactions { engine.transcripts.sessionTransactions }
    var chatCommandTranscripts: TranscriptsFacade { engine.transcripts }
    var quietPinnedChatSessionIDs: [String] { ChatSessionRetention.load() }
    func quietChatIsDetached(_ sessionId: String) -> Bool {
        DetachedChatWindowController.shared.isDetached(sessionId)
    }
    func openQuietChatWindow(sessionId: String) {
        DetachedChatWindowController.shared.open(sessionId: sessionId)
    }
    func closeQuietChatWindow(sessionId: String) {
        DetachedChatWindowController.shared.close(sessionId: sessionId)
    }
    func unpinQuietChatSession(_ sessionId: String) -> Bool? {
        do {
            switch try ChatSessionRetention.closePinnedTab(sessionID: sessionId) {
            case .closed(let encoded):
                ChatSessionRetention.request(encodedPinnedIDs: encoded) { _ in
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
                return true
            case .refusedAlreadyUnpinned: return false
            case .refusedInvalidSessionID: return nil
            }
        } catch { return nil }
    }

    func clearQuietChatMessages(sessionId: String) async -> (succeeded: Bool, agentMessage: String) {
        let result = await clearActiveChatMessages(sessionId: sessionId)
        return (result.succeeded, result.agentMessage)
    }
    func archiveQuietChat(sessionId: String) async -> (succeeded: Bool, agentMessage: String) {
        let result = await archiveActiveChat(sessionId: sessionId)
        return (result.succeeded, result.agentMessage)
    }
    func compactQuietChat(sessionId: String, model: String?, providerID: String?, force: Bool) async throws -> ChatSessionCompactionOutcome {
        try await compactSession(sessionId: sessionId, model: model, providerID: providerID, force: force)
    }
    func exportQuietChat(session: NativeAgentShared.ChatSession?, sessionId: String, messages: [ChatMessage]) async throws -> URL {
        try await ChatExportService.export(session: session, sessionId: sessionId, messages: messages)
    }
    func isQuietSyntheticNotice(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix(Self.syntheticErrorIDPrefix)
    }
}
