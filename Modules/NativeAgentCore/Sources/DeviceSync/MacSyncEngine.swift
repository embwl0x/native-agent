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

// Blueprint: | `MacSyncEngine.swift` | Mac snapshot/inbox state, pairing write/verification phase and active chat tasks; scoped Stop is retained by the durable chat admission ledger; chat snapshots add read-only other-room exchanges beside canonical messages |

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
    /// Exact snapshot-file observation; app/store mutations own normal writes.
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
    /// cognition/organism -> iOS snapshot path; exact file observations and
    /// explicit launch/repair reconciliation cover integrity.
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
        /// Leave the current run and disk markers untouched.
        case runMismatch
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
            // The action router durably retained this named Stop before task cancellation.
            guard !runIDs.isEmpty else { return .noActiveTask }
            return .noActiveTask
        }
        if !runIDs.isEmpty, let runID = entry.runID, !runIDs.contains(runID) {
            // Leave the other run untouched; the router retained the named Stop.
            return .runMismatch
        }
        entry.task.cancel()
        return .cancelled
    }

    let processedIdsCap = 5000
    var _pairingSecret: Data?
    enum PairingSecretRotation: Equatable { case writing, awaitingVerification }
    var pairingSecretRotation: PairingSecretRotation?
    var pairingSecretRotationInProgress: Bool { pairingSecretRotation != nil }
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
