import AttentionRouting
import AppToolRuntime
import TurnTrace
import Dispatcher
import Transcripts
import ApprovalTransactions
import Privacy
import MacControl
import Foundation
import Observation
import Darwin
import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import ChatToolParsing
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import StandingBots
import MemoryV2
import AuthoredCapabilities
// Blueprint: | `EngineTranscripts.swift` | `TranscriptsFacade`: root-scoped index/transcript invalidations, `CommandPaletteMessageIndex` and checked saved bot/memory search inputs; per-session observable slots and `LatestRead` card/read-status publication returning each read's own result; message writes retain published card rows/models, committed transcript clears use `write`; messages, streaming tails and first-conversation identity; resolved display titles and shared navigation/pin/anchor mutations; `loadTranscript` projects cards, heading and attachment previews from one transcript/root while preserving live rows; `refreshCards` and helper `observeSessionMessages` use that owner; Mac, detached, Shotgun, quiet chat, inbox cards and DeviceSync share the projection; `ChatTranscriptCache` owns file-identity transcript/shell/context reads; session transactions, unread accounting, stream/resume/settlement, mutations and slash execution |

public enum ChatMessageClearError: Error, LocalizedError, Sendable {
    case transcriptClearedMetadataNotSaved(String)
    case transcriptVersionExhausted

    public var errorDescription: String? {
        switch self {
        case .transcriptClearedMetadataNotSaved(let reason):
            return "Messages were cleared, but conversation metadata could not be saved: \(reason)"
        case .transcriptVersionExhausted:
            return "This conversation's transcript version cannot advance any further, so clearing it could not be published to your other devices. Nothing was deleted."
        }
    }
}

/// One transcript, projected for the UI: the messages a view renders and
/// the recollections the same rows carry, read together.
public struct ChatTranscriptProjection: Sendable {
    public enum ReadStatus: Equatable, Sendable {
        case loading, current
        case unavailable(String)
    }
    public struct Card: Sendable, Equatable {
        public let interaction: InlineInteraction
        public let descriptor: InlineInteractionDescriptor
        public let sessionID: String
        public let model: InlineCardModel
        public let repeatCount: Int
    }
    public var messages: [ChatMessage]
    /// Oldest first, exactly as `ChatSessionRecollections.recollections`
    /// returns them — this is that parser, over rows already decoded.
    public let recollections: [ChatSessionRecollection]
    var interactions: [(rowID: String, interaction: InlineInteraction)] = []
    public var cardsHeading: String = ""
    public var cardsByRow: [String: [Card]] {
        Dictionary(messages.filter { !$0.inlineCards.isEmpty }.map { ($0.id, $0.inlineCards) }, uniquingKeysWith: { _, last in last })
    }
    public var readStatus: ReadStatus = .current

    public static let empty = ChatTranscriptProjection(messages: [], recollections: [])
    public init(messages: [ChatMessage], recollections: [ChatSessionRecollection]) {
        self.messages = messages
        self.recollections = recollections
    }

}

@MainActor
@Observable
private final class ChatTranscriptSlot {
    @ObservationIgnored var messages: [ChatMessage] = []
    @ObservationIgnored lazy var cardReads = LatestRead()
    var structureVersion: UInt64 = 0
    var readStatus: ChatTranscriptProjection.ReadStatus = .loading
}

