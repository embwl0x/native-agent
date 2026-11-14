import ApprovalTransactions
import ChatSessionWork
import ChatTurnRuntime
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import Privacy
import TurnTrace
// Blueprint: | `BodyFaceTranscripts.swift` | Connection-owned press readers, live conversation projections and checked transcript resource grants |

@MainActor
final class BodyFaceTranscripts {
    private let engine: NativeAgentEngine
    private struct Reader {
        let lifetime = UUID()
        var request: TranscriptReaderRequest
        var appliedScript: UUID?
        var task: Task<Void, Never>?
    }
    private var readers: [UUID: Reader] = [:]
    private var stores: [String: Task<Void, Never>] = [:]
    private var observations: [UUID: Task<Void, Never>] = [:]
    private var conversationReads: [String: LatestRead] = [:]
    private var pendingConversations: [String: ConversationFace] = [:]
    private var conversationDelivery: Task<Void, Never>?

    init(engine: NativeAgentEngine) { self.engine = engine }

    func close() async {
        let held = readers
        let watched = observations
        let saved = stores
        readers.removeAll()
        observations.removeAll()
        stores.removeAll()
        for reader in held.values { reader.task?.cancel() }
        for task in watched.values { task.cancel() }
        for task in saved.values { task.cancel() }
        for (id, reader) in held {
            await reader.task?.value
            await engine.transcripts.press.remove(reader: id)
        }
        for task in watched.values { await task.value }
        for task in saved.values { await task.value }
        conversationDelivery?.cancel()
        pendingConversations.removeAll()
        await conversationDelivery?.value
        conversationReads.removeAll()
    }

