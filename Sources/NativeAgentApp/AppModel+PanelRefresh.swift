import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import BodyRuntime
import MindCore
import PersistenceCore
import WidgetKit
import AppIntents
import Observation
import ProviderRouting
import SenseCore
import DeskCore
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
            switch engine.doctor.health?.reachable {
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
        func fresh(_ endpoint: String, _ failure: String?) -> Bool {
            if let failure { failedEndpoints.append(endpoint + ": " + failure) }
            return failure == nil
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
            let documentsFailure = await panelRead { _ = try await persona.loadDocuments() }
            if named { _ = fresh("personality", documentsFailure) }
            // Load the profile on Chat entry so names come from their owner.
            if persona.profile == nil {
                let profileFailure = await panelRead { _ = try await persona.loadProfile() }
                if named { _ = fresh("personality profile", profileFailure) }
                teachMemoryHygieneName(previousName: previousName)
            }
        case .bots:
            if !(await engine.contactThreads.refreshHelpers()) { failedEndpoints.append("helpers") }
        case .desk:
            // No read means no freshness claim.
            performedRead = false
            break
        case .memories, .knowledge:
            async let nextMemories = panelRead { _ = try await memory.refreshMemories() }
            async let nextMemoryProposals = panelRead { _ = try await memory.proposals(status: "pending") }
            async let nextMemoryStatus = memory.refreshStatuses()
            async let nextGraph: Void = memory.loadGraph()
            async let nextPersonality = panelRead { _ = try await persona.loadProfile() }
            async let nextTrustPolicy = panelRead { _ = try await engine.trust.load() }
            let (memoryFailure, proposalFailure, _, _, personalityFailure, trustFailure) = await (
                nextMemories,
                nextMemoryProposals,
                nextMemoryStatus,
                nextGraph,
                nextPersonality,
                nextTrustPolicy
            )
            if fresh("memories", memoryFailure) {
                // Even unchanged newest-200 rows can conceal a changed older search hit; refresh search after every successful read.
                await memory.refreshSearch()
            }
            _ = fresh("memory proposals", proposalFailure)
            failedEndpoints += memory.statusRefresh?.failedEndpoints ?? []
            _ = fresh("personality", personalityFailure)
            teachMemoryHygieneName(previousName: previousName)
            _ = fresh("trust policy", trustFailure)
        case .connectors:
            _ = fresh("connectors", await panelRead { _ = try await engine.connectors.refresh().get() })
            _ = fresh("shared folders", await panelRead { _ = try await engine.connectors.refreshWorkspaces() })
        case .providers:
            // Arriving here asks only a connected provider with no list saved for its current credential.
            engine.providers.fetchMissingModelListsInBackground()
            switch await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
            case .loaded(let settings):
                if settings.catalogError != nil { failedEndpoints.append("model catalog") }
            case .failed: failedEndpoints.append("providers")
            }
        case .settings:
            async let nextConfig = panelRead { try await RuntimeReadouts.configuration(engine: engine) }
            async let nextTelegramStatus = panelRead { _ = try await engine.telegram.refresh(manager: backgroundLoopsManager) }
            async let nextConnectors = panelRead { _ = try await engine.connectors.refresh().get() }
            let (configurationFailure, telegramFailure, connectorFailure) = await (
                nextConfig,
                nextTelegramStatus,
                nextConnectors
            )
            _ = fresh("config", configurationFailure)
            _ = fresh("telegram status", telegramFailure)
            _ = fresh("connectors", connectorFailure)
        case .activity:
            let badgeReceipt = await refreshSidebarActivityBadge()
            failedEndpoints += badgeReceipt.failedEndpoints
        case .capabilities:
            async let nextCatalog = engine.trust.refreshCapabilityCatalog()
            async let nextNativePower = toolStore.refreshNativePower()
            async let nextHardening = engine.doctor.refreshHardening()
            async let nextConnectorActions = panelRead { _ = try await engine.connectors.refreshActions() }
            async let nextTrust = panelRead { _ = try await engine.trust.load() }
            let (_, _, _, connectorFailure, trustFailure) = await (
                nextCatalog, nextNativePower, nextHardening, nextConnectorActions, nextTrust)
            failedEndpoints += engine.trust.catalogRefresh?.failedEndpoints ?? []
            failedEndpoints += toolStore.nativePowerRefresh?.failedEndpoints ?? []
            failedEndpoints += engine.doctor.hardeningRefresh?.failedEndpoints ?? []
            _ = fresh("connector actions", connectorFailure)
            _ = fresh("trust policy", trustFailure)
            await engine.pages.refresh(page: "capabilities")
        case .dreams:
            // Refresh Trust on Dreams entry so the REM switch reflects the saved policy; the tab owns its diary read.
            _ = fresh("trust policy", await panelRead { _ = try await engine.trust.load() })
        case .cognition, .inboxPolicy:
            // The Inbox face reads its own owner through engine.pages.
            performedRead = false
        case .diagnostics:
            await refreshLiveDoctorCoverage()
            await engine.refreshDiagnosticsLivingStatus()
            async let nextActivity = panelRead { try await engine.doctor.refreshActivity() }
            async let nextRuns = panelRead { _ = try await engine.runs.refresh(dataRoot: engine.dataRoot) }
            async let nextWatchdog = engine.doctor.refreshWatchdog(manager: backgroundLoopsManager)
            await engine.doctor.refreshHealth()
            let (activityFailure, runFailure, _) = await (
                nextActivity,
                nextRuns,
                nextWatchdog
            )
            _ = fresh("activity", activityFailure)
            _ = fresh("runs", runFailure)
        case .personality:
            async let nextPersonality = panelRead { _ = try await persona.loadProfile() }
            async let nextDocs = reloadPersonalityDocuments()
            let (personalityFailure, docsResponse) = await (
                nextPersonality,
                nextDocs
            )
            _ = fresh("personality", personalityFailure)
            teachMemoryHygieneName(previousName: previousName)
            if case .failed(let detail, _) = docsResponse { failedEndpoints.append("personality docs: " + detail) }
        case .trust:
            async let nextTrust = panelRead { _ = try await engine.trust.load() }
            async let nextConnectors = panelRead { _ = try await engine.connectors.refresh().get() }
            async let nextWorkspaces = panelRead { _ = try await engine.connectors.refreshWorkspaces() }
            async let nextBackups = panelRead { _ = try await engine.trust.refreshBackups() }
            let (trustFailure, connectorFailure, workspaceFailure, backupFailure) = await (nextTrust, nextConnectors, nextWorkspaces, nextBackups)
            _ = fresh("trust policy", trustFailure)
            _ = fresh("connectors", connectorFailure)
            _ = fresh("workspaces", workspaceFailure)
            _ = fresh("backups", backupFailure)
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

    private func panelRead(_ operation: @MainActor () async throws -> Void) async -> String? {
        do { try await operation(); return nil }
        catch { return NativeAppSecretRedactor.redactText(error.localizedDescription) }
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
        async let nextApprovals = panelRead { _ = try await approvalStore.list() }
        async let nextInbox = panelRead { _ = try await inbox.list() }
        async let nextMemoryProposals = panelRead { _ = try await memory.proposals(status: "pending") }
        let (approvalFailure, inboxFailure, proposalFailure) = await (
            nextApprovals,
            nextInbox,
            nextMemoryProposals
        )
        // Approval, inbox and proposal reads must publish through their owners.
        var failed: [String] = []
        if let approvalFailure { failed.append("approvals: " + approvalFailure) }
        if let inboxFailure { failed.append("inbox: " + inboxFailure) }
        if let proposalFailure { failed.append("memory proposals: " + proposalFailure) }
        return failed
    }
}
