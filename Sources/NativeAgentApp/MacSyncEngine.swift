// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CognitiveSubstrate
import CryptoKit
import AppKit
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import KnowledgeGraph
import PersistenceCore

// MARK: - MacSyncEngine

@MainActor
final class MacSyncEngine: ObservableObject {
    static let shared = MacSyncEngine()

    @Published var isActive = false
    @Published var lastSnapshotAt: Date?
    @Published var lastInboxAt: Date?
    @Published var syncError: String?

    var snapshotDir: URL?
    var inboxDir: URL?
    var responsesDir: URL?
    var transactionDir: URL?
    var inboxQuery: NSMetadataQuery?
    /// Slow missed-event integrity fallback. Normal snapshot writes are driven
    /// by app/store mutation seams; unchanged passes write nothing and make no
    /// provider calls.
    var snapshotIntegrityTask: Task<Void, Never>?
    /// Payload-free resident-state subscription. This closes the normal
    /// cognition/organism -> iOS snapshot path without shortening the slow
    /// integrity fallback or adding a polling loop.
    var cognitionSnapshotObservationTask: Task<Void, Never>?
    /// Existing chat completion notifications drive one bounded transcript
    /// projection pass. The short coalescer absorbs completion fan-out (for
    /// example a bridge delivery plus its local refresh) without polling or
    /// rebuilding the transcript for every notification.
    var chatTurnCompletedObserver: NSObjectProtocol?
    /// 2026-09-06: transcripts are also rewritten outside a turn — the
    /// compaction distiller swaps its recollection into the summary row long
    /// after the turn that triggered it finished. That write posts its own
    /// edge, and it feeds the same coalescer.
    var chatTranscriptDidChangeObserver: NSObjectProtocol?
    var chatTranscriptSnapshotPublicationTask: Task<Void, Never>?
    var chatSnapshotCoalescer = MacSyncChatSnapshotCoalescerState()
    /// One exact archive-retention crossing, recalculated after each prune.
    var pruneDeadlineTask: Task<Void, Never>?
    var archiveRetentionWatcher: FileChangeWatcher?
    var activeDocsURL: URL?
    var snapshotWriteInFlight = false
    var snapshotWriteQueued = false
    var snapshotWriteQueuedNeedsHeavy = false
    var snapshotWriteQueuedNeedsChatTranscripts = false
    var snapshotWriteQueuedNeedsStandardPass = false
    /// Invalidates any snapshot pass suspended across stop/restart. A late pass
    /// must never publish into a newly selected cache/container generation.
    var snapshotLifecycleGeneration: UInt64 = 0
    var inboxProcessingInFlight = false
    var inboxProcessingQueued = false
    var snapshotFileDigests: [String: String] = [:]
    /// 2026-09-06: the last published transcript block per session, keyed by
    /// the transcript generation it was read at, so a completion edge re-reads
    /// history only for the sessions whose generation actually moved. In-memory
    /// only (a cold start republishes from source) and pruned every pass to the
    /// sessions that fit the chat group's byte budget.
    var chatTranscriptBlockCache: [String: ChatTranscriptBlock] = [:]
    var lastHeavySnapshotAt: Date?
    // fix-R9-9 Maintain insertion order so oldest are evicted first (not random).
    var processedMsgIds: Set<String> = []
    var processedMsgIdsOrdered: [String] = []
    /// Sweep R4 item 1: the last `loadProcessedIds()` found the file present but
    /// unreadable, so the in-memory window may be missing ids that really were
    /// processed. Distinct from "no file yet", which is ordinary genesis.
    var processedIdsUnreadable = false

