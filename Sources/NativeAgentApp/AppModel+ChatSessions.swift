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
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import ChatTurnRuntime
import ChatSessionWork
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
import DeviceSync
// Blueprint: | `AppModel+ChatSessions.swift` | `AppModel`: chat load/selection/index refresh and `recordPanelRefresh`; sidebar refresh uses engine persona/configuration/runs/provider and connector owners; `composerDraft(for:)` owns one draft per session for main/detached composers and commands, exact accepted-edit clearing and empty-only prefills; quiet chat commands delegate to shared transcript/session transactions |

extension Notification.Name {
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

    // Keep one object's identity for each live session; cap nonempty drafts at 50.
    @MainActor
    private func pruneChatDrafts() {
        let activeIds = Set(engine.transcripts.sessions.map(\.id))
        chatComposerDrafts = chatComposerDrafts.filter { activeIds.contains($0.key) }
        chatPendingAttachments = chatPendingAttachments.filter { activeIds.contains($0.key) }
        let nonempty = chatComposerDrafts.values.filter { !$0.text.isEmpty }.sorted { $0.editedAt < $1.editedAt }
        for draft in nonempty.prefix(max(0, nonempty.count - 50)) { draft.edit("") }
    }

    @MainActor
    private func migrateEmptySessionChatState(to sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if let draft = chatComposerDrafts[""], !draft.text.isEmpty {
            let target = composerDraft(for: sessionId)
            if target.text.isEmpty { target.edit(draft.text) }
            draft.edit("")
        }
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
        let persona = engine.persona
        let previousName = persona.profile?.name
        let memory = engine.memory
        let approvalStore = engine.approvals
        let inbox = engine.inbox
        let toolStore = engine.tools
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
            if engine.providers.settings?.catalogError != nil { failedEndpoints.append("model catalog") }
            await reloadChatState()
            if chatStateLoadFailed { failedEndpoints.append("chat messages") }
            _ = fresh("personality", try? await persona.prepareDocuments())
            // The chat header, composer placeholder, and turn cards all read
            // `agentDisplayName`, which resolves from `engine.persona.profile?.name`
            // first. That profile was only ever loaded by the Memory and
            // Personality screens, so a fresh launch straight into chat
            // labelled the agent with the app's fallback name until one of
            // those screens had been visited. Load it once here; the name is
            // the profile's, never a literal.
            if persona.profile == nil {
                _ = fresh("personality profile", try? await persona.loadProfile())
                teachMemoryHygieneName(previousName: previousName)
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
            _ = fresh("runs", try? await engine.runs.refresh(dataRoot: engine.dataRoot))
        case .desk, .workshop, .work, .command, .bots:
            // Nothing is read here, so nothing is said about freshness below.
            performedRead = false
            // DeskPageView, SchedulerView, and ResearchView own their bounded reads.
            // `.command` and `.workshop` are retired aliases → Desk
            // 2026-07-23); its old command-summary fetch went with the view.
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
            if memoryRows != nil, let query = memory.searchResultQuery, query.count >= 3 {
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
            async let nextConfig = try? RuntimeReadProjection.configuration(engine: engine)
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
            let nextMisses = await missLessonsRead.read({ await MemoryStatusProjection.recentMisses(dataRoot: engine.dataRoot) }, publish: { rows in
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
            async let nextGenSnapshot = decodeLogged("nextgen snapshot") {
                try await engine.nextGen.snapshot()
            }
            async let nextGraph: Void = engine.memory.loadGraph()
            let (
                skillRows,
                toolRows,
                approvalRows,
                connectorActionRegistryRow,
                nextGenRow,
                _
            ) = await (
                nextSkills,
                nextTools,
                nextApprovals,
                nextConnectorActionRegistry,
                nextGenSnapshot,
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
            _ = fresh("nextgen snapshot", nextGenRow)
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
            // Health used to be fetched unconditionally for every page above;
            // Status is the page that actually reads it, so it reads it here.
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
            async let nextDocs = try? persona.loadDocuments()
            let (personalityRow, docsResponse) = await (
                nextPersonality,
                nextDocs
            )
            _ = fresh("personality", personalityRow)
            teachMemoryHygieneName(previousName: previousName)
            _ = fresh("personality docs", docsResponse)
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

    func composerDraft(for sessionId: String) -> ChatComposerDraft {
        if let draft = chatComposerDrafts[sessionId] { return draft }
        let draft = ChatComposerDraft(sessionId: sessionId)
        chatComposerDrafts[sessionId] = draft
        return draft
    }

    /// Acceptance clears only the exact live edit that was sent.
    @MainActor
    func clearChatDraftAfterSend(_ sent: String, sessionId: String, editedAt: Date) {
        let draft = composerDraft(for: sessionId)
        if draft.text == sent, draft.editedAt == editedAt {
            draft.edit("")
        }
    }

    @MainActor
    func injectChatDraft(_ text: String, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let draft = composerDraft(for: sessionId)
        if draft.text.isEmpty { draft.edit(text) }
    }

    @MainActor
    func chatDraft(for sessionId: String) -> String {
        composerDraft(for: sessionId).text
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
            try await transcripts.list()
        }
    }

    /// Injectable seam for the bridge-created-session regression. A failed
    /// read preserves the last proven list; an equal read performs no observed
    /// write, so duplicate vnode edges cannot relayout Chat.
    @MainActor
    func refreshChatSessionIndex(
        load: @escaping @MainActor @Sendable () async throws -> [ChatSession]
    ) async {
        let transactions = engine.transcripts.sessionTransactions
        var replacement: ChatSession?
        _ = await transactions.indexRead.read({ () async -> Result<[ChatSession], Error> in
        do {
            let refreshed = try await load()
            let knownSessionIds = Set(refreshed.map(\.id))
            if !chatTurnLifecycleRepairCompleted {
                await repairChatTurnLifecyclesIfNeeded(
                    knownSessionIds: knownSessionIds
                ) { identity in
                    await self.readCanonicalChatTurnTerminalProof(identity: identity)
                }
            }
            return .success(refreshed)
        } catch { return .failure(error) }
        }, publish: { result in
        switch result {
        case .success(let refreshed):
            let knownSessionIds = Set(refreshed.map(\.id))
            chatSessionIndexRefreshFailed = false
            guard refreshed != engine.transcripts.sessions else { return }
            engine.transcripts.publishSessionIndexRead(refreshed)
            pruneChatDrafts()
            pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
            if !activeChatSessionId.isEmpty, !knownSessionIds.contains(activeChatSessionId) {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                persistActiveChatSessionID(nil)
                replacement = refreshed.first(where: { $0.archived != true })
            }
        case .failure:
            if !chatSessionIndexRefreshFailed {
                chatSessionIndexRefreshFailed = true
            }
        }
        })
        if let replacement { await selectChatSession(replacement) }
    }

    /// Simple has no conversation list, so it follows the conversation User is
    /// in: when the anchor MOVES (he sent from another door) the window moves
    /// with it. A chat he opened here stays until the anchor moves again.
    @MainActor
    func followMovedAnchorInSimple() async {
        engine.transcripts.refreshNavigationIdentity()
        guard SimpleViewMode.isShowing,
              let anchorId = engine.transcripts.conversationAnchor?.sessionId,
              anchorId != MacChatSelectionIntent.lastSeenAnchorSessionId else { return }
        MacChatSelectionIntent.lastSeenAnchorSessionId = anchorId
        guard anchorId != activeChatSessionId else { return }
        if !engine.transcripts.sessions.contains(where: { $0.id == anchorId }) {
            let selection = chatSelectionGeneration
            await refreshChatSessionIndex()
            guard chatSelectionGeneration == selection else { return }
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
                await engine.doctor.refreshHealth()
            }
            _ = try? await engine.trust.load()
            let transactions = engine.transcripts.sessionTransactions
            _ = try await transactions.indexRead.read({ try await engine.transcripts.list() }, publish: { fetchedSessions in
                chatSessionIndexRefreshFailed = false
                engine.transcripts.publishSessionIndexRead(fetchedSessions)
            })
            // Simple owns its current thread. Advanced may default to the
            // remote conversation anchor — but only until the human
            // picks something. `shouldAdoptAnchor` owns that rule and also
            // refuses an anchor that names no live session, so a stale pin can
            // never blank the window. Surface-agnostic: nothing here knows or
            // cares which adapter published the anchor.
            guard chatSelectionGeneration == selectionGenerationAtStart else { return }
            if !SimpleViewMode.isShowing, ConversationAnchor.shouldAdoptAnchor(
                anchorSessionId: engine.transcripts.conversationAnchor?.sessionId,
                currentSelection: activeChatSessionId,
                userChoseThisLaunch: MacChatSelectionIntent.userChoseThisLaunch,
                liveSessionIds: Set(engine.transcripts.sessions.filter { $0.archived != true }.map(\.id))
            ), let anchorId = engine.transcripts.conversationAnchor?.sessionId {
                activeChatSessionId = anchorId
                persistActiveChatSessionID(activeChatSessionId)
            }
            if activeChatSessionId.isEmpty || !engine.transcripts.sessions.contains(where: { $0.id == activeChatSessionId }) {
                if !activeAtStart.isEmpty,
                   (activeChatSessionId != activeAtStart || chatSelectionGeneration != selectionGenerationAtStart) {
                    return
                }
                let reconciled = try await engine.transcripts.sessionTransactions.reconcileStartupSession(store: engine.transcripts)
                if reconciled.created {
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
                guard chatSelectionGeneration == selectionGenerationAtStart else { return }
                activeChatSessionId = reconciled.session.id
                UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
            }
            migrateEmptySessionChatState(to: activeChatSessionId)
            let indexSnapshot = engine.transcripts.sessions
            let knownSessionIds = Set(engine.transcripts.sessions.map(\.id))
            await repairChatTurnLifecyclesIfNeeded(
                knownSessionIds: knownSessionIds
            ) { identity in
                await self.readCanonicalChatTurnTerminalProof(identity: identity)
            }
            guard chatSelectionGeneration == selectionGenerationAtStart else { return }
            // Pruning reads the index: only while it is still the one read here.
            // The conversation itself loads either way.
            if engine.transcripts.sessions == indexSnapshot {
                pruneChatDrafts()
                // 2026-07-21 audit fix: prune per-session message caches
                // for sessions the list no longer reports — mirrors the stale-draft
                // prune above, same low-frequency hook.
                pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
            }
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
            await refreshChatSessionIndex()
            migrateEmptySessionChatState(to: activeChatSessionId)
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
    var quietPinnedChatSessionIDs: [String] { engine.transcripts.pinnedSessionIDs }
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
            switch try engine.transcripts.closePinnedTab(sessionId) {
            case .closed(let encoded):
                _ = engine.transcripts.publishPins(encoded, includeTranscripts: false)
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
