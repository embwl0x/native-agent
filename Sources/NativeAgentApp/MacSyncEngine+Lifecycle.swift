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

extension MacSyncEngine {
    // MARK: - Start

    /// Public Developer ID builds carry CloudKit but cannot carry the
    /// Mac-App-Store-only CloudDocuments entitlement. Keep producing the exact
    /// same bounded snapshot files in a local rebuildable cache; iCloudBridge
    /// publishes those bytes through NAStatus after each owner-driven write.
    func startCloudKitSnapshotProjection() {
        let docsURL = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mobile_snapshot_cache", isDirectory: true)
        if isActive, activeDocsURL == docsURL {
            return
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        activeDocsURL = docsURL
        loadProcessedIds()
        loadSnapshotDigests()
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots, isDirectory: true)
        inboxDir = nil
        responsesDir = docsURL.appendingPathComponent(Folder.responses, isDirectory: true)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions, isDirectory: true)
        for directory in [snapshotDir, responsesDir, transactionDir].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        isActive = true
        startSnapshotIntegrityFallback()
        startCognitionSnapshotObservation()
        startChatTranscriptSnapshotObservation()
        Task {
            await writeSnapshots(forceHeavy: true)
            if let snapshotDir {
                _ = await iCloudBridge.shared.publishMobileSnapshotStatus(
                    groups: Set(NAMobileSnapshotGroup.allCases),
                    snapshotDirectory: snapshotDir
                )
            }
        }
    }

    func start(docsURL: URL) {
        if isActive, activeDocsURL == docsURL {
            return
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        activeDocsURL = docsURL
        // PATCH-2026-05-08: fix-A.3 Load persisted processed IDs before any inbox processing.
        loadProcessedIds()
        // fix-snapshot-digest-persist: reload digests so a reconnect skips
        // re-writing unchanged snapshots instead of triggering an iOS read-storm.
        loadSnapshotDigests()
        let fm = FileManager.default
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots)
        inboxDir = docsURL.appendingPathComponent(Folder.inbox)
        responsesDir = docsURL.appendingPathComponent(Folder.responses)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions)
        let inboxRejectedDir = docsURL.appendingPathComponent(Folder.inboxRejected)

        for dir in [snapshotDir, inboxDir, inboxRejectedDir, responsesDir, transactionDir].compactMap({ $0 }) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        isActive = true

        // KVS observation for iOS-initiated inbox deposits
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        Task.detached(priority: .utility) {
            _ = await withCKTimeout("MacSyncEngine.start.kvsSynchronize") {
                NSUbiquitousKeyValueStore.default.synchronize()
            }
        }

        // Normal writes are mutation-driven. Retain one deliberately slow
        // integrity path for an out-of-process change or crash-window event the
        // app could not observe; unchanged passes write nothing and call no LLM.
        startSnapshotIntegrityFallback()
        startCognitionSnapshotObservation()
        startChatTranscriptSnapshotObservation()

        // Watch inbox for iOS-deposited action files
        startInboxQuery(docsURL: docsURL)

        // Immediate first snapshot
        Task { await writeSnapshots(forceHeavy: true) }

        // R11-N30: prune at startup, then schedule the exact earliest 7-day
        // retention crossing instead of waking every ten minutes.
        startArchiveRetentionWatcher()
        pruneOldArchiveFiles()
    }


    func stop() {
        snapshotLifecycleGeneration &+= 1
        isActive = false
        activeDocsURL = nil
        snapshotIntegrityTask?.cancel()
        snapshotIntegrityTask = nil
        cognitionSnapshotObservationTask?.cancel()
        cognitionSnapshotObservationTask = nil
        if let chatTurnCompletedObserver {
            NotificationCenter.default.removeObserver(chatTurnCompletedObserver)
            self.chatTurnCompletedObserver = nil
        }
        chatTranscriptSnapshotPublicationTask?.cancel()
        chatTranscriptSnapshotPublicationTask = nil
        snapshotWriteInFlight = false
        snapshotWriteQueued = false
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        snapshotWriteQueuedNeedsStandardPass = false
        // fix-snapshot-digest-persist: do NOT clear the digest map on stop().
        // Clearing it meant every reconnect re-wrote all snapshots (full iOS
        // read-storm). Persist it instead, and keep it in memory so a same-process
        // reconnect short-circuits unchanged files immediately.
        saveSnapshotDigests()
        lastHeavySnapshotAt = nil
        pruneDeadlineTask?.cancel()
        pruneDeadlineTask = nil
        archiveRetentionWatcher?.cancel()
        archiveRetentionWatcher = nil
        inboxQuery?.stop()
        inboxQuery = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func startSnapshotIntegrityFallback() {
        snapshotIntegrityTask?.cancel()
        snapshotIntegrityTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, self.isActive else { return }
                await self.writeSnapshots()
            }
        }
    }

    private func startCognitionSnapshotObservation() {
        cognitionSnapshotObservationTask?.cancel()
        cognitionSnapshotObservationTask = Task { [weak self] in
            let changes = await NativeCognitionRuntime.shared.changes()
            for await change in changes {
                guard !Task.isCancelled, let self, self.isActive else { return }
                guard Self.shouldWriteSnapshot(for: change) else { continue }
                await self.writeSnapshots()
            }
        }
    }

    private func startChatTranscriptSnapshotObservation() {
        if let chatTurnCompletedObserver {
            NotificationCenter.default.removeObserver(chatTurnCompletedObserver)
        }
        chatTurnCompletedObserver = NotificationCenter.default.addObserver(
            forName: .chatTurnCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestChatSnapshotPublication(includeTranscripts: true)
            }
        }
    }

    /// Coalesces a burst of completion edges into one sessions + transcript
    /// snapshot pass. It deliberately does not request the unrelated heavy
    /// catalogs, graph, run, or provider projections.
    func requestChatTranscriptSnapshotPublication() {
        requestChatSnapshotPublication(includeTranscripts: true)
    }

    /// One coalescer owns both transcript completions and session-index
    /// mutations. A later transcript request upgrades an already-pending
    /// sessions-only request without starting a second timer.
    func requestChatSnapshotPublication(includeTranscripts: Bool) {
        guard isActive else { return }
        snapshotWriteQueuedNeedsChatTranscripts =
            snapshotWriteQueuedNeedsChatTranscripts || includeTranscripts
        guard chatTranscriptSnapshotPublicationTask == nil else { return }
        let generation = snapshotLifecycleGeneration
        chatTranscriptSnapshotPublicationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self,
                  self.isActive,
                  generation == self.snapshotLifecycleGeneration else { return }
            let includeTranscripts = self.snapshotWriteQueuedNeedsChatTranscripts
            self.snapshotWriteQueuedNeedsChatTranscripts = false
            self.chatTranscriptSnapshotPublicationTask = nil
            await self.writeSnapshots(
                includeChatTranscripts: includeTranscripts,
                scope: .chatSessions
            )
        }
    }

    nonisolated static func shouldWriteSnapshot(
        for change: NativeCognitionRuntimeChange
    ) -> Bool {
        change.reason.hasPrefix("configuration:")
            || change.reason.hasPrefix("organism:")
            || change.reason.hasPrefix("transient_clear:")
            || change.reason == "microcycle_settlement:finished"
            || change.reason == "residual_repair:completed"
    }

    private func startArchiveRetentionWatcher() {
        archiveRetentionWatcher?.cancel()
        let rejected = inboxDir?.appendingPathComponent("_rejected", isDirectory: true)
        let paths = [inboxDir, responsesDir, rejected].compactMap { $0 }
        archiveRetentionWatcher = FileChangeWatcher(paths: paths) { [weak self] _ in
            Task { @MainActor in
                self?.rescheduleArchiveRetentionDeadline()
            }
        }
    }
}