    // F7 P0 #3: in-flight chat stream tasks keyed by sessionID, registered by
    // forwardToSwiftRuntime and cancelled by the iOS "cancelChat" inbox action. The
    // cancelled.flag file (NativeClient.cancelChatSession) is still written by
    // the existing api.cancelChatSession() call as a secondary signal that the
    // streaming chat path also polls — Task.cancel() is the primary mechanism.
    /// What a remote Stop actually did to the session's in-flight chat task.
    enum MacSyncChatCancelOutcome: String, Equatable {
        case cancelled
        /// A different run holds this session now — nothing was cancelled and
        /// no cancel marker belongs on disk either. 2026-09-06: the named run
        /// is not necessarily over. Another turn holding the session is also
        /// exactly what a Stop that overtook its own turn's handoff sees, so
        /// the id is held as stop-requested here too and the turn dies at
        /// registration; a run that really was over never registers again and
        /// its hold is pruned by the TTL.
        case runMismatch
        /// 2026-09-06: a scoped Stop arrived before its run registered — the
        /// turn is still in handoff. The run id is held as stop-requested and
        /// the turn dies the moment it registers. No cancel marker belongs on
        /// disk: turn acceptance deletes the session's cancelled.flag before
        /// the stream starts, so an unscoped marker would be wiped and the
        /// stopped turn would run to completion anyway.
        case stopRecorded
        case noActiveTask
    }

    /// 2026-09-06: the run id (the iOS correlation id of the turn) is stored
    /// with the task so a Stop that names its run cannot cancel a later turn
    /// that took the same session in the meantime.
    struct ActiveChatTask {
        let task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>
        let runID: String?
    }

    var activeChatTasks: [String: ActiveChatTask] = [:]

    /// 2026-09-06: run ids a scoped Stop named while the run was still in
    /// handoff (minted on the phone, not yet registered here), with the moment
    /// each stops counting. Keyed by session and run so a Stop can only ever
    /// kill the turn it named. Entries are consumed at registration and swept
    /// on the next write; the TTL only bounds the memory of a run that never
    /// arrives at all.
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

