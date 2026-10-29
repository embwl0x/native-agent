import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import MemoryV2
import PersistenceCore
import AttentionRouting
import DoctorChecks
import WidgetKit
import AppIntents
import Observation
import ProviderRouting
import BackgroundLoops
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import TrustCenter
import MultimodalTTS
import SystemOps
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+PanelRefresh.swift` | `AppModel`: per-panel `LatestRead` and freshness receipts; sidebar reads engine-owned sources without claiming unrelated refreshes |

@MainActor
extension AppModel {
    // Per-panel LatestRead receipts identify failed endpoints while retaining other successful reads.
    @MainActor
    @discardableResult
    func refreshForSidebarItem(_ item: SidebarItem) async -> PanelRefreshStatus {
        panelRefreshCounts[item, default: 0] += 1
        defer {
            let remaining = panelRefreshCounts[item, default: 1] - 1
            if remaining == 0 { panelRefreshCounts.removeValue(forKey: item) }
            else { panelRefreshCounts[item] = remaining }
        }
        let read = panelRefreshReads[item] ?? LatestRead()
        panelRefreshReads[item] = read
        let result = await read.read({
        let persona = engine.persona
        let previousName = persona.profile?.name
        let memory = engine.memory
        let approvalStore = engine.approvals
        let inbox = engine.inbox
        let toolStore = engine.tools
        var failedEndpoints: [String] = []
        // Branches that perform no read must not claim refreshed data.
        var performedRead = true
        /// Retain displayed values and record each unavailable endpoint.
        func fresh<T>(_ endpoint: String, _ value: T?) -> T? {
            if value == nil { failedEndpoints.append(endpoint) }
            return value
        }

        // Navigation fetches page data; refreshAll and each health consumer own their health reads.
        switch item {
        case .chat:
            if !(await loadProvidersForChat()) { failedEndpoints.append("providers") }
            if engine.providers.settings?.catalogError != nil { failedEndpoints.append("model catalog") }
            await reloadChatState()
            if chatStateLoadFailed { failedEndpoints.append("chat messages") }
            _ = fresh("personality", try? await persona.prepareDocuments())
            // Load the profile on Chat entry so every name comes from its owner.
            if persona.profile == nil {
                _ = fresh("personality profile", try? await persona.loadProfile())
                teachMemoryHygieneName(previousName: previousName)
            }
        case .legacyWorkshop:
            // Approvals refresh independently of execution runs.
            _ = fresh("runs", try? await engine.runs.refresh(dataRoot: engine.dataRoot))
        case .desk, .workshop, .work, .command, .bots:
            // Nothing is read here, so nothing is said about freshness below.
            performedRead = false
            // DeskPageView, SchedulerView and ResearchView own their bounded reads.
            break
        case .memory, .memories, .knowledge:
            async let nextMemories = try? memory.refreshMemories()
            async let nextMemoryProposals = try? memory.proposals(status: "pending")
            async let nextMemoryStatus = memory.refreshStatuses()
            async let nextGraph: Void = memory.loadGraph()
            async let nextPersonality = try? persona.loadProfile()
            async let nextTrustPolicy = try? engine.trust.load()
            let (memoryRows, proposalRows, _, _, personalityRow, trustRow) = await (
                nextMemories,
                nextMemoryProposals,
                nextMemoryStatus,
                nextGraph,
                nextPersonality,
                nextTrustPolicy
            )
            _ = fresh("memories", memoryRows)
            if memoryRows != nil, let query = memory.searchQuery, query.count >= 3 {
                // Even an unchanged newest-200 list can hide a changed older
                // search hit. Ask the search owner again on every successful read.
                await memory.search(query: query)
            }
            _ = fresh("memory proposals", proposalRows)
            failedEndpoints += memory.statusRefresh?.failedEndpoints ?? []
            _ = fresh("personality", personalityRow)
            teachMemoryHygieneName(previousName: previousName)
            _ = fresh("trust policy", trustRow)
        case .connectors:
            _ = fresh("connectors", try? await engine.connectors.refresh().get())
            _ = fresh("shared folders", try? await engine.connectors.refreshWorkspaces())
        case .settingsHub, .settings, .providers, .telegram, .inboxPolicy, .macIntegration:
            async let nextConfig: Void? = try? RuntimeReadouts.configuration(engine: engine)
            async let nextTelegramStatus = try? engine.telegram.refresh(manager: backgroundLoopsManager)
            async let nextConnectors = try? engine.connectors.refresh().get()
            let (configRow, telegramRow, connectorRows) = await (
                nextConfig,
                nextTelegramStatus,
                nextConnectors
            )
            _ = fresh("config", configRow)
            _ = fresh("telegram status", telegramRow)
            _ = fresh("connectors", connectorRows)
        case .approvals, .activity:
            async let nextApprovals = try? approvalStore.list()
            async let nextInbox = try? inbox.list()
            async let nextMemoryProposals = try? memory.proposals(status: "pending")
            let (approvalRows, inboxRows, proposalRows) = await (
                nextApprovals,
                nextInbox,
                nextMemoryProposals
            )
            _ = fresh("approvals", approvalRows)
            _ = fresh("inbox", inboxRows)
            _ = fresh("memory proposals", proposalRows)
            // LatestRead is main-actor owned: read it here, not in an async let child task.
            let nextMisses = await missLessonsRead.read({ await MemoryRecoveryReadout.recentMisses(dataRoot: engine.dataRoot) }, publish: { rows in
                if let rows { missLessons = rows }
            })
            _ = fresh("misses", nextMisses)
        case .capabilities:
            async let nextSkills = try? toolStore.refreshSkills()
            async let nextTools = try? toolStore.listAuthored()
            async let nextApprovals = try? approvalStore.list()
            async let nextCatalog = engine.trust.refreshCapabilityCatalog()
            async let nextWorkflows: Void? = try? engine.desk.refreshWorkflows()
            async let nextNativePower = toolStore.refreshNativePower()
            async let nextMemoryStatus = memory.refreshStatuses()
            async let nextHardening = engine.doctor.refreshHardening()
            async let nextTraces: Void = engine.turns.refreshCapabilityTraces()
            async let nextConnectorActionRegistry = try? engine.connectors.refreshActions()
            async let nextGraph: Void = engine.memory.loadGraph()
            let (
                skillRows,
                toolRows,
                approvalRows,
                connectorActionRegistryRow,
                _
            ) = await (
                nextSkills,
                nextTools,
                nextApprovals,
                nextConnectorActionRegistry,
                nextGraph
            )
            let (_, workflowRead, _, _, _, _) = await (
                nextCatalog, nextWorkflows, nextNativePower, nextMemoryStatus, nextHardening, nextTraces)
            failedEndpoints += engine.trust.catalogRefresh?.failedEndpoints ?? []
            _ = fresh("workflows", workflowRead)
            failedEndpoints += toolStore.nativePowerRefresh?.failedEndpoints ?? []
            failedEndpoints += memory.statusRefresh?.failedEndpoints ?? []
            failedEndpoints += engine.doctor.hardeningRefresh?.failedEndpoints ?? []
            _ = fresh("skills", skillRows)
            _ = fresh("tools", toolRows)
            _ = fresh("approvals", approvalRows)
            _ = fresh("connector actions", connectorActionRegistryRow)
        case .autoImprovement:
            // The weekly pass reads its digest directly.
            _ = await refreshSchedulerJobs()
        case .dreams:
            // The Dreams tab fetches its diary itself; refresh the trust policy
            // here so the REM toggle (trainingPolicy.rem_cycle_enabled) reflects
            // current state on tab entry.
            _ = fresh("trust policy", try? await engine.trust.load())
        case .cognition:
            performedRead = false
        case .skills, .skillLifecycle:
            _ = fresh("skills", try? await toolStore.refreshSkills())
        case .diagnostics:
            // Diagnostics reads Doctor's activity projection and the run ledger.
            async let nextActivity: Void? = try? engine.doctor.refreshActivity()
            async let nextRuns = try? engine.runs.refresh(dataRoot: engine.dataRoot)
            async let nextWatchdog = engine.doctor.refreshWatchdog(manager: backgroundLoopsManager)
            // Diagnostics owns the runtime health read.
            await engine.doctor.refreshHealth()
            let (activityRows, runRows, watchdogRow) = await (
                nextActivity,
                nextRuns,
                nextWatchdog
            )
            _ = fresh("activity", activityRows)
            _ = fresh("runs", runRows)
            _ = fresh("watchdog", watchdogRow)
        case .personality:
            async let nextPersonality = try? persona.loadProfile()
            async let nextDocs = reloadPersonalityDocuments()
            let (personalityRow, docsResponse) = await (
                nextPersonality,
                nextDocs
            )
            _ = fresh("personality", personalityRow)
            teachMemoryHygieneName(previousName: previousName)
            if case .failed = docsResponse { failedEndpoints.append("personality docs") }
        case .trust:
            async let nextTrust = try? engine.trust.load()
            async let nextConnectors = try? engine.connectors.refresh().get()
            async let nextWorkspaces = try? engine.connectors.refreshWorkspaces()
            async let nextBackups = try? engine.trust.refreshBackups()
            let (trustRow, connectorRows, workspaceRows, backupRows) = await (nextTrust, nextConnectors, nextWorkspaces, nextBackups)
            _ = fresh("trust policy", trustRow)
            _ = fresh("connectors", connectorRows)
            _ = fresh("workspaces", workspaceRows)
            _ = fresh("backups", backupRows)
        case .panels:
            async let nextSkills = try? toolStore.refreshSkills()
            async let nextTools = try? toolStore.listAuthored()
            let (skillRows, toolRows) = await (nextSkills, nextTools)
            _ = fresh("skills", skillRows)
            _ = fresh("tools", toolRows)
        case .tools:
            async let nextTools = try? toolStore.listAuthored()
            async let nextConnectorActions = try? engine.connectors.refreshActions()
            // Tools renders the current catalog *and* its Full Mac lifecycle
            // explanation. Refresh the Trust policy in the same pass so an
            // expired/unreadable window is never flattened into "off".
            async let nextTrustPolicy = try? engine.trust.load()
            let (toolRows, connectorRows, trustPolicyRow) = await (
                nextTools,
                nextConnectorActions,
                nextTrustPolicy
            )
            _ = fresh("tools", toolRows)
            _ = fresh("connector actions", connectorRows)
            _ = fresh("trust policy", trustPolicyRow)
            if !(await toolStore.refreshCatalog()) {
                failedEndpoints.append("tool catalog")
            }
        case .inspector:
            // Turn Inspector owns live TurnTraceBus events and persisted turn_traces JSONL replay.
            performedRead = false
        }
        return (Self.nextRefreshStatus(previous: panelRefreshStatus[item],
                                       failedEndpoints: failedEndpoints, at: Date()), performedRead)
        }, publish: { result in
        let (receipt, performedRead) = result
        panelRefreshStatus[item] = receipt
        if item.normalized == .activity {
            // Reuse the Activity read for the badge’s three sources without another fetch.
            let badgeEndpoints: Set<String> = ["approvals", "inbox", "memory proposals"]
            let badgeFailures = receipt.failedEndpoints.filter { badgeEndpoints.contains($0) }
            if let nextStatus = Self.staleFlagOnlyStatusToStore(
                previous: sidebarActivityRefreshStatus,
                failedEndpoints: badgeFailures,
                at: receipt.lastAttemptAt
            ) {
                sidebarActivityRefreshStatus = nextStatus
            }
        }
        // Only Diagnostics reads runtime health; other pages report their own reads.
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
        })
        return result.0
    }

    // MARK: - Panel staleness

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

    /// Store only changed failure lists for readers of `isStale`; panel timestamps remain live.
    static func staleFlagOnlyStatusToStore(
        previous: PanelRefreshStatus?,
        failedEndpoints: [String],
        at now: Date
    ) -> PanelRefreshStatus? {
        // Nil means loading, so the first receipt always publishes.
        guard let previous else {
            return nextRefreshStatus(previous: nil, failedEndpoints: failedEndpoints, at: now)
        }
        // A changed failure set is a changed outcome even while still stale.
        guard previous.failedEndpoints == failedEndpoints else {
            return nextRefreshStatus(previous: previous, failedEndpoints: failedEndpoints, at: now)
        }
        return nil
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
            return Set(status.failedEndpoints).isSubset(of: ["providers", "model catalog"]) && engine.providers.settings != nil && !engine.providers.hasReadyConnection
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
        // Approval, inbox and pending proposal reads publish through their owners.
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
}
