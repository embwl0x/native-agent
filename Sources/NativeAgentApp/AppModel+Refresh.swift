import Foundation
import EngineRuntime
// Blueprint: | `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll`; Telegram form reads share `refreshTelegramSettingsDraft` with the direct refresh |

@MainActor
extension AppModel {
    /// Equal values must not invalidate readers through Observation writes.
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
        _ = await decodeLogged("getMemories") {
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
        for failure in await engine.tools.refreshNativePower() { recordRefreshFailure(failure.label, error: failure.error) }
        for failure in await engine.memory.refreshStatuses() { recordRefreshFailure(failure.label, error: failure.error) }
        _ = await decodeLogged("getConnectorActions") { try await engine.connectors.refreshActions() }
        for failure in await engine.doctor.refreshHardening() { recordRefreshFailure(failure.label, error: failure.error) }
        _ = await decodeLogged("getTrustPolicy") { try await engine.trust.load() }
        _ = await decodeLogged("getBackups") { try await engine.trust.refreshBackups() }
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
        // Load providers at startup so the composer can populate its provider menu.
        await loadProvidersForChat()
        if let detail = engine.providers.settings?.catalogError {
            recordRefreshFailure("getModelCatalog", error: RuntimeReadError.unreadableFeed(detail))
        }
        await reloadChatState()
        _ = await decodeLogged("getConfig", { try await RuntimeReadouts.configuration(engine: engine) })
        setIfChanged(\.statusText, engine.doctor.health?.ok == true ? "I'm online" : "I'm unavailable")
        await publishWorkStatus()
    }
}
