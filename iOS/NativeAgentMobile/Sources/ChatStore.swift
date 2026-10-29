import SwiftUI
import Observation
import UIKit
import NativeAgentShared

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
    /// Captured at acceptance. Missing legacy identities stay held for an
    /// explicit new submission; restoration never adopts the current peer.
    var pairingFingerprint: String? = nil

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
    /// ChatPendingExchange durably retains observation across launches and session switches, without resending.
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
    /// User pauses persist alongside the queue and survive relaunch.
    private let pausedQueueSessionKeysKey = "NativeAgentMobile.chatPausedQueueSessions.v1"

    private func persistPausedQueueSessionKeys() {
        if pausedQueueSessionKeys.isEmpty {
            defaults.removeObject(forKey: pausedQueueSessionKeysKey)
            return
        }
        defaults.set(Array(pausedQueueSessionKeys), forKey: pausedQueueSessionKeysKey)
    }
    // setStreamingText admits newer full-text sequences per correlation; receiveICloudReply drops resolved deltas.
    var maxDeltaSeqByCorrelation: [String: Int] = [:]
    private(set) var selectedSessionID: String?
    var mainSessionID: String? { iCloudSyncEngine.shared.chatAnchor?.cleanSessionId }
    /// A phone-created main session remains locally authoritative until the
    /// Mac publishes that exact identity. Session-list snapshots can lag the
    /// first send, so treating absence as removal can otherwise roll the UI
    /// back to the previous main chat and stamp the send with the wrong id.
    private(set) var locallyCreatedSessionID: String?

    private static let locallyCreatedSessionIDKey = "NativeAgentMobile.locallyCreatedChatSessionID"
    /// One session switch owns the composer lock. The generation prevents a
    /// cancelled/late history read from releasing a newer switch.
    var sessionSwitchGeneration: UInt64 = 0
    var sessionSwitchTask: Task<Void, Never>?
    @ObservationIgnored var restorationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = MobileLocalStorage(defaults: defaults)
        // A launch opens main. History is only selected by an explicit action
        // in this launch, never by restoring yesterday's open history thread.
        let savedLocal = Self.cleanSessionID(defaults.string(forKey: Self.locallyCreatedSessionIDKey))
        selectedSessionID = nil
        locallyCreatedSessionID = savedLocal
        if let restoredPaused = defaults.array(forKey: pausedQueueSessionKeysKey) as? [String] {
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
            do { queuedSends = try await storage.read([QueuedChatSend].self, key: queuedSendsKey) ?? [] }
            catch { failures.append(error.localizedDescription) }
            do {
                let exchanges = try await storage.read([ChatPendingExchange].self, key: Self.pendingExchangesKey) ?? []
                pendingExchanges = Dictionary(exchanges.map { ($0.correlationID, $0) }, uniquingKeysWith: { _, newer in newer })
            } catch { failures.append(error.localizedDescription) }
            guard sessionSwitchGeneration == 0 else { return }
            restorePendingExchanges(for: nil)
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

    /// The store calls once per session change; the microphone-owning surface ends dictation.
    var onSessionChange: (() -> Void)?

    // receiveICloudReply uses the pending correlation to update the existing placeholder.
    var pendingICloudPlaceholders: [String: UUID] = [:]
    /// Locally minted send IDs keep Stop scoped while transport is awaiting acceptance.
    var inFlightSendIDs: Set<String> = []
    // armTimeout owns a cancellable silence watchdog for each pending correlation.
    var pendingTimeouts: [String: Task<Void, Never>] = [:]
    var replyCatchUpTask: Task<Void, Never>?
    var sendTask: Task<Void, Never>?
    var timedOutPendingIds: [String: UUID] = [:]
    /// Queued messages the Mac's working turn has been offered (Steer): the
    /// queue holds them until the Mac says the turn read them or gave them back.
    var steeringQueuedIDs: Set<UUID> = []
    var resolvedICloudReplyIds: Set<String> = []
    var macPublishedMessageIDs: Set<UUID> { iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.publishedIDs ?? [] }
    /// Turns another door started in this conversation, by run id, and the
    /// bubble each one streams into (`receiveLiveTurn`).
    var liveTurnBubbles: [String: UUID] = [:]
    var isLoadingHistory = false
    var historyExhaustedSessionIDs: Set<String> = []
    /// Sessions opened from a Mac page (no published transcript) whose page
    /// said there is more before it.
    var pagedSessionsWithOlder: Set<String> = []
    /// ChatView registers its visible store for notification suppression and clears it on disappearance.
    static weak var visibleStore: ChatStore?

    static let snapshotTruncationMarker = "[truncated for iPhone snapshot]"

    /// Timestamp of the last successful (or in-progress) refresh attempt.
    /// Used as a throttle guard — skips if a refresh happened within 2 seconds.
    var lastRefreshAt: Date = .distantPast

    /// Throttle interval (seconds). Refreshes closer together than this are skipped.
    let refreshThrottleSeconds: TimeInterval = 2.0

    /// Weak client for queued sends; installing it schedules any drain already owed.
    weak var pendingRetryClient: MacBridgeClient? {
        didSet {
            guard pendingRetryClient !== oldValue, pendingRetryClient != nil else { return }
            scheduleQueuedSendDrain()
        }
    }

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
            (queueSessionKey($0.sessionID) == key || !canDeliverQueuedSend($0))
                && !inFlightSendIDs.contains($0.id.uuidString)
        }
    }

    func canDeliverQueuedSend(_ queued: QueuedChatSend) -> Bool {
        guard let pairing = queued.pairingFingerprint else { return false }
        return pairing == AgentNameCache.fingerprint(pendingRetryClient?.pairingStore?.iCloudPairingSecret)
    }

    var isSelectedQueuePaused: Bool {
        let key = queueSessionKey(selectedSessionID)
        return pausedQueueSessionKeys.contains(key) || transportPausedQueueSessionKeys.contains(key)
    }

    /// Late replies signal ChatView to scroll into view even when the person had scrolled away.
    var scrollToBottomTick = 0
    func requestScrollToBottom() { scrollToBottomTick &+= 1 }

    /// A signed expiry keeps the request available for "Send now".
    func isExpiredRequest(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && !message.isStreaming
            && expiredExchange(for: message.id) != nil
    }


    /// Silence releases the composer while observation of the same request continues.
    let iCloudReplyTimeoutSeconds: UInt64 = 180
}
