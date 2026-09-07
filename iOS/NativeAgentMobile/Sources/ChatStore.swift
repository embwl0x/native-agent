import SwiftUI
import UIKit
import NativeAgentShared

enum ChatSendDisposition: Equatable {
    case started
    case queued(UUID)
    case rejected
}

struct QueuedChatSend: Identifiable, Codable {
    static let maxPerSession = 20
    let id: UUID
    var sessionID: String?
    let text: String
    let controls: ChatRuntimeControls
    let attachments: [MultimodalAttachment]
    let createdAt: Date
    /// Present once handoff starts; replay retains the exact signed payload.
    var preparedMessage: BridgeMessage? = nil
    var placeholderID: UUID? = nil

    var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }
}

// MARK: - Store

@MainActor
final class ChatStore: ObservableObject {
    struct CachedTranscript: Codable {
        let schemaVersion: Int
        let sessionID: String?
        let messages: [ChatMessage]
        /// 2026-09-06: the newest Mac transcript version these rows were
        /// reconciled against. It rides WITH the rows because it only means
        /// anything about them: an empty transcript is allowed to wipe this
        /// cache exactly when it is newer than this. Held only in memory, a
        /// relaunch forgot it and the next stale empty snapshot wiped a
        /// rebuilt chat. nil for envelopes written before this field existed.
        var appliedTranscriptGeneration: Int? = nil
    }

    @Published var messages: [ChatMessage] = [] {
        didSet {
            noteMessageArrivals(previous: oldValue, current: messages)
            persistMessages()
        }
    }
    @Published var isLoading = false {
        didSet {
            if oldValue && !isLoading {
                scheduleQueuedSendDrain()
            }
        }
    }
    @Published var isSwitchingSession = false
    @Published var isPollingFallback = false   // true after 10s waiting — drives "still waiting…" hint
    @Published var errorBanner: String?

    /// Dismisses only the currently rendered error. Future transport or reply
    /// failures assign a new value to `errorBanner` and must remain visible.
    func dismissErrorBanner() {
        errorBanner = nil
    }
    @Published var streamingHintsByMessageId: [UUID: String] = [:]
    @Published var queuedSends: [QueuedChatSend] = [] {
        didSet { persistQueuedSends() }
    }
    /// Persist every accepted send. Admission is bounded per session; a global
    /// persistence cap would silently discard other sessions' paused queues.
    private let queuedSendsKey = "NativeAgentMobile.chatQueuedSends.v1"
    /// Production has one app-owned store, so queue restoration has one owner.
    /// Tests inject an isolated defaults suite and may opt out of restoration.
    let defaults: UserDefaults

    private func persistQueuedSends() {
        if queuedSends.isEmpty {
            defaults.removeObject(forKey: queuedSendsKey)
            return
        }
        if let data = try? JSONEncoder().encode(queuedSends) {
            defaults.set(data, forKey: queuedSendsKey)
        }
    }

    func checkpointQueuedSend(_ id: UUID) throws {
        guard queuedSends.contains(where: { $0.id == id }) else {
            throw DeviceSyncError.underlying(message: "Queued send is no longer available")
        }
        defaults.set(try JSONEncoder().encode(queuedSends), forKey: queuedSendsKey)
        guard defaults.synchronize() else {
            throw DeviceSyncError.underlying(message: "Could not save queued send")
        }
    }
    @Published var pausedQueueSessionKeys: Set<String> = [] {
        didSet { persistPausedQueueSessionKeys() }
    }
    /// 2026-09-06: the pause set was in-memory while the queue it pauses is
    /// persisted, so a relaunch drained (and sent) messages the user had
    /// explicitly stopped. Persist it alongside the queue.
    private let pausedQueueSessionKeysKey = "NativeAgentMobile.chatPausedQueueSessions.v1"

