import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+ChatSessions.swift` | Local drafts, body session acts and composer compare-and-set calls |

@MainActor
extension AppModel {
    func focusFaceComposer(session: String) -> FaceReply {
        let detached = DetachedChatWindowController.shared.isDetached(session)
        guard detached || activeChatSessionId == session else {
            return .refused(WireFailure(code: "composer_not_mounted", message: "That conversation's composer is not mounted.",
                                        cause: nil, effects: .none))
        }
        return FaceComposerFocus.focus(session: session, detached: detached)
    }

    func composerDraft(for sessionId: String) -> ChatComposerDraft {
        if let draft = chatComposerDrafts[sessionId] { return draft }
        let draft = ChatComposerDraft(sessionId: sessionId)
        chatComposerDrafts[sessionId] = draft
        return draft
    }

    /// Acceptance clears only the edit the sender captured.
    func clearChatDraftAfterSend(_ sent: String, sessionId: String, editedAt: Date) {
        let draft = composerDraft(for: sessionId)
        if draft.text == sent, draft.editedAt == editedAt { draft.edit("") }
    }

    func injectChatDraft(_ text: String, sessionId: String) {
        let draft = composerDraft(for: sessionId)
        if draft.text.isEmpty { draft.edit(text) }
    }

    func chatDraft(for sessionId: String) -> String { composerDraft(for: sessionId).text }

    @discardableResult
    func requestSkillBuild(starter: String = "Create a skill from this conversation: ") -> SkillBuildRequestPresentation.DraftOutcome {
        let session = activeChatSessionId
        let outcome = SkillBuildRequestPresentation.build(activeSessionID: session, existingDraft: chatDraft(for: session))
        if case .draftPrepared = outcome { injectChatDraft(starter, sessionId: session) }
        NotificationCenter.default.post(name: .skillBuildRequest, object: starter)
        return outcome
    }

    /// The empty-session composer is retained until a committed selection can receive it.
    private func moveUnassignedDraft(to session: String) {
        guard !session.isEmpty else { return }
        if let source = chatComposerDrafts[""], !source.text.isEmpty {
            let destination = composerDraft(for: session)
            if destination.text.isEmpty {
                destination.edit(source.text)
                source.edit("")
            } else {
                systemToasts.push(error: "An earlier unsent draft is kept separately. Start a new chat to move it into an empty composer.")
            }
        }
        if let attachments = chatPendingAttachments.removeValue(forKey: ""), !attachments.isEmpty {
            chatPendingAttachments[session, default: []].append(contentsOf: attachments)
        }
    }

    func loadChatState() async {
        guard activeChatSessionId.isEmpty else { await refreshChatFace(.session(activeChatSessionId)); return }
        let generation = chatSelectionGeneration
        chatRestoreIssue = nil
        do {
            let session = try acceptedConversation(await chatAct(.restoreConversation))
            guard chatSelectionGeneration == generation, activeChatSessionId.isEmpty else { return }
            commitChatSessionSelection(session)
        } catch {
            guard !Task.isCancelled, chatSelectionGeneration == generation, activeChatSessionId.isEmpty else { return }
            chatRestoreIssue = error.localizedDescription
            setFailureStatus(error, action: "restore the conversation")
        }
    }
    func reloadChatState() async { await loadChatState() }
    func refreshChatSessionIndex() async { await refreshChatFace(.panel("chat.sessions")) }
    func readActiveTranscript(sessionId: String) async { await refreshChatFace(.session(sessionId)) }
    func readDetachedTranscript(sessionId: String) async { await refreshChatFace(.session(sessionId)) }

    func selectChatSession(id: String) async { await selectChatSession(id: id, userInitiated: true) }
    func selectChatSession(_ session: ChatSession) async { await selectChatSession(id: session.id) }

    @discardableResult
    func selectChatSession(id: String, userInitiated: Bool) async -> Bool {
        chatSelectionGeneration = UUID()
        let generation = chatSelectionGeneration
        // The chat shows as soon as it is chosen. Her side can take seconds re-reading it, and its transcript arrives by its own reader.
        let previous = activeChatSessionId
        commitChatSessionSelection(id)
        do {
            let reply = try await chatAct(.selectConversation(session: id, userInitiated: userInitiated))
            guard case .accepted(let selected, _, _) = reply, selected == id else {
                throw chatProtocolFailure("the selected conversation identity.")
            }
            return chatSelectionGeneration == generation
        } catch {
            if chatSelectionGeneration == generation { commitChatSessionSelection(previous) }
            setFailureStatus(error, action: "open your conversation")
            return false
        }
    }

    func commitChatSessionSelection(_ requestedId: String) {
        activeChatSessionId = requestedId
        chatRestoreIssue = nil
        moveUnassignedDraft(to: requestedId)
    }

    func newChatSession() async {
        do { _ = try await createFaceConversation() }
        catch { setFailureStatus(error, action: "start a new chat") }
    }

    private func createFaceConversation() async throws -> String {
        chatSelectionGeneration = UUID()
        let generation = chatSelectionGeneration
        let reply = try await chatAct(.createConversation)
        let session = try acceptedConversation(reply)
        guard chatSelectionGeneration == generation else {
            throw WireFailure(code: "conversation_selection_changed", message: "The conversation was created, but the selection changed.",
                cause: "The new conversation is in the list. The current selection and its draft were preserved.", effects: .known)
        }
        commitChatSessionSelection(session)
        return session
    }

    /// One renderer operation prepares the draft after navigation, preserving every existing edit and attachment.
    func prepareChatDraft(_ text: String) async throws -> ComposerEditResult {
        try Task.checkCancellation()
        guard !text.isEmpty else {
            throw PartCallError(code: "draft_text_required", message: "No words were supplied for the chat draft.")
        }
        _ = try ApplicationLifetime.shared.sceneReport()
        let navigation = try await ApplicationLifetime.shared.navigate(.init(
            destination: .init(page: "chat", item: nil, session: nil, message: nil), policy: .foreground))
        guard case .navigation(let receipt) = navigation, receipt.disposition == .mounted else {
            throw PartCallError(code: "composer_unmounted", message: "The Chat scene did not confirm its presentation. No draft was changed.")
        }
        let session: String
        if activeChatSessionId.isEmpty { session = try await createFaceConversation() }
        else { session = activeChatSessionId }
        try Task.checkCancellation()
        let before = readFaceComposer(session: session)
        guard before.text.isEmpty else {
            throw PartCallError(code: "composer_draft_occupied", message: "Chat is open; the person's existing draft and attachments were preserved.")
        }
        return editFaceComposer(.init(session: session, text: text, attachments: before.attachments,
            expectedRevision: before.revision, expectedEditedAt: before.editedAt, existingAttachmentIDs: before.attachments.map(\.id)))
    }

    func renameChatSession(id sessionId: String, title: String) async {
        await performChatMutation(.renameConversation(session: sessionId, title: title), success: "Chat renamed")
    }

    func readFaceComposer(session: String) -> ComposerSnapshot {
        let draft = composerDraft(for: session)
        return ComposerSnapshot(session: session, text: draft.text, revision: draft.manualEditRevision,
                                editedAt: draft.editedAt, attachments: chatPendingAttachments[session] ?? [])
    }

    func editFaceComposer(_ request: ComposerEditRequest) -> ComposerEditResult {
        let before = readFaceComposer(session: request.session)
        guard before.revision == request.expectedRevision, before.editedAt == request.expectedEditedAt,
              before.attachments.map(\.id) == request.existingAttachmentIDs else {
            return ComposerEditResult(disposition: .conflict, snapshot: before)
        }
        if before.text != request.text { composerDraft(for: request.session).edit(request.text) }
        if before.attachments != request.attachments { chatPendingAttachments[request.session] = request.attachments }
        return ComposerEditResult(disposition: .applied, snapshot: readFaceComposer(session: request.session))
    }

    func clearFaceAcceptedComposer(_ request: ComposerAcceptedEdit) -> ComposerEditResult {
        let before = readFaceComposer(session: request.session)
        guard before.revision == request.revision, before.text == request.text,
              before.attachments.map(\.id) == request.attachmentIDs else {
            return ComposerEditResult(disposition: .conflict, snapshot: before)
        }
        if !before.text.isEmpty { composerDraft(for: request.session).edit("") }
        if !before.attachments.isEmpty { chatPendingAttachments[request.session] = [] }
        return ComposerEditResult(disposition: .applied, snapshot: readFaceComposer(session: request.session))
    }
}
