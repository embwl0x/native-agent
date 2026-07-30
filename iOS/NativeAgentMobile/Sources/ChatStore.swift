// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
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

    var preview: String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return attachments.count == 1 ? "One attachment" : "\(attachments.count) attachments"
    }
}

// MARK: - Store

@MainActor
final class ChatStore: ObservableObject {
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
    @Published var streamingHintsByMessageId: [UUID: String] = [:]
    @Published var queuedSends: [QueuedChatSend] = [] {
        didSet { persistQueuedSends() }
    }
    /// 2026-07-21 audit fix: queued sends were in-memory only — a relaunch
    /// silently discarded user-composed messages. Persist alongside the
    /// transcript keys, hard-capped (queue is at most maxPerSession per
    /// session, but cap the on-disk copy too).
    private let queuedSendsKey = "NativeAgentMobile.chatQueuedSends.v1"
    private let maxPersistedQueuedSends = 60
    /// Restore runs ONCE per process: production relaunch = new process = one
    /// restore. Multiple in-process instances (tests) must not each restore —
    /// the persisted queue would duplicate into every instance (the full
    /// script/test.sh iOS gate caught exactly that: [first, second] became
    /// [first, second, first, second]).
    private static var didRestoreQueuedSendsThisProcess = false

    private func persistQueuedSends() {
        let trimmed = Array(queuedSends.suffix(maxPersistedQueuedSends))
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: queuedSendsKey)
            return
        }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: queuedSendsKey)
        }
    }
    @Published var pausedQueueSessionKeys: Set<String> = []
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

    // PATCH-2026-05-11: unified-session-v1 — drop stale iOS-only session ID on first launch
    // so the Mac app resolves to the shared mobile session via sourceKey.
    private static let selectedSessionIDKey = "NativeAgentMobile.chatSessionID"
    private static let mainSessionIDKey = "NativeAgentMobile.mainChatSessionID"
    let transcriptKey = "NativeAgentMobile.chatMessages"
    let transcriptPrefix = "NativeAgentMobile.chatMessages.session."
    var suppressMessagePersistence = false

    init() {
        if !UserDefaults.standard.bool(forKey: "NativeAgent.unifiedSession.v1") {
            UserDefaults.standard.removeObject(forKey: Self.selectedSessionIDKey)
            UserDefaults.standard.removeObject(forKey: Self.mainSessionIDKey)
            UserDefaults.standard.set(true, forKey: "NativeAgent.unifiedSession.v1")
        }
        let savedSelected = Self.cleanSessionID(UserDefaults.standard.string(forKey: Self.selectedSessionIDKey))
        let savedMain = Self.cleanSessionID(UserDefaults.standard.string(forKey: Self.mainSessionIDKey)) ?? savedSelected
        selectedSessionID = savedSelected
        mainSessionID = savedMain
        // 2026-07-21 audit fix: restore persisted queued sends (were in-memory
        // only; a relaunch silently discarded user-composed messages). Once
        // per process — see didRestoreQueuedSendsThisProcess.
        if !Self.didRestoreQueuedSendsThisProcess {
            Self.didRestoreQueuedSendsThisProcess = true
            if let queueData = UserDefaults.standard.data(forKey: queuedSendsKey),
               let restoredQueue = try? JSONDecoder().decode([QueuedChatSend].self, from: queueData) {
                queuedSends = restoredQueue
            }
        }
        if let savedMain, UserDefaults.standard.string(forKey: Self.mainSessionIDKey) == nil {
            UserDefaults.standard.set(savedMain, forKey: Self.mainSessionIDKey)
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
            UserDefaults.standard.set(clean, forKey: Self.selectedSessionIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSessionIDKey)
        }
    }

    func replaceMainSessionID(_ value: String?) {
        let clean = Self.cleanSessionID(value)
        mainSessionID = clean
        if let clean {
            UserDefaults.standard.set(clean, forKey: Self.mainSessionIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.mainSessionIDKey)
        }
    }

    func rememberMainSessionIDIfNeeded(_ value: String?) {
        guard mainSessionID == nil, let clean = Self.cleanSessionID(value) else { return }
        mainSessionID = clean
        UserDefaults.standard.set(clean, forKey: Self.mainSessionIDKey)
    }

    func adoptMainSessionIDIfNeeded(_ value: String?) {
        guard mainSessionID == nil, let clean = Self.cleanSessionID(value) else { return }
        mainSessionID = clean
        UserDefaults.standard.set(clean, forKey: Self.mainSessionIDKey)
    }

    func transcriptStorageKey(for sessionID: String?) -> String {
        guard let clean = Self.cleanSessionID(sessionID) else { return transcriptKey }
        return transcriptPrefix + clean
    }

    func loadCachedMessages(for sessionID: String?) -> [ChatMessage] {
        let keys = [transcriptStorageKey(for: sessionID), transcriptKey]
        for key in keys {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) else { continue }
            return saved.map { msg in
                var copy = msg
                copy.isStreaming = false
                return copy
            }
        }
        return []
    }

    /// Set by ChatView after init; called with each assistant reply text so
    /// VoiceOutputController can speak it without the store importing AVFoundation.
    var onReply: ((String) -> Void)?

    // N5 fix (R18): track placeholder indices by pending message ID so iCloud
    // replies can update the correct bubble when they arrive asynchronously.
    // MacBridgeClient is iCloud-only: sendMessage returns the sent message's ID; the reply arrives
    // via observeICloudReplies, which looks up and updates the placeholder here.
    var pendingICloudPlaceholders: [String: UUID] = [:]
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
    weak var pendingRetryClient: MacBridgeClient?
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
        return queuedSends.filter { queueSessionKey($0.sessionID) == key }
    }

    var isSelectedQueuePaused: Bool {
        pausedQueueSessionKeys.contains(queueSessionKey(selectedSessionID))
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
    let iCloudReplyTimeoutSeconds: UInt64 = 180
}