/// `NativeAgentEngine.transcripts` (S10): the chat session index
/// (`chat/sessions.json`) and the transcripts (`chat/messages/<id>.jsonl`) for
/// one data root, in core types. The session list and the loaded transcripts
/// are observable state the chat window, the sidebar, Simple view, detached
/// panels, Status and Today render; the reads and writes are nonisolated so
/// the phone lanes use the same owner.
@MainActor
@Observable
public final class TranscriptsFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let presentation: PresentationFaces
    public nonisolated let messageIndex = CommandPaletteMessageIndex()
    public private(set) var savedBotReplies: [(BotsShelfRecord, ShelfEntry)] = []
    public private(set) var savedMemories: [MemoryV2.MemoryRecord] = []
    public private(set) var savedSearchError: String?
    @ObservationIgnored private let savedSearchRead = LatestRead()
    @ObservationIgnored private var firstConversationReceiptTitleCache: String?

    /// Cache positive evidence only: the write token may arm mid-launch.
    public var firstConversationReceiptTitle: String? {
        if let cached = firstConversationReceiptTitleCache { return cached }
        let title = FirstConversationPersonaExemption.recordedWriteTitle(dataRoot: dataRoot)
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
    public var messagesBySession: [String: [ChatMessage]] {
        get {
            access(keyPath: \.messagesBySession)
            return Dictionary(uniqueKeysWithValues: loadedSessions.map { ($0, storage[$0]!.messages) })
        }
        set {
            withMutation(keyPath: \.messagesBySession) {
                for id in loadedSessions.union(newValue.keys) {
                    let slot = slot(for: id)
                    let messages = retainingPublishedCards(newValue[id] ?? [], for: id)
                    if slot.messages != messages || loadedSessions.contains(id) != (newValue[id] != nil) {
                        slot.messages = messages
                        slot.structureVersion &+= 1
                    }
                }
                loadedSessions = Set(newValue.keys)
                structureVersion &+= 1
            }
        }
    }

    /// The live content of one streaming row, observed by that row's bubble
    /// and by nothing else.
    ///
    /// Boxes are handed out per message id and created on demand, so the
    /// bubble can take one before the first chunk exists and a placeholder
    /// that migrates to a confirmed session id keeps the box it already has.
    @ObservationIgnored private var streamingTailBoxes: [String: ChatStreamingTailBox] = [:]
    @ObservationIgnored private var streamingTailBoxOrder: [String] = []

    /// Keeps the converted disk projection separate from optimistic/streaming
    /// UI rows, for the window's own reads.
    public nonisolated let cache = ChatTranscriptCache.shared

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.presentation = PresentationFaces(dataRoot: dataRoot)
    }

    // MARK: - Loaded transcripts

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

    public func cards(forRow rowID: String, in sessionID: String) -> [InlineCardModel] {
        if case .unavailable = slot(for: sessionID).readStatus { return [] }
        return messages(for: sessionID).first { $0.id == rowID }?.inlineCards.map(\.model) ?? []
    }

    public func card(id: String, in sessionID: String) -> InlineCardModel? {
        if case .unavailable = slot(for: sessionID).readStatus { return nil }
        return messages(for: sessionID).lazy.flatMap(\.inlineCards).first { $0.interaction.id == id }?.model
    }

    public func transcriptReadStatus(for sessionID: String) -> ChatTranscriptProjection.ReadStatus {
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
        withMutation(keyPath: \.messagesBySession) {
            let slot = slot(for: sessionId)
            slot.messages = messages
            loadedSessions.insert(sessionId)
            slot.structureVersion &+= 1
            structureVersion &+= 1
        }
    }

    private func publishClearedTranscript(_ sessionId: String) {
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

    /// Write `messages` knowing that only the FINAL row differs from what is
    /// there now. The one caller is the streaming delta (2026-09-06).
    public func setMessagesTailOnly(_ messages: [ChatMessage], for sessionId: String) {
        slot(for: sessionId).messages = retainingPublishedCards(messages, for: sessionId)
        loadedSessions.insert(sessionId)
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

    public func applyLoadedMessages(_ disk: [ChatMessage], for sessionId: String) {
        let loaded = MacChatRetrySnapshot.preservingSyntheticNotice(
            disk: disk, local: messagesBySession[sessionId],
            sessionId: sessionId, syntheticErrorIDPrefix: MacChatTurnRuntime.syntheticErrorIDPrefix,
            isCompletedAssistant: MacChatTurnRuntime.isCompletedAssistant
        )
        guard messagesBySession[sessionId] != loaded else { return }
        messagesBySession[sessionId] = loaded
    }

    public func removeMessage(id messageId: String, from sessionId: String) {
        guard var rows = messagesBySession[sessionId] else { return }
        rows.removeAll { $0.id == messageId }
        setMessages(rows, for: sessionId)
    }

    public func updateMessageContent(id messageId: String, in sessionId: String, content: String) {
        if setTailMessageContent(content, id: messageId, in: sessionId) { return }
        guard var rows = messagesBySession[sessionId],
              let index = rows.firstIndex(where: { $0.id == messageId }) else { return }
        rows[index].content = content
        if index == rows.count - 1 {
            setMessagesTailOnly(rows, for: sessionId)
        } else {
            setMessages(rows, for: sessionId)
        }
    }

    // MARK: - Paths

    nonisolated private var chatRoot: URL {
        dataRoot.appendingPathComponent("chat", isDirectory: true)
    }

    nonisolated private var sessionsPath: URL {
        chatRoot.appendingPathComponent("sessions.json")
    }

    // MARK: - Reads

    /// The session index, after retention has run under the same lock.
    /// Missing file → `[]`.
    public nonisolated func list() async throws -> [NativeAgentShared.ChatSession] {
        let dataRoot = self.dataRoot
        let url = sessionsPath
        let rows = try await SwiftNativePersistenceCore().withFileLock(url) {
            _ = try ChatSessionRetention.enforce(
                dataRoot: dataRoot,
                now: Date()
            )
            return try ChatSessionIndexFile.loadObjectRowsForMutation(at: url)
        }
        let sessions = try rows.map(NativeAgentShared.ChatSession.init(row:))
        await refreshNavigationIdentity()
        let projections = try await ChatShellOpeningLine.shared.prepareProjections(sessions, dataRoot: dataRoot)
        try Task.checkCancellation()
        let sources = sessions.map { session in
            (id:session.id,source:ChatShellConversationRow.titleSource(for:session,openingLine:projections[session.id]?.line))
        }
        let automated = sources.filter { $0.source.automated }
        let face = await presentation.prepareSnapshot("conversations",input:.object(["kind":.string("conversations"),
            "rows":.array(automated.map { .object(["key":.string($0.id),"opening":.string($0.source.text)]) })]))
        try Task.checkCancellation()
        let projected = Dictionary((face.face?.sections.flatMap(\.rows) ?? []).map { ($0.id,$0.title) },uniquingKeysWith:{ first,_ in first })
        let titles = Dictionary(sources.map { row -> (String,String) in
            if !row.source.automated { return (row.id,row.source.text) }
            if face.status != .ready { return (row.id,"Conversation "+face.status.rawValue) }
            if let title=projected[row.id] {
                return (row.id,row.source.text.hasPrefix("Current standing instructions for ") ? ChatShellConversationRow.clamp(title) : title)
            }
            return (row.id,"Conversation unavailable: unbound title")
        },uniquingKeysWith:{ first,_ in first })
        return await MainActor.run {
            sessions.map { session in
                var resolved = session
                resolved.displayTitle = titles[session.id]!
                resolved.isWorkingConversation = ChatShellConversationRow.isWorking(session)
                return resolved
            }
        }
    }

    /// The archive tier (`chat/archive/sessions.jsonl`), where Archive and
    /// retention move a conversation out of the index: the newest row per id,
    /// less any a door has since brought back into the index. Missing file → `[]`.
    public nonisolated func listArchived() async throws -> [NativeAgentShared.ChatSession] {
        let url = sessionsPath
        let archivePath = chatRoot
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        return try await SwiftNativePersistenceCore().withFileLock(url) {
            let hot = Set(try ChatSessionIndexFile.loadObjectRowsForMutation(at: url).compactMap { row -> String? in
                guard case .string(let id)? = row["id"], row["archived"] != .bool(true) else { return nil }
                return id
            })
            guard FileManager.default.fileExists(atPath: archivePath.path) else { return [] }
            var newest: [String: NativeAgentShared.ChatSession] = [:]
            for line in try Data(contentsOf: archivePath).split(separator: 10) {
                guard case .object(let row) = try JSONValue.parse(Data(line)) else { continue }
                let session = try NativeAgentShared.ChatSession(row: row)
                if !hot.contains(session.id) { newest[session.id] = session }
            }
            return Array(newest.values)
        }
    }

    public nonisolated func loadMessages(sessionId: String, cached: Bool = false) async throws -> [ChatMessage] {
        try await loadTranscript(sessionId: sessionId, cached: cached).messages
    }

    /// Messages AND recollections from one read of one transcript.
    ///
    /// User, 2026-09-13 (speed): Today used to take its eight transcripts
    /// through the cache for messages and then have its snapshot read and
    /// parse the same eight JSONL files again for recollections. Both answers
    /// come from the same decoded rows, so they are decoded once. `cached`
    /// reads go through the window's projection cache.
    public nonisolated func loadTranscript(sessionId: String, cached: Bool = false) async throws -> ChatTranscriptProjection {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return .empty
        }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached)
    }

    private func readPublishedTranscript(safeSessionId: String, cached: Bool) async throws -> ChatTranscriptProjection {
        let current = slot(for: safeSessionId)
        let outcome: Result<ChatTranscriptProjection, Error> = await current.cardReads.read {
            do { return .success(try await readTranscriptProjection(safeSessionId: safeSessionId, cached: cached)) }
            catch { return .failure(error) }
        } publish: { read in
            switch read {
            case .success(let projection):
                current.readStatus = .current
                let cards = projection.cardsByRow
                var messages = hasCachedTranscript(for: safeSessionId) ? current.messages : projection.messages
                // Keep live rows while admitting card rows raised since this session was loaded.
                let loadedRowIDs = Set(messages.map(\.id))
                messages += projection.messages.filter { !$0.inlineCards.isEmpty && !loadedRowIDs.contains($0.id) }
                for index in messages.indices { messages[index].inlineCards = cards[messages[index].id] ?? [] }
                if !hasCachedTranscript(for: safeSessionId) || messages != current.messages {
                    publishMessages(messages, for: safeSessionId)
                }
            case .failure(let error):
                current.readStatus = .unavailable(error.localizedDescription)
            }
        }
        return try outcome.get()
    }

    nonisolated private func readTranscriptProjection(safeSessionId: String, cached: Bool) async throws -> ChatTranscriptProjection {
        var projection: ChatTranscriptProjection
        if cached {
            let path = dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl")
            projection = try await cache.projection(at: path) {
                try await self.readTranscript(safeSessionId: safeSessionId)
            }
        } else { projection = try await readTranscript(safeSessionId: safeSessionId) }
        let cards = await InlineCardProjection.cardsByRow(
            projection.interactions, messages: projection.messages, sessionID: safeSessionId, dataRoot: dataRoot)
        for index in projection.messages.indices {
            projection.messages[index].inlineCards = cards.cardsByRow[projection.messages[index].id] ?? []
        }
        projection.cardsHeading = cards.heading
        return await projection.attachmentPreviews()
    }

    nonisolated private func readTranscript(safeSessionId: String) async throws -> ChatTranscriptProjection {
        // The native SessionHistoryReader reads `chat/messages/<id>.jsonl` and
        // resolves legacy text/timestamp aliases; each row's `extras` is the
        // raw transcript row, which carries id, runId, source and the tool-pill
        // metadata (kind/toolName/inputJSON/resultSummary) the streaming
        // tool-loop persists.
        let reader = ChatSessionWork.SessionHistoryReader(dataRoot: dataRoot)
        let history = try await reader.messagesWithStats(forSessionId: safeSessionId)
        // Prompt history intentionally tolerates damaged rows, but an empty
        // result caused by a failed read is not a successfully loaded UI
        // transcript. Propagate that failure to transactional session selection
        // so it keeps the previous conversation instead of replacing it.
        guard history.stats.mode != "read_failed" else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation could not be read. Its data was left unchanged."]
            )
        }
        let rejectedRows = history.stats.malformedRowCount + history.stats.invalidShapeRowCount
        guard !history.messages.isEmpty || rejectedRows == 0 else {
            throw NSError(
                domain: "NativeClient.ChatHistory", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The saved conversation has no readable messages (\(rejectedRows) damaged rows). Its data was left unchanged."]
            )
        }
        // Missing/empty new sessions remain valid, and mixed transcripts keep
        // their readable rows under the existing tolerant reader contract.
        let coMessages = history.messages
        // The canonical recollection parser, over the rows this read already
        // decoded. `extras` is the raw transcript row, which is exactly what
        // `ChatSessionRecollections.recollections` parses per line — so this
        // is the same answer without a second pass over the file.
        let recollections = coMessages.compactMap { co -> ChatSessionRecollection? in
            guard let extras = co.extras else { return nil }
            return ChatSessionRecollections.recollection(
                fromTranscriptRow: extras,
                sessionId: safeSessionId
            )
        }
        let messages = coMessages.map { co -> ChatMessage in
            guard case .object(let row)? = co.extras else {
                return ChatMessage(
                    sessionId: safeSessionId,
                    role: co.role,
                    content: co.content,
                    createdAt: co.timestamp
                )
            }
            var message = ChatMessage(row: row)
            // A fork keeps its source rows byte-for-byte, including their
            // original session IDs. This UI projection belongs to the
            // requested transcript; actions on an inherited row must not
            // jump back to the source conversation. Recorded metadata and
            // on-disk provenance remain untouched.
            message.sessionId = safeSessionId
            // The history reader already resolves legacy text/timestamp
            // aliases; the row's own fields must not replace them with defaults.
            message.content = co.content
            if !co.timestamp.isEmpty { message.createdAt = co.timestamp }
            return message
        }
        var projection = ChatTranscriptProjection(messages: messages, recollections: recollections)
        projection.interactions = InlineInteractionResolver.interactionsByRow(in: coMessages.compactMap(\.extras),
            lifeID: try DataRootLife.current(in: dataRoot))
        return projection
    }

    // MARK: - Writes

    /// A new session row at the top of the index.
    public nonisolated func create(title: String, sourceKey: String? = nil) async throws -> NativeAgentShared.ChatSession {
        let dataRoot = self.dataRoot
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        var sessionRow: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "source": .string("app"),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        if let sourceKey, !sourceKey.isEmpty { sessionRow["sourceKey"] = .string(sourceKey) }
        let rowToInsert = sessionRow
        let sessionsPath = self.sessionsPath
        try await SwiftNativePersistenceCore().withFileLock(sessionsPath) {
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            sessions.insert(rowToInsert, at: 0)
            try ChatSessionIndexFile.write(sessions, to: sessionsPath)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: Date(),
                context: "TranscriptsFacade.create"
            )
        }
        return try NativeAgentShared.ChatSession(row: sessionRow)
    }

    /// Patch a session's title (rename) and/or archived flag.
    public nonisolated func update(id: String, title: String?, archived: Bool?) async throws -> NativeAgentShared.ChatSession {
        let sessionsPath = self.sessionsPath
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let updated: [String: JSONValue]? = try await ChatSessionIndexFile.mutate(at: sessionsPath) { sessions in
            guard let idx = sessions.firstIndex(where: { $0["id"] == .string(id) }) else { return nil }
            var row = sessions[idx]
            if let title { row["title"] = .string(title) }
            if let archived { row["archived"] = .bool(archived) }
            // A rename is not a conversation event: the row's time is
            // when someone last spoke, so only an archive flip bumps it.
            if archived != nil { row["updatedAt"] = .string(nowIso) }
            sessions[idx] = row
            return row
        }
        guard let updated else {
            throw NSError(domain: "NativeAgent", code: -404,
                          userInfo: [NSLocalizedDescriptionKey: "chat session \(id) not found"])
        }
        return try NativeAgentShared.ChatSession(row: updated)
    }

    /// A user-initiated archive leaves the hot index immediately. Retention
    /// later bounds the archive tier, but it must not be responsible for the
    /// visible archive action: an archived chat may never linger in
    /// `sessions.json` or append duplicate retry records to the archive tail.
    public nonisolated func archive(id: String) async throws -> NativeAgentShared.ChatSession? {
        try await ChatSessionRetention.archiveSession(id: id, dataRoot: dataRoot)
            .map(NativeAgentShared.ChatSession.init(row:))
    }

    /// Empty one transcript (`chat/messages/<id>.jsonl`) under its lock and
    /// publish the empty on the index row. Every live writer
    /// (ChatOrchestrationClient.appendMessage / persistPartialIfNeeded /
    /// SessionHistoryReader / iOS-bridge forward) uses this FLAT path; any
    /// stale nested file left over from the earlier
    /// `chat/sessions/<id>/messages.jsonl` shape is removed too.
    public nonisolated func clear(sessionId: String) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw NSError(
                domain: "NativeAgentChatSession",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Cannot clear chat messages: invalid chat session id"]
            )
        }
        let messagesPath = chatRoot
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let staleNestedPath = chatRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSessionId, isDirectory: true)
            .appendingPathComponent("messages.jsonl")
        let persistence = SwiftNativePersistenceCore()
        let sessionsPath = self.sessionsPath
        let usagePath = chatRoot
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(safeSessionId, isDirectory: true)
            .appendingPathComponent("provider_usage.json")
        // Refuse known index corruption before deleting any transcript bytes.
        // Keep locks separate: other writers have their own transcript/index
        // ordering, so clear must not add a nested cross-file lock dependency.
        _ = try await persistence.withFileLock(sessionsPath) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            // 2026-09-06: a row whose transcript counter has hit the ceiling
            // can never prove the empty this clear is about to publish is the
            // newest state, so the phone would refuse it and keep showing the
            // conversation the Mac just deleted. Refuse here, before any
            // transcript byte is gone, rather than half-clear the pair.
            if let row = rows.first(where: { $0["id"] == .string(safeSessionId) }),
               ChatSessionIndexFile.isTranscriptGenerationExhausted(in: row) {
                nativeLog("TranscriptsFacade.clear: refusing to clear \(safeSessionId) — its transcript version is at Int64.max and cannot advance")
                throw ChatMessageClearError.transcriptVersionExhausted
            }
            return rows
        }
        let usageBeforeClear: Data? = try await persistence.withFileLock(messagesPath) {
            let usage: Data?
            do {
                usage = try Data(contentsOf: usagePath)
            } catch CocoaError.fileReadNoSuchFile {
                usage = nil
            }
            try ContactThread.replace(Data(), to: messagesPath)
            if FileManager.default.fileExists(atPath: staleNestedPath.path) {
                try? FileManager.default.removeItem(at: staleNestedPath)
            }
            return usage
        }
        await publishClearedTranscript(safeSessionId)
        do {
            if let usageBeforeClear {
                let invalidated = try await persistence.withFileLock(usagePath) {
                    let current: Data
                    do {
                        current = try Data(contentsOf: usagePath)
                    } catch CocoaError.fileReadNoSuchFile {
                        return false
                    }
                    // A concurrent provider call owns its replacement receipt.
                    guard current == usageBeforeClear else { return false }
                    try FileManager.default.removeItem(at: usagePath)
                    return true
                }
                if invalidated {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .nativeAgentSessionProviderUsageDidChange,
                            object: safeSessionId
                        )
                    }
                }
            }
            try await ChatSessionIndexFile.mutate(at: sessionsPath, using: persistence) { rows in
                // A real append after clear owns the new index projection. Its
                // normal writer will synchronize it; never zero its preview.
                guard try messagesPath.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0,
                      let index = rows.firstIndex(where: { $0["id"] == .string(safeSessionId) })
                else { return }
                rows[index]["messageCount"] = .int(0)
                rows[index]["firstMessageAt"] = .null
                rows[index]["lastMessageAt"] = .null
                rows[index]["lastMessagePreview"] = .null
                rows[index]["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                // 2026-09-06: the clear is what makes the published transcript
                // EMPTY, and an empty transcript is the one publication a
                // remote reader is allowed to wipe a chat for. It may only do
                // that when it can prove the empty is newer than what it
                // shows, and this counter is that proof — the wall clock above
                // is not, since it can step back and it moves for reasons that
                // are not transcript writes.
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index])
            }
        } catch {
            throw ChatMessageClearError.transcriptClearedMetadataNotSaved(error.localizedDescription)
        }
    }
}

