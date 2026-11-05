import SwiftUI
import Observation
import UIKit
import NativeAgentShared

final class MobileLocalStorage: @unchecked Sendable {
    /// Missing is first use; an existing value must decode before any replacement.
    static func restore<Value: Decodable>(_ type: Value.Type, key: String, defaults: UserDefaults) throws -> Value? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard let data = raw as? Data else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Saved \(key) is not a data record."])
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func recordingURL(id: String, mime: String? = nil) throws -> URL {
        guard let id = UUID(uuidString: id) else { throw CocoaError(.fileReadInvalidFileName) }
        let ext = mime == "audio/mp4" || mime == "audio/x-m4a" ? "m4a" : "caf"
        return URL.applicationSupportDirectory.appendingPathComponent("chat/attachments/\(id.uuidString).\(ext)")
    }

    /// Keep the phone's playable copy as the same bytes travel to the Mac.
    static func retainRecording(_ attachment: MultimodalAttachment) throws -> URL {
        let url = try recordingURL(id: attachment.id, mime: attachment.mime)
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
                    let value = try Self.restore(type, key: key, defaults: defaults)
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
    /// Captured at acceptance; restoration never adopts the current peer.
    var pairingFingerprint: String
    /// Preserve replacement intent even if the app closes before preparation.
    var suppressRemoteUserAppend: Bool = false
    var replacementAssistantMessageID: UUID? = nil

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
    /// Snapshots, history and bridge updates share one projection so their writes reconcile at one owner.
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
    var showsReplyWaitHint = false
    var errorBanner: String?

    /// Dismiss only the rendered error; later transport/reply failures must remain visible.
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
    /// Persist all accepted sends with per-session admission bounds; a global cap could discard other sessions' paused queues.
    private let queuedSendsKey = "NativeAgentMobile.chatQueuedSends.v1"
    /// One app-owned store keeps queue restoration under one owner.
    let defaults: UserDefaults
    let storage: MobileLocalStorage
    /// An unreadable owner remains unavailable for this launch; projections and mutations must not overwrite its saved bytes.
    private(set) var storageErrors: [String: String] = [:]

    @discardableResult
    func admitChatMutation() -> Bool {
        guard restorationTask == nil else { return false }
        guard storageErrors.isEmpty else {
            errorBanner = storageErrors.values.sorted().joined(separator: "\n")
            return false
        }
        return true
    }

    private func persistQueuedSends() {
        guard storageErrors[queuedSendsKey] == nil else { return }
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
        guard admitChatMutation() else {
            throw DeviceSyncError.underlying(message: "Saved chat is unavailable; its original bytes are retained.")
        }
        guard queuedSends.contains(where: { $0.id == id }) else {
            throw DeviceSyncError.underlying(message: "Queued send is no longer available")
        }
        persistQueuedSends()
        try await storage.flush()
    }
    var pausedQueueSessionKeys: Set<String> = [] {
        didSet { persistPausedQueueSessionKeys() }
    }
    /// Transport recovery can resume transport failures; user pauses survive recovery and relaunch.
    var transportPausedQueueSessionKeys: Set<String> = []
    private let pausedQueueSessionKeysKey = "NativeAgentMobile.chatPausedQueueSessions.v1"

    private func persistPausedQueueSessionKeys() {
        if pausedQueueSessionKeys.isEmpty {
            defaults.removeObject(forKey: pausedQueueSessionKeysKey)
            return
        }
        defaults.set(Array(pausedQueueSessionKeys), forKey: pausedQueueSessionKeysKey)
    }
    var maxDeltaSeqByCorrelation: [String: Int] = [:]
    private(set) var selectedSessionID: String?
    var mainSessionID: String? { iCloudSyncEngine.shared.chatAnchor?.cleanSessionId }
    /// Phone-created main stays authoritative until the Mac publishes its exact ID; lagging snapshots must not redirect a send.
    private(set) var locallyCreatedSessionID: String?

    private static let locallyCreatedSessionIDKey = "NativeAgentMobile.locallyCreatedChatSessionID"
    /// The switch generation prevents a late cancelled history read from releasing a newer composer's lock.
    var sessionSwitchGeneration: UInt64 = 0
    var sessionSwitchTask: Task<Void, Never>?
    @ObservationIgnored var restorationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = MobileLocalStorage(defaults: defaults)
        // Launch follows main; history selection requires an explicit action in this launch.
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
            catch {
                let message = "Saved chat queue is unavailable: \(error.localizedDescription). Its bytes are retained; repair saved chat before submitting."
                storageErrors[queuedSendsKey] = message
                failures.append(message)
            }
            do {
                let exchanges = try await storage.read([ChatPendingExchange].self, key: Self.pendingExchangesKey) ?? []
                guard Set(exchanges.map(\.correlationID)).count == exchanges.count else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Saved chat has repeated request identities."])
                }
                pendingExchanges = Dictionary(uniqueKeysWithValues: exchanges.map { ($0.correlationID, $0) })
            } catch {
                let message = "Saved pending chat is unavailable: \(error.localizedDescription). Its bytes are retained; repair saved chat before submitting."
                storageErrors[Self.pendingExchangesKey] = message
                failures.append(message)
            }
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

