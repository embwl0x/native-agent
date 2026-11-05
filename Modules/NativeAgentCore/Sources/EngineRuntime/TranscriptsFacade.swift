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
// Blueprint: | `TranscriptsFacade.swift` | Root-scoped transcript publication and consumer-held live tail boxes |
@MainActor
@Observable
private final class ChatTranscriptSlot {
    /// Overlay live turn rows on saved store publication.
    @ObservationIgnored var messages: [ChatMessage] = []
    /// Only committed store reads may replace saved rows.
    @ObservationIgnored var saved: [ChatMessage] = []
    /// Leading rows supersede their saved copies; settled rows leave when the store holds them.
    @ObservationIgnored var live: [LiveRow] = []
    @ObservationIgnored lazy var cardReads = LatestRead()
    var groups = MessageGrouper.GroupedTranscript(base: [])
    @ObservationIgnored var preparation: Task<Void, Never>?
    @ObservationIgnored let groupReads = LatestRead()
    var structureVersion: UInt64 = 0
    var readStatus: TranscriptReadout.ReadStatus = .loading
}
struct LiveRow {
    var message: ChatMessage
    var leads = true
    var replaces: Set<String> = []
    /// Unsaved rows yield only after a newer completed reply lands.
    var seen: Set<String> = []
}
/// Share root-specific session and transcript ownership across every surface, including nonisolated phone reads and writes.
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

    /// Cache positive evidence only because the write token may arm during launch.
    public var firstConversationReceiptTitle: String? {
        if let cached = firstConversationReceiptTitleCache { return cached }
        let title = FirstConversationPersonaProgression.recordedWriteTitle(dataRoot: dataRoot)
        firstConversationReceiptTitleCache = title
        return title
    }
    public var firstConversationPersonName: String {
        get throws { try NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) }
    }
    @ObservationIgnored public lazy var sessionTransactions = MacChatSessionTransactions()

    /// Any index publication supersedes suspended presentation reads.
    private var sessionSnapshot: [NativeAgentShared.ChatSession] = []
    public private(set) var sessionIndexError: String?
    public private(set) var hasLoadedSessionIndex = false
    public static let sessionIndexDidChange = Notification.Name("NativeAgent.sessionIndexDidChange")
    public var sessions: [NativeAgentShared.ChatSession] {
        get { sessionSnapshot }
        set { sessionTransactions.indexRead.write { publishSessionIndexRead(newValue) } }
    }
    /// Keep the original read ticket; treating publication as a write would fence a newer running read.
    public func publishSessionIndexRead(_ sessions: [NativeAgentShared.ChatSession]) {
        let changed = !hasLoadedSessionIndex || sessionIndexError != nil || sessionSnapshot != sessions
        sessionSnapshot = sessions
        sessionIndexError = nil
        hasLoadedSessionIndex = true
        if changed { NotificationCenter.default.post(name: Self.sessionIndexDidChange, object: dataRoot) }
    }
    /// Retain the displayed index with its failure cause after failed refresh.
    @discardableResult
    public func refreshSessionIndex() async -> Bool {
        let result = await sessionTransactions.indexRead.read({
            do { return Result<[NativeAgentShared.ChatSession], Error>.success(try await list()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): publishSessionIndexRead(rows)
            case .failure(let error):
                let problem = UserFacingError.cause(error, action: "refresh the conversation list")
                if sessionIndexError != problem {
                    sessionIndexError = problem
                    NotificationCenter.default.post(name: Self.sessionIndexDidChange, object: dataRoot)
                }
            }
        })
        if case .success = result { return true }
        return false
    }
    public private(set) var pinnedSessionIDs: [String] = []
    public private(set) var conversationAnchor: ConversationAnchorPin?
    public private(set) var navigationError: String?
    public var navigationReadIssue: String? {
        let issues = [sessionIndexError, navigationError].compactMap { $0 }
        return issues.isEmpty ? nil : issues.joined(separator: "\n")
    }

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
        do {
            pinnedSessionIDs = try ChatSessionRetention.load(dataRoot: dataRoot)
            navigationError = nil
        } catch {
            navigationError = UserFacingError.cause(error, action: "read pinned conversations")
        }
        conversationAnchor = ConversationAnchor.current(dataRoot: dataRoot)
    }
    public func watchNavigation() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [ConversationAnchor.path(dataRoot: dataRoot),
            ChatSessionRetention.macPinnedSessionIdsPath(dataRoot: dataRoot)]) { self.refreshNavigationIdentity() }
    }
    public func savePinnedSessionIDs(_ ids: [String]) throws -> String {
        let encoded = try ChatSessionRetention.save(ids, dataRoot: dataRoot)
        pinnedSessionIDs = try ChatSessionRetention.decode(encoded)
        navigationError = nil
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
        ChatSessionRetention.request(encodedPinnedIDs: encoded, dataRoot: dataRoot) { _ in
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: includeTranscripts)
        }
    }
    // Observe per-conversation structure; token content publishes only through its unobserved tail box.
    @ObservationIgnored private var storage: [String: ChatTranscriptSlot] = [:]
    @ObservationIgnored private var loadedSessions: Set<String> = []
    public private(set) var structureVersion: UInt64 = 0
    public var loadedSessionIDs: Set<String> {
        _ = structureVersion
        return loadedSessions
    }
    /// Create boxes on demand before chunks exist; only the exact row’s bubble observes its live content.
    @ObservationIgnored private var streamingTailBoxes: [String: ChatStreamingTailBox] = [:]
    @ObservationIgnored private var streamingTailBoxOrder: [String] = []

    /// Disk projections remain separate from optimistic/streaming rows.
    public nonisolated let cache = ChatTranscriptCache.shared

    public nonisolated init(turns: TurnsFacade) {
        self.turns = turns
        self.presentation = PresentationFaces(dataRoot: turns.dataRoot)
    }

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
            // Observe card answers because mirror rows can change without a transcript-file write.
            notifications: [.nativeAgentChatTranscriptDidChange],
            debounceDelay: .milliseconds(100), refresh: refresh
        )
    }
    private func slot(for sessionId: String) -> ChatTranscriptSlot {
        if let slot = storage[sessionId] { return slot }
        let slot = ChatTranscriptSlot()
        storage[sessionId] = slot
        return slot
    }
    /// Keep live turns over committed loader results.
    public func setMessages(_ messages: [ChatMessage], for sessionId: String) {
        slot(for: sessionId).saved = messages
        reproject(sessionId)
    }
    /// Derive the screen from saved and live rows, never a separate mutable copy.
    private func reproject(_ sessionId: String) {
        let slot = slot(for: sessionId)
        let savedIDs = Set(slot.saved.map(\.id))
        slot.live.removeAll { row in
            guard !row.leads else { return false }
            if savedIDs.contains(row.message.id) { return true }
            // Unsaved rows yield to a newer completed reply.
            return slot.saved.contains { $0.role == "assistant" && !$0.macChatPartial && !$0.macChatCancelled && !row.seen.contains($0.id) }
        }
        let leading = Dictionary(slot.live.filter(\.leads).map { ($0.message.id, $0.message) }, uniquingKeysWith: { first, _ in first })
        let replaced = slot.live.filter(\.leads).reduce(into: Set<String>()) { $0.formUnion($1.replaces) }
        var rows: [ChatMessage] = slot.saved.compactMap { row in
            guard !replaced.contains(row.id) else { return nil }
            guard var over = leading[row.id] else { return row }
            over.inlineCards = row.inlineCards
            return over
        }
        rows += slot.live.map(\.message).filter { !savedIDs.contains($0.id) }
        if rows != slot.messages || !loadedSessions.contains(sessionId) { publishMessages(rows, for: sessionId) }
    }
    /// Stop leading at turn end; leave rows only when the store takes them.
    public func settleLive(_ sessionId: String, only messageId: String? = nil) {
        let slot = slot(for: sessionId)
        for index in slot.live.indices where messageId == nil || slot.live[index].message.id == messageId { slot.live[index].leads = false }
        reproject(sessionId)
    }
    /// Leading resumed replies supersede their saved partials.
    public func appendLive(_ message: ChatMessage, to sessionId: String, replacing: Set<String>) {
        let slot = slot(for: sessionId)
        slot.live.append(LiveRow(message: message, replaces: replacing, seen: Set(slot.saved.map(\.id))))
        reproject(sessionId)
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
        slot.saved = []; slot.live = []
        publishMessages([], for: sessionId)
        loadedSessions.remove(sessionId)
        return messages
    }
    internal func publishClearedTranscript(_ sessionId: String) {
        let current = slot(for: sessionId)
        current.cardReads.write {
            current.readStatus = .current
            current.saved = []; current.live = []
            publishMessages([], for: sessionId)
        }
    }
    /// Create boxes without observation so view-body access remains a cheap dictionary lookup.
    public func streamingTailBox(forMessage messageId: String) -> ChatStreamingTailBox {
        if let existing = streamingTailBoxes[messageId] {
            pruneStreamingTailBoxes()
            return existing
        }
        let box = ChatStreamingTailBox()
        streamingTailBoxes[messageId] = box
        streamingTailBoxOrder.append(messageId)
        pruneStreamingTailBoxes()
        return box
    }
    /// Eight is a cache target, never a reply limit; evict only unheld inactive boxes because mounted views retain final chunks until structural publication.
    private func pruneStreamingTailBoxes() {
        guard streamingTailBoxes.count > 8 else { return }
        let active = Set(turns.streamingBubbleIds.values)
        streamingTailBoxOrder.removeAll { id in
            guard streamingTailBoxes.count > 8, !active.contains(id),
                  isKnownUniquelyReferenced(&streamingTailBoxes[id]) else { return false }
            streamingTailBoxes.removeValue(forKey: id)
            return true
        }
    }
    /// Tail updates must not publish structure; interior rewrites return false for structural handling.
    public func setTailMessageContent(_ content: String, id messageId: String, in sessionId: String) -> Bool {
        guard let slot = storage[sessionId], !slot.messages.isEmpty,
              slot.messages.last?.id == messageId
        else { return false }
        slot.messages[slot.messages.count - 1].content = content
        if let live = slot.live.firstIndex(where: { $0.message.id == messageId }) { slot.live[live].message.content = content }
        // Publish streamed chunks only to the exact leaf bubble so parent structure and layout stay stable.
        streamingTailBox(forMessage: messageId).content = content
        return true
    }
    /// Only running-turn rows lead; local notices and unsent requests yield to newer completed replies.
    public func appendMessage(_ message: ChatMessage, to sessionId: String, leads: Bool = true) {
        let slot = slot(for: sessionId)
        slot.live.append(LiveRow(message: message, leads: leads, seen: Set(slot.saved.map(\.id))))
        reproject(sessionId)
    }
    @discardableResult
    public func refreshMessages(sessionId: String, cached: Bool = true) async throws -> Bool {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return false }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached).applied
    }
    public func removeMessage(id messageId: String, from sessionId: String) {
        let slot = slot(for: sessionId)
        guard slot.live.contains(where: { $0.message.id == messageId }) else { return }
        slot.live.removeAll { $0.message.id == messageId }
        reproject(sessionId)
    }
    public func updateMessageContent(id messageId: String, in sessionId: String, content: String) {
        if setTailMessageContent(content, id: messageId, in: sessionId) { return }
        let slot = slot(for: sessionId)
        guard let index = slot.live.firstIndex(where: { $0.message.id == messageId }) else { return }
        slot.live[index].message.content = content
        reproject(sessionId)
    }
    internal func readPublishedTranscript(safeSessionId: String, cached: Bool)
        async throws -> (projection: TranscriptReadout, applied: Bool) {
        let current = slot(for: safeSessionId)
        var applied = false
        let outcome: Result<TranscriptReadout, Error> = await current.cardReads.read {
            do { return .success(try await readTranscriptProjection(safeSessionId: safeSessionId, cached: cached)) }
            catch { return .failure(error) }
        } publish: { read in
            switch read {
            case .success(let projection):
                applied = true
                current.readStatus = .current
                current.saved = projection.messages
                reproject(safeSessionId)
            case .failure(let error):
                current.readStatus = .unavailable(error.localizedDescription)
            }
        }
        return (try outcome.get(), applied)
    }
}
// Session transactions share the canonical read/write owner across surfaces.
extension TranscriptsFacade: MacChatSessionStore {}

extension TranscriptsFacade: QuietChatTranscriptPort {}

@MainActor
extension TranscriptsFacade {
    public func setWorkingCommentary(_ characters: Int, id messageId: String, in sessionId: String) {
        let slot = slot(for: sessionId)
        guard let index = slot.live.lastIndex(where: { $0.message.id == messageId }),
              slot.live[index].message.metadata?.workingCommentaryChars != characters
        else { return }
        var metadata = slot.live[index].message.metadata ?? ChatMessageMetadata()
        metadata.workingCommentaryChars = characters
        slot.live[index].message.metadata = metadata
        reproject(sessionId)
    }
}
