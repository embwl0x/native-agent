import SwiftUI
import Observation
import UIKit
import NativeAgentShared

enum ChatSendDisposition: Equatable {
    case started
    case queued(UUID)
    case rejected
}

/// Local payloads share one serial IO owner; callers retain their existing keys.
final class MobileLocalStorage: @unchecked Sendable {
    static func recordingURL(id: String) throws -> URL {
        guard let id = UUID(uuidString: id) else { throw CocoaError(.fileReadInvalidFileName) }
        return URL.applicationSupportDirectory.appendingPathComponent("chat/attachments/\(id.uuidString).caf")
    }

    /// Audio stays on this phone, independently of the Mac transcript.
    static func retainRecording(_ attachment: MultimodalAttachment) throws -> URL {
        let url = try recordingURL(id: attachment.id)
        guard let bytes = Data(base64Encoded: attachment.base64), !bytes.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "nativeagent.mobile.defaults", qos: .utility)
    private var errors: [String: Error] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private let lock = NSLock()
    private var writes: [String: @Sendable () -> Void] = [:]

    private func submit(key: String, operation: @escaping @Sendable () -> Void) {
        lock.lock()
        let scheduled = writes[key] != nil
        writes[key] = operation
        lock.unlock()
        guard !scheduled else { return }
        queue.async { [self] in
            lock.lock()
            let write = writes.removeValue(forKey: key)
            lock.unlock()
            write?()
        }
    }

    func save<Value: Encodable & Sendable>(key: String, value: @escaping @Sendable () -> Value,
                                         onError: @escaping @Sendable (Error) -> Void) {
        submit(key: key) { [self] in
            do {
                let payload = value()
                defaults.set(try JSONEncoder().encode(payload), forKey: key)
                errors[key] = nil
            } catch { errors[key] = error; onError(error) }
        }
    }

    func remove(key: String) {
        submit(key: key) { [self] in defaults.removeObject(forKey: key); errors[key] = nil }
    }

    @MainActor func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if let error = errors.values.first { throw error }
                    guard defaults.synchronize() else { throw DeviceSyncError.underlying(message: "Could not save queued send") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor func checkpoint<Value: Encodable & Sendable>(_ value: Value, to file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor func read<Value: Decodable & Sendable>(_ type: Value.Type, key: String) async throws -> Value? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let value = try defaults.data(forKey: key).map { try JSONDecoder().decode(type, from: $0) }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct QueuedChatSend: Identifiable, Codable, Sendable {
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
    var userMessageID: UUID? = nil

    var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }
}

// MARK: - Store

@MainActor
@Observable
final class ChatStore {
    /// The scene and cold App Intents must settle the same durable exchanges.
    static let shared = ChatStore()
    /// Snapshots, history pages and bridge updates all write this shared projection.
    var messages: [ChatMessage] {
        get { iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.messages ?? [] }
        set {
            var transcript = iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]
                ?? .init(records: [], messages: [], generation: nil)
            transcript.messages = newValue
            iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey] = transcript
        }
    }
    var transcriptSessionKey: String { selectedSessionID ?? Self.nilQueueSessionKey }
    var isLoading = false {
        didSet {
            if !isLoading { loadingPlaceholderID = nil }
            if oldValue && !isLoading {
                scheduleQueuedSendDrain()
            }
        }
    }
    var loadingPlaceholderID: UUID?

    func releaseLoading(for placeholderID: UUID) {
        guard loadingPlaceholderID == placeholderID else { return }
        isLoading = false
    }
    var isSwitchingSession = false
    var isPollingFallback = false   // true after 10s waiting — drives "still waiting…" hint
    var errorBanner: String?
    /// Signature rejections already shown once (see receiveICloudRejection).
    var surfacedSignatureRejectionIDs: Set<String> = []