    /// Deliver reply text through the surface callback so the store does not need AVFoundation.
    var onReply: ((String, String?) -> Void)?
    var onTalkReply: ((String, String, Bool, String?) -> Void)?
    var onTalkRunRenamed: ((String, String) -> Void)?
    var onTalkSessionChange: (() -> Void)?
    @ObservationIgnored var replyObserverID: UUID?
    @ObservationIgnored var rejectionObserverID: UUID?
    @ObservationIgnored var resyncObserverID: UUID?

    /// End dictation at the microphone-owning surface on every session change.
    var onSessionChange: (() -> Void)?

    var pendingICloudPlaceholders: [String: UUID] = [:]
    /// Locally minted send IDs keep Stop scoped while transport is awaiting acceptance.
    var inFlightSendIDs: Set<String> = []
    var pendingTimeouts: [String: Task<Void, Never>] = [:]
    var replyStatusTask: Task<Void, Never>?
    var sendTask: Task<Void, Never>?
    var timedOutPendingIds: [String: UUID] = [:]
    /// Retain steered queue entries until the Mac evidences reading them or gives them back.
    var steeringQueuedIDs: Set<UUID> = []
    var resolvedICloudReplyIds: Set<String> = []
    var macPublishedMessageIDs: Set<UUID> { iCloudSyncEngine.shared.chatTranscripts[transcriptSessionKey]?.publishedIDs ?? [] }
    var liveTurnBubbles: [String: UUID] = [:]
    var isLoadingHistory = false
    var historyExhaustedSessionIDs: Set<String> = []
    var pagedSessionsWithOlder: Set<String> = []
    static weak var visibleStore: ChatStore?

    static let snapshotTruncationMarker = "[truncated for iPhone snapshot]"

    /// Throttle refresh attempts for two seconds, including attempts still in progress.
    var lastRefreshAt: Date = .distantPast

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
                && (pendingExchanges[$0.id.uuidString]?.deliveryConfirmationDeadline == nil
                    || pendingExchanges[$0.id.uuidString]?.deliveryUnconfirmed == true)
                && !(pendingExchanges[$0.id.uuidString]?.deliveryUnconfirmed == true && $0.preparedMessage == nil)
        }
    }

    func canDeliverQueuedSend(_ queued: QueuedChatSend) -> Bool {
        queued.pairingFingerprint == AgentNameCache.fingerprint(pendingRetryClient?.pairingStore?.iCloudPairingSecret)
    }

    var isSelectedQueuePaused: Bool {
        let key = queueSessionKey(selectedSessionID)
        return pausedQueueSessionKeys.contains(key) || transportPausedQueueSessionKeys.contains(key)
    }

    /// A signed expiry keeps the request available for "Send now".
    func isExpiredRequest(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && !message.isStreaming
            && expiredExchange(for: message.id) != nil
    }


    /// Silence releases the composer while observation of the same request continues.
    let iCloudReplyTimeoutSeconds: UInt64 = 180
}
