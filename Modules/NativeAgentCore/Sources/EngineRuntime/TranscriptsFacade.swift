import AppToolRuntime
import Transcripts
import ApprovalTransactions
import Foundation
import Observation
import ChatTurnRuntime
import AgentWorkspace
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import StandingBots
import MemoryV2
import AuthoredCapabilities
import AttentionRouting
import TurnTrace
import Privacy
import MacControl
import Darwin
import ChatTurnContracts
import ChatToolParsing
// Blueprint: | `TranscriptsFacade.swift` | Root-scoped observable transcript/session publication, navigation and streaming cache; LatestRead preserves each read and committed clears |
@MainActor
@Observable
private final class ChatTranscriptSlot {
    @ObservationIgnored var messages: [ChatMessage] = []
    @ObservationIgnored lazy var cardReads = LatestRead()
    var groups = MessageGrouper.GroupedTranscript(base: [])
    @ObservationIgnored var preparation: Task<Void, Never>?
    @ObservationIgnored let groupReads = LatestRead()
    var structureVersion: UInt64 = 0
    var readStatus: TranscriptReadout.ReadStatus = .loading
}
/// `NativeAgentEngine.transcripts`: the chat session index
/// (`chat/sessions.json`) and the transcripts (`chat/messages/<id>.jsonl`) for
/// one data root, in core types. The session list and the loaded transcripts
/// are observable state the chat window, the sidebar, Simple view, detached
/// panels, Status and Today render; the reads and writes are nonisolated so
/// the phone lanes use the same owner.
@MainActor
@Observable
public final class TranscriptsFacade {
    private nonisolated let turns: TurnsFacade
    public nonisolated var dataRoot: URL { turns.dataRoot }
    public var openingLines: ChatShellOpeningLine { ChatShellOpeningLine.forRoot(dataRoot) }
    public nonisolated let presentation: PresentationFaces
    public nonisolated let messageIndex = CommandPaletteMessageIndex()
    public internal(set) var savedBotReplies: [(BotsShelfRecord, ShelfEntry)] = []
    public internal(set) var savedMemories: [MemoryV2.MemoryRecord] = []
    public internal(set) var savedSearchError: String?
    @ObservationIgnored let savedSearchRead = LatestRead()
    @ObservationIgnored private var firstConversationReceiptTitleCache: String?

