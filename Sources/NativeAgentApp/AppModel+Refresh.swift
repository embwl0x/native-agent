import EngineRuntime
import Foundation
import AppToolRuntime
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
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import TrustCenter
import DreamREMCycle
import DoctorChecks
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
import MacIntegration
import WorkflowOrchestration
import Connectors
import Browser
// Blueprint: | `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll`; Telegram form reads share `refreshTelegramSettingsDraft` with the direct refresh |

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
            isRecordingRefreshAllFailures = false
            refreshAllInFlight = false
            if refreshAllQueued {
                refreshAllQueued = false
                Task { @MainActor in
                    await self.refreshAll()
                }
            }
        }

        // Start a fresh, complete failure set for this pass. Individual lanes
        // append their detail through `recordRefreshFailure`; a successful
        // empty result remains a real empty projection rather than looking
        // like one of those failures.
        refreshAllFailureDetails.removeAll(keepingCapacity: true)
        isRecordingRefreshAllFailures = true
        setIfChanged(\.lastRefreshError, nil)
        // Each engine facade owns its retained reads and their availability.
        // App-only fields below are published together after their reads.
        await engine.doctor.refreshHealth()

        _ = await decodeLogged("getRuns") { try await engine.runs.refresh(dataRoot: engine.dataRoot) }
        _ = await decodeLogged("getActivity") { try await engine.doctor.refreshActivity() }
        _ = await refreshPreserving("getMemories", current: engine.memory.memories) {
            try await engine.memory.refreshMemories()
        }
        let previousName = engine.persona.profile?.name
        if let profile = await decodeLogged("getPersonality", { try await engine.persona.loadProfile() }), profile.name != previousName {
            NativeAgentShortcuts.updateAppShortcutParameters()
        }
        _ = await decodeLogged("getPersonalityDocs", { try await engine.persona.loadDocuments() })
        _ = await decodeLogged("getSkills") { try await engine.tools.refreshSkills() }
        _ = await decodeLogged("getTools") { try await engine.tools.listAuthored() }
        for failure in await engine.trust.refreshCapabilityCatalog() { recordRefreshFailure(failure.label, error: failure.error) }
        _ = await decodeLogged("getWorkflows") { try await engine.desk.refreshWorkflows() }
        _ = await decodeLogged("getApprovals") { try await engine.approvals.list() }
        _ = await decodeLogged("getInboxItems") { try await engine.inbox.list() }
        await engine.desk.refreshResearchRuns()
        await engine.turns.refreshCapabilityTraces()
        await engine.memory.loadGraph()
        _ = await decodeLogged("nextgen snapshot") { try await engine.nextGen.snapshot() }
        for failure in await engine.tools.refreshNativePower() { recordRefreshFailure(failure.label, error: failure.error) }
        for failure in await engine.memory.refreshStatuses() { recordRefreshFailure(failure.label, error: failure.error) }
        _ = await decodeLogged("getConnectorActions") { try await engine.connectors.refreshActions() }
        for failure in await engine.doctor.refreshHardening() { recordRefreshFailure(failure.label, error: failure.error) }
        _ = await decodeLogged("getTrustPolicy") { try await engine.trust.load() }
        _ = await refreshPreserving("getBackups", current: engine.trust.backups) { try await engine.trust.refreshBackups() }
        _ = await decodeLogged("getConnectors") { try await engine.connectors.refresh().get() }
        _ = await decodeLogged("getWorkspaces") { try await engine.connectors.refreshWorkspaces() }
        _ = await decodeLogged("getWatchdog") { await engine.doctor.refreshWatchdog(manager: backgroundLoopsManager) }
        _ = await engine.desk.refreshJobs()
        if let detail = engine.desk.jobsFeedState?.failureDetail {
            recordRefreshFailure("getJobs", error: RuntimeReadError.unreadableFeed(detail))
        }
        await refreshTelegramSettingsDraft({
        await decodeLogged("getTelegramStatus") { try await engine.telegram.refresh(manager: backgroundLoopsManager) }
        }, snapshot: { status in
            guard let st = status else { return nil }
            return TelegramSettingsDraftSnapshot(
                enabled: st.enabled, chats: st.allowedChatIds.joined(separator: ","),
                users: st.allowedUserIds.joined(separator: ","), requireMention: st.requireMention
            )
        }, publish: { fetchedTelegramStatus in
        if fetchedTelegramStatus != nil {
            telegramStatusRefreshError = nil
        }
        })
        // PATCH-2026-05-07: chat-provider-picker Populate providers list at
        // app startup so the chat brain bar's Provider dropdown isn't
        // empty on first render. The bar's own .task also calls this, but
        // that doesn't help when the chat surface mounts before the
        // providers fetch completes.
        await loadProvidersForChat()
        if let detail = engine.providers.settings?.catalogError {
            recordRefreshFailure("getModelCatalog", error: RuntimeReadError.unreadableFeed(detail))
        }
        await reloadChatState()
        await refreshTelegramSettingsDraft({
        await decodeLogged("getConfig", { try await RuntimeReadProjection.configuration(engine: engine) })
        }, snapshot: { config in
            guard let telegram = config?.telegram else { return nil }
            return TelegramSettingsDraftSnapshot(
                enabled: telegram.enabled, chats: telegram.allowedChatIds.joined(separator: ","),
                users: telegram.allowedUserIds.joined(separator: ","), requireMention: telegram.requireMention
            )
        })
        setIfChanged(\.statusText, engine.doctor.health?.ok == true ? "I'm online" : "I'm unavailable")
        await publishWorkStatus()
    }
}
