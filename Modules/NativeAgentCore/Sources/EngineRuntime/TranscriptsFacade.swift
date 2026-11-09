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
// Blueprint: | `TranscriptsFacade.swift` | Root-scoped transcripts, press, session faces, mounted invalidations and live tail boxes |
@MainActor
@Observable
private final class ChatTranscriptSlot {
    /// Overlay live turn rows on saved store publication.
    @ObservationIgnored var messages: [ChatMessage] = []
    /// Only committed store reads may replace saved rows.
    @ObservationIgnored var saved: [ChatMessage] = []
    @ObservationIgnored var savedIsComplete = false
    /// A full-history demand holds for this slot's lifetime, including file invalidations.
    @ObservationIgnored var requiresComplete = false
    @ObservationIgnored var openingRowCount = 64
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
    public nonisolated let press: TranscriptPress<ChatMessage>
    public nonisolated let messageIndex = CommandPaletteMessageIndex()
    public internal(set) var savedBotReplies: [(BotsShelfRecord, ShelfEntry)] = []
    public internal(set) var savedMemories: [MemoryV2.MemoryRecord] = []
    public internal(set) var savedSearchError: String?
    @ObservationIgnored let savedSearchRead = LatestRead()
    public private(set) var firstConversationReceiptTitle: String?