    /// Cache positive evidence only: the write token may arm mid-launch.
    public var firstConversationReceiptTitle: String? {
        if let cached = firstConversationReceiptTitleCache { return cached }
        let title = FirstConversationPersonaProgression.recordedWriteTitle(dataRoot: dataRoot)
        firstConversationReceiptTitleCache = title
        return title
    }
    public var firstConversationPersonName: String {
        NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot)
    }
    @ObservationIgnored public lazy var sessionTransactions = MacChatSessionTransactions()

    /// The current index; any publication supersedes suspended presentation reads.
    private var sessionSnapshot: [NativeAgentShared.ChatSession] = []
    public var sessions: [NativeAgentShared.ChatSession] {
        get { sessionSnapshot }
        set { sessionTransactions.indexRead.write { sessionSnapshot = newValue } }
    }
    /// Read publication keeps its original ticket. Treating it as a committed
    /// write would fence a newer read that is still running.
    public func publishSessionIndexRead(_ sessions: [NativeAgentShared.ChatSession]) {
        sessionSnapshot = sessions
    }
    public private(set) var pinnedSessionIDs: [String] = []
    public private(set) var conversationAnchor: ConversationAnchorPin?

    public var navigation: ChatSessionNavigation { navigation(for: sessions) }

    public func navigation(for sessions: [NativeAgentShared.ChatSession]) -> ChatSessionNavigation {
        let byID = Dictionary(sessions.filter { $0.archived != true }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = ConversationAnchor.merged(into: pinnedSessionIDs, anchorSessionId: conversationAnchor?.sessionId)
            .compactMap { id -> ChatSessionNavigation.Row? in
                byID[id].map { .init(session: $0, isPinned: pinnedSessionIDs.contains(id), isAnchor: id == conversationAnchor?.sessionId) }
            }
        return .init(rows: rows, pinnedSessionIDs: pinnedSessionIDs, anchor: conversationAnchor)
    }
    public func refreshNavigationIdentity() {
        pinnedSessionIDs = ChatSessionRetention.load()
        conversationAnchor = ConversationAnchor.current(dataRoot: dataRoot)
    }
    public func watchNavigation() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [ConversationAnchor.path(dataRoot: dataRoot)],
            notifications: [UserDefaults.didChangeNotification]) { self.refreshNavigationIdentity() }
    }
    public func savePinnedSessionIDs(_ ids: [String]) throws -> String {
        let encoded = try ChatSessionRetention.save(ids, dataRoot: dataRoot)
        pinnedSessionIDs = ChatSessionRetention.decode(encoded)
        return encoded
    }
    public func pinSession(_ sessionID: String) throws -> (changed: Bool, shared: Bool) {
        guard !pinnedSessionIDs.contains(sessionID) else { return (false, true) }
        let encoded = try savePinnedSessionIDs(pinnedSessionIDs + [sessionID])
        return (true, publishPins(encoded, includeTranscripts: true))
    }
    public func closePinnedTab(_ sessionID: String) throws -> ChatSessionRetention.CloseResult {
        let result = try ChatSessionRetention.closePinnedTab(sessionID: sessionID, dataRoot: dataRoot)
        refreshNavigationIdentity()
        return result
    }
    public func publishPins(_ encoded: String, includeTranscripts: Bool) -> Bool {
        ChatSessionRetention.request(encodedPinnedIDs: encoded) { _ in
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: includeTranscripts)
        }
    }
    // Each mounted conversation observes its own structure; token content
    // remains unobserved here and publishes only through the tail box.
    @ObservationIgnored private var storage: [String: ChatTranscriptSlot] = [:]
    @ObservationIgnored private var loadedSessions: Set<String> = []
    public private(set) var structureVersion: UInt64 = 0
    public var loadedSessionIDs: Set<String> {
        _ = structureVersion
        return loadedSessions
    }
    /// The live content of one streaming row, observed by that row's bubble
    /// and by nothing else.
    ///
    /// Boxes are handed out per message id and created on demand, so the
    /// bubble can take one before the first chunk exists.
    @ObservationIgnored private var streamingTailBoxes: [String: ChatStreamingTailBox] = [:]
    @ObservationIgnored private var streamingTailBoxOrder: [String] = []

    /// Disk projections remain separate from optimistic/streaming rows.
    public nonisolated let cache = ChatTranscriptCache.shared

    public nonisolated init(turns: TurnsFacade) {
        self.turns = turns
        self.presentation = PresentationFaces(dataRoot: turns.dataRoot)
    }

    /// One session's loaded messages; empty when none are loaded.
    public func messages(for sessionId: String) -> [ChatMessage] {
        let slot = slot(for: sessionId)
        _ = slot.structureVersion
        return slot.messages
    }
    public func hasCachedTranscript(for sessionID: String) -> Bool {
        loadedSessions.contains(sessionID)
    }
    public func structureVersion(for sessionId: String) -> UInt64 {
        slot(for: sessionId).structureVersion
    }
    public func prepareGroups(for sessionId: String) async {
        let slot = slot(for: sessionId)
        if slot.preparation == nil {
            let messages = slot.messages
            slot.preparation = Task {
                await slot.groupReads.read {
                    await Task.detached(priority: .userInitiated) { MessageGrouper.projection(for: messages) }.value
                } publish: { slot.groups = $0 }
            }
        }
        await slot.preparation?.value
    }
    public func groups(for sessionId: String) -> MessageGrouper.GroupedTranscript {
        let slot = slot(for: sessionId)
        _ = slot.structureVersion
        return slot.groups.readingTail(from: slot.messages)
    }
    public func card(id: String, in sessionID: String) -> InlineCardModel? {
        if case .unavailable = slot(for: sessionID).readStatus { return nil }
        return messages(for: sessionID).lazy.flatMap(\.inlineCards).first { $0.interaction.id == id }?.model
    }
    public func transcriptReadStatus(for sessionID: String) -> TranscriptReadout.ReadStatus {
        slot(for: sessionID).readStatus
    }
    public nonisolated func reclaimContinuations(for sessionID: String) async {
        await InlineInteractionResolver.reclaimStrandedContinuations(sessionID: sessionID, dataRoot: dataRoot)
    }
    public func refreshCards(in sessionID: String) async {
        _ = try? await loadTranscript(sessionId: sessionID)
    }
    public func watchIndexChanges(refresh: @escaping @MainActor @Sendable () async -> Void) async {
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: [dataRoot.appendingPathComponent("chat/sessions.json")],
            notifications: [AbilityStore.didChange], debounceDelay: .milliseconds(150), refresh: refresh
        )
    }
    public func watchChanges(sessionID: String, refresh: @escaping @MainActor @Sendable () async -> Void) async {
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { return }
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: [dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")],
            debounceDelay: .milliseconds(100), refresh: refresh
        )
    }
    private func slot(for sessionId: String) -> ChatTranscriptSlot {
        if let slot = storage[sessionId] { return slot }
        let slot = ChatTranscriptSlot()
        storage[sessionId] = slot
        return slot
    }
    public func setMessages(_ messages: [ChatMessage], for sessionId: String) {
        publishMessages(retainingPublishedCards(messages, for: sessionId), for: sessionId)
    }
    /// Message writes retain the cards published by the transcript reader.
    private func retainingPublishedCards(_ messages: [ChatMessage], for sessionId: String) -> [ChatMessage] {
        let cards = Dictionary(slot(for: sessionId).messages.map { ($0.id, $0.inlineCards) },
                               uniquingKeysWith: { _, last in last })
        var retained = messages.map { message in
            var message = message
            message.inlineCards = cards[message.id] ?? []
            return message
        }
        let rowIDs = Set(retained.map(\.id))
        retained += slot(for: sessionId).messages.filter { !$0.inlineCards.isEmpty && !rowIDs.contains($0.id) }
        return retained
    }
    private func publishMessages(_ messages: [ChatMessage], for sessionId: String) {
        let slot = slot(for: sessionId)
        slot.preparation?.cancel()
        slot.preparation = nil
        slot.groupReads.write { slot.messages = messages }
        loadedSessions.insert(sessionId)
        slot.structureVersion &+= 1
        structureVersion &+= 1
    }
    @discardableResult
    public func removeMessages(for sessionId: String) -> [ChatMessage]? {
        guard loadedSessions.remove(sessionId) != nil else { return nil }
        let slot = slot(for: sessionId)
        let messages = slot.messages
        publishMessages(retainingPublishedCards([], for: sessionId), for: sessionId)
        loadedSessions.remove(sessionId)
        return messages
    }
    internal func publishClearedTranscript(_ sessionId: String) {
        let current = slot(for: sessionId)
        current.cardReads.write {
            current.readStatus = .current
            publishMessages([], for: sessionId)
        }
    }
    /// The box for `messageId`, created if this is the first ask. Cheap enough
    /// to call from a view body: one dictionary lookup, no observation.
    public func streamingTailBox(forMessage messageId: String) -> ChatStreamingTailBox {
        if let existing = streamingTailBoxes[messageId] { return existing }
        let box = ChatStreamingTailBox()
        streamingTailBoxes[messageId] = box
        streamingTailBoxOrder.append(messageId)
        // A handful of live tails at once (the main window, detached panels,
        // parallel sessions) is the whole working set; older rows are settled
        // and render from the transcript.
        while streamingTailBoxOrder.count > 8 {
            streamingTailBoxes.removeValue(forKey: streamingTailBoxOrder.removeFirst())
        }
        return box
    }
    /// Mutate only the tail and its leaf box, without publishing structure.
    /// False leaves an interior rewrite to the caller's structural path.
    public func setTailMessageContent(_ content: String, id messageId: String, in sessionId: String) -> Bool {
        guard let slot = storage[sessionId], !slot.messages.isEmpty,
              slot.messages.last?.id == messageId
        else { return false }
        slot.messages[slot.messages.count - 1].content = content
        // The one publication a streamed chunk makes: the leaf bubble for this
        // exact row. Nothing else observes it, so the parent list keeps its
        // structural snapshot and its layout.
        streamingTailBox(forMessage: messageId).content = content
        return true
    }
    public func appendMessage(_ message: ChatMessage, to sessionId: String) {
        var messages = self.messages(for: sessionId)
        messages.append(message)
        setMessages(messages, for: sessionId)
    }
    @discardableResult
    public func refreshMessages(sessionId: String, cached: Bool = true) async throws -> Bool {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return false }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached).applied
    }
    public func removeMessage(id messageId: String, from sessionId: String) {
        guard hasCachedTranscript(for: sessionId) else { return }
        var rows = messages(for: sessionId)
        rows.removeAll { $0.id == messageId }
        setMessages(rows, for: sessionId)
    }
    public func updateMessageContent(id messageId: String, in sessionId: String, content: String) {
        if setTailMessageContent(content, id: messageId, in: sessionId) { return }
        guard hasCachedTranscript(for: sessionId) else { return }
        var rows = messages(for: sessionId)
        guard let index = rows.firstIndex(where: { $0.id == messageId }) else { return }
        rows[index].content = content
        setMessages(rows, for: sessionId)
    }
    internal func readPublishedTranscript(safeSessionId: String, cached: Bool)
        async throws -> (projection: TranscriptReadout, applied: Bool) {
        let current = slot(for: safeSessionId)
        let lifecycleAtStart = turns.lifecycle(for: safeSessionId)
        var applied = false
        let outcome: Result<TranscriptReadout, Error> = await current.cardReads.read {
            do { return .success(try await readTranscriptProjection(safeSessionId: safeSessionId, cached: cached)) }
            catch { return .failure(error) }
        } publish: { read in
            switch read {
            case .success(let projection):
                let lifecycle = turns.lifecycle(for: safeSessionId)
                applied = lifecycle == nil || lifecycle == lifecycleAtStart
                var messages = current.messages
                if applied {
                    let local = hasCachedTranscript(for: safeSessionId) ? messages : nil
                    let live = turns.streamingSessions.contains(safeSessionId) || turns.activeTurnIDsBySession[safeSessionId] != nil
                    if !live || local?.isEmpty != false {
                        messages = retainingPublishedCards(MacChatRetrySnapshot.preservingSyntheticNotice(
                            disk: projection.messages, local: local, sessionId: safeSessionId,
                            syntheticErrorIDPrefix: MacChatTurnRuntime.syntheticErrorIDPrefix,
                            isCompletedAssistant: MacChatTurnRuntime.isCompletedAssistant), for: safeSessionId)
                    }
                    if turns.streamingSessions.contains(safeSessionId) {
                        for (id, role, text) in [
                            (turns.streamingUserTurnIds[safeSessionId], "user", turns.streamingUserTurnTexts[safeSessionId]),
                            (turns.streamingBubbleIds[safeSessionId], "assistant", turns.streamingTexts[safeSessionId])
                        ] {
                            guard let id, !messages.contains(where: { $0.id == id }) else { continue }
                            var row = ChatMessage(id: id, sessionId: safeSessionId, role: role, content: text ?? "")
                            if role == "assistant" {
                                var metadata = ChatMessageMetadata(); metadata.turnTraceId = turns.activeTurnIDsBySession[safeSessionId]
                                row.metadata = metadata
                            }
                            messages.append(row)
                        }
                    }
                }
                current.readStatus = .current
                let cards = projection.cardsByRow
                // Keep live rows while admitting card rows raised since this session was loaded.
                let loadedRowIDs = Set(messages.map(\.id))
                messages += projection.messages.filter { !$0.inlineCards.isEmpty && !loadedRowIDs.contains($0.id) }
                for index in messages.indices { messages[index].inlineCards = cards[messages[index].id] ?? [] }
                if messages != current.messages || (applied && !hasCachedTranscript(for: safeSessionId)) {
                    publishMessages(messages, for: safeSessionId)
                }
            case .failure(let error):
                current.readStatus = .unavailable(error.localizedDescription)
            }
        }
        return (try outcome.get(), applied)
    }
}
// Session transactions use the same canonical read/write owner as every surface.
extension TranscriptsFacade: MacChatSessionStore {}

extension TranscriptsFacade: QuietChatTranscriptPort {}

@MainActor
extension TranscriptsFacade {
    public func setWorkingCommentary(_ characters: Int, id messageId: String, in sessionId: String) {
        var arr = messages(for: sessionId)
        guard let idx = arr.lastIndex(where: { $0.id == messageId }),
              arr[idx].metadata?.workingCommentaryChars != characters
        else { return }
        var metadata = arr[idx].metadata ?? ChatMessageMetadata()
        metadata.workingCommentaryChars = characters
        arr[idx].metadata = metadata
        setMessages(arr, for: sessionId)
    }
}
