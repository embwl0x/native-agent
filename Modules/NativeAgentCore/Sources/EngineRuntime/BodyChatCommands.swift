import ChatTurnContracts
import ChatTurnRuntime
import DeviceSync
import Dispatcher
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Transcripts
// Blueprint: | `BodyChatCommands.swift` | Body-owned Mac admission, selection, commands and turn presentation without a mounted window |

@MainActor
public final class BodyChatCommands: MacChatTurnPresentationPort {
    private let engine: NativeAgentEngine
    public private(set) var activeChatSessionId = ""
    public var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    public var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }
    private let selection = LatestRead()

    public init(engine: NativeAgentEngine) {
        self.engine = engine
        Task { await engine.countsStatus.observeToasts(SystemToastCenter.shared) }
    }

    public func handle(_ act: FaceAct, renderer: UUID? = nil) async throws -> FaceActReply {
        switch act {
        case .createConversation:
            let session = try await engine.transcripts.sessionTransactions.create(store: engine.transcripts)
            engine.transcripts.setMessages([], for: session.id)
            selection.write {
                activeChatSessionId = session.id
                UserDefaults.standard.set(session.id, forKey: "activeChatSessionId")
            }
            // An empty chat is not yet where the conversation is: the first message anchors it, so phone and Telegram don't follow a blank row.
            engine.deviceSync?.engine.requestChatTranscriptSnapshotPublication()
            return .accepted(session: session.id, turn: nil, operation: nil)
        case .selectConversation(let session, let userInitiated):
            let result: Result<String, Error> = await selection.read({
                do {
                    guard let row = try await engine.transcripts.readSessionIdentity(session), row.archived != true else {
                        throw EngineFaceActs.failure("session_unavailable", "That conversation is not in the current index.")
                    }
                    return .success(session)
                } catch { return .failure(error) }
            }, publish: { read in
                if case .success(let id) = read {
                    activeChatSessionId = id
                    UserDefaults.standard.set(id, forKey: "activeChatSessionId")
                    if userInitiated { MacChatSelectionIntent.noteUserChoice() }
                    MacChatUnreadSessions.shared.markRead(id)
                }
            })
            return .accepted(session: try result.get(), turn: nil, operation: nil)
        case .markConversationRead(let session):
            MacChatUnreadSessions.shared.markRead(session)
            return .acknowledged
        case .renameConversation(let session, let title):
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw EngineFaceActs.failure("empty_title", "Enter a conversation title.") }
            let rows = try await engine.transcripts.readSessionIndex()
            guard let current = rows.first(where: { $0.id == session }) else {
                throw EngineFaceActs.failure("session_unavailable", "That conversation is not in the current index.")
            }
            if current.title == clean { return try EngineFaceActs.committed(current, identities: [session]) }
            let saved = try await engine.transcripts.update(id: session, title: clean, archived: nil)
            return await publishSessionMutation(saved)
        case .archiveConversation(let session):
            let changed = try await engine.archiveMacChatTranscript(port: self, sessionId: session) { id in
                _ = self.engine.transcripts.removeMessages(for: id)
            }
            if changed, activeChatSessionId == session {
                selection.write {
                    activeChatSessionId = ""
                    UserDefaults.standard.removeObject(forKey: "activeChatSessionId")
                }
            }
            return .result(.bool(changed))
        case .clearConversation(let session):
            var cleared = false
            defer { if cleared { engine.deviceSync?.engine.requestChatTranscriptSnapshotPublication() } }
            do { try await engine.clearMacChatTranscript(sessionId: session) { cleared = true } }
            catch {
                throw WireFailure(code: "clear_conversation", message: "The conversation clear did not fully settle.",
                    cause: error.localizedDescription, effects: cleared ? .known : .unknown)
            }
            return .committed(.init(identities: [session], value: .null, revision: nil, effects: .known, publicationFailure: nil))
        case .pinConversation(let session):
            let result = try await engine.transcripts.pinSession(session)
            return .result(.object(["changed": .bool(result.changed), "shared": .bool(result.shared)]))
        case .unpinConversation(let session):
            switch try await engine.transcripts.closePinnedTab(session) {
            case .closed(let encoded):
                let shared = await engine.transcripts.publishPins(encoded, includeTranscripts: false)
                return .result(.object(["changed": .bool(true), "shared": .bool(shared)]))
            case .refusedAlreadyUnpinned: return .result(.object(["changed": .bool(false)]))
            case .refusedInvalidSessionID: throw EngineFaceActs.failure("invalid_session", "That conversation id is invalid.")
            }
        case .send(let request): return try await send(request, renderer: renderer)
        case .stop(let session, let expected):
            let sessions = try await engine.transcripts.readSessionIndex()
            let flights = await Task.detached { [engine] in engine.turns.inFlightTurns() }.value
            guard sessions.contains(where: { $0.id == session }) || macChatTurns.tasks[session] != nil
                || macChatTurns.busySessions.contains(session) || flights.contains(where: { $0.sessionId == session }) else {
                throw EngineFaceActs.failure("session_unavailable", "That conversation has no checked session or running turn to stop.")
            }
            if let expected, macChatTurns.activeTurnIDsBySession[session] != expected {
                throw EngineFaceActs.failure("turn_changed", "That turn is no longer the conversation's current turn.")
            }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                stopChatStream(sessionId: session, didWrite: { done.resume(with: $0) })
            }
            ModuleLog.app("[face-act] stop request saved session=\(session)")
            return .acknowledged
        case .prepareRetryDraft(let session, let message):
            let (target, messages) = try await messageRow(message, session: session)
            guard target.metadata?.providerRefusalDraft == true,
                  let snapshot = MacChatRetrySnapshot.capture(target: target, messages: messages,
                    sessionId: session, isSyntheticNotice: false), !snapshot.inputHadAttachments else {
                throw EngineFaceActs.failure("retry_draft_unavailable", "This response has no reusable text draft. Reattach its files before sending.")
            }
            return .result(.string(snapshot.priorUserText))
        case .regenerate(let session, let message, let choice):
            let (target, _) = try await messageRow(message, session: session)
            if choice == .continueFromResults {
                return try await send(SendRequest(session: session, text: ChatTurnFailure.continuePrompt, attachments: [], composerRevision: 0,
                    expectedSelection: nil, options: .init(hideUserBubble: false, choice: nil, continuationReference: nil)), renderer: renderer)
            }
            if target.metadata?.providerRefusal == true {
                throw EngineFaceActs.failure("outcome_unknown", "Inspect this rejected turn before sending another request.")
            }
            var failure: Error?
            let result = await engine.regenerateMacChatResponse(port: self, target: target, sessionId: session, parent: nil,
                syntheticPrefix: MacChatTurnRuntime.syntheticErrorIDPrefix, client: engine.chatClient(profile: .mac),
                presentFailure: { failure = $0 }, didComplete: {}, renderer: renderer)
            if let failure { throw failure }
            switch result {
            case .refused(let detail): return .refused(EngineFaceActs.failure("retry_refused", detail))
            case .outcome(let identity, let phase):
                return .result(.object(["session": .string(identity.sessionId), "turn": .string(identity.turnId),
                    "phase": phase.map { .string($0.rawValue) } ?? .null]))
            }
        case .appendSlashHelp(let session):
            engine.transcripts.appendMessage(ChatMessage(sessionId: session, role: "assistant", content: ChatSlashCommandRegistry.helpText()), to: session)
            return .acknowledged
        default: throw EngineFaceActs.failure("wrong_owner", "This act does not belong to the body chat owner.")
        }
    }

    private func send(_ request: SendRequest, renderer: UUID?) async throws -> FaceActReply {
        let rows = try await engine.transcripts.readSessionIndex()
        let target = request.session ?? activeChatSessionId
        guard rows.contains(where: { $0.id == target && $0.archived != true }) else {
            throw EngineFaceActs.failure("session_unavailable", "Choose an available conversation before sending. The draft is preserved.")
        }
        if let expected = request.expectedSelection, expected != activeChatSessionId {
            throw EngineFaceActs.failure("selection_changed", "The selected conversation changed before send. The draft is preserved.")
        }
        // These options require ingress support before admission; they cannot be silently dropped or saved globally.
        guard request.options.choice == nil, request.options.continuationReference == nil else {
            throw EngineFaceActs.failure("send_options_unavailable", "Save the chat choice before sending; a continuation must enter through its owner.")
        }
        let attachments = try await Self.readAttachments(request.attachments)
        let started = await startChatTurn(request.text, attachments: ChatAttachmentTypeResolver.submittingSpeech(attachments, text: request.text),
            sessionId: target, hideUserBubble: request.options.hideUserBubble, requireActiveSession: request.session == nil, renderer: renderer)
        switch started.acceptance {
        case .rejected(let message): return .refused(EngineFaceActs.failure("send_refused", message))
        case .accepted(let session):
            ModuleLog.app("[face-act] send accepted session=\(session)")
            return try await anchor(session: session, kind: nil, turn: macChatTurns.activeTurnIDsBySession[session])
        }
    }

    @concurrent public nonisolated static func readAttachments(_ values: [FaceAttachment]) async throws -> [MultimodalAttachment] {
        try values.map { value in
            let bytes: Data
            if let carried = value.bytes { bytes = carried }
            else if let resource = value.resource {
                var stale = false
                let url = try URL(resolvingBookmarkData: resource.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
                guard !stale else { throw EngineFaceActs.failure("attachment_grant_stale", "Choose the attachment again; its file grant is stale.") }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                bytes = try Data(contentsOf: url)
            } else { throw EngineFaceActs.failure("attachment_unavailable", "The attachment contains neither bytes nor a file grant.") }
            guard value.byteCount == bytes.count else { throw EngineFaceActs.failure("attachment_changed", "The attachment changed before send.") }
            let kind: String
            if value.mimeType.hasPrefix("image/") { kind = "image" }
            else if value.mimeType.hasPrefix("audio/") { kind = "audio" }
            else { kind = "file" }
            return MultimodalAttachment(id: value.id, type: kind, base64: bytes.base64EncodedString(), mime: value.mimeType,
                name: value.name, byteSize: bytes.count)
        }
    }

    private func messageRow(_ id: String, session: String) async throws -> (ChatMessage, [ChatMessage]) {
        let messages = try await engine.transcripts.loadMessages(sessionId: session, cached: false)
        guard let row = messages.first(where: { $0.id == id }) else {
            throw EngineFaceActs.failure("message_unavailable", "That message is absent from the checked transcript.")
        }
        return (row, messages)
    }

    private func anchor(session: String, kind: ChatThreadKind?, turn: String? = nil) async throws -> FaceActReply {
        var issue: WireFailure?
        do {
            let root = engine.dataRoot
            try await Task.detached {
                let checked = try kind ?? SessionConversation.checkedKind(session, dataRoot: root) ?? .unclassified
                _ = try await ConversationAnchor.publish(sessionId: session, source: "app", conversationKind: checked, dataRoot: root)
            }.value
        } catch {
            issue = WireFailure(code: "anchor_publication", message: "The conversation was accepted, but its shared anchor could not be published.",
                cause: error.localizedDescription, effects: .known)
        }
        if let issue {
            return .committed(.init(identities: [session], value: .object(["session": .string(session),
                "turn": turn.map(PartFace.Value.string) ?? .null]), revision: nil, effects: .known, publicationFailure: issue))
        }
        engine.deviceSync?.engine.requestChatTranscriptSnapshotPublication()
        return .accepted(session: session, turn: turn, operation: nil)
    }

    private func publishSessionMutation(_ session: NativeAgentShared.ChatSession) async -> FaceActReply {
        let issue: WireFailure?
        do { _ = try await engine.transcripts.readSessionIndex(); issue = nil }
        catch { issue = WireFailure(code: "session_publication", message: "The title was saved, but the conversation index could not be read.",
            cause: error.localizedDescription, effects: .known) }
        engine.deviceSync?.engine.requestChatTranscriptSnapshotPublication()
        return .committed(.init(identities: [session.id], value: .string(session.title), revision: nil, effects: .known, publicationFailure: issue))
    }

    public func chatHasConversationRows(sessionId: String) throws -> Bool {
        FirstRunWelcomeTransaction.hasConversationRows(try engine.transcripts.completeDisplayedMessages(for: sessionId),
            syntheticErrorIDPrefix: MacChatTurnRuntime.syntheticErrorIDPrefix)
    }
    public func prepareMacChatTranscript(sessionId: String) async throws {
        _ = try await engine.transcripts.loadMessages(sessionId: sessionId, cached: true)
        _ = try engine.transcripts.completeDisplayedMessages(for: sessionId)
    }
    public func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation? {
        guard UserMessageIntentSignals.isTakeOver(text) else { return nil }
        guard let capture = MacWorkContinuation.capture else { return .unsupported("continuation_capture_unavailable", taskReference: taskReference) }
        return await capture(text, taskReference)
    }
    public func animateMacChatMutation(_ mutation: () -> Void) { mutation() }
    public func presentMacChatTurn(_ event: MacChatTurnPresentationEvent) {
        switch event {
        case .status(let text): SystemToastCenter.shared.push(info: text, autoDismissAfter: nil)
        case .activity(let activity):
            if case .notice = activity.source, let text = activity.userVisibleNoticeText, !text.isEmpty {
                SystemToastCenter.shared.push(info: text, autoDismissAfter: nil)
            }
        }
    }
    public func recordMacControlHandoff(text: String, reply: String, sessionId: String, turn: Turn) async throws {
        try await engine.chatClient(profile: .mac).recordControlHandoff(message: text, reply: reply, sessionId: sessionId, surface: "chat", turn: turn)
        _ = try await engine.transcripts.refreshMessages(sessionId: sessionId, cached: false)
    }
    public func cancelICloudChatTurnForControlHandoff(sessionId: String) { _ = engine.deviceSync?.engine.cancelActiveChatTask(for: sessionId) }
    public func saveMacArrival(_ words: String, attachments: [MultimodalAttachment], sessionId: String, turn: Turn) async throws {
        try await engine.chatClient(profile: .mac).saveArrival(message: words, sessionId: sessionId, surface: "chat", attachments: attachments,
            fileAccess: "auto", turn: turn)
    }
    public func showMacChatUserBubble(_ text: String, attachments: [MultimodalAttachment], sessionId: String, turn: Turn) {
        engine.showMacChatUserBubble(text, attachments: attachments, sessionId: sessionId, turn: turn, port: self)
    }
    public func runMacChatTurnBody(_ text: String, attachments: [MultimodalAttachment], sessionId: String, generation: Int,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity, turn: Turn) async {
        await engine.runMacChatTurnBody(text, attachments: attachments, sessionId: sessionId, generation: generation,
            hideUserBubble: hideUserBubble, activityIdentity: activityIdentity, turn: turn, port: self, client: engine.chatClient(profile: .mac),
            missingProviderGuidance: nil, errorAdvice: UserFacingError.advice, finishReplyPresentation: {})
    }
}
