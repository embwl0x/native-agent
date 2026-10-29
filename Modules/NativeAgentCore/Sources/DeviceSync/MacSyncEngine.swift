import CommonCrypto
import CognitiveSubstrate
import CryptoKit
import AppKit
import Cognition
import Foundation
import Combine
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore

// Blueprint: | `MacSyncEngine.swift` | Mac snapshot/inbox state, active chat tasks and stop bookkeeping; chat snapshots add read-only other-room exchanges beside canonical messages |

// MARK: - MacSyncEngine

@MainActor
public final class MacSyncEngine: ObservableObject {
    unowned let sync: DeviceSync

    @Published public internal(set) var isActive = false
    @Published public internal(set) var lastSnapshotAt: Date?
    @Published public internal(set) var lastInboxAt: Date?
    @Published public var syncError: String?

    var snapshotDir: URL?
    var inboxDir: URL?
    var responsesDir: URL?
    var transactionDir: URL?
    var inboxQuery: NSMetadataQuery?
    /// Slow missed-event integrity fallback. Normal snapshot writes are driven
    /// by app/store mutation seams; unchanged passes write nothing and make no
    /// provider calls.
    var snapshotIntegrityTask: Task<Void, Never>?
    var snapshotIntegrityWatcher: FileChangeWatcher?
    var snapshotIntegrityReconcileTask: Task<Void, Never>?
    var snapshotIntegrityReconcileQueued = false
    var snapshotIntegrityRetryRequested = false
    var snapshotIntegrityObservedSkips: [String: String]?
    /// The engine owns protocol state; BackgroundLoops owns the beat deadline.
    var presenceBeatRegistrationTask: Task<Void, Never>?
    var presenceBeatRegistrationID = UUID()
    var presenceBeatEvents: AsyncStream<Void>.Continuation?
    var presenceBeatDue: Date?
    var presenceBeatDelay = NAMacPresence.beat
    /// Payload-free resident-state subscription. This closes the normal
    /// cognition/organism -> iOS snapshot path without shortening the slow
    /// integrity fallback or adding a polling loop.
    var cognitionSnapshotObservationTask: Task<Void, Never>?
    var helpersSnapshotWatcher: FileChangeWatcher?
    var workActivityObservationTask: Task<Void, Never>?
    var workActivityPublicationTask: Task<Void, Never>?
    var workActivities: [String: MobileWorkActivity] = [:]
    /// Relays turns another door started in the anchored conversation.
    var liveTurnRelayTask: Task<Void, Never>?
    /// Existing chat completion notifications drive one bounded transcript
    /// projection pass. The short coalescer absorbs completion fan-out (for
    /// example a bridge delivery plus its local refresh) without polling or
    /// rebuilding the transcript for every notification.
    var chatTurnCompletedObserver: NSObjectProtocol?
    /// Transcript rewrites outside turns feed the same snapshot coalescer as turn completions.
    var chatTranscriptDidChangeObserver: NSObjectProtocol?
    var chatTranscriptSnapshotPublicationTask: Task<Void, Never>?
    var chatSnapshotCoalescer = MacSyncChatSnapshotCoalescerState()
    /// One exact archive-retention crossing, recalculated after each prune.
    var pruneDeadlineTask: Task<Void, Never>?
    var archiveRetentionRetryAfter: Date?
    var archiveRetentionWatcher: FileChangeWatcher?
    var schedulerSnapshotWatcher: FileChangeWatcher?
    var connectorsSnapshotWatcher: FileChangeWatcher?
    var connectorHealthState: JSONValue?
    var activeDocsURL: URL?
    var snapshotWriteInFlight = false
    var snapshotWriteQueuedScope: SnapshotWriteScope?
    var snapshotWriteQueuedNeedsHeavy = false
    var snapshotWriteQueuedNeedsRepublish = false
    var snapshotWriteQueuedNeedsMemories = false
    var snapshotWriteQueuedNeedsChatTranscripts = false
    /// Invalidates any snapshot pass suspended across stop/restart. A late pass
    /// must never publish into a newly selected cache/container generation.
    var snapshotLifecycleGeneration: UInt64 = 0
    /// Retained through accepted action settlement; stop closes the next admission.
    var inboxProcessingTask: Task<Void, Never>?
    var inboxProcessingQueued = false
    var snapshotFileDigests: [String: SnapshotFileDigest] = [:]
    // Maintain insertion order so oldest are evicted first.
    var processedMsgIds: Set<String> = []
    var processedMsgIdsOrdered: [String] = []

    // Phone Stop cancels the registered task; the turn also reads its disk cancel flag.
    /// What a remote Stop actually did to the session's in-flight chat task.
    public enum MacSyncChatCancelOutcome: String, Equatable {
        case cancelled
        /// Leave the current run and disk markers untouched; retain Stop for the named run's registration.
        case runMismatch
        /// Hold an early scoped Stop until its run registers, without writing a session cancel marker.
        case stopRecorded
        case noActiveTask
    }