    func handle(_ act: FaceAct) async throws -> FaceActReply? {
        let press = engine.transcripts.press
        switch act {
        case .openTranscriptReader(let request):
            let id = request.geometry.reader
            guard readers[id] == nil, Self.valid(request.geometry), request.openingParagraphCount > 0,
                  NativeAgentChatSessionID.normalizedPathComponent(request.session) == request.session else {
                throw BodyFaceServices.failure("invalid_transcript_reader", "Open the transcript with a unique reader and valid layout geometry.")
            }
            try Task.checkCancellation()
            let reader = Reader(request: request)
            readers[id] = reader
            do {
                // Every transcript reads the contact readout: a contact's room for its lines, any other for the exchanges had in other rooms.
                engine.contactThreads.start()
                if Self.contact(request) == nil { try await readOpeningTranscript(request.session, minimumRows: request.openingParagraphCount) }
                try Task.checkCancellation()
                guard readers[id]?.lifetime == reader.lifetime else { throw FaceWireError.disconnected }
                await update(id)
                guard readers[id]?.lifetime == reader.lifetime else { throw FaceWireError.disconnected }
                if Self.contact(request) == nil, engine.transcripts.displayedTranscript(for: request.session).messages.contains(where: {
                    !$0.inlineCards.isEmpty || $0.metadata?.isPendingApproval == true
                }) { _ = await engine.pages.refresh(page: "inbox") }
                if Self.contact(request) == nil {
                    await publishConversation(request.session, transcript: engine.transcripts.displayedTranscript(for: request.session))
                }
                try Task.checkCancellation()
                guard readers[id]?.lifetime == reader.lifetime else { throw FaceWireError.disconnected }
            } catch {
                if readers[id]?.lifetime == reader.lifetime {
                    if Task.isCancelled {
                        readers.removeValue(forKey: id)
                        await press.remove(reader: id)
                    } else {
                        readers[id]?.task = Task { [weak self] in await self?.watch(id) }
                    }
                }
                throw error
            }
            readers[id]?.task = Task { [weak self] in await self?.watch(id) }
            return .acknowledged
        case .resizeTranscriptReader(let geometry):
            guard var reader = readers[geometry.reader], Self.valid(geometry) else {
                throw BodyFaceServices.failure("transcript_reader_missing", "The transcript reader is closed or its layout is invalid.")
            }
            reader.request.geometry = geometry
            readers[geometry.reader] = reader
            await press.resize(reader: geometry.reader, width: geometry.width, scale: geometry.scale, viewport: geometry.viewport)
            return .acknowledged
        case .releaseTranscriptReader(let id):
            let reader = readers.removeValue(forKey: id)
            reader?.task?.cancel()
            await reader?.task?.value
            await press.remove(reader: id)
            return .acknowledged
        case .transcriptReceipt(let id, let receipt):
            guard readers[id] != nil else { throw BodyFaceServices.failure("transcript_reader_missing", "The transcript reader is closed.") }
            switch receipt {
            case .complete:
                guard let reader = readers[id] else { throw FaceWireError.disconnected }
                if Self.contact(reader.request) == nil {
                    _ = try await engine.transcripts.refreshMessages(sessionId: reader.request.session)
                }
                try Task.checkCancellation()
                guard readers[id]?.lifetime == reader.lifetime else { throw FaceWireError.disconnected }
                await update(id)
            case .viewport(let blocks):
                readers[id]?.request.geometry.viewport = blocks
                guard let geometry = readers[id]?.request.geometry else { throw FaceWireError.disconnected }
                await press.resize(reader: id, width: geometry.width, scale: geometry.scale, viewport: blocks)
            case .applied(let script):
                guard await press.applied(reader: id, script: script) else {
                    throw BodyFaceServices.failure("transcript_script_unknown", "The transcript receipt names a script that was not sent to this reader.")
                }
                readers[id]?.appliedScript = script
            case .painted(let script): await press.painted(reader: id, script: script)
            case .rejected(let script, let cause):
                ModuleLog.app("[face-transcript] reader %@ rejected script %@: %@", id.uuidString, script.uuidString,
                    NativeAppSecretRedactor.redactText(cause))
                await press.rejected(reader: id, script: script)
            case .rebase: await press.rebase(reader: id)
            case .revealed(let row): await press.revealed(reader: id, rowID: row)
            }
            return .acknowledged
        case .firstVisibleReply(let receipt):
            guard receipt.visible, let reader = readers[receipt.reader], reader.request.session == receipt.session,
                  reader.appliedScript == receipt.script else {
                throw BodyFaceServices.failure("visible_reply_reader_changed", "The visible reply has no matching applied transcript reader.")
            }
            guard let message = engine.transcripts.displayedTranscript(for: receipt.session).messages.last(where: { $0.role == "assistant" }),
                  message.id == receipt.message, message.metadata?.turnTraceId == receipt.turn,
                  !receipt.turn.isEmpty else {
                throw BodyFaceServices.failure("visible_reply_changed", "The visible reply no longer identifies this conversation's latest assistant turn.")
            }
            let text: String
            if engine.turns.streamingBubbleID(for: receipt.session) == message.id {
                guard let live = engine.transcripts.streamingTailBox(forMessage: message.id).content else {
                    throw BodyFaceServices.failure("visible_reply_text_unavailable", "The visible reply has no matching live text at its owner.")
                }
                text = live
            } else { text = message.content }
            await TurnFirstRenderRegistry.shared.observeFirstRender(role: message.role, content: text, isLastAssistant: true,
                messageSessionID: message.sessionId, messageTurnID: receipt.turn, activeSessionID: receipt.session,
                observedBy: "NativeAgentFace.TranscriptDocumentView")
            return .acknowledged
        case .setTranscriptFold(let id, let rowIDs, let expanded):
            guard let reader = readers[id] else { throw BodyFaceServices.failure("transcript_reader_missing", "The transcript reader is closed.") }
            guard Self.contact(reader.request) == nil else {
                throw BodyFaceServices.failure("contact_fold_unavailable", "Contact messages do not contain tool folds.")
            }
            let selected = Set(rowIDs)
            let all = engine.transcripts.displayedTranscript(for: reader.request.session).messages
            let messages = all.filter { selected.contains($0.id) }
            guard messages.count == selected.count else {
                throw BodyFaceServices.failure("transcript_fold_changed", "A folded row is absent from the current conversation. Read it again.")
            }
            await engine.transcripts.prepareToolFold(messages, expanded: expanded)
            await words(reader: id, messages: all)
            return .acknowledged
        case .requestCopy(let keys):
            var values: [String: PartFace.Value] = [:]
            for key in keys {
                guard let words = await engine.transcripts.presentation.words(key) else {
                    throw BodyFaceServices.failure("copy_words_waiting", "The requested words have not been prepared by their presentation owner.")
                }
                values[key] = .string(words)
            }
            return .result(.object(values))
        case .exportConversation(let request): return try await export(request)
        case .observe(let id, .key(.conversation(let session))):
            guard NativeAgentChatSessionID.normalizedPathComponent(session) == session else {
                throw BodyFaceServices.failure("invalid_conversation", "Choose a conversation before observing its transcript.")
            }
            guard observations[id] == nil else { throw BodyFaceServices.failure("observation_exists", "This observation is already open.") }
            try Task.checkCancellation()
            observations[id] = Task { [weak self] in await self?.observeConversation(session) }
            return .observation(id: id)
        case .unobserve(let id) where observations[id] != nil:
            let task = observations.removeValue(forKey: id)
            task?.cancel()
            await task?.value
            return .acknowledged
        default: return nil
        }
    }

