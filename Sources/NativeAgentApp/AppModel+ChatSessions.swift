import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import EngineRuntime
import Transcripts
import ChatTurnRuntime
import ChatSessionWork
import AppToolRuntime
// Blueprint: | `AppModel+ChatSessions.swift` | `AppModel`: chat load/selection/index refresh; `composerDraft(for:)` owns one draft per session for main/detached composers and commands, exact accepted-edit clearing and empty-only prefills; quiet chat commands delegate to shared transcript/session transactions |

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

    // Only empty derived state may leave memory when a row leaves the hot index.
    @MainActor
    private func pruneChatDrafts() {
        let activeIds = Set(engine.transcripts.sessions.map(\.id))
        chatComposerDrafts = chatComposerDrafts.filter { activeIds.contains($0.key) || !$0.value.text.isEmpty }
        chatPendingAttachments = chatPendingAttachments.filter { activeIds.contains($0.key) || !$0.value.isEmpty }
    }

    @MainActor
    private func migrateEmptySessionChatState(to sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if let draft = chatComposerDrafts[""], !draft.text.isEmpty {
            let target = composerDraft(for: sessionId)
            if target.text.isEmpty {
                target.edit(draft.text)
                draft.edit("")
            } else {
                systemToasts.push(error: "An earlier unsent draft is kept separately because this conversation already has a draft. Start a new chat to move it into an empty composer.")
            }
        }
        if let pending = chatPendingAttachments.removeValue(forKey: ""), !pending.isEmpty {
            var existing = chatPendingAttachments[sessionId] ?? []
            existing.append(contentsOf: pending)
            chatPendingAttachments[sessionId] = existing
        }
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

    /// Index file events refresh shared session projections without reloading the active transcript.
    @MainActor
    func refreshChatSessionIndex() async {
        await refreshChatSessionIndex { [transcripts = engine.transcripts] in
            try await transcripts.list()
        }
    }

    /// Failed index reads retain proven rows; equal reads do not invalidate observers.
    @MainActor
    func refreshChatSessionIndex(
        load: @escaping @MainActor @Sendable () async throws -> [ChatSession]
    ) async {
        let transactions = engine.transcripts.sessionTransactions
        var needsReplacement = false
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
            if !activeChatSessionId.isEmpty, !refreshed.contains(where: { $0.id == activeChatSessionId && $0.archived != true }) {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                needsReplacement = true
            }
        case .failure:
            if !chatSessionIndexRefreshFailed {
                chatSessionIndexRefreshFailed = true
            }
        }
        })
        if needsReplacement {
            do { try await selectAutomaticChatSession() }
            catch { setFailureStatus(error, action: "open your conversation") }
        }
    }

    func selectAutomaticChatSession() async throws {
        let generation = chatSelectionGeneration
        let resolved = try await engine.transcripts.sessionTransactions.reconcileStartupSession(
            store: engine.transcripts, anchorSessionId: engine.transcripts.conversationAnchor?.sessionId,
            currentSelection: activeChatSessionId)
        guard generation == chatSelectionGeneration else { return }
        await selectChatSession(resolved.session, userInitiated: false)
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
        guard let session = engine.transcripts.sessions.first(where: {
            $0.id == anchorId && $0.archived != true && SessionConversation.kind($0).isHisConversation
        })
        else { return }
        await selectChatSession(session, userInitiated: false)
    }

    @MainActor
    private func performLoadChatState() async {
        let selectionGenerationAtStart = chatSelectionGeneration
        // The conversation on screen loads first, straight from disk, while the
        // rest of startup (health, trust, the index, lifecycle repair) runs.
        let remembered = activeChatSessionId
        let firstRead: Task<Void, Never>? = remembered.isEmpty ? nil : Task { [engine] in
            _ = try? await engine.transcripts.refreshMessages(sessionId: remembered)
        }
        // Health runs beside startup, never in front of the conversation list.
        if engine.doctor.health?.ok != true {
            Task { [engine] in await engine.doctor.refreshHealth() }
        }
        do {
            _ = try? await engine.trust.load()
            let transactions = engine.transcripts.sessionTransactions
            _ = try await transactions.indexRead.read({ try await engine.transcripts.list() }, publish: { fetchedSessions in
                chatSessionIndexRefreshFailed = false
                engine.transcripts.publishSessionIndexRead(fetchedSessions)
            })
            // Automatic selection on every Mac surface resolves a live direct
            // row. Only an explicit choice made this launch may retain a helper.
            guard chatSelectionGeneration == selectionGenerationAtStart else { return }
            let currentIsLive = engine.transcripts.sessions.contains { $0.id == activeChatSessionId && $0.archived != true }
            if !MacChatSelectionIntent.userChoseThisLaunch || !currentIsLive {
                let reconciled = try await transactions.reconcileStartupSession(
                    store: engine.transcripts, anchorSessionId: engine.transcripts.conversationAnchor?.sessionId,
                    currentSelection: activeChatSessionId.isEmpty
                        ? UserDefaults.standard.string(forKey: "activeChatSessionId") : activeChatSessionId)
                if reconciled.created {
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
                guard chatSelectionGeneration == selectionGenerationAtStart else { return }
                activeChatSessionId = reconciled.session.id
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
                // Prune absent sessions' message caches while preserving unsent composer work.
                pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
            }
            let targetSessionId = activeChatSessionId
            if targetSessionId == remembered { await firstRead?.value }
            try await engine.transcripts.refreshMessages(sessionId: targetSessionId)
            guard activeChatSessionId == targetSessionId else { return }
            markChatSidebarLoadSucceeded()
        } catch {
            chatStateLoadFailed = true
            setFailureStatus(error, action: "load your chats")
        }
    }

    func refreshChatMessagesAfterTurn(sessionId: String, messagesAlreadyRefreshed: Bool = false) async {
        await engine.refreshChatMessagesAfterTurn(
            sessionId: sessionId, messagesAlreadyRefreshed: messagesAlreadyRefreshed,
            isMounted: { activeChatSessionId == sessionId },
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

    @MainActor
    func selectChatSession(_ session: ChatSession) async {
        await selectChatSession(session, userInitiated: true)
    }

    @MainActor
    func selectChatSession(_ session: ChatSession, userInitiated: Bool) async {
        await engine.transcripts.sessionTransactions.select(
            session.id, userInitiated: userInitiated, port: self,
            store: engine.transcripts, presentStatus: { statusText = $0 }
        ) { [engine] requestedId in
            let pulledDot = await engine.agents.refreshDotSession(requestedId)
            try await engine.transcripts.refreshMessages(sessionId: requestedId, cached: !pulledDot)
        }
    }

    @MainActor
    func commitChatSessionSelection(_ requestedId: String) {
        // Publish the identity only after the requested transcript slot is
        // ready. This keeps the previous conversation visible through an
        // uncached load and leaves it untouched when that load fails.
        activeChatSessionId = requestedId
    }

    @MainActor
    func newChatSession() async {
        let activityAt = Date()
        do {
            let session = try await engine.transcripts.sessionTransactions.create(store: engine.transcripts)
            // His new chat becomes the conversation anchor across surfaces.
            publishConversationAnchor(sessionId: session.id, conversationKind: .direct, activityAt: activityAt)
            MacChatSelectionIntent.noteUserChoice()
            chatSelectionGeneration += 1
            // Seed before publishing the session: the next await lets its
            // composer start a turn, which must retain ownership of these rows.
            engine.transcripts.setMessages([], for: session.id)
            activeChatSessionId = session.id
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
    /// The live model has no override: its engine's root is the root (X-DEAD-2 removed the stored field).
    var dataRootOverride: URL? { engine.dataRoot }
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
    func exportQuietChat(session: NativeAgentShared.ChatSession?, sessionId: String, messages: [ChatMessage]) async throws -> ChatExportResult {
        try await ChatExport.export(session: session, sessionId: sessionId, messages: messages)
    }
    func isQuietSyntheticNotice(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix(Self.syntheticErrorIDPrefix)
    }
}
