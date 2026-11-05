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
// Blueprint: | `AppModel+PanelRefresh.swift` | `AppModel`, `LatestRead`: Ordered panel reads and shared activity badges |

@MainActor
extension AppModel {
    // Retain successful reads while per-panel LatestRead receipts identify failed endpoints.
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
        let toolStore = engine.tools
        var failedEndpoints: [String] = []
        // Branches that perform no read must not claim refreshed data.
        var performedRead = true
        /// Retain displayed values while recording unavailable endpoints.
        func fresh<T>(_ endpoint: String, _ value: T?) -> T? {
            if value == nil { failedEndpoints.append(endpoint) }
            return value
        }

        // Navigation fetches page data; health reads belong to refreshAll and each health consumer.
        switch item {
        case .chat:
            if !(await loadProvidersForChat()) { failedEndpoints.append("providers") }
            if engine.providers.settings?.catalogError != nil { failedEndpoints.append("model catalog") }
            await reloadChatState()
            if chatStateLoadFailed { failedEndpoints.append("chat messages") }
            _ = fresh("personality", try? await persona.loadDocuments())
            // Load the profile on Chat entry so names come from their owner.
            if persona.profile == nil {
                _ = fresh("personality profile", try? await persona.loadProfile())
                teachMemoryHygieneName(previousName: previousName)
            }
        case .bots:
            if !(await engine.contactThreads.refreshHelpers()) { failedEndpoints.append("helpers") }
        case .desk:
            // No read means no freshness claim.
            performedRead = false
            break
        case .memories, .knowledge:
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
                // Even unchanged newest-200 rows can conceal a changed older search hit; refresh search after every successful read.
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
        case .providers:
            switch await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            case .loaded(let settings):
                if settings.catalogError != nil { failedEndpoints.append("model catalog") }
            case .failed: failedEndpoints.append("providers")
            }
        case .settings, .telegram, .inboxPolicy, .macIntegration:
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
        case .activity:
            let badgeReceipt = await refreshSidebarActivityBadge()
            failedEndpoints += badgeReceipt.failedEndpoints
            // Read main-actor-owned LatestRead here; an async let child cannot access it.
            let nextMisses = await missLessonsRead.read({ await MemoryRecoveryReadout.recentMisses(dataRoot: engine.dataRoot) }, publish: { rows in
                if let rows { missLessons = rows }
            })
            _ = fresh("misses", nextMisses)
        case .capabilities:
            async let nextCatalog = engine.trust.refreshCapabilityCatalog()
            async let nextWorkflows: Void? = try? engine.desk.refreshWorkflows()
            async let nextNativePower = toolStore.refreshNativePower()
            async let nextHardening = engine.doctor.refreshHardening()
            async let nextConnectorActions = try? engine.connectors.refreshActions()
            async let nextTrust = try? engine.trust.load()
            let (_, workflowRead, _, _, connectorRead, trustRead) = await (
                nextCatalog, nextWorkflows, nextNativePower, nextHardening, nextConnectorActions, nextTrust)
            failedEndpoints += engine.trust.catalogRefresh?.failedEndpoints ?? []
            failedEndpoints += toolStore.nativePowerRefresh?.failedEndpoints ?? []
            failedEndpoints += engine.doctor.hardeningRefresh?.failedEndpoints ?? []
            _ = fresh("workflows", workflowRead)
            _ = fresh("connector actions", connectorRead)
            _ = fresh("trust policy", trustRead)
            await engine.pages.refresh(page: "capabilities")
        case .dreams:
            // Refresh Trust on Dreams entry so the REM switch reflects the saved policy; the tab owns its diary read.
            _ = fresh("trust policy", try? await engine.trust.load())
        case .cognition:
            performedRead = false
        case .skills:
            _ = fresh("skills", try? await toolStore.refreshSkills())
        case .diagnostics:
            await refreshLiveDoctorCoverage()
            await engine.refreshDiagnosticsLivingStatus()
            async let nextActivity: Void? = try? engine.doctor.refreshActivity()
            async let nextRuns = try? engine.runs.refresh(dataRoot: engine.dataRoot)
            async let nextWatchdog = engine.doctor.refreshWatchdog(manager: backgroundLoopsManager)
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
        case .tools:
            async let nextTools = try? toolStore.listAuthored()
            async let nextConnectorActions = try? engine.connectors.refreshActions()
            // Refresh Trust with the tool catalog so an unavailable policy cannot render as off.
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
            performedRead = false
        }
        return (Self.nextRefreshStatus(previous: panelRefreshStatus[item],
                                       failedEndpoints: failedEndpoints, at: Date()), performedRead)
        }, publish: { result in
        let (receipt, performedRead) = result
        panelRefreshStatus[item] = receipt
        // Health belongs to Diagnostics; other pages report only their own reads.
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

    /// Only changed failure lists invalidate isStale readers; timestamps remain live.
    static func staleFlagOnlyStatusToStore(
        previous: PanelRefreshStatus?,
        failedEndpoints: [String],
        at now: Date
    ) -> PanelRefreshStatus? {
        // Nil means loading, so the first receipt must publish.
        guard let previous else {
            return nextRefreshStatus(previous: nil, failedEndpoints: failedEndpoints, at: now)
        }
        // A changed failure set is a changed outcome even while stale.
        guard previous.failedEndpoints == failedEndpoints else {
            return nextRefreshStatus(previous: previous, failedEndpoints: failedEndpoints, at: now)
        }
        return nil
    }

    /// Name failed endpoints and retained-data age so stale values cannot imply a successful read.
    @MainActor
    func panelStaleNotice(for item: SidebarItem) -> String? {
        guard let status = panelRefreshStatus[item], status.isStale else { return nil }
        // Translate internal endpoint names into plain user-facing vocabulary.
        guard let lastSuccess = status.lastSuccessAt else {
            // Name missing providers only when that is the recorded cause; other failures retain their own scope.
            return Set(status.failedEndpoints).isSubset(of: ["providers", "model catalog"]) && engine.providers.settings != nil
                && !engine.providers.hasReadyConnection
                ? "Nothing has loaded yet this session: no AI provider is connected. Connect one in Providers."
                : "Nothing has loaded yet this session: the last read failed."
        }
        let age = Self.approximateAgeDescription(since: lastSuccess, now: status.lastAttemptAt)
        return "Showing data from \(age) — some information couldn't be refreshed."
    }

    /// Coarse age communicates staleness without implying precise timing.
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
        let attemptedAt = Date()
        let receipt = await sidebarActivityRead.read({
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
        // Approval, inbox and proposal reads must publish through their owners.
        var failed: [String] = []
        if approvalRows == nil { failed.append("approvals") }
        if inboxRows == nil { failed.append("inbox") }
        if proposalRows == nil { failed.append("memory proposals") }
        let receipt = PanelRefreshStatus(
            lastAttemptAt: attemptedAt,
            lastSuccessAt: failed.isEmpty ? attemptedAt : sidebarActivityRefreshStatus?.lastSuccessAt,
            failedEndpoints: failed
        )
        return receipt
        }, publish: { receipt in
        if let nextStatus = Self.staleFlagOnlyStatusToStore(
            previous: sidebarActivityRefreshStatus,
            failedEndpoints: receipt.failedEndpoints,
            at: receipt.lastAttemptAt
        ) {
            sidebarActivityRefreshStatus = nextStatus
            ModuleLog.app("""
                [sidebar-activity] published attempt=\(receipt.lastAttemptAt.timeIntervalSince1970) \
                failed_endpoints=\(receipt.failedEndpoints.joined(separator: ","))
                """)
        }
        })
        await publishWorkStatus()
        return receipt
    }
}