    private func persistPausedQueueSessionKeys() {
        if pausedQueueSessionKeys.isEmpty {
            defaults.removeObject(forKey: pausedQueueSessionKeysKey)
            return
        }
        defaults.set(Array(pausedQueueSessionKeys), forKey: pausedQueueSessionKeysKey)
    }
    // PATCH-2026-05-30: incremental text streaming over iCloud.
    // The Mac side writes batched text_delta BridgeMessages every ~1.5s during
    // a chat turn so iOS users see Agent "typing" in real time instead of a
    // 20-second wall of silence followed by the whole answer dropping in.
    //
    // Each delta carries the FULL accumulated text-so-far (not incremental
    // characters) plus a monotonic `seq` per correlation, so out-of-order
    // delivery from iCloud Drive is recoverable — we just keep the highest
    // seq we've seen and ignore stragglers. The final reply (no `kind` set
    // or `kind:"final"`) supersedes all deltas via the existing finalize
    // path; once a correlation is in resolvedICloudReplyIds, late deltas
    // are dropped on the dispatcher.
    var maxDeltaSeqByCorrelation: [String: Int] = [:]
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var mainSessionID: String?
    /// A phone-created main session remains locally authoritative until the
    /// Mac publishes that exact identity. Session-list snapshots can lag the
    /// first send, so treating absence as removal can otherwise roll the UI
    /// back to the previous main chat and stamp the send with the wrong id.
    private(set) var locallyCreatedSessionID: String?