    private static func valid(_ geometry: TranscriptReaderGeometry) -> Bool {
        geometry.width.isFinite && geometry.width > 0 && geometry.scale.isFinite && geometry.scale > 0
            && geometry.viewportHeight.isFinite && geometry.viewportHeight > 0
    }

    private static func contact(_ request: TranscriptReaderRequest) -> String? {
        guard request.presentation == "contact", request.session.hasPrefix("contact:") else { return nil }
        let id = String(request.session.dropFirst(8))
        return id.isEmpty ? nil : id
    }

    /// Keep visited transcripts current between readers, until their connection closes.
    private func readOpeningTranscript(_ session: String, minimumRows: Int) async throws {
        defer { if !Task.isCancelled { watchStore(session) } }
        let changed: Bool
        if stores[session] == nil { changed = await engine.agents.refreshDotSession(session) }
        else { changed = false }
        let displayed = engine.transcripts.displayedTranscript(for: session)
        if changed || displayed.readStatus != .current || (!displayed.isComplete && displayed.messages.count < minimumRows) {
            _ = try await engine.transcripts.refreshDisplayedMessages(sessionId: session, cached: !changed, minimumRows: minimumRows)
        }
        try Task.checkCancellation()
    }

    private func watchStore(_ session: String) {
        guard stores[session] == nil else { return }
        stores[session] = Task { [weak self, engine] in
            await engine.transcripts.watchChanges(sessionID: session) {
                guard let self, self.stores[session] != nil else { return }
                do { _ = try await engine.transcripts.refreshDisplayedMessages(sessionId: session, cached: false) }
                catch { await self.publishCurrentConversation(session) }
            }
        }
    }