/// Keeps the converted disk projection separate from optimistic/streaming
/// UI rows. A hit still passes through the existing selection lifecycle and
/// synthetic-row merge, and context receipts are independently refreshed.
public actor ChatTranscriptCache {
    static let shared = ChatTranscriptCache()

    private struct Entry {
        let identity: String
        var projection: ChatTranscriptProjection?
        var contextStatistics: (totalChars: Int, messageCount: Int)?
    }

    private var entries: [String: Entry] = [:]
    private var recentPaths: [String] = []
    private let maximumSessions = 8

    func shellProjections(
        for sessions: [NativeAgentShared.ChatSession], dataRoot: URL,
        cached: [String: ChatShellOpeningLine.Projection]
    ) throws -> [String: ChatShellOpeningLine.Projection] {
        var projections: [String: ChatShellOpeningLine.Projection] = [:]
        for session in sessions {
            try Task.checkCancellation()
            let revision = ChatShellOpeningLine.revision(for: session)
            if let hit = cached[session.id], hit.revision == revision {
                projections[session.id] = hit
            } else {
                var projection = ChatShellOpeningLine.read(sessionID: session.id, dataRoot: dataRoot)
                projection.revision = revision
                projection.lastTurn = ChatShellOpeningLine.readLastTurn(sessionID: session.id, dataRoot: dataRoot)
                projections[session.id] = projection
            }
        }
        return projections
    }

    public func projection(
        at path: URL,
        load: @Sendable () async throws -> ChatTranscriptProjection
    ) async throws -> ChatTranscriptProjection {
        let key = path.path
        let before = Self.identity(at: path)
        if before == nil || entries[key]?.identity != before {
            entries[key] = nil
            recentPaths.removeAll { $0 == key }
        }
        if let projection = entries[key]?.projection {
            touch(key)
            return projection
        }
        let projection = try await load()
        // A writer can advance the file while the asynchronous loader is
        // running. Return that read under the existing selection semantics,
        // but never certify it as the projection of a different revision.
        if let before, Self.identity(at: path) == before {
            var entry = entries[key].flatMap { $0.identity == before ? $0 : nil }
                ?? Entry(identity: before)
            entry.projection = projection
            store(entry, for: key)
        }
        return projection
    }

    func contextStatistics(at path: URL) -> (totalChars: Int, messageCount: Int) {
        let key = path.path
        let before = Self.identity(at: path)
        if before == nil || entries[key]?.identity != before {
            entries[key] = nil
            recentPaths.removeAll { $0 == key }
        }
        if let statistics = entries[key]?.contextStatistics {
            touch(key)
            return statistics
        }
        var totalChars = 0
        var messageCount = 0
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return (0, 0) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // gpt-5.5 review #5 (NIT): only count rows that actually
            // decode. A partially-flushed row at the tail was previously
            // inflating messageCount even though its tokens were skipped.
            if let rowData = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any] {
                messageCount += 1
                if let content = obj["content"] as? String {
                    totalChars += content.count
                } else if let content = obj["content"] {
                    // Tool-result rows store content as a JSON array;
                    // re-serialize to charge for the bytes.
                    if let blob = try? JSONSerialization.data(withJSONObject: content) {
                        totalChars += blob.count
                    }
                }
            }
        }

        let statistics = (totalChars: totalChars, messageCount: messageCount)
        if let before, Self.identity(at: path) == before {
            var entry = entries[key] ?? Entry(identity: before)
            entry.contextStatistics = statistics
            store(entry, for: key)
        }
        return statistics
    }

    private func store(_ entry: Entry, for key: String) {
        entries[key] = entry
        touch(key)
        while recentPaths.count > maximumSessions {
            entries[recentPaths.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        recentPaths.removeAll { $0 == key }
        recentPaths.append(key)
    }

    private static func identity(at path: URL) -> String? {
        var info = stat()
        // Do not cache missing paths, symlinks, nonregular entries or failed
        // inspections. ctime catches same-size rewrites with restored mtime
        // as well as permission changes; inode catches atomic replacement.
        guard lstat(path.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}

// Session transactions use the same canonical read/write owner as every surface.
extension TranscriptsFacade: MacChatSessionStore {}

extension TranscriptsFacade {
    public func observeSavedSearch(bots: BotRunnerScheduler, memory: MemoryFacade) async {
        let paths = ["memory/memory.sqlite", "memory/memory.sqlite-wal", "bots/definitions",
                     "bots/shelf-index.json", "bots/runner-jobs.json", "bots/last-events.json", "trust/policy.json"]
        await EventDeadlinePhysiology.refreshOnChanges(paths: paths.map { dataRoot.appendingPathComponent($0) },
                                                       notifications: [BotRunQueue.didChange]) {
            await self.refreshSavedSearch(bots: bots, memory: memory)
        }
    }

    /// The remaining saved search inputs share the transcript search owner;
    /// Desk and dreams already publish their own revisions.
    public func refreshSavedSearch(bots: BotRunnerScheduler, memory: MemoryFacade) async {
        _ = await savedSearchRead.read({
        var failures: [String] = []
        var botReplies: [(BotsShelfRecord, ShelfEntry)]?
        var memories: [MemoryV2.MemoryRecord]?
        do {
            let timing = try await bots.effectiveSchedule()
            let root = dataRoot
            let records = try await Task.detached(priority: .utility) {
                try BotsShelfRecord.read(root: root, timing: timing)
            }.value
            let replies = records.flatMap { record in
                record.sortedEntries.filter { !$0.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { (record, $0) }
            }.sorted { $0.1.runAt > $1.1.runAt }
            botReplies = Array(replies.prefix(40))
        } catch {
            failures.append(UserFacingError.message(error, action: "read saved bot replies"))
        }
        do {
            memories = try await memory.activeMemories(limit: nil)
        } catch {
            failures.append(UserFacingError.message(error, action: "read saved memories"))
        }
        return (botReplies, memories, failures)
        }, publish: { botReplies, memories, failures in
        if let botReplies { savedBotReplies = botReplies }
        if let memories { savedMemories = memories }
        savedSearchError = failures.isEmpty ? nil
            : (failures + ["Saved results may be out of date."]).joined(separator: " ")
        })
    }
}

/// Every visible conversation's words, for ⌘K: the text ⌘F searches in the
/// open chat (`MacChatTranscriptSearch`), across all of them. A transcript is
/// read again when its session or transcript revision moves. Each engine's
/// transcript facade owns its index, so roots never share search documents.
public actor CommandPaletteMessageIndex {

    public struct Hit: Sendable {
        public let sessionID: String
        public let snippet: String
    }

    private struct Snapshot: Sendable {
        var texts: [String: (stamp: String, lines: [String])] = [:]
        /// Newest conversation first, as the palette lists them.
        var order: [String] = []
    }

    @MainActor private final class Projection {
        var snapshot = Snapshot()
        let latest = LatestRead()
        nonisolated init() {}

        func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> Int {
            let read = await latest.read({
                let stale = sessions.filter { snapshot.texts[$0.id]?.stamp != $0.stamp }
                return await withTaskGroup(of: (String, String, [String]?).self) { group in
                    for session in stale {
                        group.addTask {
                            guard let messages = try? await transcripts.loadMessages(sessionId: session.id) else {
                                return (session.id, session.stamp, nil)
                            }
                            return (session.id, session.stamp, TranscriptSearch.documents(from: messages).map(\.content))
                        }
                    }
                    var read: [(String, String, [String]?)] = []
                    for await row in group { read.append(row) }
                    return read
                }
            }, publish: { read in
                snapshot.order = sessions.map(\.id)
                for (id, stamp, lines) in read {
                    if let lines { snapshot.texts[id] = (stamp, lines) }
                }
                let kept = Set(snapshot.order)
                snapshot.texts = snapshot.texts.filter { kept.contains($0.key) }
            })
            return read.filter { $0.2 == nil }.count
        }
    }
    private let projection = Projection()

    public nonisolated static func stamp(_ session: NativeAgentShared.ChatSession) -> String {
        "\(session.updatedAt ?? session.createdAt)|\(session.transcriptGeneration ?? -1)|\(session.messageCount ?? -1)"
    }

    /// Reads what changed and returns how many conversations could not be
    /// read. A failed read is not cached: it keeps whatever text it had
    /// before, and is tried again on the next revision refresh.
    public func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> Int {
        await projection.refresh(sessions, transcripts: transcripts)
    }

    /// The newest line in each conversation that holds `query`, newest
    /// conversation first, every conversation that has one.
    public func search(_ query: String) async -> [Hit] {
        let snapshot = await projection.snapshot
        let texts = snapshot.texts
        let order = snapshot.order
        var hits: [Hit] = []
        for id in order {
            guard !Task.isCancelled else { break }
            guard let lines = texts[id]?.lines else { continue }
            for line in lines.reversed() {
                guard let range = line.range(of: query, options: .caseInsensitive) else { continue }
                hits.append(Hit(sessionID: id, snippet: Self.snippet(line, around: range)))
                break
            }
        }
        return hits
    }

    /// A line of the message starting a few words before the match.
    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        var start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        if start != text.startIndex, let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        let flat = text[start...].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start == text.startIndex ? "" : "…") + TodayWords.line(flat, limit: 90)
    }
}
/// Phone activity in a background chat stays unread until that chat opens.
@MainActor @Observable
public final class MacChatUnreadSessions {
    public static let shared = MacChatUnreadSessions()
    private static let key = "NativeAgent.unreadPhoneChatSessions"
    public private(set) var ids = Set(UserDefaults.standard.stringArray(forKey: MacChatUnreadSessions.key) ?? [])

    public func received(in sessionID: String) {
        guard sessionID != UserDefaults.standard.string(forKey: "activeChatSessionId") else { return }
        ids.insert(sessionID)
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }

    public func markRead(_ sessionID: String) {
        guard ids.remove(sessionID) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }
}


extension NativeAgentEngine {
    @MainActor
    public func runMacChatTurnBody<Port: MacChatTurnTranscriptPort>(
        _ text: String,
        attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String,
        generation: Int,
        ctx: MacChatTurnBodyContext,
        hideUserBubble: Bool,
        activityIdentity: MacChatTurnIdentity,
        port: Port,
        client: SwiftNativeChatOrchestrationClient,
        missingProviderGuidance: String?,
        errorAdvice: @escaping (Error) -> String,
        finishReplyPresentation: () async -> Void
    ) async where Port.MacChatMessage == ChatMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // A successful local reload prevents a second notification-driven read.
        var messagesAlreadyRefreshed = false
        // A confirmed session ID rebinds every subsequent presentation write.
        var requestSessionId = sessionId
        let userContent = trimmed.isEmpty ? "(attached \(attachments.count) item(s))" : trimmed
        let bubbleId = UUID().uuidString
        let userTurnId = UUID().uuidString
        // No-provider guidance precedes streaming cleanup because no turn ran.
        if let guidance = missingProviderGuidance {
            var typedBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            typedBubble.id = userTurnId
            port.appendMacChatMessage(typedBubble, to: requestSessionId)
            // Synthetic notices survive reload and retain their retry affordance.
            let guidanceBubble = ChatMessage(
                id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                sessionId: requestSessionId,
                role: "assistant",
                content: guidance,
                metadata: .syntheticError(
                    "no_provider_connected",
                    userRowPersisted: false,
                    inputHadAttachments: !attachments.isEmpty
                )
            )
            port.appendMacChatMessage(guidanceBubble, to: requestSessionId)
            await InlineInteractionResolver.raiseMissingChatProvider(
                sessionID: requestSessionId, userContent: userContent,
                hasAttachments: !attachments.isEmpty,
                dataRoot: dataRoot
            )
            port.presentMacChatTurn(.status("No AI provider connected — connect one with Open Providers in the chat."))
            _ = await port.settleChatTurnLifecycle(
                identity: activityIdentity,
                kind: .failed(reason: "No AI provider is connected."),
                at: Date()
            )
            return
        }
        // Retain only the accepted local request and its preceding conversation
        // row. If routing fails before the core writes the user, an unchanged
        // canonical tail can prove that this request still needs persistence.
        var originalUserBubble = ChatMessage(
            id: userTurnId, sessionId: requestSessionId, role: "user", content: userContent
        )
        if let origin = ChatPersistenceContext.originProvenance {
            var recorded = ChatMessageOriginMetadata(surface: origin.surface, agent: origin.agent)
            recorded.authored = origin.authored?.rawValue
            recorded.peerSources = PeerDataTaint.current?.checkpointSources ?? []
            recorded.elevatedPeerSources = PeerDataTaint.current?.elevatedSources ?? []
            var metadata = ChatMessageMetadata()
            metadata.origin = recorded
            originalUserBubble.metadata = metadata
        }
        let originalRequestPredecessor = transcripts.messages(for: requestSessionId)
            .last(where: { $0.role == "user" || $0.role == "assistant" })

        // A session switch restores the accepted prompt and its live reply.
        turns.streamingBubbleIds[requestSessionId] = bubbleId
        turns.streamingTexts[requestSessionId] = ""
        // Hidden (agent-first) turns must not register user-turn restore state,
        // or a mid-greeting session switch would reinject the hidden kickoff as a
        // user bubble on return.
        if !hideUserBubble {
            turns.streamingUserTurnIds[requestSessionId] = userTurnId
            turns.streamingUserTurnTexts[requestSessionId] = userContent
        }
        // Optimistic rows belong to the request session, including detached views.
        if !hideUserBubble {
            port.appendMacChatMessage(originalUserBubble, to: requestSessionId)
        }
        var streamingBubble = ChatMessage(sessionId: requestSessionId, role: "assistant", content: "")
        streamingBubble.id = bubbleId
        var streamingMetadata = ChatMessageMetadata()
        streamingMetadata.turnTraceId = activityIdentity.turnId
        streamingBubble.metadata = streamingMetadata
        port.appendMacChatMessage(streamingBubble, to: requestSessionId)
        turns.busySessions.insert(requestSessionId)
        defer {
            turns.busySessions.remove(requestSessionId)
            turns.replyingSessions.remove(requestSessionId)
            turns.streamingTexts[requestSessionId] = nil
            turns.streamingBubbleIds[requestSessionId] = nil
            turns.streamingUserTurnIds[requestSessionId] = nil
            turns.streamingUserTurnTexts[requestSessionId] = nil
        }

        let metaBox = MacChatStreamAdapter.MetaBox()
        do {
            let stream = MacChatStreamAdapter.chatStream(
                client: client, text: trimmed, attachments: attachments,
                sessionId: requestSessionId, activityIdentity: activityIdentity, replyRowId: bubbleId, metaBox: metaBox,
                hideUserBubble: hideUserBubble,
                serviceTier: { NativeChatTurnOptions.current(surface: "chat").serviceTier },
                onTurnActivity: { [weak port] in await port?.receiveChatTurnActivity($0) },
                onScreenPreview: { [turns] in await turns.receiveScreenPreview($0, identity: activityIdentity) },
                helperSession: { progress in self.standingBotSession(admitted: true, attachments: attachments, progress: progress) }, dataRoot: dataRoot
            )
            let streamedText = try await port.consumeMacChatStream(
                stream, sessionId: requestSessionId, bubbleId: bubbleId,
                generation: generation, activityIdentity: activityIdentity
            )
            guard let completion = try await port.completeMacChatStream(
                metaBox: metaBox, sessionId: requestSessionId,
                generation: generation, streamedText: streamedText
            ) else { return }
            let finalStreamText = completion.text
            let finalTrimmed = finalStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamProducedNoContent = finalTrimmed.isEmpty
            if !streamProducedNoContent {
                transcripts.updateMessageContent(id: bubbleId, in: requestSessionId, content: finalStreamText)
                if let commentary = completion.workingCommentaryCharacters {
                    port.presentMacChatTurn(.workingCommentary(
                        sessionId: requestSessionId, bubbleId: bubbleId, characters: commentary
                    ))
                }
            }
            if let sid = completion.sessionId, !sid.isEmpty, sid != requestSessionId {
                let migratingActive = port.activeChatSessionId == requestSessionId
                guard await port.reconcileMacChatStreamSession(
                    from: requestSessionId, to: sid, turnId: activityIdentity.turnId,
                    dropPresentation: { sessionId in
                        port.presentMacChatTurn(.dropDraft(sessionId: sessionId))
                    },
                    migratePresentation: { [self] from, to in
                        if let v = turns.streamingTexts.removeValue(forKey: from) { turns.streamingTexts[to] = v }
                        if let v = turns.streamingBubbleIds.removeValue(forKey: from) { turns.streamingBubbleIds[to] = v }
                        if let v = turns.streamingUserTurnIds.removeValue(forKey: from) { turns.streamingUserTurnIds[to] = v }
                        if let v = turns.streamingUserTurnTexts.removeValue(forKey: from) { turns.streamingUserTurnTexts[to] = v }
                        port.presentMacChatTurn(.moveDraft(from: from, to: to))
                    }
                ) else { return }
                if migratingActive {
                    port.presentMacChatTurn(.selectMigratedSession(sid))
                }
                // Outer admission cleanup must follow the migrated generation.
                requestSessionId = sid
                ctx.effectiveSessionId = sid
            }
            // Clear restore IDs before reload can reinject an empty bubble.
            if streamProducedNoContent {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
                turns.clearStreamingBubbleState(requestSessionId)
            }
            // Fluid glass A1: a reply that settled before the stream ended is
            // still crossfading (or folding its notes). Its saved row keeps this
            // bubble's id (TurnTraceContext.replyRow) and lands in place; the
            // reload still waits the one crossfade before rewriting it.
            if !streamProducedNoContent, turns.isReplyTextSettled(requestSessionId) {
                await finishReplyPresentation()
            }
            let reconciliation = await port.reconcileCompletedMacChatStream(
                identity: MacChatTurnIdentity(sessionId: requestSessionId, turnId: activityIdentity.turnId),
                metaBox: metaBox, producedNoContent: streamProducedNoContent,
                makeNoContentNotice: {
                    ChatMessage(
                        id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId, role: "assistant",
                        content: "No reply came back. Use Try again to retry.",
                        metadata: .syntheticError("stream_produced_no_content", inputHadAttachments: !attachments.isEmpty)
                    )
                }
            )
            messagesAlreadyRefreshed = reconciliation.messagesRefreshed
            guard reconciliation.proceed else { return }
            _ = try? await persona.prepareDocuments()
        } catch {
            guard await port.joinFailedMacChatStream(
                metaBox: metaBox, sessionId: requestSessionId, generation: generation
            ) else { return }
            if Task.isCancelled {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
                await port.reconcileCancelledMacChatStream(
                    identity: MacChatTurnIdentity(sessionId: requestSessionId, turnId: activityIdentity.turnId),
                    metaBox: metaBox
                )
                return
            }
            transcripts.removeMessage(id: bubbleId, from: requestSessionId)
            guard await port.reconcileFailedMacChatStream(
                identity: MacChatTurnIdentity(sessionId: requestSessionId, turnId: activityIdentity.turnId),
                metaBox: metaBox, error: error,
                originalUser: originalUserBubble, predecessor: originalRequestPredecessor,
                hideUserBubble: hideUserBubble, syntheticPrefix: MacChatTurnRuntime.syntheticErrorIDPrefix,
                makeNotice: {
                    let isRefusal = ProviderFailure.classify(error) == .refused
                    var metadata = ChatMessageMetadata.syntheticError(
                        error.localizedDescription, inputHadAttachments: !attachments.isEmpty
                    )
                    if isRefusal { metadata.providerRefusal = true }
                    metadata.failureWork = ChatTurnFailure.work(for: error)
                    return ChatMessage(
                        id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId, role: "assistant",
                        content: MacChatTurnRuntime.normalizeStreamErrorForChat(error, advice: errorAdvice)
                            + (isRefusal ? " outcome unknown — inspect before retry." : ""),
                        metadata: metadata
                    )
                },
                markUnpersisted: { notice in
                    var notice = notice
                    notice.metadata?.syntheticUserRowPersisted = false
                    return notice
                }
            ) else { return }
        }
        NotificationCenter.default.post(
            name: .chatTurnCompleted, object: requestSessionId,
            userInfo: ["messagesAlreadyRefreshed": messagesAlreadyRefreshed])
    }

}

extension NativeAgentEngine {
    @MainActor
    public func resumeMacChatTurn<Port: MacChatTurnTranscriptPort>(_ checkpoint: TurnCheckpoint,
        port: Port,
        operation: @escaping @Sendable (@escaping ChatOrchestrationProgressHandler) async throws -> Void) async throws where Port.MacChatMessage == ChatMessage {
        let macChatTurns = turns.runtime
        let session = checkpoint.sessionId
        let identity = MacChatTurnIdentity(sessionId: session, turnId: checkpoint.turnId)
        guard let generation = macChatTurns.reserveTurn(sessionId: session) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        defer {
            if macChatTurns.taskGenerations[session] == generation {
                turns.streamingTexts[session] = nil
                turns.streamingBubbleIds[session] = nil
                turns.replyingSessions.remove(session)
                // A send queued behind this reservation goes once it is released.
                if macChatTurns.finishRuntime(sessionId: session, generation: generation) {
                    Task { @MainActor in await port.drainNextQueuedChatTurnIfPossible(sessionId: session) }
                }
            }
        }
        await macChatTurns.pendingStopWrites[session]?.value
        let records = try await macChatTurns.lifecycleStore.records()
        guard let state = records.first(where: { $0.identity == identity })?.restoredState(),
              macChatTurns.taskGenerations[session] == generation else { throw MacChatTurnLifecycleStoreError.invalidRecord }
        var rows = try await transcripts.loadMessages(sessionId: session)
        try Task.checkCancellation()
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        rows.removeAll { $0.runId == checkpoint.runId && $0.metadata?.partial == true }
        let bubble = ChatMessage(sessionId: session, runId: checkpoint.runId)
        rows.append(bubble)
        transcripts.setMessages(rows, for: session)
        macChatTurns.activeTurnIDsBySession[session] = identity.turnId
        macChatTurns.lifecycleBySession[session] = state
        macChatTurns.streamingSessions.insert(session)
        turns.streamingBubbleIds[session] = bubble.id

        let events = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
        let frames = AsyncThrowingStream<MacChatStreamUpdate, Error>.makeStream()
        let meta = MacChatStreamAdapter.MetaBox()
        let adapter = Task {
            await MacChatStreamAdapter.bridgeChatStreamEvents(events.stream, sessionId: session,
                activityIdentity: identity, metaBox: meta,
                onTurnActivity: { [weak port] in await port?.receiveChatTurnActivity($0) },
                continuation: frames.continuation)
        }
        let producer = Task {
            defer { events.continuation.finish() }
            do { try await ChatToolSessionContext.$replyStreamRendersCards.withValue(true) {
                try await MacScreenPreviewBus.$publish.withValue({ [turns] in
                    await turns.receiveScreenPreview($0, identity: identity)
                }) {
                    try await operation { events.continuation.yield($0) }
                }
            } } catch { events.continuation.finish(throwing: error); throw error }
        }
        macChatTurns.tasks[session] = Task {
            _ = await withTaskCancellationHandler { await producer.result } onCancel: { producer.cancel() }
        }
        let consumer = Task {
            try await port.consumeMacChatStream(frames.stream, sessionId: session, bubbleId: bubble.id,
                generation: generation, activityIdentity: identity)
        }
        let outcome = await producer.result
        await adapter.value
        let rendered = await consumer.result
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        _ = await port.settleMacChatStream(identity: identity, metaBox: meta, exit: .exhausted)
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        _ = port.closeChatTurnLifecycleIntake(sessionId: session, turnId: identity.turnId, at: Date())
        turns.streamingTexts[session] = nil
        turns.streamingBubbleIds[session] = nil
        turns.replyingSessions.remove(session)
        _ = macChatTurns.finishRuntime(sessionId: session, generation: generation)
        await port.refreshChatMessagesAfterTurn(sessionId: session, messagesAlreadyRefreshed: false)
        try outcome.get()
        _ = try rendered.get()
    }

}

extension NativeAgentEngine {
    /// Re-read the active transcript after a turn to replace optimistic rows
    /// with persisted ones. Local turns already land their disk snapshot and
    /// set `messagesAlreadyRefreshed`; remote turns keep the full refresh.
    @MainActor
    public func refreshChatMessagesAfterTurn(
        sessionId: String, messagesAlreadyRefreshed: Bool,
        activeSession: () -> String, failure: (Error) -> Void
    ) async {
        guard !sessionId.isEmpty, activeSession() == sessionId else { return }
        let lifecycleAtLoadStart = turns.lifecycle(for: sessionId)
        var messages: [ChatMessage]? = nil
        if !messagesAlreadyRefreshed {
            do {
                messages = try await transcripts.loadMessages(sessionId: sessionId, cached: true)
            } catch {
                // Don't swallow this. A failed post-turn refresh leaves optimistic
                // bubble ids on screen; saying nothing is the same lie M12 is about.
                failure(error)
                return
            }
        }
        // The active session can change while the load is in flight.
        guard activeSession() == sessionId,
              !turns.streamingSessions.contains(sessionId),
              turns.lifecycle(for: sessionId) == lifecycleAtLoadStart else { return }
        if let messages {
            // A NEW turn may have started on this session while we were fetching
            // (the user sent again immediately). That turn owns the slot and its
            // optimistic bubbles are fresher than this disk snapshot — mirrors
            // selectChatSession's streaming guard. The finished turn's rows are
            // already in memory, so nothing is lost by skipping the swap.
            guard !turns.streamingSessions.contains(sessionId) else { return }
            transcripts.applyLoadedMessages(messages, for: sessionId)
        }
    }

    /// Refresh a visible detached transcript after a turn completed on another
    /// surface. This mirrors the active-chat refresh without changing the main
    /// selection and never replaces a slot while a newer local stream owns it.
    @MainActor
    public func refreshDetachedChatMessagesAfterTurn(
        sessionId: String, messagesAlreadyRefreshed: Bool,
        isDetached: () -> Bool, finished: ([String]) -> Void
    ) async {
        guard !sessionId.isEmpty,
              isDetached(),
              !turns.streamingSessions.contains(sessionId)
        else { return }
        let lifecycleAtLoadStart = turns.lifecycle(for: sessionId)
        var messages: [ChatMessage]?
        if !messagesAlreadyRefreshed {
            do {
                messages = try await transcripts.loadMessages(sessionId: sessionId, cached: true)
            } catch {
                finished(["messages"])
                return
            }
        }
        guard isDetached(),
              turns.lifecycle(for: sessionId) == lifecycleAtLoadStart,
              !turns.streamingSessions.contains(sessionId)
        else { return }
        if let messages {
            transcripts.applyLoadedMessages(messages, for: sessionId)
        }
        finished([])
    }

}

extension NativeAgentEngine {
    @MainActor
    public func observeSessionMessages(_ sessionID: String, finished: (Error?) -> Void) async {
        let events = FileChangeEvents(paths: [dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")], emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                var failure: Error?
                await refreshChatMessagesAfterTurn(sessionId: sessionID, messagesAlreadyRefreshed: false,
                    activeSession: { sessionID }, failure: { failure = $0 })
                finished(failure)
            }
        } onCancel: { events.cancel() }
    }

    @MainActor
    public func loadDetachedSessionMessages(
        _ sessionId: String, finished: ([String]) -> Void
    ) async {
        guard !sessionId.isEmpty else { return }
        // Skip if a stream is already populating this slot — overwriting
        // would clobber live deltas (mirrors selectChatSession's guard).
        if turns.streamingSessions.contains(sessionId),
           !(transcripts.messagesBySession[sessionId] ?? []).isEmpty {
            return
        }
        let lifecycleAtLoadStart = turns.lifecycle(for: sessionId)
        var messageFailures: [String] = []
        let fetched: [ChatMessage]?
        do {
            fetched = try await transcripts.loadMessages(sessionId: sessionId, cached: true)
        } catch {
            fetched = nil
            messageFailures.append("messages")
        }
        // 2026-06-08 W1.2 review fix (MEDIUM): re-check the streaming guard
        // AFTER the network await. A stream may have STARTED for this
        // session during the fetch (e.g. the user typed + sent in the
        // detached panel while history was loading). Writing the stale
        // disk snapshot now would drop the live optimistic + streaming
        // bubbles and the by-id delta updates would then miss. Only seed
        // the slot when no stream has taken ownership of it.
        let streamTookOver = turns.streamingSessions.contains(sessionId)
            && !(transcripts.messagesBySession[sessionId] ?? []).isEmpty
        let lifecycleAfterMessages = turns.lifecycle(for: sessionId)
        guard !streamTookOver,
              lifecycleAfterMessages == nil || lifecycleAfterMessages == lifecycleAtLoadStart
        else { return }
        if let fetched {
            transcripts.applyLoadedMessages(fetched, for: sessionId)
        }
        finished(messageFailures)
    }

}

extension NativeAgentEngine {
    @MainActor
    public func runChatSlashCommand(tool: String, input: [String: Any], sessionId: String) async {
        let pending = ChatMessage(role: "system", content: "⏳ Dispatching **\(tool)**…")
        transcripts.appendMessage(pending, to: sessionId)
        guard let inputData = try? JSONSerialization.data(withJSONObject: input) else {
            await replaceChatSlashPlaceholder(
                pending.id,
                with: ChatMessage(role: "system",
                    content: "❌ **\(tool)** could not run: the input could not be prepared"),
                in: sessionId
            )
            return
        }
        await dispatchChatSlashCommand(tool: tool, inputData: inputData, sessionId: sessionId, pendingID: pending.id) {
            input
        }
    }

    @MainActor
    public func runChatSlashCommand(tool: String, inputData: Data, sessionId: String) async {
        let pending = ChatMessage(role: "system", content: "⏳ Dispatching **\(tool)**…")
        transcripts.appendMessage(pending, to: sessionId)
        await dispatchChatSlashCommand(tool: tool, inputData: inputData, sessionId: sessionId, pendingID: pending.id) {
            (try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]) ?? [:]
        }
    }

    @MainActor
    private func dispatchChatSlashCommand(
        tool: String, inputData: Data, sessionId: String, pendingID: String,
        displayInput: () -> [String: Any]
    ) async {
        do {
            guard case .object(let input)? = try? JSONValue.parse(inputData) else {
                throw NSError(domain: "NativeAgent", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not deserialize inputData"])
            }
            let result = try await dispatchSlashCommand(
                tool: tool, input: input, sessionId: sessionId.isEmpty ? nil : sessionId, dataRoot: dataRoot
            )
            await replaceChatSlashPlaceholder(
                pendingID, with: .slashCommandReceipt(result: result, tool: tool, input: displayInput()), in: sessionId
            )
        } catch {
            await replaceChatSlashPlaceholder(
                pendingID,
                with: ChatMessage(role: "system",
                    content: "❌ **\(tool)** could not run: \(ChatToolOutcome.errorMessage(error))"),
                in: sessionId
            )
        }
    }

    @MainActor
    private func replaceChatSlashPlaceholder(_ placeholderId: String, with message: ChatMessage, in sessionId: String) async {
        var message = message
        do {
            try await chatClient(profile: .mac).appendSystemReceipt(
                sessionId: sessionId, messageId: message.id, content: message.content
            )
        } catch {
            message.content += "\n\nCould not confirm this receipt was saved: \(ChatToolOutcome.errorMessage(error))"
        }
        var messages = transcripts.messages(for: sessionId)
        messages.removeAll { $0.id == placeholderId || $0.id == message.id }
        messages.append(message)
        transcripts.setMessages(messages, for: sessionId)
    }
}

extension TranscriptsFacade: QuietChatTranscriptPort {}