    /// Dismisses only the currently rendered error. Future transport or reply
    /// failures assign a new value to `errorBanner` and must remain visible.
    func dismissErrorBanner() {
        errorBanner = nil
    }
    var streamingHintsByMessageId: [UUID: String] = [:]
    /// 2026-09-13: unfinished exchanges, by correlation. Durable so closing the
    /// app (or opening another conversation) does not erase the fact that a
    /// request is still outstanding. Observation state only — never a resend
    /// queue; see ChatStore+PendingExchanges.swift.
    var pendingExchanges: [String: ChatPendingExchange] = [:] {
        didSet { persistPendingExchanges() }
    }
    static let pendingExchangesKey = "NativeAgentMobile.chatPendingExchanges.v1"
    var sharedInboxControls: ChatRuntimeControls?
    @ObservationIgnored var sharedInboxReadTask: Task<(items: [(URL, SharedChatItem)], errors: [String]), Error>?
    @ObservationIgnored var sharedInboxImportTask: Task<Void, Never>?
    var queuedSends: [QueuedChatSend] = [] {
        didSet {
            persistQueuedSends()
            if queuedSends.count < oldValue.count { scheduleSharedInboxRetry() }
        }
    }
    /// Persist every accepted send. Admission is bounded per session; a global
    /// persistence cap would silently discard other sessions' paused queues.
    private let queuedSendsKey = "NativeAgentMobile.chatQueuedSends.v1"
    /// Production has one app-owned store, so queue restoration has one owner.
    /// Tests inject an isolated defaults suite and may opt out of restoration.
    let defaults: UserDefaults
    let storage: MobileLocalStorage

    private func persistQueuedSends() {
        if queuedSends.isEmpty {
            storage.remove(key: queuedSendsKey)
            return
        }
        let rows = queuedSends
        storage.save(key: queuedSendsKey, value: { rows }) { [weak self] error in
            Task { @MainActor in self?.errorBanner = "Queued chat could not be saved: \(error.localizedDescription)" }
        }
    }

    func checkpointQueuedSend(_ id: UUID) async throws {
        guard queuedSends.contains(where: { $0.id == id }) else {
            throw DeviceSyncError.underlying(message: "Queued send is no longer available")
        }
        persistQueuedSends()
        try await storage.flush()
    }
    var pausedQueueSessionKeys: Set<String> = [] {
        didSet { persistPausedQueueSessionKeys() }
    }
    /// Transport failures wait for recovery; user pauses survive it and launch.
    var transportPausedQueueSessionKeys: Set<String> = []
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
    // The Mac side writes batched text_delta BridgeMessages every ~1s during
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
    private(set) var selectedSessionID: String?
    var mainSessionID: String? { iCloudSyncEngine.shared.chatAnchor?.cleanSessionId }
    /// A phone-created main session remains locally authoritative until the
    /// Mac publishes that exact identity. Session-list snapshots can lag the
    /// first send, so treating absence as removal can otherwise roll the UI
    /// back to the previous main chat and stamp the send with the wrong id.
    private(set) var locallyCreatedSessionID: String?

