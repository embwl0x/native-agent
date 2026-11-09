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

// Blueprint: | `MacSyncEngine.swift` | Snapshot/inbox lifecycle state; durable scoped Stop and active phone turns. |

// MARK: - MacSyncEngine

@MainActor
public final class MacSyncEngine: ObservableObject {
    unowned let sync: DeviceSync

    @Published public internal(set) var isActive = false
    @Published public internal(set) var lastSnapshotAt: Date?
    @Published public internal(set) var lastInboxAt: Date?
    @Published public var syncError: String? {
        didSet { if oldValue != syncError { sync.bridge.refreshPhoneConnection() } }
    }

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
    /// Resident-state events own normal phone updates; exact files and launch/repair reconciliation protect integrity.
    var cognitionSnapshotObservationTask: Task<Void, Never>?
    var helpersSnapshotWatcher: FileChangeWatcher?
    var workActivityObservationTask: Task<Void, Never>?
    var workActivityPublicationTask: Task<Void, Never>?
    var liveTurnRelayTask: Task<Void, Never>?
    /// Coalesce completion fan-out into one transcript pass without polling or rebuilding for each notification.
    var chatTurnCompletedObserver: NSObjectProtocol?
    /// Transcript rewrites outside turns feed the same snapshot coalescer as turn completions.
    var chatTranscriptDidChangeObserver: NSObjectProtocol?
    var pageFacePublishedObserver: NSObjectProtocol?
    var turnSessionsFacePublishedObserver: NSObjectProtocol?
    var pruneDeadlineTask: Task<Void, Never>?
    var archiveRetentionWatcher: FileChangeWatcher?
    var connectorsSnapshotWatcher: FileChangeWatcher?
    var connectorHealthState: JSONValue?
    var activeDocsURL: URL?
    var snapshotWriteInFlight = false
    var snapshotWriteQueuedScope: SnapshotWriteScope?
    var snapshotWriteQueuedNeedsHeavy = false
    var snapshotWriteQueuedNeedsRepublish = false
    var snapshotWriteQueuedRepairs: Set<String> = []
    var snapshotWriteQueuedNeedsMemories = false
    var snapshotWriteQueuedNeedsChatTranscripts = false
    /// Generation fences stop late passes from publishing into a restarted cache or container.
    var snapshotLifecycleGeneration: UInt64 = 0
    /// Retained through accepted action settlement; stop closes the next admission.
    var inboxProcessingTask: Task<Void, Never>?
    var inboxProcessingQueued = false
    var snapshotFileDigests: [String: SnapshotFileDigest] = [:]
    // Maintain insertion order so oldest are evicted first.
    var processedMsgIds: Set<String> = []
    var processedMsgIdsOrdered: [String] = []

    // Phone Stop cancels the registered task; the turn also reads its disk cancel flag.
    public enum MacSyncChatCancelOutcome: String, Equatable {
        case cancelled
        case runMismatch
        case noActiveTask
    }

    /// One phone message's outcome; `readBy` names the agent's turn in progress when that turn read it instead.
    public typealias ICloudChatOutcome = (text: String, deltaSeq: Int, error: String?, toolEvents: Int,
        attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?, readBy: String?)

    /// The turn's iOS correlation ID binds scoped Stop to its task within the session.
    struct ActiveChatTask {
        let task: Task<ICloudChatOutcome, Never>
        let runID: String?
    }

    var activeChatTasks: [String: ActiveChatTask] = [:]
    // Passive stop keeps accepted turns registered until settlement; only explicit remote Stop cancels them.

    public func registerActiveChatTask(
        _ task: Task<ICloudChatOutcome, Never>,
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
        expecting task: Task<ICloudChatOutcome, Never>
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

    /// The phone's Steers still waiting for the agent's turn, by conversation and run: Stop there settles them as stopped.
    var waitingSteers: [String: [String: @Sendable () -> Void]] = [:]

    /// Stop only the caller's named runs; a different run occupying the session must remain untouched.
    /// A Stop in the conversation also stops the phone's Steers still waiting there, so none is sent again after it.
    public func cancelActiveChatTask(for sessionID: String, runIDs: [String] = []) -> MacSyncChatCancelOutcome {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noActiveTask }
        for stop in (waitingSteers.removeValue(forKey: trimmed) ?? [:]).values { stop() }
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
