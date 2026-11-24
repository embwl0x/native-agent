import MindCore
import AppKit
import Foundation
import Combine
import NativeAgentShared
import NativeAgentCore
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
    var responsesDir: URL?
    var transactionDir: URL?
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
    var chatTurnCompletedObserver: NotificationCenter.ObservationToken?
    /// Transcript rewrites outside turns feed the same snapshot coalescer as turn completions.
    var chatTranscriptDidChangeObserver: NSObjectProtocol?
    var pageFacePublishedObserver: NotificationCenter.ObservationToken?
    var turnSessionsFacePublishedObserver: NSObjectProtocol?
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

    public enum ICloudChatOutcome: Sendable {
        case undispatched
        case steered(readBy: String)
        case ran(Result<ChatResponse, any Error>, partial: String)
    }

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

    public func chatRunIDsForControlHandoff(for sessionID: String) -> [String] {
        let active = activeChatTasks[sessionID]?.runID
        return (active.map { [$0] } ?? []) + Array(waitingSteers[sessionID, default: [:]].keys)
    }

    /// The phone's Steers still waiting for the agent's turn, by conversation and run: Stop there settles them as stopped.
    var waitingSteers: [String: [String: @Sendable () -> Void]] = [:]

    /// A scoped Stop names exact runs. A session-wide handoff cancels the active task and every waiting Steer.
    public func cancelActiveChatTask(for sessionID: String, runIDs: [String] = []) -> MacSyncChatCancelOutcome {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noActiveTask }
        var stoppedSteer = false
        let steerIDs = runIDs.isEmpty ? (waitingSteers[trimmed].map { Array($0.keys) } ?? []) : runIDs
        for runID in steerIDs {
            if let stop = waitingSteers[trimmed]?.removeValue(forKey: runID) {
                stop()
                stoppedSteer = true
            }
        }
        if waitingSteers[trimmed]?.isEmpty == true { waitingSteers[trimmed] = nil }
        guard let entry = activeChatTasks[trimmed] else {
            return stoppedSteer ? .cancelled : .noActiveTask
        }
        if !runIDs.isEmpty, !runIDs.contains(where: { $0 == entry.runID }) {
            // Leave the other run untouched; the router retained the named Stop.
            return stoppedSteer ? .cancelled : .runMismatch
        }
        entry.task.cancel()
        return .cancelled
    }

    let processedIdsCap = 5000
    var _pairingSecret: Data?
    enum PairingSecretRotation: Equatable { case writing, awaitingVerification }
    var pairingSecretRotation: PairingSecretRotation?
    var pairingSecretRotationInProgress: Bool { pairingSecretRotation != nil }
    init(sync: DeviceSync) {
        self.sync = sync
    }

    enum Folder {
        static let snapshots = "snapshots"
        static let responses = "responses"
        static let transactions = "transactions/mac"
    }
}