    // PATCH-2026-05-11: unified-session-v1 — drop stale iOS-only session ID on first launch
    // so the Mac app resolves to the shared mobile session via sourceKey.
    private static let selectedSessionIDKey = "NativeAgentMobile.chatSessionID"
    private static let locallyCreatedSessionIDKey = "NativeAgentMobile.locallyCreatedChatSessionID"
    /// One session switch owns the composer lock. The generation prevents a
    /// cancelled/late history read from releasing a newer switch.
    var sessionSwitchGeneration: UInt64 = 0
    var sessionSwitchTask: Task<Void, Never>?
    @ObservationIgnored var restorationTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        restoreQueuedSends: Bool = true,
        iCloudReplyTimeoutSeconds: UInt64 = 180
    ) {
        self.defaults = defaults
        storage = MobileLocalStorage(defaults: defaults)
        self.iCloudReplyTimeoutSeconds = iCloudReplyTimeoutSeconds
        if !defaults.bool(forKey: "NativeAgent.unifiedSession.v1") {
            defaults.removeObject(forKey: Self.selectedSessionIDKey)
            defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
        }
        // A launch opens main. History is only selected by an explicit action
        // in this launch, never by restoring yesterday's open history thread.
        let savedSelected: String? = nil
        let savedLocal = Self.cleanSessionID(defaults.string(forKey: Self.locallyCreatedSessionIDKey))
        selectedSessionID = savedSelected
        locallyCreatedSessionID = savedLocal
        if restoreQueuedSends, let restoredPaused = defaults.array(forKey: pausedQueueSessionKeysKey) as? [String] {
            pausedQueueSessionKeys = Set(restoredPaused)
        }
        isSwitchingSession = true
        restorationTask = Task { [self] in
            defer {
                restorationTask = nil
                if sessionSwitchGeneration == 0 { isSwitchingSession = false }
                scheduleSharedInboxRetry()
                scheduleQueuedSendDrain()
            }
            var failures: [String] = []
            if restoreQueuedSends {
                do { queuedSends = try await storage.read([QueuedChatSend].self, key: queuedSendsKey) ?? [] }
                catch { failures.append(error.localizedDescription) }
                do {
                    let exchanges = try await storage.read([ChatPendingExchange].self, key: Self.pendingExchangesKey) ?? []
                    pendingExchanges = Dictionary(exchanges.map { ($0.correlationID, $0) }, uniquingKeysWith: { _, newer in newer })
                } catch { failures.append(error.localizedDescription) }
            }
            guard sessionSwitchGeneration == 0 else { return }
            restorePendingExchanges(for: savedSelected)
            if !failures.isEmpty { errorBanner = "Chat could not be restored: " + failures.joined(separator: "\n") }
        }
    }

    nonisolated static func cleanSessionID(_ value: String?) -> String? {
        let clean = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    func setSelectedSessionID(_ value: String?) {
        let clean = Self.cleanSessionID(value)
        if clean != selectedSessionID { historyExhaustedSessionIDs.removeAll() }
        selectedSessionID = clean
        if let clean {
            defaults.set(clean, forKey: Self.selectedSessionIDKey)
        } else {
            defaults.removeObject(forKey: Self.selectedSessionIDKey)
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
    var timedOutPendingIds: [String: UUID] = [:]
    /// Queued messages the Mac's working turn has been offered (Steer): the
    /// queue holds them until the Mac says the turn read them or gave them back.
    var steeringQueuedIDs: Set<UUID> = []
    /// Requests the Mac signed a refusal for because they aged out unread:
    /// proven never started, so their retained text may be sent again — and
    /// only ever by the person, through `sendNow` (2026-09-13).
    var expiredPendingIds: [String: UUID] = [:]
    var resolvedICloudReplyIds: Set<String> = []
    var macPublishedMessageIDs: Set<UUID> {
        Set(iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.records.compactMap { UUID(uuidString: $0.id) } ?? [])
    }
    /// 2026-09-06: assistant ids removed locally for a regenerate. They are
    /// deliberately absent until the Mac's replacement lands, which is exactly
    /// the shape snapshot reply selection reads as "the awaited
    /// reply" — a stale snapshot would otherwise complete the regeneration
    /// with the answer being replaced.
    var regeneratedAwayAssistantIDs: Set<UUID> {
        get { iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.regeneratedAwayIDs ?? [] }
        set {
            guard var transcript = iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey] else { return }
            transcript.regeneratedAwayIDs = newValue
            iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey] = transcript
        }
    }
    /// Turns another door started in this conversation, by run id, and the
    /// bubble each one streams into (`receiveLiveTurn`).
    var liveTurnBubbles: [String: UUID] = [:]
    /// Mac history rows retained in the shared transcript beyond its snapshot window.
    var pagedHistoryIDs: Set<UUID> {
        iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.historyIDs ?? []
    }
    var isLoadingHistory = false
    var historyExhaustedSessionIDs: Set<String> = []
    /// Sessions opened from a Mac page (no published transcript) whose page
    /// said there is more before it.
    var pagedSessionsWithOlder: Set<String> = []
    /// 2026-09-06: the store the visible chat is bound to, so the notification
    /// delegate can tell a reply the user is already reading from one worth
    /// alerting about. Nil whenever no chat surface is on screen.
    static weak var visibleStore: ChatStore?

    static let snapshotTruncationMarker = "[truncated for iPhone snapshot]"

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
        let key = queueSessionKey(selectedSessionID)
        return pausedQueueSessionKeys.contains(key) || transportPausedQueueSessionKeys.contains(key)
    }

    // 2026-09-06: Mac snapshots cannot retire an unaccepted local handoff.
    var retainedSendMessageIDs: Set<UUID> {
        let key = queueSessionKey(selectedSessionID)
        return Set(queuedSends.filter { queueSessionKey($0.sessionID) == key }
            .flatMap { [$0.id, $0.placeholderID, $0.userMessageID].compactMap { $0 } })
    }

    /// B2: bumped when a straggler reply lands after its bubble already timed
    /// out, so ChatView force-scrolls to it even if the user had scrolled away.
    var scrollToBottomTick = 0
    func requestScrollToBottom() { scrollToBottomTick &+= 1 }

    /// True for an assistant bubble that was retired locally and can resume
    /// observing the original signed event. Since 2026-09-13 a local timeout no
    /// longer produces one of these — waiting simply continues — so this only
    /// names bubbles retired by other paths. It never queues a second turn.
    /// A bubble whose request the Mac refused as expired: it shows "Send now"
    /// instead of a retry that would only resume observing nothing.
    func isExpiredRequest(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && !message.isStreaming
            && expiredPendingIds.values.contains(message.id)
    }

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