    func registerActiveChatTask(
        _ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>,
        for sessionID: String,
        runID: String? = nil
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed] {
            existing.task.cancel()
        }
        activeChatTasks[trimmed] = ActiveChatTask(task: task, runID: runID)
        // 2026-09-06: the Stop for this run beat its registration. Honour it
        // now — it is still the turn the user pressed Stop on.
        if consumeStopRequestedChatRun(for: trimmed, runID: runID) {
            task.cancel()
        }
    }

    func unregisterActiveChatTask(
        for sessionID: String,
        expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed], existing.task == task {
            activeChatTasks.removeValue(forKey: trimmed)
        }
    }

    /// Cancel the session's in-flight chat task. `runIDs` are the runs the
    /// caller believes it is stopping; when they name a run that is NOT the one
    /// holding the session, nothing is cancelled and the caller is told so —
    /// the stopped turn is already over and the current one is somebody else's.
    func cancelActiveChatTask(for sessionID: String, runIDs: [String] = []) -> MacSyncChatCancelOutcome {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noActiveTask }
        guard let entry = activeChatTasks[trimmed] else {
            // 2026-09-06: a NAMED run with nothing registered yet is a Stop
            // that overtook its own turn's handoff. Hold the id so
            // registration cancels it; an unscoped marker here would be
            // deleted by turn acceptance and the turn would run anyway.
            guard !runIDs.isEmpty else { return .noActiveTask }
            recordStopRequestedChatRuns(for: trimmed, runIDs: runIDs)
            return .stopRecorded
        }
        if !runIDs.isEmpty, let runID = entry.runID, !runIDs.contains(runID) {
            // 2026-09-06: the named run may still be crossing from the phone
            // while an older run holds the session. Hold the Stop against its
            // run id — registration consumes it — or the stopped turn starts
            // and runs to completion right after this returns.
            recordStopRequestedChatRuns(for: trimmed, runIDs: runIDs)
            return .runMismatch
        }
        entry.task.cancel()
        return .cancelled
    }

    struct ChatTranscriptSnapshot: Codable {
        var sessionId: String
        var messages: [ChatMessage]
        /// 2026-09-06: the session's transcript version at publication (see
        /// `ChatSessionIndexFile.transcriptGenerationKey`). A row with
        /// `messages: []` is the Mac SAYING the transcript is empty (cleared),
        /// which is different from publishing no row at all; the phone only
        /// lets an empty row clear its copy when this counter is strictly
        /// greater than the last one it applied for that session, so an
        /// out-of-order read cannot wipe a rebuilt transcript. A counter, not
        /// a clock — `updatedAt` moves for reasons that are not transcript
        /// writes and can step backwards. `nil` (older Mac builds, or a row
        /// never written since this shipped) is never authority to clear.
        var transcriptGeneration: Int?
    }

    /// One session's published transcript held for reuse (see
    /// `chatTranscriptBlockCache`), with the encoded size the chat group's byte
    /// budget is spent against. `generation` is `nil` on rows that carry no
    /// counter — those are never reused, since nothing can say whether they
    /// moved.
    struct ChatTranscriptBlock {
        var generation: Int?
        var snapshot: ChatTranscriptSnapshot
        var encodedBytes: Int
    }
    let processedIdsCap = 5000
    var _pairingSecret: Data?
    var pairingSecretRotationInProgress = false
    /// The production CloudKit response route. Kept as one seam so the inbox
    /// owner can prove durable-before-send and restart resend behavior without
    /// substituting a second action processor or a hand-built envelope.
    var cloudKitActionResponseSender: (@Sendable ([String: String], String) async throws -> Void)?
    /// Test-only root seam for CloudKit action bookkeeping; production keeps
    /// the canonical NativeAgent data root.
    var cloudKitActionStateRootOverride: URL?
    /// Test seam for the durable completion-marker recovery path.
    var cloudKitActionProcessedIDPersistence: (() -> Bool)?
    /// The production observer listens on `.default`; an isolated center keeps
    /// transcript-coalescer evaluations from subscribing to the live app.
    let chatTurnCompletedNotificationCenter: NotificationCenter
    /// Production always takes the real snapshot writer. The injected path is
    /// deliberately limited to the final coalesced chat projection boundary.
    let chatTranscriptSnapshotWriter: (@MainActor @Sendable (Bool) async -> Void)?
    /// Production sleeps for the requested coalescing duration. An injected
    /// delay lets lifecycle evaluations hold the real debounce task at that
    /// boundary without depending on wall-clock scheduler timing.
    let chatSnapshotCoalescingDelay: @MainActor @Sendable (Duration) async throws -> Void
    /// Isolated lifecycle evaluations persist only their digest state beneath
    /// this injected root. Production always uses the canonical data root.
    let stateDataRootOverride: URL?
    /// The production closure reads the app-owned cognition actor. Snapshot
    /// projection evals inject an immutable organism read so they can execute
    /// the real Mac writer without touching the resident agent's body state.
    let organismSnapshotProvider: @Sendable () async -> OrganismSnapshot

    enum KVSKey {
        static let snapshotUpdated = "snapshot_updated"
        static let inboxPending = "inbox_pending"
    }

    init(
        stateDataRootOverride: URL?,
        chatTurnCompletedNotificationCenter: NotificationCenter = .default,
        chatTranscriptSnapshotWriter: (@MainActor @Sendable (Bool) async -> Void)? = nil,
        chatSnapshotCoalescingDelay: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        organismSnapshotProvider: @escaping @Sendable () async -> OrganismSnapshot = {
            await NativeCognitionRuntime.shared.organismSnapshot()
        }
    ) {
        self.stateDataRootOverride = stateDataRootOverride
        self.chatTurnCompletedNotificationCenter = chatTurnCompletedNotificationCenter
        self.chatTranscriptSnapshotWriter = chatTranscriptSnapshotWriter
        self.chatSnapshotCoalescingDelay = chatSnapshotCoalescingDelay
        self.organismSnapshotProvider = organismSnapshotProvider
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

    private convenience init() {
        self.init(stateDataRootOverride: nil)
    }
}
