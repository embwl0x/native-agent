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
// Blueprint: | `AppModel+PanelRefresh.swift` | Panel commands and selected freshness reads; `PanelFreshnessOwner` admits receipts off main |

@MainActor
extension AppModel {
    @discardableResult
    func refreshForSidebarItem(_ item: SidebarItem) async -> PanelRefreshStatus {
        let result = await engine.panelFreshness.refresh(panel: item.rawValue) { [self] in
            await readPanelEndpoints(item)
        }
        guard result.admitted else { return result.receipt }
        let receipt = result.receipt
        if item == .diagnostics {
            switch engine.doctor.health?.ok {
            case true?: statusText = "I'm online"
            case false?: statusText = "I'm unavailable"
            case nil: statusText = "My connection status is unknown"
            }
        } else if !result.performedRead {
            statusText = "\(item.rawValue) opened"
        } else if receipt.failedEndpoints.isEmpty {
            statusText = "\(item.rawValue) up to date"
        } else {
            statusText = "\(item.rawValue) partly unavailable: " + receipt.failedEndpoints.joined(separator: ", ")
        }
        return receipt
    }

    private func readPanelEndpoints(_ item: SidebarItem) async -> PanelFreshnessOwner.ReadOutcome {
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
            // Before the first names are saved there is no personality to read: absent, not a failed refresh.
            let named = FileManager.default.fileExists(atPath: engine.dataRoot.appendingPathComponent("memory/profile.json").path)
            let documents = try? await persona.loadDocuments()
            if named { _ = fresh("personality", documents) }
            // Load the profile on Chat entry so names come from their owner.
            if persona.profile == nil {
                let profile = try? await persona.loadProfile()
                if named { _ = fresh("personality profile", profile) }
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
            if memoryRows != nil {
                // Even unchanged newest-200 rows can conceal a changed older search hit; refresh search after every successful read.
                await memory.refreshSearch()
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
            // Arriving here asks only a connected provider with no list saved for its current credential.
            engine.providers.fetchMissingModelListsInBackground()
            switch await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            case .loaded(let settings):
                if settings.catalogError != nil { failedEndpoints.append("model catalog") }
            case .failed: failedEndpoints.append("providers")
            }
        case .settings:
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
        case .cognition, .inboxPolicy:
            // The Inbox face reads its own owner through engine.pages.
            performedRead = false
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
        case .inspector:
            performedRead = false
        case .ownPage:
            // A page of the agent's own reads itself through engine.pages when it is drawn or read.
            performedRead = false
        }
        return .init(failedEndpoints: failedEndpoints, performedRead: performedRead,
                     providerNeedsConnection: engine.providers.settings != nil && !engine.providers.hasReadyConnection)
    }

    // MARK: - Panel staleness

    func panelStaleNotice(for item: SidebarItem) -> String? {
        let id = item.rawValue
        return face.slot(.counts).select("panel.notice.\(id)", as: CountsFace.self) { $0?.panels.panels[id]?.staleNotice }
    }

    @MainActor
    @discardableResult
    func refreshSidebarActivityBadge() async -> PanelRefreshStatus {
        let receipt = await engine.panelFreshness.refreshSidebar { [self] in
            await readSidebarEndpoints()
        }
        await publishWorkStatus()
        return receipt
    }

    private func readSidebarEndpoints() async -> [String] {
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
        return failed
    }
}
