import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import EngineRuntime
import Transcripts
import ChatTurnRuntime
import ChatSessionWork
import AppToolRuntime
// Blueprint: | `AppModel+ChatSessions.swift` | `AppModel`, `composerDraft(for:)`: Shared drafts and checked session transactions |

extension Notification.Name {
    static let nativeAgentTurnNotice = Notification.Name("nativeagent.turn.notice")
}

@MainActor
extension AppModel: MacChatSessionSelectionPort {
    func loadChatState() async {
        // Install the defaults observer at the earliest model entry point so external writes reach the running app.
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
                systemToasts.push(error: """
                    An earlier unsent draft is kept separately because this conversation already has a draft. Start a new chat to move it into an empty \
                    composer.
                    """)
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

    /// Prepare the draft before routing so a handoff before the first session cannot lose its starter; preserve existing edits.
    @MainActor
    @discardableResult
    func requestSkillBuild(starter: String = "Create a skill from this conversation: ") -> SkillBuildRequestPresentation.DraftOutcome {
        let sessionID = activeChatSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = SkillBuildRequestPresentation.build(
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

    /// Index events must refresh session projections without reloading the active transcript.
    @MainActor
    func refreshChatSessionIndex() async {
        await refreshChatSessionIndex { [transcripts = engine.transcripts] in
            try await transcripts.list()
        }
    }

    /// Failed index reads retain proven rows; equal reads must not invalidate observers.
    @MainActor
    func refreshChatSessionIndex(
        load: @escaping @MainActor @Sendable () async throws -> [ChatSession]
    ) async {
        let transactions = engine.transcripts.sessionTransactions
        var needsReplacement = false
        var admittedIndex: [ChatSession]?
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
            let changed = refreshed != engine.transcripts.sessions
            engine.transcripts.publishSessionIndexRead(refreshed)
            guard changed else { return }
            pruneChatDrafts()
            admittedIndex = refreshed
            if !activeChatSessionId.isEmpty, !refreshed.contains(where: { $0.id == activeChatSessionId && $0.archived != true }) {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                needsReplacement = true
            }
        case .failure(let error):
            engine.transcripts.publishSessionIndexFailure(error)
        }
        })
        if let admittedIndex, engine.transcripts.sessions == admittedIndex {
            await pruneStaleSessionChatState(knownSessionIds: Set(admittedIndex.map(\.id)))
        }
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

    /// Without a conversation list, Simple follows the user's cross-surface anchor; local selection lasts until that anchor moves.
    @MainActor
    func followMovedAnchorInSimple() async {
        await engine.transcripts.refreshNavigationIdentity()
        guard SimpleViewMode.isShowing,
              let anchorId = engine.transcripts.conversationAnchor?.sessionId,
              anchorId != MacChatSelectionIntent.lastSeenAnchorSessionId else { return }
        if anchorId == activeChatSessionId {
            MacChatSelectionIntent.lastSeenAnchorSessionId = anchorId
            return
        }
        if !engine.transcripts.sessions.contains(where: { $0.id == anchorId }) {
            let selection = chatSelectionGeneration
            await refreshChatSessionIndex()
            guard chatSelectionGeneration == selection else { return }
        }
        guard let session = engine.transcripts.sessions.first(where: {
            $0.id == anchorId && $0.archived != true && SessionConversation.kind($0).isPersonConversation
        })
        else { return }
        await selectChatSession(session, userInitiated: false)
        if activeChatSessionId == anchorId { MacChatSelectionIntent.lastSeenAnchorSessionId = anchorId }
    }

    @MainActor
    private func performLoadChatState() async {
        let selectionGenerationAtStart = chatSelectionGeneration
        // Load the visible conversation alongside startup so health and lifecycle work cannot delay its first frame.
        let remembered = activeChatSessionId
        let firstRead: Task<Void, Never>? = remembered.isEmpty ? nil : Task { [engine] in
            _ = try? await engine.transcripts.refreshMessages(sessionId: remembered)
        }
        // Health must not block the conversation list.
        if engine.doctor.health?.ok != true {
            Task { [engine] in await engine.doctor.refreshHealth() }
        }
        do {
            _ = try? await engine.trust.load()
            let transactions = engine.transcripts.sessionTransactions
            let index = await transactions.indexRead.read({
                do { return Result<[ChatSession], Error>.success(try await engine.transcripts.list()) }
                catch { return .failure(error) }
            }, publish: { result in
                switch result {
                case .success(let rows): engine.transcripts.publishSessionIndexRead(rows)
                case .failure(let error): engine.transcripts.publishSessionIndexFailure(error)
                }
            })
            _ = try index.get()
            // Automatic selection requires a live direct row; only an explicit selection this launch may retain a helper.
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
            // Prune only against the index read that is still current; load the conversation either way.
            if engine.transcripts.sessions == indexSnapshot {
                pruneChatDrafts()
                // Pruning must preserve unsent composer work.
                await pruneStaleSessionChatState(knownSessionIds: knownSessionIds)
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

    func readActiveTranscript(sessionId: String) async {
        guard activeChatSessionId == sessionId else { return }
        await engine.readMountedTranscript(sessionId: sessionId, failure: { setFailureStatus($0, action: "refresh your chats") })
    }

    @MainActor
    func selectChatSession(id: String) async {
        do {
            guard let session = try await engine.transcripts.readSessionIdentity(id) else {
                statusText = "This conversation is not in the current index."
                return
            }
            await selectChatSession(session)
        } catch {
            setFailureStatus(error, action: "open your conversation")
        }
    }

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
        // Publish identity after the transcript is ready so failed or uncached loads preserve the previous conversation.
        activeChatSessionId = requestedId
    }

    @MainActor
    func newChatSession() async {
        let activityAt = Date()
        do {
            let session = try await engine.transcripts.sessionTransactions.create(store: engine.transcripts)
            publishConversationAnchor(sessionId: session.id, conversationKind: .direct, activityAt: activityAt)
            MacChatSelectionIntent.noteUserChoice()
            chatSelectionGeneration += 1
            // Seed before publishing because the next suspension lets the composer start a turn that owns these rows.
            engine.transcripts.setMessages([], for: session.id)
            activeChatSessionId = session.id
            MacChatSelectionIntent.lastSeenAnchorSessionId = engine.transcripts.conversationAnchor?.sessionId
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
    /// The live model must use its engine's data root.
    var dataRootOverride: URL? { engine.dataRoot }
    var chatSessionTransactions: MacChatSessionTransactions { engine.transcripts.sessionTransactions }
    var chatCommandTranscripts: TranscriptsFacade { engine.transcripts }
    var quietPinnedChatSessionIDs: [String] { engine.transcripts.pinnedSessionIDs }
    func unpinQuietChatSession(_ sessionId: String) async -> Bool? {
        do {
            switch try await engine.transcripts.closePinnedTab(sessionId) {
            case .closed(let encoded):
                _ = await engine.transcripts.publishPins(encoded, includeTranscripts: false)
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
    func exportQuietChat(session: NativeAgentShared.ChatSession?, sessionId: String, messages: [ChatMessage]) async throws -> ChatExportResult {
        try await ChatExport.export(session: session, sessionId: sessionId, messages: messages)
    }
    func isQuietSyntheticNotice(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix(Self.syntheticErrorIDPrefix)
    }
    func regenerateAssistantMessage(_ message: ChatMessage, parent: Turn) async {
        await regenerateChatResponse(message, parent: parent)
    }
}
