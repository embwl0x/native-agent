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
            chatTurnCompletedNotificationCenter.removeObserver(chatTurnCompletedObserver)
            self.chatTurnCompletedObserver = nil
        }
        chatTranscriptSnapshotPublicationTask?.cancel()
        chatTranscriptSnapshotPublicationTask = nil
        chatSnapshotCoalescer.reset()
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
        // A stopped lifecycle must not retain a routable old container. Late
        // work is already generation-gated; clearing these roots also makes a
        // post-stop inbox/action call fail closed instead of writing to a
        // superseded Drive or local-cache generation.
        snapshotDir = nil
        inboxDir = nil
        responsesDir = nil
        transactionDir = nil
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
                await self.runSnapshotIntegrityPass()
            }
        }
    }

    /// Slow repair for a missed mutation edge or an externally modified
    /// snapshot.  Normal publications remain event-driven; this pass merely
    /// proves that every cached digest still matches the specific file iOS can
    /// consume before allowing the writer to skip it.
    private func runSnapshotIntegrityPass() async {
        guard isActive, let snapshotDir else { return }
        let lifecycleGeneration = snapshotLifecycleGeneration
        let digests = snapshotFileDigests
        let report = await Task.detached(priority: .utility) {
            MacSyncSnapshotIntegrity.reconcile(digests: digests, in: snapshotDir)
        }.value
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }

        if report.retainedDigests != snapshotFileDigests {
            snapshotFileDigests = report.retainedDigests
            saveSnapshotDigests()
        }
        if report.requiresRepair {
            syncError = "iPhone snapshot integrity check found \(report.integrityFailures.joined(separator: "; ")). Rebuilding the affected mobile snapshot groups."
            // A mismatch can belong to a heavyweight group (catalog, graph,
            // transcripts). A standard pass would retain that bad file forever,
            // so the bounded 15-minute integrity owner explicitly rebuilds all
            // active projections once.
            await writeSnapshots(forceHeavy: true)
        } else {
            await writeSnapshots()
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

    /// Install the exact completion-edge observer that feeds the bounded chat
    /// snapshot coalescer. Kept internal so its notification-to-write contract
    /// can be exercised with an isolated notification center.
    func startChatTranscriptSnapshotObservation() {
        if let chatTurnCompletedObserver {
            chatTurnCompletedNotificationCenter.removeObserver(chatTurnCompletedObserver)
        }
        chatTurnCompletedObserver = chatTurnCompletedNotificationCenter.addObserver(
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
        let generation = snapshotLifecycleGeneration
        guard chatSnapshotCoalescer.enqueue(
            includeTranscripts: includeTranscripts,
            generation: generation
        ) else { return }
        chatTranscriptSnapshotPublicationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self else { return }
            guard let includeTranscripts = self.chatSnapshotCoalescer.resolve(
                generation: generation,
                currentGeneration: self.snapshotLifecycleGeneration,
                isActive: self.isActive
            ) else { return }
            self.chatTranscriptSnapshotPublicationTask = nil
            if let chatTranscriptSnapshotWriter = self.chatTranscriptSnapshotWriter {
                await chatTranscriptSnapshotWriter(includeTranscripts)
            } else {
                await self.writeSnapshots(
                    includeChatTranscripts: includeTranscripts,
                    scope: .chatSessions
                )
            }
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

    /// Arms retention observation only after every canonical archive directory
    /// is a real directory. Kept internal for hermetic lifecycle proof of the
    /// failure state; production still invokes it only from `start(docsURL:)`.
    func startArchiveRetentionWatcher() {
        archiveRetentionWatcher?.cancel()
        let paths = MacSyncArchiveRetentionWatchPaths.resolve(
            inboxDirectory: inboxDir,
            responsesDirectory: responsesDir
        )
        guard paths.count == 3 else {
            syncError = "Archive retention watcher unavailable — iCloud inbox paths are unresolved"
            return
        }
        archiveRetentionWatcher = FileChangeWatcher(paths: paths) { [weak self] _ in
            Task { @MainActor in
                self?.rescheduleArchiveRetentionDeadline()
            }
        }
    }
}