    private func watch(_ id: UUID) async {
        let (changes, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        var events = changes.makeAsyncIterator()
        while !Task.isCancelled, let reader = readers[id] {
            let session = reader.request.session
            withObservationTracking {
                if let contact = Self.contact(reader.request) {
                    let owner = engine.contactThreads
                    _ = owner.lines[contact]
                    _ = owner.partial(for: contact)
                    _ = owner.flight(for: contact)
                    _ = owner.contacts
                    _ = owner.helpers
                    _ = owner.loaded
                    _ = owner.helpersLoaded
                    _ = owner.contactRefreshError
                    _ = owner.helpersRefreshError
                    _ = engine.persona.displayName
                    _ = engine.transcripts.sessions
                    _ = engine.transcripts.sessionIndexError
                    _ = engine.transcripts.hasLoadedSessionIndex
                } else {
                    _ = engine.transcripts.structureVersion(for: session)
                    let live = engine.turns.streamingBubbleID(for: session)
                    if let live { _ = engine.transcripts.streamingTailBox(forMessage: live).content }
                    _ = engine.contactThreads.otherRooms
                    _ = engine.transcripts.transcriptReadStatus(for: session)
                }
            } onChange: { signal.yield() }
            await update(id)
            guard await events.next() != nil else { return }
        }
    }

    private func observeConversation(_ session: String) async {
        let (changes, signal) = AsyncStream<Void>.makeStream()
        let token = NotificationCenter.default.addObserver(forName: .pageFacePublished, object: nil, queue: nil) { notice in
            if notice.object as? String == "inbox" { signal.yield() }
        }
        defer { NotificationCenter.default.removeObserver(token); signal.finish() }
        var events = changes.makeAsyncIterator()
        while !Task.isCancelled {
            withObservationTracking {
                _ = engine.transcripts.structureVersion(for: session)
                _ = engine.transcripts.transcriptReadStatus(for: session)
            } onChange: { signal.yield() }
            await publishCurrentConversation(session)
            guard await events.next() != nil else { return }
        }
    }

    private func update(_ id: UUID) async {
        guard let reader = readers[id] else { return }
        let request = reader.request
        if let contact = Self.contact(request) {
            await updateContact(id, reader: reader, contact: contact)
            return
        }
        let title = await engine.transcripts.readFirstConversationReceiptTitle()
        guard !Task.isCancelled, readers[id]?.lifetime == reader.lifetime else { return }
        guard case .current = engine.transcripts.transcriptReadStatus(for: request.session) else {
            await publishCurrentConversation(request.session)
            return
        }
        let displayed = engine.transcripts.displayedTranscript(for: request.session)
        var messages = displayed.messages
        let all = messages
        if request.presentation == "shotgun" {
            let said = messages.filter { $0.role == "user" || $0.role == "assistant" }.suffix(10).map(\.id)
            let decisions = messages.filter {
                $0.metadata?.isPendingApproval == true || $0.inlineCards.contains { $0.model.needsAttention }
                    || $0.metadata?.interactionMirror != nil
            }.map(\.id)
            let selected = Set(said).union(decisions)
            messages = messages.filter { selected.contains($0.id) }
        }
        let groups = MessageGrouper.projection(for: messages)
        let liveID = engine.turns.streamingBubbleID(for: request.session)
        let live = liveID.flatMap { engine.transcripts.streamingTailBox(forMessage: $0).content }
        let transcripts = engine.transcripts
        let cards = TranscriptReadout(messages: messages).cardsByRow.mapValues { $0.map(\.model.id) }
        let trailing = ChatTurnFailure.read(all) == nil ? [] : [TranscriptBlock(id: "trouble", messageID: "trouble", role: "system",
            kind: .attachment(.trouble), source: "", lead: .message, foldGroup: nil)]
        let input = TranscriptPressInput(session: request.session, presentation: request.presentation, groups: Array(groups),
            exchanges: engine.contactThreads.otherRooms.filter { $0.sessionID != request.session }, cards: cards,
            faceEpoch: title ?? "", face: { TranscriptRowFace.read($0, receiptTitle: title) },
            wanted: { [weak self] rows in
                Task { @MainActor in
                    await transcripts.prepareToolFold(rows)
                    await self?.words(reader: id, messages: transcripts.displayedTranscript(for: request.session).messages)
                }
            }, render: TranscriptRenderer.prepare, door: TranscriptDoor(trailing: trailing), liveID: liveID, liveText: live,
            width: request.geometry.width, scale: request.geometry.scale, viewport: request.geometry.viewport,
            openingParagraphs: request.openingParagraphCount, hasEarlierMessages: !displayed.isComplete)
        guard !Task.isCancelled, readers[id]?.lifetime == reader.lifetime else { return }
        await transcripts.press.update(reader: id, input: input)
    }

    private func updateContact(_ id: UUID, reader: Reader, contact: String) async {
        let request = reader.request
        let document = await conversationRead(request.session).read({
            await engine.contactThreadDocument(contact)
        }, publish: { value in
            guard readers[id]?.lifetime == reader.lifetime else { return }
            enqueueConversation(ConversationFace(session: request.session, state: value.face.state, cacheReady: value.face.state == .ready,
                actions: [], attachments: [], otherRoomExchanges: [], transcriptComplete: value.face.state == .ready))
        })
        let input = TranscriptPressInput(session: request.session, presentation: request.presentation,
            groups: Array(MessageGrouper.projection(for: document.messages)), exchanges: [], cards: [:], faceEpoch: "contact",
            face: { TranscriptRowFace.plain($0) }, wanted: { _ in }, render: TranscriptRenderer.prepare,
            door: TranscriptDoor(), liveID: nil, liveText: nil, width: request.geometry.width, scale: request.geometry.scale,
            viewport: request.geometry.viewport, openingParagraphs: request.openingParagraphCount)
        guard !Task.isCancelled, readers[id]?.lifetime == reader.lifetime else { return }
        await engine.transcripts.press.update(reader: id, input: input)
    }

    private func words(reader: UUID, messages: [ChatMessage]) async {
        var values: [String: String] = [:]
        for message in messages {
            if let text = await engine.transcripts.presentation.words("headline:" + message.id) { values["headline:" + message.id] = text }
            if let text = await engine.transcripts.presentation.words("detail:" + message.id) { values["detail:" + message.id] = text }
        }
        guard readers[reader] != nil else { return }
        await engine.transcripts.press.words(reader: reader, values: values)
    }

    private func publishConversation(_ session: String, transcript: TranscriptReadout) async {
        do {
            _ = try await conversationRead(session).read({ try await readConversation(session, transcript: transcript) }, publish: enqueueConversation)
        } catch is CancellationError {
        } catch { await failed(session, error: error) }
    }

    private func publishCurrentConversation(_ session: String) async {
        switch engine.transcripts.transcriptReadStatus(for: session) {
        case .current: await publishConversation(session, transcript: engine.transcripts.displayedTranscript(for: session))
        case .loading: break
        case .unavailable(let cause): await failed(session, error: BodyFaceServices.failure("transcript_read_failed", cause))
        }
    }

    private func conversationRead(_ session: String) -> LatestRead {
        if let read = conversationReads[session] { return read }
        let read = LatestRead()
        conversationReads[session] = read
        return read
    }

    private func enqueueConversation(_ value: ConversationFace) {
        pendingConversations[value.session] = value
        guard conversationDelivery == nil else { return }
        conversationDelivery = Task { [weak self] in await self?.deliverConversations() }
    }

    private func deliverConversations() async {
        defer { conversationDelivery = nil }
        while !Task.isCancelled, let next = pendingConversations.first {
            pendingConversations.removeValue(forKey: next.key)
            await engine.face.post(next.value, at: .conversation(session: next.key))
        }
    }

    private func readConversation(_ session: String, transcript: TranscriptReadout) async throws -> ConversationFace {
        let messages = transcript.messages
        let snapshot = await engine.pages.snapshots["inbox"]
        let inbox = snapshot?.drawnFace
        var attachments: [FaceResolvedAttachment] = []
        for message in messages {
            try Task.checkCancellation()
            for (index, attachment) in (message.metadata?.attachments ?? []).enumerated() {
                let kind: String
                switch attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "image": kind = "image"
                case "audio": kind = "voice"
                default: kind = "file"
                }
                let id = message.id + "@" + kind + "-" + String(index)
                do {
                    let resource = try await Self.resource(attachment)
                    let preview = kind == "image" ? await TranscriptAttachmentPreviews.shared.read(attachment.path) : nil
                    attachments.append(.init(id: id, message: message.id, kind: kind, title: attachment.name ?? attachment.id,
                        text: kind == "voice" ? message.content : nil, resource: resource, card: nil, failure: nil, preview: preview))
                } catch {
                    attachments.append(.init(id: id, message: message.id, kind: kind, title: attachment.name ?? attachment.id,
                        text: nil, resource: nil, card: nil, failure: .init(code: "attachment_read_failed",
                            message: "The saved attachment could not be opened.", cause: error.localizedDescription, effects: .none)))
                }
            }
            for card in message.inlineCards {
                let row = inbox?.sections.flatMap(\.rows).first { $0.id == "interaction:" + card.interaction.id }
                attachments.append(.init(id: "card-" + card.interaction.id, message: message.id, kind: "card", title: card.model.title,
                    text: nil, resource: nil, card: row.map { PartFace(sections: [.init(id: $0.id, style: .list, rows: [$0])]) },
                    failure: row == nil ? .init(code: "card_presentation_unavailable", message: "This request could not be read from Inbox.",
                        cause: snapshot?.error?.message, effects: .none) : nil, secureCard: card.secureFace))
            }
            if let approval = message.metadata?.approvalId, message.metadata?.isPendingApproval == true {
                let row = inbox?.sections.flatMap(\.rows).first { $0.id == approval }
                attachments.append(.init(id: "approval-" + message.id, message: message.id, kind: "approval", title: "Approval request",
                    text: nil, resource: nil, card: row.map { PartFace(sections: [.init(id: $0.id, style: .list, rows: [$0])]) },
                    failure: row == nil ? .init(code: "approval_presentation_unavailable", message: "This approval could not be read from Inbox.",
                        cause: snapshot?.error?.message, effects: .none) : nil))
            }
            if TranscriptRowFace.read(message, receiptTitle: nil).seat == .envelope {
                attachments.append(.init(id: message.id + "#0", message: message.id, kind: "envelope", title: "Message",
                    text: message.content, resource: nil, card: nil, failure: nil))
            }
        }
        if let trouble = ChatTurnFailure.read(messages) {
            attachments.append(.init(id: "trouble", message: trouble.message.id, kind: "trouble", title: "Reply failed",
                text: trouble.failure.line(model: nil), resource: nil, card: nil, failure: nil))
        }
        let actions = messages.map { message in
            MessageActionFace(message: message.id, canRetry: ChatTurnFailure.isFailed(message),
                canContinue: ChatTurnFailure.isFailed(message), canRemember: message.role == "assistant",
                retryDraft: nil, failure: nil)
        }
        let waiting = messages.contains {
            $0.metadata?.isPendingApproval == true || $0.inlineCards.contains { $0.model.needsAttention }
        }
        let target = messages.last(where: { $0.role == "assistant" }).flatMap { message in
            message.metadata?.turnTraceId.map { VisibleReplyTarget(message: message.id, turn: $0) }
        }
        return ConversationFace(session: session, state: .ready, cacheReady: engine.transcripts.hasCachedTranscript(for: session),
            actions: actions, attachments: attachments, otherRoomExchanges: [],
            waitingForPerson: waiting ? true : (transcript.isComplete ? false : nil), visibleReply: target,
            transcriptComplete: transcript.isComplete)
    }