    /// The turn's iOS correlation ID binds scoped Stop to its task within the session.
    struct ActiveChatTask {
        let task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int, attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?), Never>
        let runID: String?
    }

    var activeChatTasks: [String: ActiveChatTask] = [:]
    // Stopping passive sync deliberately leaves these accepted human turns
    // registered until their forwarder settles and unregisters the exact task.
    // Remote Stop remains the separate explicit cancellation path.

    /// Early Stops are keyed by session and run, consumed at registration, and bounded by TTL and cap.
    var stopRequestedChatRuns: [String: Date] = [:]
    static let stopRequestedRunTTL: TimeInterval = 300
    static let stopRequestedRunCap = 64

    private static func stopRequestKey(session: String, runID: String) -> String {
        "\(session)\u{1}\(runID)"
    }

    private func pruneStopRequestedChatRuns(now: Date = Date()) {
        stopRequestedChatRuns = stopRequestedChatRuns.filter { $0.value > now }
        guard stopRequestedChatRuns.count > Self.stopRequestedRunCap else { return }
        // Oldest deadline first; a run that never registers is the only way to
        // get here and dropping the stalest one is the right eviction.
        let doomed = stopRequestedChatRuns
            .sorted { $0.value < $1.value }
            .prefix(stopRequestedChatRuns.count - Self.stopRequestedRunCap)
        for entry in doomed { stopRequestedChatRuns.removeValue(forKey: entry.key) }
    }

    func recordStopRequestedChatRuns(for sessionID: String, runIDs: [String]) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !runIDs.isEmpty else { return }
        let deadline = Date().addingTimeInterval(Self.stopRequestedRunTTL)
        for runID in runIDs where !runID.isEmpty {
            stopRequestedChatRuns[Self.stopRequestKey(session: trimmed, runID: runID)] = deadline
        }
        pruneStopRequestedChatRuns()
    }

    /// True exactly once per recorded (session, run): a Stop was already asked
    /// for and this run is it.
    func consumeStopRequestedChatRun(for sessionID: String, runID: String?) -> Bool {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let runID, !runID.isEmpty else { return false }
        pruneStopRequestedChatRuns()
        return stopRequestedChatRuns
            .removeValue(forKey: Self.stopRequestKey(session: trimmed, runID: runID)) != nil
    }

    public func registerActiveChatTask(
        _ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int, attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?), Never>,
        for sessionID: String,
        runID: String? = nil
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed] {
            existing.task.cancel()
        }
        activeChatTasks[trimmed] = ActiveChatTask(task: task, runID: runID)
        // Registration honors any Stop already recorded for this exact run.
        if consumeStopRequestedChatRun(for: trimmed, runID: runID) {
            task.cancel()
        }
    }

    public func unregisterActiveChatTask(
        for sessionID: String,
        expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int, attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?), Never>
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed], existing.task == task {
            activeChatTasks.removeValue(forKey: trimmed)
        }
    }

    public func activeChatRunID(for sessionID: String) -> String? {
        activeChatTasks[sessionID]?.runID
    }

    /// Cancel the session's in-flight chat task. `runIDs` are the runs the
    /// caller believes it is stopping; when they name a run that is NOT the one
    /// holding the session, nothing is cancelled and the caller is told so —
    /// the stopped turn is already over and the current one is somebody else's.
    public func cancelActiveChatTask(for sessionID: String, runIDs: [String] = []) -> MacSyncChatCancelOutcome {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noActiveTask }
        guard let entry = activeChatTasks[trimmed] else {
            // Retain a named Stop until registration; turn acceptance clears unscoped disk markers.
            guard !runIDs.isEmpty else { return .noActiveTask }
            recordStopRequestedChatRuns(for: trimmed, runIDs: runIDs)
            return .stopRecorded
        }
        if !runIDs.isEmpty, let runID = entry.runID, !runIDs.contains(runID) {
            // Hold Stop for the named run's registration while leaving the current run untouched.
            recordStopRequestedChatRuns(for: trimmed, runIDs: runIDs)
            return .runMismatch
        }
        entry.task.cancel()
        return .cancelled
    }

    let processedIdsCap = 5000
    var _pairingSecret: Data?
    var pairingSecretRotationInProgress = false
    enum KVSKey {
        static let snapshotUpdated = "snapshot_updated"
        static let inboxPending = "inbox_pending"
    }

    init(sync: DeviceSync) {
        self.sync = sync
    }

    enum Folder {
        static let snapshots = "snapshots"
        static let inbox = "inbox"
        static let inboxRejected = "inbox/_rejected"
        static let responses = "responses"
        static let transactions = "transactions/mac"
    }

    let inboxResponseKeyPrefix = ICloudKVSProgressWriteAdmission.inboxResponseKeyPrefix
    let inboxResponseKeyTTL: TimeInterval = 24 * 3600
    /// Backstop ceiling kept well below the hard 1024-key KVS quota.
    let inboxResponseKeyMaxCount = ICloudKVSProgressWriteAdmission.inboxResponseKeyCeiling
}
