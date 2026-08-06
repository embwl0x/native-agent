// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
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
    /// One exact archive-retention crossing, recalculated after each prune.
    var pruneDeadlineTask: Task<Void, Never>?
    var archiveRetentionWatcher: FileChangeWatcher?
    var activeDocsURL: URL?
    var snapshotWriteInFlight = false
    var snapshotWriteQueued = false
    var snapshotWriteQueuedNeedsHeavy = false
    var inboxProcessingInFlight = false
    var inboxProcessingQueued = false
    var snapshotFileDigests: [String: String] = [:]
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
    var activeChatTasks: [String: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>] = [:]

    func registerActiveChatTask(
        _ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>,
        for sessionID: String
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed] {
            existing.cancel()
        }
        activeChatTasks[trimmed] = task
    }

    func unregisterActiveChatTask(
        for sessionID: String,
        expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>
    ) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = activeChatTasks[trimmed], existing == task {
            activeChatTasks.removeValue(forKey: trimmed)
        }
    }

    func cancelActiveChatTask(for sessionID: String) -> Bool {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let task = activeChatTasks[trimmed] else { return false }
        task.cancel()
        return true
    }

    struct ChatTranscriptSnapshot: Codable {
        var sessionId: String
        var messages: [ChatMessage]
    }
    let processedIdsCap = 5000
    var _pairingSecret: Data?

    enum KVSKey {
        static let snapshotUpdated = "snapshot_updated"
        static let inboxPending = "inbox_pending"
    }

    enum Folder {
        static let snapshots = "snapshots"
        static let inbox = "inbox"
        static let inboxRejected = "inbox/_rejected"
        static let responses = "responses"
        static let transactions = "transactions/mac"
    }

    let inboxResponseKeyPrefix = "inbox_response_"
    let inboxResponseKeyTTL: TimeInterval = 24 * 3600
    /// Backstop ceiling kept well below the hard 1024-key KVS quota.
    let inboxResponseKeyMaxCount = 800

    private init() {}
}