    /// Cache positive evidence only because the write token may arm during launch.
    public func readFirstConversationReceiptTitle() async -> String? {
        if let cached = firstConversationReceiptTitle { return cached }
        let root = dataRoot
        let title = await Task.detached(priority: .userInitiated) {
            FirstConversationPersonaProgression.recordedWriteTitle(dataRoot: root)
        }.value
        if let title { firstConversationReceiptTitle = title }
        return title
    }
    public var firstConversationPersonName: String {
        get throws { try NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) }
    }
    @ObservationIgnored public lazy var sessionTransactions = MacChatSessionTransactions()

    /// Any index publication supersedes suspended presentation reads.
    @ObservationIgnored private var sessionSnapshot: [NativeAgentShared.ChatSession] = []
    @ObservationIgnored public private(set) var sessionIndexError: String?
    @ObservationIgnored public private(set) var hasLoadedSessionIndex = false
    @ObservationIgnored var sessionIndexDidPublish: (() -> Void)?
    @ObservationIgnored private var sessionFacePublication: Task<Void, Never>?
    @ObservationIgnored private var pendingSessionFaceInput: SessionFaceProjection.Input?
    @ObservationIgnored private var sessionUnreadObservation: Task<Void, Never>?
    @ObservationIgnored private var paletteSearch = ""
    private nonisolated let sessionFaces: SessionFaceProjection
    nonisolated public static let sessionIndexDidChange = Notification.Name("NativeAgent.sessionIndexDidChange")
    public var sessions: [NativeAgentShared.ChatSession] {
        get { sessionSnapshot }
        set { sessionTransactions.indexRead.write { publishSessionIndex(newValue, isRead: false) } }
    }
    /// Keep the original read ticket; treating publication as a write would fence a newer running read.
    public func publishSessionIndexRead(_ sessions: [NativeAgentShared.ChatSession]) {
        publishSessionIndex(sessions, isRead: true)
    }
    private func publishSessionIndex(_ sessions: [NativeAgentShared.ChatSession], isRead: Bool) {
        let changed = sessionSnapshot != sessions || (isRead && (!hasLoadedSessionIndex || sessionIndexError != nil))
        if sessionSnapshot != sessions { sessionSnapshot = sessions }
        if isRead {
            if sessionIndexError != nil { sessionIndexError = nil }
            if !hasLoadedSessionIndex { hasLoadedSessionIndex = true }
        }
        publishSessionFaces()
        if changed {
            sessionIndexDidPublish?()
            NotificationCenter.default.post(name: Self.sessionIndexDidChange, object: dataRoot)
        }
    }
    public func publishSessionIndexFailure(_ error: Error) {
        let problem = UserFacingError.cause(error, action: "refresh the conversation list")
        guard sessionIndexError != problem else { return }
        sessionIndexError = problem
        publishSessionFaces()
        NotificationCenter.default.post(name: Self.sessionIndexDidChange, object: dataRoot)
    }
    /// Retain the displayed index with its failure cause after failed refresh.
    @discardableResult
    public func refreshSessionIndex() async -> Bool {
        do { _ = try await readSessionIndex(); return true }
        catch { return false }
    }

    public func readSessionIndex() async throws -> [NativeAgentShared.ChatSession] {
        let result = await sessionTransactions.indexRead.read({
            do { return Result<[NativeAgentShared.ChatSession], Error>.success(try await list()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): publishSessionIndexRead(rows)
            case .failure(let error):
                publishSessionIndexFailure(error)
            }
        })
        return try result.get()
    }
    @ObservationIgnored public private(set) var pinnedSessionIDs: [String] = []
    @ObservationIgnored private var hasReadPins = false
    @ObservationIgnored public private(set) var conversationAnchor: ConversationAnchorPin?
    @ObservationIgnored public private(set) var navigationError: String?
    @ObservationIgnored private let navigationRead = LatestRead()
    public func navigation(for sessions: [NativeAgentShared.ChatSession]) -> ChatSessionNavigation {
        let byID = Dictionary(sessions.filter { $0.archived != true }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = ConversationAnchor.merged(into: pinnedSessionIDs, anchorSessionId: conversationAnchor?.sessionId)
            .compactMap { id -> ChatSessionNavigation.Row? in
                byID[id].map { .init(session: $0, isPinned: pinnedSessionIDs.contains(id), isAnchor: id == conversationAnchor?.sessionId) }
            }
        return .init(rows: rows, pinnedSessionIDs: pinnedSessionIDs, anchor: conversationAnchor)
    }
    public func refreshNavigationIdentity() async {
        let root = dataRoot
        _ = await navigationRead.read({
            await Task.detached(priority: .userInitiated) {
                let pins = Result { try ChatSessionRetention.load(dataRoot: root) }
                let anchor = Result { try ConversationAnchor.checkedCurrent(dataRoot: root) }
                return (pins, anchor)
            }.value
        }, publish: { pins, anchor in
            var issues: [String] = []
            switch pins {
            case .success(let ids):
                if pinnedSessionIDs != ids { pinnedSessionIDs = ids }
                hasReadPins = true
            case .failure(let error): issues.append(UserFacingError.cause(error, action: "read pinned conversations"))
            }
            switch anchor {
            case .success(let pin): if conversationAnchor != pin { conversationAnchor = pin }
            case .failure(let error): issues.append(UserFacingError.cause(error, action: "read the current conversation"))
            }
            navigationError = issues.isEmpty ? nil : issues.joined(separator: "\n")
            publishSessionFaces()
        })
    }
    public func watchNavigation() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [ConversationAnchor.path(dataRoot: dataRoot),
            ChatSessionRetention.macPinnedSessionIdsPath(dataRoot: dataRoot)]) { await self.refreshNavigationIdentity() }
    }
    public func prunePinnedSessionIDs(retaining ids: Set<String>) async throws -> (encoded: String, changed: Bool) {
        let root = dataRoot
        let (encoded, pins, changed) = try await VolumeIO.run {
            let current = try ChatSessionRetention.load(dataRoot: root)
            let next = current.filter { ids.contains($0) }
            let encoded = try ChatSessionRetention.save(next, dataRoot: root)
            return (encoded, try ChatSessionRetention.decode(encoded), next != current)
        }
        navigationRead.write { pinnedSessionIDs = pins; hasReadPins = true; navigationError = nil }
        publishSessionFaces()
        return (encoded, changed)
    }
    public func pinSession(_ sessionID: String) async throws -> (changed: Bool, shared: Bool) {
        let root = dataRoot
        let (changed, encoded, pins) = try await VolumeIO.run {
            let current = try ChatSessionRetention.load(dataRoot: root)
            let changed = !current.contains(sessionID)
            let encoded = try ChatSessionRetention.save(changed ? current + [sessionID] : current, dataRoot: root)
            return (changed, encoded, try ChatSessionRetention.decode(encoded))
        }
        navigationRead.write { pinnedSessionIDs = pins; hasReadPins = true; navigationError = nil }
        publishSessionFaces()
        guard changed else { return (false, true) }
        return (changed, await publishPins(encoded, includeTranscripts: true))
    }
    public func closePinnedTab(_ sessionID: String) async throws -> ChatSessionRetention.CloseResult {
        let root = dataRoot
        let (result, pins): (ChatSessionRetention.CloseResult, [String]?) = try await VolumeIO.run {
            let result = try ChatSessionRetention.closePinnedTab(sessionID: sessionID, dataRoot: root)
            if case .closed(let encoded) = result { return (result, try ChatSessionRetention.decode(encoded)) }
            return (result, nil)
        }
        if let pins { navigationRead.write { pinnedSessionIDs = pins; hasReadPins = true; navigationError = nil } }
        publishSessionFaces()
        return result
    }
    public func publishPins(_ encoded: String, includeTranscripts: Bool) async -> Bool {
        let root = dataRoot
        do {
            guard try await VolumeIO.run({ try ChatSessionRetention.request(encodedPinnedIDs: encoded, dataRoot: root) }) else { return false }
            NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: includeTranscripts)
            return true
        } catch {
            navigationError = UserFacingError.cause(error, action: "share pinned conversations")
            publishSessionFaces()
            return false
        }
    }
    // Observe row revisions; only the turn's current streaming leaf changes through its tail box without advancing the revision.
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

    public nonisolated init(turns: TurnsFacade, feed: FaceFeedSource) {
        self.turns = turns
        self.presentation = PresentationFaces(dataRoot: turns.dataRoot, feed: feed)
        self.press = TranscriptPress(feed: feed)
        self.sessionFaces = SessionFaceProjection(source: feed, dataRoot: turns.dataRoot)
    }

    public nonisolated func observeSessionSearch(_ query: String, viewID: UUID) async {
        await sessionFaces.observeSearch(query, viewID: viewID)
    }

    public func setPaletteSearch(_ query: String) {
        guard paletteSearch != query else { return }
        paletteSearch = query
        publishSessionFaces()
    }

    func bindSessionFaces() {
        guard sessionUnreadObservation == nil else { return }
        sessionUnreadObservation = Task { @MainActor [weak self] in
            let changes = NotificationCenter.default.notifications(named: MacChatUnreadSessions.didChange).map { _ in () }
            self?.publishSessionFaces()
            for await _ in changes {
                guard let self else { return }
                self.publishSessionFaces()
            }
        }
    }

    deinit { sessionUnreadObservation?.cancel() }

    /// Capture canonical values only; formatting, sectioning and feed delivery run on the projection actor.
    func publishSessionFaces() {
        pendingSessionFaceInput = SessionFaceProjection.Input(
            sessions: sessions, openings: openingLines.reading, pins: pinnedSessionIDs, pinsKnown: hasReadPins,
            anchor: conversationAnchor?.sessionId,
            unread: MacChatUnreadSessions.shared.ids,
            streaming: turns.runtime.streamingSessions.filter { turns.runtime.lifecycleBySession[$0]?.replyTextSettled != true },
            active: turns.runtime.activeTurnIDsBySession,
            loaded: hasLoadedSessionIndex, indexIssue: sessionIndexError, navigationIssue: navigationError,
            paletteSearch: paletteSearch
        )
        guard sessionFacePublication == nil else { return }
        let projection = sessionFaces
        sessionFacePublication = Task.detached { [weak self] in
            while let input = await self?.takeSessionFaceInput() { await projection.post(input) }
        }
    }

    private func takeSessionFaceInput() -> SessionFaceProjection.Input? {
        defer { pendingSessionFaceInput = nil }
        if pendingSessionFaceInput == nil { sessionFacePublication = nil }
        return pendingSessionFaceInput
    }

    public func deliverSessionFaces() async {
        publishSessionFaces()
        await sessionFacePublication?.value
    }

    /// Message indexing is an engine operation; the window never needs its source session rows.
    public func refreshPaletteMessageIndex() async throws -> Int {
        try await refreshPaletteMessageIndexFailures().count
    }

    public func refreshPaletteMessageIndexFailures() async throws -> [String: String] {
        let sessions = try await readSessionIndex().filter { $0.archived != true }
            .map { (id: $0.id, stamp: CommandPaletteMessageIndex.stamp($0) + "|\(structureVersion(for: $0.id))") }
        return await messageIndex.refreshWithFailures(sessions, transcripts: self)
    }

    /// Presentation can hold only the end. Semantic readers use loadMessages, which always reads the whole conversation.
    public func displayedTranscript(for sessionId: String) -> TranscriptReadout {
        let slot = slot(for: sessionId)
        _ = slot.structureVersion
        var result = TranscriptReadout(messages: slot.messages)
        result.isComplete = slot.savedIsComplete
        result.readStatus = slot.readStatus
        return result
    }
    public func completeDisplayedMessages(for sessionId: String) throws -> [ChatMessage] {
        let reading = displayedTranscript(for: sessionId)
        guard reading.isComplete, reading.readStatus == .current else {
            let cause: String
            if case .unavailable(let detail) = reading.readStatus { cause = detail }
            else { cause = "The complete conversation has not been published. Read it before using its history." }
            throw NSError(domain: "NativeAgent.ChatHistory", code: 409, userInfo: [
                NSLocalizedDescriptionKey: cause
            ])
        }
        return reading.messages
    }
    public func hasCachedTranscript(for sessionID: String) -> Bool {
        // A mounted unread room must wake when its first committed rows arrive, even when that first read is empty.
        _ = slot(for: sessionID).structureVersion
        return loadedSessions.contains(sessionID)
    }
    public func structureVersion(for sessionId: String) -> UInt64 {
        slot(for: sessionId).structureVersion
    }
    public func prepareGroups(for sessionId: String) async {
        let slot = slot(for: sessionId)
        if slot.preparation == nil {
            let messages = slot.messages
            let version = slot.structureVersion
            slot.preparation = Task {
                await slot.groupReads.read {
                    await Task.detached(priority: .userInitiated) { MessageGrouper.projection(for: messages) }.value
                } publish: { (built: MessageGrouper.GroupedTranscript) in
                    var groups = built
                    groups.structureVersion = version
                    slot.groups = groups
                }
            }
        }
        await slot.preparation?.value
    }
    public func groups(for sessionId: String) -> MessageGrouper.GroupedTranscript {
        let slot = slot(for: sessionId)
        _ = slot.structureVersion
        return slot.groups.readingTail(from: slot.messages)
    }
    public func transcriptReadStatus(for sessionID: String) -> TranscriptReadout.ReadStatus {
        slot(for: sessionID).readStatus
    }
    public nonisolated func reclaimContinuations(for sessionID: String) async {
        await InlineInteractionResolver.reclaimStrandedContinuations(sessionID: sessionID, dataRoot: dataRoot)
    }
    public func refreshCards(in sessionID: String) async {
        do { _ = try await refreshDisplayedMessages(sessionId: sessionID) }
        catch { ModuleLog.app("[transcript-read] cards unavailable session=%@: %@", sessionID, error.localizedDescription) }
    }
    public func watchIndexChanges(refresh: @escaping @MainActor @Sendable () async -> Void) async {
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: [dataRoot.appendingPathComponent("chat/sessions.json")],
            notifications: [AbilityStore.didChange], debounceDelay: .milliseconds(150), refresh: refresh
        )
    }
    @concurrent public nonisolated func watchChanges(sessionID: String, refresh: @escaping @MainActor @Sendable () async -> Void) async {
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { return }
        let changes = FileChangeEvents(paths: [dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")], emitInitial: false)
        let reload = StoreReloadDebouncer(delay: .milliseconds(100)) { await refresh() }
        await changes.waitUntilArmed()
        if !Task.isCancelled { await refresh() }
        await reload.setVisible(!Task.isCancelled)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes.stream {
                    guard !Task.isCancelled else { return }
                    await reload.signal()
                }
            }
            group.addTask {
                // The sequence lives in the task that reads it; all current writers post the affected session as object.
                let notifications = NotificationCenter.default.notifications(named: .nativeAgentChatTranscriptDidChange)
                    .compactMap { $0.object as? String }
                for await changedSession in notifications {
                    guard !Task.isCancelled else { return }
                    // A card answer changes mirror rows even without a transcript-file write.
                    if changedSession == session { await reload.signal() }
                }
            }
        }
        await reload.cancel()
        changes.cancel()
    }
    private func slot(for sessionId: String) -> ChatTranscriptSlot {
        if let slot = storage[sessionId] { return slot }
        let slot = ChatTranscriptSlot()
        storage[sessionId] = slot
        return slot
    }
    /// Keep live turns over committed loader results.
    public func setMessages(_ messages: [ChatMessage], for sessionId: String) {
        let current = slot(for: sessionId)
        current.cardReads.write {
            current.saved = messages
            current.savedIsComplete = true
            current.requiresComplete = true
            current.readStatus = .current
        }
        reproject(sessionId)
    }
    /// Derive the screen from saved and live rows, never a separate mutable copy.
    private func reproject(_ sessionId: String, extentChanged: Bool = false) {
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
        if extentChanged || rows != slot.messages || !loadedSessions.contains(sessionId) { publishMessages(rows, for: sessionId) }
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
        slot.savedIsComplete = false
        slot.requiresComplete = false
        publishMessages([], for: sessionId)
        loadedSessions.remove(sessionId)
        return messages
    }
    internal func publishClearedTranscript(_ sessionId: String) {
        let current = slot(for: sessionId)
        current.cardReads.write {
            current.readStatus = .current
            current.savedIsComplete = true
            current.requiresComplete = true
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
        let active = turns.activeStreamingBubbleIDs
        streamingTailBoxOrder.removeAll { id in
            guard streamingTailBoxes.count > 8, !active.contains(id),
                  isKnownUniquelyReferenced(&streamingTailBoxes[id]) else { return false }
            streamingTailBoxes.removeValue(forKey: id)
            return true
        }
    }
    /// Only the turn owner's live streaming leaf skips group invalidation; every other tail edit publishes a row revision.
    public func setTailMessageContent(_ content: String, id messageId: String, in sessionId: String) -> Bool {
        guard let slot = storage[sessionId], let last = slot.messages.indices.last,
              slot.messages[last].id == messageId
        else { return false }
        let streaming = turns.streamingBubbleID(for: sessionId) == messageId
        if !streaming && slot.messages[last].content == content { return true }
        slot.messages[last].content = content
        if let live = slot.live.firstIndex(where: { $0.message.id == messageId }) { slot.live[live].message.content = content }
        // Publish streamed chunks only to the exact leaf bubble so parent structure and layout stay stable.
        streamingTailBox(forMessage: messageId).content = content
        if !streaming { publishMessages(slot.messages, for: sessionId) }
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
    /// File changes refresh the held extent; only an explicit full-history reader promotes it.
    @discardableResult
    public func refreshDisplayedMessages(sessionId: String, cached: Bool = true, minimumRows: Int = 64) async throws -> Bool {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return false }
        return try await readPublishedTranscript(safeSessionId: safeSessionId, cached: cached, opening: true, minimumRows: minimumRows).applied
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
    internal func readPublishedTranscript(safeSessionId: String, cached: Bool, opening: Bool = false, minimumRows: Int = 64)
        async throws -> (projection: TranscriptReadout, applied: Bool) {
        let current = slot(for: safeSessionId)
        if !opening { current.requiresComplete = true }
        if opening { current.openingRowCount = max(current.openingRowCount, minimumRows) }
        let limit: Int? = current.requiresComplete ? nil : current.openingRowCount
        var applied = false
        let outcome: Result<TranscriptReadout, Error> = await current.cardReads.read {
            do { return .success(try await readTranscriptProjection(safeSessionId: safeSessionId, cached: cached, limit: limit)) }
            catch { return .failure(error) }
        } publish: { read in
            switch read {
            case .success(let projection):
                applied = true
                let extentChanged = current.savedIsComplete != projection.isComplete
                current.readStatus = .current
                current.saved = projection.messages
                current.savedIsComplete = projection.isComplete
                reproject(safeSessionId, extentChanged: extentChanged)
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

/// Send caches retain presentation only; the facade and runtime remain the command owners.
private actor SessionFaceProjection {
    struct Input: Sendable, Equatable {
        let sessions: [ChatSession]
        let openings: [String: ChatShellOpeningLine.OpeningLine]
        let pins: [String]
        let pinsKnown: Bool
        let anchor: String?
        let unread: Set<String>
        let streaming: Set<String>
        let active: [String: String]
        let loaded: Bool
        let indexIssue: String?
        let navigationIssue: String?
        let paletteSearch: String
    }
    private struct RowInput: Equatable {
        let session: ChatSession
        let opening: ChatShellOpeningLine.OpeningLine?
        let unread: Bool
        let pinned: Bool?
        let running: Bool
    }
    private struct Words {
        let title: String
        let preview: String
        let surface: String
        let date: Date?
        let sidebarTitle: String
        let sidebarPreview: String
        let isWorking: Bool
        let isAgentOwn: Bool
    }
    private let source: FaceFeedSource
    private let dataRoot: URL
    private var previous: Input?
    private var previousRunning: Set<String>?
    private var rowInputs: [String: RowInput] = [:]
    private var rows: [String: SessionRowFace] = [:]
    private var words: [String: Words] = [:]
    private var list: SessionListFace?
    private var palette: SessionPaletteFace?
    private var navigation: SessionNavigationFace?
    private struct SearchObserver {
        let lease: UUID
        let query: String
    }
    private var searchObservers: [UUID: SearchObserver] = [:]
    private var searchLists: [UUID: SessionSearchFace] = [:]

    init(source: FaceFeedSource, dataRoot: URL) { self.source = source; self.dataRoot = dataRoot }

    /// The mounted view holds its query; cancellation releases that query's projection.
    func observeSearch(_ query: String, viewID: UUID) async {
        guard !query.isEmpty else { return }
        let id = UUID()
        let (lifetime, end) = AsyncStream<Void>.makeStream()
        defer { end.finish() }
        searchObservers[viewID] = SearchObserver(lease: id, query: query)
        await postSearch(viewID)
        for await _ in lifetime {}
        endSearch(viewID, lease: id)
    }

    private func endSearch(_ viewID: UUID, lease: UUID) {
        guard searchObservers[viewID]?.lease == lease else { return }
        searchObservers[viewID] = nil
        searchLists[viewID] = nil
    }

    private func postSearch(_ viewID: UUID) async {
        guard var next = list, let query = searchObservers[viewID]?.query else { return }
        let matching = Set(words.compactMap { id, text in
            text.sidebarTitle.contains(query) || text.sidebarPreview.contains(query) ? id : nil
        })
        next.rows = next.rows.filter { matching.contains($0) }
        next.working = next.working.filter { matching.contains($0) }
        next.briefs = next.briefs.filter { matching.contains($0) }
        next.emptyIDs = next.emptyIDs.filter { matching.contains($0) }
        let answer = SessionSearchFace(query: query, sections: next)
        if searchLists[viewID] != answer {
            searchLists[viewID] = answer
            await source.post(answer, at: .sessionSearch(viewID))
        }
    }

    func post(_ input: Input) async {
        let running = Set(ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).map(\.sessionId))
            .union(input.streaming).union(input.active.keys)
        guard previous != input || previousRunning != running else { return }
        let listChanged = previous?.sessions != input.sessions || previous?.openings != input.openings
            || previous?.pins != input.pins || previous?.anchor != input.anchor
        let paletteChanged = previous?.sessions != input.sessions || previous?.openings != input.openings
            || previous?.paletteSearch != input.paletteSearch
        previous = input
        previousRunning = running
        var seen = Set<String>()
        let sessions = input.sessions.filter { seen.insert($0.id).inserted }
        let ids = Set(sessions.map(\.id))
        for session in sessions {
            let next = RowInput(session: session, opening: input.openings[session.id], unread: input.unread.contains(session.id),
                                pinned: input.pinsKnown ? input.pins.contains(session.id) : nil, running: running.contains(session.id))
            guard rowInputs[session.id] != next else { continue }
            let prepared: Words
            if let prior = rowInputs[session.id], prior.session == next.session, prior.opening == next.opening,
               let cached = words[session.id] {
                prepared = cached
            } else {
                let stamp = session.messageCount == 0 ? session.createdAt : next.opening?.lastTurn
                let title = ChatShellConversationRow.faceTitle(session.displayTitle)
                let preview = ChatShellConversationRow.preview(for: session)
                prepared = Words(title: title, preview: ChatShellConversationRow.listPreview(preview, title: title),
                    surface: ChatShellConversationRow.surface(for: session),
                    date: stamp.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst),
                    sidebarTitle: session.title.lowercased(), sidebarPreview: session.lastMessagePreview?.lowercased() ?? "",
                    isWorking: ChatShellConversationRow.isWorking(session),
                    isAgentOwn: ChatShellConversationRow.isAgentOwn(session, reading: input.openings))
                words[session.id] = prepared
            }
            rowInputs[session.id] = next
            let row = SessionRowFace(title: prepared.title, preview: prepared.preview, surface: prepared.surface, date: prepared.date,
                isUnread: next.unread, isPinned: next.pinned, isRunning: next.running, issue: next.opening?.issue)
            if rows[session.id] != row {
                rows[session.id] = row
                await source.post(row, at: .session(session.id))
            }
        }
        for id in Set(rows.keys).subtracting(ids) {
            if let row = rows.removeValue(forKey: id) {
                await source.post(SessionRowFace(title: row.title, preview: row.preview, surface: row.surface, date: row.date,
                    isUnread: row.isUnread, isPinned: row.isPinned, isRunning: row.isRunning,
                    isPresent: false, issue: row.issue), at: .session(id))
            }
            rowInputs[id] = nil
            words[id] = nil
        }
        let paletteQuery = input.paletteSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if listChanged {
            let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            var next = SessionListFace()
            next.allIDs = sessions.map(\.id)
            next.pinnedIDs = input.pins
            next.navigationIDs = ConversationAnchor.merged(into: input.pins, anchorSessionId: input.anchor)
                .filter { byID[$0].map { $0.archived != true } == true }
            let navigationIDs = Set(next.navigationIDs)
            let ordered = next.navigationIDs.compactMap { byID[$0] } + sessions.filter { !navigationIDs.contains($0.id) }
            for session in ordered {
                guard let prepared = words[session.id] else { continue }
                if session.messageCount == 0 { next.emptyIDs.append(session.id) }
                if prepared.isWorking { next.working.append(session.id) }
                else if !navigationIDs.contains(session.id), prepared.isAgentOwn {
                    next.briefs.append(session.id)
                } else { next.rows.append(session.id) }
            }
            if list != next { list = next; await source.post(next, at: .sessions) }
            for viewID in Array(searchObservers.keys) { await postSearch(viewID) }
        }
        if paletteChanged {
            let answer = SessionPaletteFace(query: paletteQuery,
                matches: ConversationPaletteRanking.matches(sessions, query: paletteQuery))
            if palette != answer { palette = answer; await source.post(answer, at: .sessionPalette) }
        }
        let issues = [input.indexIssue, input.navigationIssue].compactMap { $0 }
        let status = SessionNavigationFace(hasLoadedIndex: input.loaded,
            issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
        if navigation != status { navigation = status; await source.post(status, at: .sessionNavigation) }
    }
}

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