    private func failed(_ session: String, error: any Error) async {
        let value = ConversationFace(session: session, state: .unavailable(.init(code: "conversation_read_failed",
            message: "The conversation could not be read.", cause: NativeAppSecretRedactor.redactText(error.localizedDescription),
            effects: .none)), cacheReady: false,
            actions: [], attachments: [], otherRoomExchanges: [], transcriptComplete: false)
        conversationRead(session).write { enqueueConversation(value) }
    }

    private func export(_ request: ConversationExportRequest) async throws -> FaceActReply {
        guard request.format == "markdown", request.destination.writable else {
            throw BodyFaceServices.failure("export_format_unavailable", "Choose a writable folder for a Markdown conversation export.")
        }
        let sessions = try await engine.transcripts.readSessionIndex()
        let messages = try await engine.transcripts.loadMessages(sessionId: request.session, cached: false)
        return try await Self.export(request, session: sessions.first { $0.id == request.session }, messages: messages)
    }

    @concurrent private static func export(_ request: ConversationExportRequest, session: ChatSession?,
        messages: [ChatMessage]) async throws -> FaceActReply {
        let folder = try BodyFaceResources.resolve(request.destination)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let result = try await ChatExport.export(session: session, sessionId: request.session, messages: messages, destinationDirectory: folder)
        let grant = ResourceGrant(id: UUID(), name: result.url.lastPathComponent,
            bookmark: try result.url.bookmarkData(), writable: false)
        return .artifact(.init(resource: grant, bytes: nil, mimeType: "text/markdown", name: result.url.lastPathComponent,
            warnings: result.unavailableImages))
    }

    @concurrent private static func resource(_ attachment: PersistedAttachment) async throws -> ResourceGrant {
        guard let path = attachment.path, !path.isEmpty else {
            throw BodyFaceServices.failure("attachment_path_missing", "The saved attachment has no file path.")
        }
        let file = URL(fileURLWithPath: path)
        return .init(id: UUID(), name: attachment.name ?? file.lastPathComponent,
            bookmark: try file.bookmarkData(), writable: false)
    }
}
