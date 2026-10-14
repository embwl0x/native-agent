// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import ChatOrchestration
import CommonCrypto
import CryptoKit
import AppKit
import Cognition
import DeviceSyncState
import Foundation
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
    func startCloudKitSnapshotProjection() async {
        guard !Task.isCancelled else { return }
        let docsURL = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mobile_snapshot_cache", isDirectory: true)
        if isActive, activeDocsURL == docsURL {
            return
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        let generation = snapshotLifecycleGeneration
        activeDocsURL = docsURL
        guard await restoreState(generation: generation) else { return }
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots, isDirectory: true)
        inboxDir = nil
        responsesDir = docsURL.appendingPathComponent(Folder.responses, isDirectory: true)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions, isDirectory: true)
        let directories = [snapshotDir, responsesDir, transactionDir].compactMap({ $0 })
        await sync.storage.perform {
            for directory in directories { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
        guard generation == snapshotLifecycleGeneration else { return }
        isActive = true
        await startArchiveRetentionWatcher()
        guard generation == snapshotLifecycleGeneration, isActive else { return }
        pruneOldArchiveFiles()
        startSnapshotIntegrityFallback()
        startPresenceBeat()
        startCognitionSnapshotObservation()
        await startSchedulerSnapshotObservation()
        await startHelpersSnapshotObservation()
        guard generation == snapshotLifecycleGeneration, isActive else { return }
        startWorkActivityObservation()
        startLiveTurnRelay()
        startChatTranscriptSnapshotObservation()
        Task {
            await writeSnapshots(forceHeavy: true)
            guard generation == snapshotLifecycleGeneration, isActive else { return }
            if let snapshotDir {
                _ = await sync.bridge.publishMobileSnapshotStatus(
                    groups: Set(NAMobileSnapshotGroup.allCases),
                    snapshotDirectory: snapshotDir,
                    shouldPublish: { self.snapshotLifecycleGeneration == generation && self.isActive }
                )
            }
            // One integrity pass on the fresh snapshot, then its 15-minute clock.
            await runSnapshotIntegrityPass()
        }
    }

    func start(docsURL: URL) async {
        guard !Task.isCancelled else { return }
        if isActive, activeDocsURL == docsURL {
            return
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        let generation = snapshotLifecycleGeneration
        activeDocsURL = docsURL
        inboxDir = docsURL.appendingPathComponent(Folder.inbox)
        // Replay state must be restored before either inbox admits work.
        guard await restoreState(generation: generation) else { return }
        let secret: Data
        do {
            if pairingSecretRotationInProgress { _ = try pairingSecret() }
            let cached = _pairingSecret
            let loaded = try await sync.storage.perform { try cached ?? PairingSecretManager.loadOrGenerateSecret() }
            guard generation == snapshotLifecycleGeneration else { return }
            if pairingSecretRotationInProgress { _ = try pairingSecret() }
            secret = _pairingSecret ?? loaded
            _pairingSecret = secret
        } catch {
            guard generation == snapshotLifecycleGeneration else { return }
            syncError = "Snapshot pairing unavailable: \(error.localizedDescription)"
            return
        }
        // Same pairing fingerprint/path as the phone's cachedSnapshotDirectory.
        // Unscoped legacy snapshots are never copied into a new pairing.
        let fingerprint = SHA256.hash(data: secret).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots)
            .appendingPathComponent("pairings", isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
        responsesDir = docsURL.appendingPathComponent(Folder.responses)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions)
        let inboxRejectedDir = docsURL.appendingPathComponent(Folder.inboxRejected)

        let directories = [snapshotDir, inboxDir, inboxRejectedDir, responsesDir, transactionDir].compactMap({ $0 })
        await sync.storage.perform {
            for dir in directories { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        }
        guard generation == snapshotLifecycleGeneration else { return }

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
        startPresenceBeat()
        startCognitionSnapshotObservation()
        await startSchedulerSnapshotObservation()
        await startHelpersSnapshotObservation()
        guard generation == snapshotLifecycleGeneration, isActive else { return }
        startWorkActivityObservation()
        startLiveTurnRelay()
        startChatTranscriptSnapshotObservation()

        // Watch inbox for iOS-deposited action files
        startInboxQuery(docsURL: docsURL)

        // Immediate first snapshot, then one integrity pass on it.
        Task {
            await writeSnapshots(forceHeavy: true)
            await runSnapshotIntegrityPass()
        }

        // R11-N30: prune at startup, then schedule the exact earliest 7-day
        // retention crossing instead of waking every ten minutes.
        await startArchiveRetentionWatcher()
        guard generation == snapshotLifecycleGeneration, isActive else { return }
        pruneOldArchiveFiles()
    }


    func stop() {
        snapshotLifecycleGeneration &+= 1
        isActive = false
        workActivityObservationTask?.cancel()
        workActivityObservationTask = nil
        stopLiveTurnRelay()
        workActivityPublicationTask?.cancel()
        // The retiring publisher keeps admission until its physical write ends.
        workActivities.removeAll()
        activeDocsURL = nil
        snapshotIntegrityTask?.cancel()
        snapshotIntegrityTask = nil
        presenceBeatTask?.cancel()
        presenceBeatTask = nil
        cognitionSnapshotObservationTask?.cancel()
        cognitionSnapshotObservationTask = nil
        schedulerSnapshotWatcher?.cancel()
        schedulerSnapshotWatcher = nil
        helpersSnapshotWatcher?.cancel()
        helpersSnapshotWatcher = nil
        if let chatTurnCompletedObserver {
            NotificationCenter.default.removeObserver(chatTurnCompletedObserver)
            self.chatTurnCompletedObserver = nil
        }
        if let chatTranscriptDidChangeObserver {
            NotificationCenter.default.removeObserver(chatTranscriptDidChangeObserver)
            self.chatTranscriptDidChangeObserver = nil
        }
        chatTranscriptSnapshotPublicationTask?.cancel()
        chatTranscriptSnapshotPublicationTask = nil
        chatSnapshotCoalescer.reset()
        // The retiring pass owns admission until its physical write returns.
        snapshotWriteQueued = false
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsMemories = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        snapshotWriteQueuedNeedsStandardPass = false
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
        archiveRetentionRetryAfter = nil
        archiveRetentionWatcher?.cancel()
        archiveRetentionWatcher = nil
        inboxQuery?.stop()
        inboxQuery = nil
        NotificationCenter.default.removeObserver(self)
    }

    private static let snapshotIntegrityCadence: TimeInterval = 15 * 60

    private func startSnapshotIntegrityFallback() {
        snapshotIntegrityTask?.cancel()
        OrganPulse.recordStarting("snapshot_integrity", cadence: Self.snapshotIntegrityCadence)
        snapshotIntegrityTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.snapshotIntegrityCadence))
                guard !Task.isCancelled, self.isActive else { return }
                await self.runSnapshotIntegrityPass()
            }
        }
    }

    private func startPresenceBeat() {
        presenceBeatTask?.cancel()
        presenceBeatTask = Task { [weak self] in
            var delay = NAMacPresence.beat
            while let self, !Task.isCancelled {
                guard self.isActive else { return }
                let published = await self.sync.bridge.publishMacPresence()
                if published { OrganPulse.record("presence_beat", .worked, cadence: NAMacPresence.beat) }
                delay = published ? NAMacPresence.beat : min(NAMacPresence.phoneWindow, delay * 2)
                try? await Task.sleep(for: .seconds(delay))
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
        let dataRoot = PersistenceCore.defaultDataRoot()
        let (report, hasSkippedGroups) = await Task.detached(priority: .utility) {
            let report = MacSyncSnapshotIntegrity.reconcile(digests: digests, in: snapshotDir)
            let skipsURL = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
            let hasSkippedGroups: Bool
            if FileManager.default.fileExists(atPath: skipsURL.path) {
                if let data = try? Data(contentsOf: skipsURL),
                   let skips = try? JSONDecoder().decode([String: String].self, from: data) {
                    hasSkippedGroups = skips.keys.contains { !$0.hasPrefix("_") }
                } else {
                    hasSkippedGroups = true
                }
            } else {
                hasSkippedGroups = false
            }
            return (report, hasSkippedGroups)
        }.value
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }

        if report.retainedDigests != snapshotFileDigests {
            snapshotFileDigests = report.retainedDigests
            await saveSnapshotDigests()
        }
        let found = report.integrityFailures + (hasSkippedGroups ? ["skipped groups to republish"] : [])
        OrganPulse.record("snapshot_integrity", found: found.count, note: found.joined(separator: "; "),
                          cadence: Self.snapshotIntegrityCadence)
        if report.requiresRepair {
            syncError = "iPhone snapshot integrity check found \(report.integrityFailures.joined(separator: "; ")). Rebuilding the affected mobile snapshot groups."
            // A mismatch can belong to a heavyweight group (catalog, graph,
            // transcripts). A standard pass would retain that bad file forever,
            // so the bounded 15-minute integrity owner explicitly rebuilds all
            // active projections once.
            await writeSnapshots(forceHeavy: true)
        } else if hasSkippedGroups {
            // Failed publications may have no cached digest left to reconcile.
            await writeSnapshots(forceHeavy: true)
        } else {
            await writeSnapshots()
        }
    }

    private func startCognitionSnapshotObservation() {
        cognitionSnapshotObservationTask?.cancel()
        let cognition = sync.cognition
        cognitionSnapshotObservationTask = Task { [weak self] in
            let changes = await cognition.changes()
            for await change in changes {
                guard !Task.isCancelled, let self, self.isActive else { return }
                guard Self.shouldWriteSnapshot(for: change) else { continue }
                await self.writeSnapshots()
            }
        }
    }

    /// Install the completion-edge observer that feeds the bounded chat snapshot coalescer.
    func startChatTranscriptSnapshotObservation() {
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
        // 2026-09-06: the same edge for a transcript rewritten outside a turn
        // (the compaction distiller's swap). It bumps the session's transcript
        // version, so without a publication the phone keeps the mechanical
        // summary and every later publish looks no newer than what it holds.
        if let chatTranscriptDidChangeObserver {
            NotificationCenter.default.removeObserver(chatTranscriptDidChangeObserver)
        }
        chatTranscriptDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .nativeAgentChatTranscriptDidChange,
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
    public func requestChatTranscriptSnapshotPublication() {
        requestChatSnapshotPublication(includeTranscripts: true)
    }

    /// One coalescer owns both transcript completions and session-index
    /// mutations. A later transcript request upgrades an already-pending
    /// sessions-only request without starting a second timer.
    public func requestChatSnapshotPublication(includeTranscripts: Bool) {
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

    /// Observe the active transport's archive and transaction directories.
    func startArchiveRetentionWatcher() async {
        archiveRetentionWatcher?.cancel()
        let generation = snapshotLifecycleGeneration
        let paths = MacSyncArchiveRetentionWatchPaths.resolve(
            inboxDirectory: inboxDir,
            responsesDirectory: responsesDir,
            transactionDirectory: transactionDir,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
        guard paths.count == (inboxDir == nil ? 4 : 6) else {
            syncError = "Archive retention unavailable: sync directories could not be opened."
            return
        }
        let watcher = await FileChangeWatcher.armed(paths: paths) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                self.rescheduleArchiveRetentionDeadline()
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        archiveRetentionWatcher = watcher
    }
}
