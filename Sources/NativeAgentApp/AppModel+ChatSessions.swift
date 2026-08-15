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
    func loadChatState() async {
        await loadChatState(api: client)
    }

    @MainActor
    private func waitForChatStateLoad() async {
        await withCheckedContinuation { continuation in
            chatStateLoadWaiters.append(continuation)
        }
    }

    @MainActor
    private func finishChatStateLoad() {
        chatStateLoadInFlight = false
        let waiters = chatStateLoadWaiters
        chatStateLoadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // S.1: prune stale drafts/attachments for sessions that no longer exist,
    // drop empty drafts immediately, and cap to 50 most-recently-used entries.
    @MainActor
    private func pruneChatDrafts() {
        let activeIds = Set(chatSessions.map(\.id))
        // Drop sessions that no longer exist
        chatDrafts = chatDrafts.filter { activeIds.contains($0.key) }
        chatPendingAttachments = chatPendingAttachments.filter { activeIds.contains($0.key) }
        chatDraftLastTouched = chatDraftLastTouched.filter { activeIds.contains($0.key) }
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

    // M12 (2026-07-09): every `try? await api.getX() ?? existingValue` below
    // silently substitutes the LAST-KNOWN value when the backend is down, so a
    // dead runtime renders a full, confident-looking panel of stale data.
    // `fresh(_:_:)` records which endpoints came back nil; `recordPanelRefresh`
    // stores that per panel, and `panelStaleNotice(for:)` lets the UI say
    // "showing last-known data" instead of quietly lying. This mirrors
    // InboxView.load's catch → errorText pattern, but per-endpoint: one dead
    // endpoint should not blank a panel whose other fetches succeeded.
    @MainActor
    func refreshForSidebarItem(_ item: SidebarItem) async {
        let api = client
        var failedEndpoints: [String] = []
        /// Returns `value`, recording `endpoint` as failed when it is nil.
        /// Callers keep their `?? existingValue` fallback — the value on screen
        /// is unchanged, but now the UI knows it is carried over, not fetched.
        func fresh<T>(_ endpoint: String, _ value: T?) -> T? {
            if value == nil { failedEndpoints.append(endpoint) }
            return value
        }

        health = try? await api.getHealth()
        if health == nil {
            statusText = "Swift runtime unavailable"
            health = try? await api.getHealth()
        }
        if health == nil { failedEndpoints.append("health") }
        await loadHealthCard(includeApprovals: false)
        switch item {
        case .chat:
            if !(await loadProvidersForChat()) { failedEndpoints.append("providers") }
            modelCatalog = fresh("model catalog", try? await api.getModelCatalog(refresh: false))
            await loadChatState(api: api)
            if chatStateLoadFailed { failedEndpoints.append("chat messages") }
            compiledPersonality = fresh("personality", try? await api.getCompiledPersonality(surface: "chat"))
        case .legacyWorkshop:
            // 2026-06-06 sidebar-fix v3: removed the approvals side-effect
            // refresh. It was causing the sidebar to scroll on Executions click:
            // updating BOTH appModel.executions AND appModel.approvals in the
            // same render cycle changed TWO sidebar badge counts at once
            // (Executions running-count + Activity pending-count), triggering
            // a double re-layout that shifted the scroll position. Approvals
            // have their own refresh in the .activity case and the sidebar's
            // own 30s poll; they don't need to ride along with the execution lane.
            async let nextExecutions = try? api.getWorkshopExecutions()
            async let nextRuns = try? api.getRuns()
            let (executionRows, runRows) = await (nextExecutions, nextRuns)
            executions = fresh("missions", executionRows) ?? executions
            runs = fresh("runs", runRows) ?? runs
        case .desk, .workshop, .work, .command:
            // DeskView, SchedulerView, and ResearchView own their bounded reads.
            // `.command` and `.workshop` are retired aliases → Desk
            // 2026-07-23); its old command-summary fetch went with the view.
            break
        case .memory, .memories, .knowledge:
            async let nextMemories = try? api.getMemories()
            async let nextMemoryProposals = try? api.getMemoryProposals()
            async let nextVectorStatus = try? api.getMemoryVectorStatus()
            async let nextMemoryV2Status = try? api.getMemoryV2Status()
            async let nextAgentGraph = try? api.getAgentGraph()
            async let nextGraphEntities = try? api.getGraphEntities()
            async let nextGraphStatus = try? api.getGraphStatus()
            async let nextPersonality = try? api.getPersonality()
            async let nextTrustPolicy = try? api.getTrustPolicy()
            let (memoryRows, proposalRows, vectorRow, memoryV2Row, agentGraphRow, graphRows, graphStatusRow, personalityRow, trustRow) = await (
                nextMemories,
                nextMemoryProposals,
                nextVectorStatus,
                nextMemoryV2Status,
                nextAgentGraph,
                nextGraphEntities,
                nextGraphStatus,
                nextPersonality,
                nextTrustPolicy
            )
            memories = fresh("memories", memoryRows) ?? memories
            memoryProposals = fresh("memory proposals", proposalRows) ?? memoryProposals
            memoryVectorStatus = fresh("vector status", vectorRow) ?? memoryVectorStatus
            memoryV2Status = fresh("memory v2 status", memoryV2Row) ?? memoryV2Status
            agentGraph = fresh("agent graph", agentGraphRow) ?? agentGraph
            graphEntities = fresh("graph entities", graphRows) ?? graphEntities
            graphStatus = fresh("graph status", graphStatusRow) ?? graphStatus
            personality = fresh("personality", personalityRow) ?? personality
            trustPolicy = fresh("trust policy", trustRow) ?? trustPolicy
        case .settingsHub, .settings, .connectors, .providers, .telegram, .inboxPolicy, .macIntegration:
            async let nextConfig = try? api.getConfig()
            async let nextPrivacyMap = try? api.getPrivacyMap()
            async let nextTelegramStatus = try? api.getTelegramStatus()
            async let nextConnectors = try? api.getConnectors()
            async let nextSetupQuestions = try? api.getSetupQuestions()
            let (configRow, privacyRow, telegramRow, connectorRows, setupRows) = await (
                nextConfig,
                nextPrivacyMap,
                nextTelegramStatus,
                nextConnectors,
                nextSetupQuestions
            )
            if let config = fresh("config", configRow) {
                codexAuthStatus = config.codexAuth
                if let base = config.searxngBaseURL, !base.isEmpty {
                    searxngBaseURL = base
                }
            }
            privacyMap = fresh("privacy map", privacyRow) ?? privacyMap
            telegramStatus = fresh("telegram status", telegramRow) ?? telegramStatus
            connectors = fresh("connectors", connectorRows) ?? connectors
            setupQuestions = fresh("setup questions", setupRows) ?? setupQuestions
        case .approvals, .activity:
            async let nextApprovals = try? api.getApprovals()
            async let nextInbox = try? api.getInboxItems(unreadOnly: false)
            async let nextMemoryProposals = try? api.getMemoryProposals()
            async let nextImprovementSummary = try? api.getImprovementSummary()
            async let nextTrainingProposals = try? api.getTrainingProposals()
            async let nextPromotionCandidates = try? api.getPromotionCandidates()
            async let nextPromotionPending = try? api.getPromotionPending()
            let (approvalRows, inboxRows, proposalRows, improvementRow, trainingRows, promotionRows, pendingRows) = await (
                nextApprovals,
                nextInbox,
                nextMemoryProposals,
                nextImprovementSummary,
                nextTrainingProposals,
                nextPromotionCandidates,
                nextPromotionPending
            )
            approvals = fresh("approvals", approvalRows) ?? approvals
            inboxItems = fresh("inbox", inboxRows) ?? inboxItems
            memoryProposals = fresh("memory proposals", proposalRows) ?? memoryProposals
            improvementSummary = fresh("improvement summary", improvementRow) ?? improvementSummary
            trainingProposals = fresh("training proposals", trainingRows) ?? trainingProposals
            promotionCandidates = fresh("promotion candidates", promotionRows) ?? promotionCandidates
            promotionPending = fresh("promotion pending", pendingRows) ?? promotionPending
        case .capabilities:
            async let nextSkills = try? api.getSkills()
            async let nextTools = try? api.getTools()
            async let nextCapabilitySummary = try? api.getCapabilities()
            async let nextWorkflows = try? api.getWorkflows()
            async let nextWorkflowRuns = try? api.getWorkflowRuns()
            async let nextMCPServers = try? api.getMCPServers()
            async let nextCatalog = try? api.getCapabilityCatalog()
            async let nextCatalogSources = try? api.getCapabilityCatalogSources()
            async let nextPackInstalls = try? api.getCapabilityPackInstalls()
            async let nextCapabilityTrust = try? api.getCapabilityTrust()
            async let nextSummary = try? api.getNextGenSummary()
            async let nextPhases = try? api.getNextGenPhases()
            async let nextReceipts = try? api.getNextGenReceipts()
            let (
                skillRows,
                toolRows,
                capabilityRow,
                workflowRows,
                workflowRunRows,
                mcpRows,
                catalogRows,
                sourceRows,
                installRows,
                trustRow,
                summaryRow,
                phaseRows,
                receiptRows
            ) = await (
                nextSkills,
                nextTools,
                nextCapabilitySummary,
                nextWorkflows,
                nextWorkflowRuns,
                nextMCPServers,
                nextCatalog,
                nextCatalogSources,
                nextPackInstalls,
                nextCapabilityTrust,
                nextSummary,
                nextPhases,
                nextReceipts
            )
            skills = fresh("skills", skillRows) ?? skills
            tools = fresh("tools", toolRows) ?? tools
            capabilitySummary = fresh("capability summary", capabilityRow) ?? capabilitySummary
            workflows = fresh("workflows", workflowRows) ?? workflows
            workflowRuns = fresh("workflow runs", workflowRunRows) ?? workflowRuns
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            capabilityCatalog = fresh("capability catalog", catalogRows) ?? capabilityCatalog
            capabilityCatalogSources = fresh("catalog sources", sourceRows) ?? capabilityCatalogSources
            capabilityPackInstalls = fresh("pack installs", installRows) ?? capabilityPackInstalls
            capabilityTrust = fresh("capability trust", trustRow) ?? capabilityTrust
            nextGenSummary = fresh("nextgen summary", summaryRow) ?? nextGenSummary
            // `phaseRows` legitimately falls back to the summary's embedded
            // phases, so only count it as failed when BOTH sources are absent.
            nextGenPhases = phaseRows ?? fresh("nextgen phases", summaryRow?.phases) ?? nextGenPhases
            nextGenReceipts = fresh("nextgen receipts", receiptRows) ?? nextGenReceipts
        case .autoImprovement:
            await loadAllSelfImprovement()
            async let nextImprovementSummary = try? api.getImprovementSummary()
            async let nextImprovements = try? api.getImprovements()
            async let nextJobs = try? api.getJobs()
            async let nextTrainingArtifacts = try? api.getTrainingArtifacts()
            let (improvementRow, improvementRows, jobRows, artifactRows) = await (
                nextImprovementSummary,
                nextImprovements,
                nextJobs,
                nextTrainingArtifacts
            )
            improvementSummary = fresh("improvement summary", improvementRow) ?? improvementSummary
            improvements = fresh("improvements", improvementRows) ?? improvements
            jobs = fresh("jobs", jobRows) ?? jobs
            trainingArtifacts = fresh("training artifacts", artifactRows) ?? trainingArtifacts
        case .dreams:
            // The Dreams tab fetches its diary itself; refresh the trust policy
            // here so the REM toggle (trainingPolicy.rem_cycle_enabled) reflects
            // current state on tab entry.
            trustPolicy = fresh("trust policy", try? await api.getTrustPolicy()) ?? trustPolicy
        case .cognition:
            break
        case .skills, .skillLifecycle:
            skills = fresh("skills", try? await api.getSkills()) ?? skills
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
            async let nextActivity = try? api.getActivity()
            async let nextRuns = try? api.getRuns()
            async let nextWatchdog = try? api.getWatchdog()
            let (activityRows, runRows, watchdogRow) = await (
                nextActivity,
                nextRuns,
                nextWatchdog
            )
            activityEvents = fresh("activity", activityRows) ?? activityEvents
            runs = fresh("runs", runRows) ?? runs
            watchdogStatus = fresh("watchdog", watchdogRow) ?? watchdogStatus
        case .personality:
            async let nextPersonality = try? api.getPersonality()
            async let nextDocs = try? api.getPersonalityDocs()
            async let nextCompiled = try? api.getCompiledPersonality(surface: "chat")
            async let nextGrowth = try? api.getPersonalityGrowth()
            let (personalityRow, docsResponse, compiledRow, growthRow) = await (
                nextPersonality,
                nextDocs,
                nextCompiled,
                nextGrowth
            )
            personality = fresh("personality", personalityRow) ?? personality
            if let docsResponse = fresh("personality docs", docsResponse) {
                personalityDocs = docsResponse.docs
            }
            compiledPersonality = fresh("compiled personality", compiledRow) ?? compiledPersonality
            personalityGrowth = fresh("personality growth", growthRow) ?? personalityGrowth
        case .trust:
            async let nextTrust = try? api.getTrustPolicy()
            async let nextPrivacy = try? api.getPrivacyMap()
            async let nextConnectors = try? api.getConnectors()
            async let nextWorkspaces = try? api.getWorkspaces()
            async let nextBackups = try? api.getBackups()
            let (trustRow, privacyRow, connectorRows, workspaceRows, backupRows) = await (
                nextTrust,
                nextPrivacy,
                nextConnectors,
                nextWorkspaces,
                nextBackups
            )
            trustPolicy = fresh("trust policy", trustRow) ?? trustPolicy
            privacyMap = fresh("privacy map", privacyRow) ?? privacyMap
            connectors = fresh("connectors", connectorRows) ?? connectors
            workspaces = fresh("workspaces", workspaceRows) ?? workspaces
            backups = fresh("backups", backupRows) ?? backups
        case .panels:
            async let nextSkills = try? api.getSkills()
            async let nextTools = try? api.getTools()
            let (skillRows, toolRows) = await (nextSkills, nextTools)
            skills = fresh("skills", skillRows) ?? skills
            tools = fresh("tools", toolRows) ?? tools
        case .tools:
            async let nextTools = try? api.getTools()
            async let nextConnectorActions = try? api.getConnectorActions()
            async let nextMCPServers = try? api.getMCPServers()
            let (toolRows, connectorRows, mcpRows) = await (nextTools, nextConnectorActions, nextMCPServers)
            tools = fresh("tools", toolRows) ?? tools
            connectorActionRegistry = fresh("connector actions", connectorRows) ?? connectorActionRegistry
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            await refreshChatToolCatalog()
        case .mcp:
            async let nextMCPServers = try? api.getMCPServers()
            async let nextMCPSessions = try? api.getMCPSessions()
            async let nextMCPConsent = try? api.getMCPConsent()
            let (mcpRows, sessionRows, consentRows) = await (nextMCPServers, nextMCPSessions, nextMCPConsent)
            mcpServers = fresh("mcp servers", mcpRows) ?? mcpServers
            mcpSessions = fresh("mcp sessions", sessionRows) ?? mcpSessions
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
                mcpResources = []
            }
            if mcpServers.isEmpty {
                mcpTools = []
                mcpResources = []
            }
            if let server = selectedMCPServer {
                // Race-safe apply: only adopt fetched tools/resources if the
                // user's selection didn't change while we were awaiting.
                let pendingId = server.id
                let fetchedTools = (try? await api.getMCPTools(serverId: pendingId).tools) ?? nil
                let fetchedResources = (try? await api.getMCPResources(serverId: pendingId).resources) ?? nil
                if selectedMCPServerId == pendingId {
                    if let t = fetchedTools { mcpTools = t }
                    if let r = fetchedResources { mcpResources = r }
                }
            }
        case .inspector:
            // Turn Inspector (W3) owns its own data: it subscribes to the
            // in-process TurnTraceBus for live events and reads the persisted
            // turn_traces JSONL for replay. No daemon refresh on tab select.
            break
        }
        recordPanelRefresh(item, failedEndpoints: failedEndpoints)
        statusText = health?.ok == true ? "Native runtime online" : "Native runtime unavailable"
    }

    // MARK: - Panel staleness (M12)

    @MainActor
    func recordPanelRefresh(_ item: SidebarItem, failedEndpoints: [String]) {
        let now = Date()
        panelRefreshStatus[item] = Self.nextRefreshStatus(
            previous: panelRefreshStatus[item],
            failedEndpoints: failedEndpoints,
            at: now
        )
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

    /// True when the panel's last refresh had at least one endpoint fail, so
    /// some of what it is rendering was fetched at an earlier time.
    @MainActor
    func isPanelStale(_ item: SidebarItem) -> Bool {
        panelRefreshStatus[item]?.isStale ?? false
    }

    /// One user-facing sentence naming what could not be reached and how old
    /// the displayed data is, or nil when the last refresh was clean.
    @MainActor
    func panelStaleNotice(for item: SidebarItem) -> String? {
        guard let status = panelRefreshStatus[item], status.isStale else { return nil }
        // Endpoint names are internal vocabulary; the user-facing sentence
        // stays plain (same rule as DetachedChatLoadFailureCopy).
        guard let lastSuccess = status.lastSuccessAt else {
            return "Nothing has loaded yet this session. Check your connection."
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
    func refreshSidebarActivityBadge() async {
        let api = client
        async let nextApprovals = try? api.getApprovals()
        async let nextInbox = try? api.getInboxItems(unreadOnly: false)
        async let nextMemoryProposals = try? api.getMemoryProposals()
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
        let nextApprovalRows = Self.keepingLastGood(approvals, fetched: approvalRows)
        if approvals != nextApprovalRows { approvals = nextApprovalRows }
        let nextInboxRows = Self.keepingLastGood(inboxItems, fetched: inboxRows)
        if inboxItems != nextInboxRows { inboxItems = nextInboxRows }
        let nextProposalRows = Self.keepingLastGood(memoryProposals, fetched: proposalRows)
        if memoryProposals != nextProposalRows { memoryProposals = nextProposalRows }
        var failed: [String] = []
        if approvalRows == nil { failed.append("approvals") }
        if inboxRows == nil { failed.append("inbox") }
        if proposalRows == nil { failed.append("memory proposals") }
        if let nextStatus = Self.staleFlagOnlyStatusToStore(
            previous: sidebarActivityRefreshStatus,
            failedEndpoints: failed,
            at: Date()
        ) {
            sidebarActivityRefreshStatus = nextStatus
        }
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

    @MainActor
    func commitChatDraft(_ text: String, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if text.isEmpty {
            // Mirrors pruneChatDrafts' empty-draft rule: an empty draft is an
            // absent draft, and leaving the key behind would keep a dead
            // session pinned in the 50-entry LRU.
            chatDrafts.removeValue(forKey: sessionId)
            chatDraftLastTouched.removeValue(forKey: sessionId)
            return
        }
        guard chatDrafts[sessionId] != text else { return }
        chatDrafts[sessionId] = text
        touchChatDraft(sessionId: sessionId)
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

    // S.7: navigate to Chat and prefill the draft — ContentView's .onReceive handles tab switch + prefill.
    @MainActor
    func requestSkillBuild(starter: String = "Create a skill from this conversation: ") {
        NotificationCenter.default.post(name: .skillBuildRequest, object: starter)
    }

    @MainActor
    func loadChatState(api: NativeClient) async {
        if chatStateLoadInFlight {
            await waitForChatStateLoad()
            return
        }
        chatStateLoadInFlight = true
        await performLoadChatState(api: api)
        finishChatStateLoad()
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
        await refreshChatSessionIndex { [client] in
            try await client.getChatSessions()
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
            guard refreshed != chatSessions else { return }
            chatSessions = refreshed
            pruneChatDrafts()
            pruneStaleSessionChatState(knownSessionIds: Set(refreshed.map(\.id)))
        } catch {
            if !chatSessionIndexRefreshFailed {
                chatSessionIndexRefreshFailed = true
            }
        }
    }

    @MainActor
    private func performLoadChatState(api: NativeClient) async {
        let activeAtStart = activeChatSessionId
        let selectionGenerationAtStart = chatSelectionGeneration
        do {
            if health?.ok != true {
                for _ in 0..<8 {
                    if let fresh = try? await api.getHealth(), fresh.ok {
                        health = fresh
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
            if let policy = try? await api.getTrustPolicy() {
                trustPolicy = policy
            }
            let fetchedSessions = try await api.getChatSessions()
            chatSessionIndexRefreshFailed = false
            chatSessions = fetchedSessions
            if activeChatSessionId.isEmpty || !chatSessions.contains(where: { $0.id == activeChatSessionId }) {
                if !activeAtStart.isEmpty,
                   (activeChatSessionId != activeAtStart || chatSelectionGeneration != selectionGenerationAtStart) {
                    return
                }
                if let unified = chatSessions.first(where: { isMainAppSourceKey($0.sourceKey) && $0.archived != true }) {
                    activeChatSessionId = unified.id
                } else {
                    let session = try await api.createChatSession(title: "New Chat", sourceKey: "app")
                    activeChatSessionId = session.id
                    chatSessions = [session]
                }
                UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
            }
            migrateEmptySessionChatState(to: activeChatSessionId)
            pruneChatDrafts()
            // 2026-07-21 audit fix: prune per-session message/receipt caches
            // for sessions the list no longer reports — mirrors the stale-draft
            // prune above, same low-frequency hook.
            pruneStaleSessionChatState(knownSessionIds: Set(chatSessions.map(\.id)))
            let targetSessionId = activeChatSessionId
            let messages = try await api.getChatMessages(sessionId: targetSessionId)
            let receipt = try? await api.getLatestContextReceipt(sessionId: targetSessionId)
            guard activeChatSessionId == targetSessionId else { return }
            applyLoadedChatMessages(messages, for: targetSessionId)
            latestContextReceipt = receipt
            chatStateLoadFailed = false
        } catch {
            chatStateLoadFailed = true
            statusText = "Chat load failed: \(error.localizedDescription)"
        }
    }

    /// H4 (2026-07-09): the post-turn refresh. `.chatTurnCompleted` used to run
    /// the whole of `performLoadChatState` — a health busy-wait (up to 8 ×
    /// 350ms) plus getTrustPolicy + getChatSessions + getChatMessages +
    /// getLatestContextReceipt — on the tail of every single turn. Three of
    /// those four fetches are redundant: `_sendChatBody` already refreshes
    /// `chatSessions` and the receipt before it posts the notification, and the
    /// trust policy cannot change as a result of a chat turn. Only the message
    /// list genuinely needs re-reading from disk, to swap the optimistic
    /// bubble ids for the persisted rows.
    ///
    /// The receipt fetch stays because remote turns (iCloud/iOS forwarding)
    /// post `.chatTurnCompleted` without going through `_sendChatBody`, so
    /// nothing else refreshes it on that path.
    ///
    /// No health probe, no session-list fetch, no trust-policy fetch, and no
    /// session-creation branch: this path never *creates* state, it only
    /// re-reads the active session's messages.
    /// `messagesAlreadyRefreshed` (gpt-5.5 review, 2026-07-09): a LOCAL turn's
    /// `_sendChatBody` lands its own disk snapshot just before posting, so its
    /// notification says so and this path skips the second whole-transcript
    /// read. The receipt fetch always runs — nothing else sets it on either
    /// path — and remote turns (flag absent) keep the full refresh.
    @MainActor
    func refreshChatMessagesAfterTurn(sessionId: String, messagesAlreadyRefreshed: Bool = false) async {
        guard !sessionId.isEmpty, activeChatSessionId == sessionId else { return }
        var messages: [ChatMessage]? = nil
        if !messagesAlreadyRefreshed {
            do {
                messages = try await client.getChatMessages(sessionId: sessionId)
            } catch {
                // Don't swallow this. A failed post-turn refresh leaves optimistic
                // bubble ids on screen; saying nothing is the same lie M12 is about.
                statusText = "Chat refresh failed: \(error.localizedDescription)"
                return
            }
        }
        let receipt = try? await client.getLatestContextReceipt(sessionId: sessionId)
        // The active session can change while those awaits are in flight.
        guard activeChatSessionId == sessionId else { return }
        if let messages {
            // A NEW turn may have started on this session while we were fetching
            // (the user sent again immediately). That turn owns the slot and its
            // optimistic bubbles are fresher than this disk snapshot — mirrors
            // selectChatSession's streaming guard. The finished turn's rows are
            // already in memory, so nothing is lost by skipping the swap.
            guard !streamingSessions.contains(sessionId) else { return }
            applyLoadedChatMessages(messages, for: sessionId)
        }
        if let receipt {
            setLatestContextReceipt(receipt, for: sessionId)
        }
    }

    /// Apply a disk snapshot of `sessionId`'s messages over the in-memory list.
    ///
    /// Durability for synthetic error bubbles (audit #2 follow-up, fix Z):
    /// failure/no-content notices are in-memory only (appendChatMessage never
    /// persists), so a naive disk-replace would wipe them a beat after they
    /// appear. If the current in-memory tail is a synthetic error bubble absent
    /// from disk, carry it over so the notice survives the post-turn reload. It
    /// drops naturally once a newer turn supersedes it (it's no longer the tail).
    /// The `!isCompletedAssistant(disk.last)` clause prevents a stale error
    /// bubble from floating BELOW a newer real reply: a remote/iOS turn on this
    /// session posts .chatTurnCompleted without a local append, so only preserve
    /// while disk's newest row is NOT a completed reply (a partial/user row
    /// means the failure still stands; a real assistant reply supersedes the
    /// notice). (gpt-5.5 review of fix Z, point b.)
    ///
    /// H4: skip the write entirely when the result is identical to what's
    /// already in the slot. `chatMessagesBySession` is observed by the message
    /// list, the sidebar badges and the scroll coordinator; an equal-value
    /// write still invalidates all of them.
    @MainActor
    func applyLoadedChatMessages(_ disk: [ChatMessage], for sessionId: String) {
        var loaded = disk
        if let tail = chatMessagesBySession[sessionId]?.last,
           tail.id.hasPrefix(Self.syntheticErrorIDPrefix),
           !disk.contains(where: { $0.id == tail.id }),
           !isCompletedAssistant(disk.last) {
            loaded.append(tail)
        }
        guard chatMessagesBySession[sessionId] != loaded else { return }
        chatMessagesBySession[sessionId] = loaded
    }

    struct ChatSessionLoadSnapshot {
        let messages: [ChatMessage]
        let receipt: ContextReceipt?
    }

    @MainActor
    func selectChatSession(_ session: ChatSession) async {
        await selectChatSession(session, persistSelection: true) { [client] requestedId in
            let messages = try await client.getChatMessages(sessionId: requestedId)
            let receipt = try? await client.getLatestContextReceipt(sessionId: requestedId)
            return ChatSessionLoadSnapshot(messages: messages, receipt: receipt)
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
        let requestedId = session.id
        guard !requestedId.isEmpty else { return }
        chatSelectionGeneration += 1
        let generation = chatSelectionGeneration
        let hasCachedTranscript = chatMessagesBySession[requestedId] != nil

        if hasCachedTranscript {
            commitChatSessionSelection(
                requestedId,
                snapshot: nil,
                persistSelection: persistSelection
            )
        }

        do {
            let snapshot = try await load(requestedId)
            guard chatSelectionGeneration == generation else { return }
            if hasCachedTranscript {
                guard activeChatSessionId == requestedId else { return }
            }
            commitChatSessionSelection(
                requestedId,
                snapshot: snapshot,
                persistSelection: persistSelection
            )
        } catch {
            if chatSelectionGeneration == generation {
                statusText = "Chat session load failed: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func commitChatSessionSelection(
        _ requestedId: String,
        snapshot: ChatSessionLoadSnapshot?,
        persistSelection: Bool
    ) {
        if let snapshot {
            // A live stream owns its populated slot. An empty slot may still be
            // seeded from disk, then the optimistic rows are re-injected below.
            let isStreamingThisSession = streamingSessions.contains(requestedId)
            let inMemoryEmpty = (chatMessagesBySession[requestedId] ?? []).isEmpty
            if !isStreamingThisSession || inMemoryEmpty {
                setChatMessages(snapshot.messages, for: requestedId)
            }
            setLatestContextReceipt(snapshot.receipt, for: requestedId)
        }

        // Publish the identity only after the requested transcript slot is
        // ready. This keeps the previous conversation visible through an
        // uncached load and leaves it untouched when that load fails.
        activeChatSessionId = requestedId
        if persistSelection {
            UserDefaults.standard.set(requestedId, forKey: "activeChatSessionId")
        }

        // PATCH-2026-05-13: parallel-sessions — if this session is still
        // streaming, restore the optimistic user turn and live assistant row.
        if streamingSessions.contains(requestedId) {
            if let userTurnId = streamingUserTurnIds[requestedId],
               !chatMessages(for: requestedId).contains(where: { $0.id == userTurnId }) {
                let userText = streamingUserTurnTexts[requestedId] ?? ""
                var userBubble = ChatMessage(sessionId: requestedId, role: "user", content: userText)
                userBubble.id = userTurnId
                appendChatMessage(userBubble, to: requestedId)
            }
            if let bubbleId = streamingBubbleIds[requestedId],
               !chatMessages(for: requestedId).contains(where: { $0.id == bubbleId }) {
                let liveText = streamingTexts[requestedId] ?? ""
                var liveBubble = ChatMessage(sessionId: requestedId, role: "assistant", content: liveText)
                liveBubble.id = bubbleId
                appendChatMessage(liveBubble, to: requestedId)
            }
        }
    }

    @MainActor
    func newChatSession() async {
        do {
            let session = try await client.createChatSession(title: "New Chat", sourceKey: "app", forceNew: true)
            chatSelectionGeneration += 1
            activeChatSessionId = session.id
            UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
            chatSessions = try await client.getChatSessions()
            migrateEmptySessionChatState(to: activeChatSessionId)
            pruneChatDrafts()
            // 2026-07-21 audit fix: prune per-session message/receipt caches
            // for sessions the list no longer reports — mirrors the stale-draft
            // prune above, same low-frequency hook.
            pruneStaleSessionChatState(knownSessionIds: Set(chatSessions.map(\.id)))
            chatMessages = []
            latestContextReceipt = nil
            statusText = "New chat session ready"
        } catch {
            statusText = "New chat failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func renameActiveChat(_ title: String) async {
        await renameChatSession(id: activeChatSessionId, title: title)
    }

    @MainActor
    func renameChatSession(id sessionId: String, title: String) async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !cleanTitle.isEmpty else { return }
        do {
            let updated = try await client.updateChatSession(id: sessionId, title: cleanTitle, archived: nil)
            if let refreshed = try? await client.getChatSessions() {
                chatSessions = refreshed
            } else if let index = chatSessions.firstIndex(where: { $0.id == sessionId }) {
                chatSessions[index] = updated
            }
            statusText = "Renamed chat session"
        } catch {
            statusText = "Rename failed: \(error.localizedDescription)"
        }
    }

    // PATCH-2026-05-13: settings-toggle-2 — AppModel wrappers for the
    // embeddings-backend toggle. SlimSettingsView's
    // EmbeddingsSettingsSection consumes these (can't reach `client`
    // directly because it's private).
}