    // PATCH-2026-05-11: unified-session-v1 — drop stale iOS-only session ID on first launch
    // so the Mac app resolves to the shared mobile session via sourceKey.
    private static let selectedSessionIDKey = "NativeAgentMobile.chatSessionID"
    private static let mainSessionIDKey = "NativeAgentMobile.mainChatSessionID"
    private static let locallyCreatedSessionIDKey = "NativeAgentMobile.locallyCreatedChatSessionID"
    let transcriptKey = "NativeAgentMobile.chatMessages"
    let transcriptPrefix = "NativeAgentMobile.chatMessages.session."
    var suppressMessagePersistence = false
    /// One session switch owns the composer lock. The generation prevents a
    /// cancelled/late history read from releasing a newer switch.
    var sessionSwitchGeneration: UInt64 = 0
    var sessionSwitchTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        restoreQueuedSends: Bool = true,
        iCloudReplyTimeoutSeconds: UInt64 = 180
    ) {
        self.defaults = defaults
        self.iCloudReplyTimeoutSeconds = iCloudReplyTimeoutSeconds
        if !defaults.bool(forKey: "NativeAgent.unifiedSession.v1") {
            defaults.removeObject(forKey: Self.selectedSessionIDKey)
            defaults.removeObject(forKey: Self.mainSessionIDKey)
            defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
        }
        let savedSelected = Self.cleanSessionID(defaults.string(forKey: Self.selectedSessionIDKey))
        let savedMain = Self.cleanSessionID(defaults.string(forKey: Self.mainSessionIDKey)) ?? savedSelected
        let savedLocal = Self.cleanSessionID(defaults.string(forKey: Self.locallyCreatedSessionIDKey))
        selectedSessionID = savedSelected
        mainSessionID = savedMain
        if savedLocal == savedSelected, savedLocal == savedMain {
            locallyCreatedSessionID = savedLocal
        } else {
            locallyCreatedSessionID = nil
            defaults.removeObject(forKey: Self.locallyCreatedSessionIDKey)
        }
        // 2026-07-21 audit fix: restore persisted queued sends (were in-memory
        // only; a relaunch silently discarded user-composed messages). ChatStore
        // is owned once at the App boundary, so no process-global restore latch
        // can strand the queue when a view/store is recreated.
        if restoreQueuedSends,
           let queueData = defaults.data(forKey: queuedSendsKey),
           let restoredQueue = try? JSONDecoder().decode([QueuedChatSend].self, from: queueData) {
            queuedSends = restoredQueue
        }
        // 2026-09-06: restore the pause set with the queue. Without it a
        // relaunch resumed a queue the user had stopped.
        if restoreQueuedSends,
           let restoredPaused = defaults.array(forKey: pausedQueueSessionKeysKey) as? [String] {
            pausedQueueSessionKeys = Set(restoredPaused)
        }
        if let savedMain, defaults.string(forKey: Self.mainSessionIDKey) == nil {
            defaults.set(savedMain, forKey: Self.mainSessionIDKey)
        }
        messages = loadCachedMessages(for: savedSelected ?? savedMain)
    }

    static func cleanSessionID(_ value: String?) -> String? {
        let clean = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    func setSelectedSessionID(_ value: String?) {
        let clean = Self.cleanSessionID(value)
        selectedSessionID = clean
        if let clean {
            defaults.set(clean, forKey: Self.selectedSessionIDKey)
        } else {
            defaults.removeObject(forKey: Self.selectedSessionIDKey)
        }
    }

    func replaceMainSessionID(_ value: String?) {
        let clean = Self.cleanSessionID(value)
        mainSessionID = clean
        if let clean {
            defaults.set(clean, forKey: Self.mainSessionIDKey)
        } else {
            defaults.removeObject(forKey: Self.mainSessionIDKey)
        }
    }

    func markLocallyCreatedSession(_ value: String) {
        guard let clean = Self.cleanSessionID(value) else { return }
        locallyCreatedSessionID = clean
        defaults.set(clean, forKey: Self.locallyCreatedSessionIDKey)
    }

    func acknowledgePublishedSession(_ value: String?) {
        guard let clean = Self.cleanSessionID(value), clean == locallyCreatedSessionID else { return }
        locallyCreatedSessionID = nil
        defaults.removeObject(forKey: Self.locallyCreatedSessionIDKey)
    }

    func acknowledgePublishedSessions(_ sessionIDs: Set<String>) {
        guard let local = locallyCreatedSessionID, sessionIDs.contains(local) else { return }
        acknowledgePublishedSession(local)
    }

    func rememberMainSessionIDIfNeeded(_ value: String?) {
        guard mainSessionID == nil, let clean = Self.cleanSessionID(value) else { return }
        mainSessionID = clean
        defaults.set(clean, forKey: Self.mainSessionIDKey)
    }

    func adoptMainSessionIDIfNeeded(_ value: String?) {
        guard mainSessionID == nil, let clean = Self.cleanSessionID(value) else { return }
        mainSessionID = clean
        defaults.set(clean, forKey: Self.mainSessionIDKey)
    }

    func transcriptStorageKey(for sessionID: String?) -> String {
        guard let clean = Self.cleanSessionID(sessionID) else { return transcriptKey }
        return transcriptPrefix + clean
    }

    func loadCachedMessages(for sessionID: String?, fallback: [ChatMessage]? = nil) -> [ChatMessage] {
        let cleanSessionID = Self.cleanSessionID(sessionID)
        let exactKey = transcriptStorageKey(for: cleanSessionID)
        if let data = defaults.data(forKey: exactKey) {
            guard let saved = decodeCachedTranscript(
                data,
                expectedSessionID: cleanSessionID,
                permitsLegacyArray: exactKey != transcriptKey || cleanSessionID == nil
            ) else {
                errorBanner = "The cached transcript for this chat was unreadable. Refreshing from the Mac."
                return fallback ?? []
            }
            noteCachedTranscriptGeneration(saved.generation, for: cleanSessionID)
            return normalizedCachedMessages(saved.messages)
        }

        // The old global key has no session identity. It is safe only for an
        // unresolved main session, or when a v2 envelope proves the exact owner.
        guard exactKey != transcriptKey,
              let legacyData = defaults.data(forKey: transcriptKey),
              let saved = decodeCachedTranscript(
                legacyData,
                expectedSessionID: cleanSessionID,
                permitsLegacyArray: false
              ) else { return fallback ?? [] }
        noteCachedTranscriptGeneration(saved.generation, for: cleanSessionID)
        let normalized = normalizedCachedMessages(saved.messages)
        if let envelope = try? JSONEncoder().encode(CachedTranscript(
            schemaVersion: 2,
            sessionID: cleanSessionID,
            messages: normalized,
            appliedTranscriptGeneration: saved.generation
        )) {
            defaults.set(envelope, forKey: exactKey)
        }
        return normalized
    }

    /// 2026-09-06: restore the persisted clear-watermark for a session as its
    /// cache is read back. Without this the in-memory watermark starts empty
    /// every launch, and the first stale empty snapshot to arrive is treated as
    /// newer than everything — which is how a rebuilt transcript got wiped.
    private func noteCachedTranscriptGeneration(_ generation: Int?, for sessionID: String?) {
        guard let sessionID, let generation else { return }
        if let applied = appliedTranscriptGenerations[sessionID], generation <= applied { return }
        appliedTranscriptGenerations[sessionID] = generation
    }

    private func decodeCachedTranscript(
        _ data: Data,
        expectedSessionID: String?,
        permitsLegacyArray: Bool
    ) -> (messages: [ChatMessage], generation: Int?)? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(CachedTranscript.self, from: data),
           envelope.schemaVersion == 2,
           Self.cleanSessionID(envelope.sessionID) == expectedSessionID {
            return (envelope.messages, envelope.appliedTranscriptGeneration)
        }
        guard permitsLegacyArray else { return nil }
        guard let legacy = try? decoder.decode([ChatMessage].self, from: data) else { return nil }
        return (legacy, nil)
    }

    private func normalizedCachedMessages(_ saved: [ChatMessage]) -> [ChatMessage] {
        saved.map { msg in
            var copy = msg
            copy.isStreaming = false
            return copy
        }
    }

    /// Set by ChatView after init; called with each assistant reply text so
    /// VoiceOutputController can speak it without the store importing AVFoundation.
    var onReply: ((String) -> Void)?

    /// 2026-09-06: fired once per real session change, from the store's own
    /// switch path. Dictation belongs to the conversation it was started in, and
    /// ending it at each switch call site kept missing one — New Chat, a
    /// removed pin, the conversation anchor. The surface that owns the
    /// microphone subscribes; the store stays free of AVFoundation.
    var onSessionChange: (() -> Void)?

    // N5 fix (R18): track placeholder indices by pending message ID so iCloud
    // replies can update the correct bubble when they arrive asynchronously.
    // MacBridgeClient is iCloud-only: sendMessage returns the sent message's ID; the reply arrives
    // via observeICloudReplies, which looks up and updates the placeholder here.
    var pendingICloudPlaceholders: [String: UUID] = [:]
    /// 2026-09-06: the correlation ids of sends that have left the composer but
    /// whose transport call has not returned yet. The phone mints the id before
    /// the await, so a Stop pressed during the initial handoff can name the run
    /// it is stopping instead of arriving unscoped — an unscoped Stop makes the
    /// Mac cancel whatever holds the session, which may be somebody else's turn.
    var inFlightSendIDs: Set<String> = []
    // Phase 14e-iCloud: per-message timeout tasks. Each entry maps a pending
    // message ID to the cancellable Task that will fire if no reply arrives.
    var pendingTimeouts: [String: Task<Void, Never>] = [:]
    var pendingPolls: [String: Task<Void, Never>] = [:]
    var sendTask: Task<Void, Never>?
    // Phase 14e-iCloud HMAC self-heal: remember the args of every iCloud-queued
    // send so we can replay ONCE after a signature_invalid_resync. Cleared on
    // successful final/cancel/timeout paths.
    struct PendingSendArgs: Sendable {
        let text: String
        let sessionID: String?
        let controls: ChatRuntimeControls
        let attachments: [MultimodalAttachment]
        let appendedUserId: UUID?
    }
    var pendingSendArgs: [String: PendingSendArgs] = [:]
    var retriedSignatureCorrelations: Set<String> = []
    var canceledPendingIds: Set<String> = []
    var timedOutPendingIds: [String: UUID] = [:]
    var resolvedICloudReplyIds: Set<String> = []
    /// 2026-09-06: the message ids of the newest Mac transcript snapshot this
    /// session has adopted. A bridge-resolved reply keeps the phone's
    /// placeholder UUID forever (finishPlaceholder), so only these ids name a
    /// row the Mac can actually find — regenerate replaces exactly one
    /// persisted row by id and throws when the id names none.
    var macPublishedMessageIDs: Set<UUID> = []
    /// 2026-09-06: assistant ids removed locally for a regenerate. They are
    /// deliberately absent until the Mac's replacement lands, which is exactly
    /// the shape `newestMacAssistantReply`'s fallback reads as "the awaited
    /// reply" — a stale snapshot would otherwise complete the regeneration
    /// with the answer being replaced.
    var regeneratedAwayAssistantIDs: Set<UUID> = []
    /// 2026-09-06: the newest Mac transcript version applied per session. An
    /// EMPTY published transcript is authority to clear the visible chat, so it
    /// must be provably newer than what is on screen — two overlapping snapshot
    /// reads can finish out of order, and the older one must not be allowed to
    /// wipe a live transcript. Seeded from the persisted cache envelope on
    /// load, so the watermark survives a relaunch.
    var appliedTranscriptGenerations: [String: Int] = [:]
    /// 2026-09-06: the store the visible chat is bound to, so the notification
    /// delegate can tell a reply the user is already reading from one worth
    /// alerting about. Nil whenever no chat surface is on screen.
    static weak var visibleStore: ChatStore?

    static let resolvedPreserveWindowSeconds: TimeInterval = 15 * 60
    static let snapshotTruncationMarker = "[truncated for iPhone snapshot]"

    /// When each message id first appeared locally. Maintained from the messages
    /// didSet so every append path (send, bridge resolve, snapshot apply, cache
    /// load) is covered without instrumenting each call site. Internal for tests.
    var localArrivalDates: [UUID: Date] = [:]

    var typewriterTasks: [UUID: Task<Void, Never>] = [:]
    var typewriterTargets: [UUID: String] = [:]
    static let typewriterTickSeconds: TimeInterval = 0.07

    /// Timestamp of the last successful (or in-progress) refresh attempt.
    /// Used as a throttle guard — skips if a refresh happened within 2 seconds.
    var lastRefreshAt: Date = .distantPast

    /// Throttle interval (seconds). Refreshes closer together than this are skipped.
    let refreshThrottleSeconds: TimeInterval = 2.0

    /// Held weakly so receiveICloudRejection can replay a send without the
    /// caller threading the client through the rejection observer.
    ///
    /// It is also the last precondition `scheduleQueuedSendDrain` waits on, and
    /// it only arrives from `ChatView.onAppear` — which does not run on a
    /// launch that lands on another tab. A resume that happened first (network
    /// restore, rejection replay) would otherwise schedule nothing and be lost,
    /// so installing the client picks up whatever the queue is already owed.
    weak var pendingRetryClient: MacBridgeClient? {
        didSet {
            guard pendingRetryClient !== oldValue, pendingRetryClient != nil else { return }
            scheduleQueuedSendDrain()
        }
    }
    /// Held weakly so the rejection-retry path can call refreshFromKVS() without
    /// the caller threading PairingStore through every observer signature.
    weak var pairingStoreRef: PairingStore?

    var hasPendingICloudReplies: Bool {
        !pendingICloudPlaceholders.isEmpty
    }

    static let nilQueueSessionKey = "__nativeagent_main_session__"

    func queueSessionKey(_ sessionID: String?) -> String {
        Self.cleanSessionID(sessionID) ?? Self.nilQueueSessionKey
    }

    var queuedSendsForSelectedSession: [QueuedChatSend] {
        let key = queueSessionKey(selectedSessionID)
        return queuedSends.filter {
            queueSessionKey($0.sessionID) == key && !inFlightSendIDs.contains($0.id.uuidString)
        }
    }

    var isSelectedQueuePaused: Bool {
        pausedQueueSessionKeys.contains(queueSessionKey(selectedSessionID))
    }

    // 2026-09-06: Mac snapshots cannot retire an unaccepted local handoff.
    var retainedSendMessageIDs: Set<UUID> {
        let key = queueSessionKey(selectedSessionID)
        return Set(queuedSends.filter { queueSessionKey($0.sessionID) == key }
            .flatMap { [$0.id, $0.placeholderID].compactMap { $0 } })
    }

    /// B2: bumped when a straggler reply lands after its bubble already timed
    /// out, so ChatView force-scrolls to it even if the user had scrolled away.
    @Published var scrollToBottomTick = 0
    func requestScrollToBottom() { scrollToBottomTick &+= 1 }

    /// True for an assistant bubble that timed out locally and can resume
    /// observing the original signed event. Drives the compact "Keep waiting"
    /// accessory; it never queues a second agent turn.
    func isTimedOut(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && !message.isStreaming
            && timedOutPendingIds.values.contains(message.id)
    }

    /// How long to wait for an iCloud reply before surfacing an error.
    /// 30s covers typical iCloud sync latency (1–10s) with comfortable margin.
    /// Tunable via DEBUG override in Settings if needed.
    let iCloudReplyTimeoutSeconds: UInt64
}
