// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import BackgroundLoops
import CommonCrypto
import CryptoKit
import AppKit
import Cognition
import DeviceSyncState
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`: `startCloudKitSnapshotProjection`, `start`, `stop`; saved connector setup changes and receipt-ledger health edges rebuild the heavy snapshots, so the phone follows health changes without rebuilding for repeated healthy receipts |

extension MacSyncEngine {
    /// A repair attempt uses the mounted writer and transport; its next health
    /// reading, not admission to the writer, proves the failed postcondition.
    public func repairPhoneSync() async -> String {
        guard isActive, snapshotDir != nil else {
            return "Phone sync is not active; no snapshot or presence was published."
        }
        let generation = snapshotLifecycleGeneration
        let queued = snapshotWriteInFlight
        await sync.bridge.repairReceive()
        await writeSnapshots(forceHeavy: true, republish: true, includeChatTranscripts: true)
        guard !queued else {
            return "Phone snapshot rebuild was queued behind the active writer; recovery is not verified."
        }
        guard generation == snapshotLifecycleGeneration, isActive else {
            return "Phone sync changed while rebuilding snapshots; recovery is not verified."
        }
        let presence = await sync.bridge.publishMacPresence()
        guard generation == snapshotLifecycleGeneration, isActive else {
            return "Phone snapshot transport is unavailable or changed during publication; recovery is not verified."
        }
        let presenceSummary: String
        switch presence {
        case .published: presenceSummary = "CloudKit accepted Mac presence."
        case .ineligible: presenceSummary = "Mac presence is not eligible for this phone."
        case .failed: presenceSummary = "CloudKit has not accepted Mac presence."
        }
        return ([presenceSummary]
            + (syncError.map { [$0] } ?? [])
            + ["Snapshot publication was attempted; the phone's receipt is not confirmed. Doctor must verify the failed postcondition."])
            .joined(separator: " ")
    }

    /// Every page and the presence beat as this Mac has them now, whatever
    /// was last sent: another Mac may have written over them while it held
    /// the phone, and unchanged files would otherwise never go out again.
    func republishPhonePages() async {
        guard isActive, let snapshotDir else { return }
        let generation = snapshotLifecycleGeneration
        sync.bridge.notePublication(await sync.bridge.publishMobileSnapshotStatus(
            groups: Set(NAMobileSnapshotGroup.allCases),
            snapshotDirectory: snapshotDir,
            shouldPublish: { self.snapshotLifecycleGeneration == generation && self.isActive }
        ))
        if case .published = await sync.bridge.publishMacPresence() {
            OrganPulse.record("presence_beat", .worked, cadence: NAMacPresence.beat)
        }
    }

    // MARK: - Start

    /// Public Developer ID builds carry CloudKit but cannot carry the
    /// Mac-App-Store-only CloudDocuments entitlement. Keep producing the exact
    /// same bounded snapshot files in a local rebuildable cache; iCloudBridge
    /// publishes those bytes through NAStatus after each owner-driven write.
    /// Nil when it started (or was superseded); otherwise why it did not.
    /// Readiness is the first publication's result, handed to the bridge.
    @discardableResult
    func startCloudKitSnapshotProjection() async -> String? {
        guard !Task.isCancelled else { return nil }
        let docsURL = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mobile_snapshot_cache", isDirectory: true)
        if isActive, activeDocsURL == docsURL {
            return nil
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        let generation = snapshotLifecycleGeneration
        activeDocsURL = docsURL
        guard await restoreState(generation: generation) else { return nil }
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots, isDirectory: true)
        inboxDir = nil
        responsesDir = docsURL.appendingPathComponent(Folder.responses, isDirectory: true)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions, isDirectory: true)
        let directories = [snapshotDir, responsesDir, transactionDir].compactMap({ $0 })
        if let failure = await createDirectories(directories, generation: generation) { return failure }
        guard generation == snapshotLifecycleGeneration else { return nil }
        isActive = true
        await startArchiveRetentionWatcher()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        reconcileArchiveRetention(pruneFirst: true)
        await startSnapshotIntegrityFallback()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        startPresenceBeat()
        startCognitionSnapshotObservation()
        await startSchedulerSnapshotObservation()
        await startHelpersSnapshotObservation()
        await startConnectorsSnapshotObservation()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        startWorkActivityObservation()
        startLiveTurnRelay()
        startChatTranscriptSnapshotObservation()
        await writeSnapshots(forceHeavy: true)
        if generation == snapshotLifecycleGeneration, isActive, let snapshotDir {
            let failures = await sync.bridge.publishMobileSnapshotStatus(
                groups: Set(NAMobileSnapshotGroup.allCases),
                snapshotDirectory: snapshotDir,
                shouldPublish: { self.snapshotLifecycleGeneration == generation && self.isActive }
            )
            guard generation == snapshotLifecycleGeneration, isActive else { return nil }
            sync.bridge.notePublication(failures)
            // One integrity pass on the fresh snapshot, then its 15-minute clock.
            requestSnapshotIntegrityPass(retrySkipped: true)
        }
        return nil
    }

    /// Nil when it started (or was superseded); otherwise why it did not.
    @discardableResult
    func start(docsURL: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        if isActive, activeDocsURL == docsURL {
            return nil
        }
        if isActive {
            stop()
        }
        snapshotLifecycleGeneration &+= 1
        let generation = snapshotLifecycleGeneration
        activeDocsURL = docsURL
        inboxDir = docsURL.appendingPathComponent(Folder.inbox)
        // Replay state must be restored before either inbox admits work.
        guard await restoreState(generation: generation) else { return nil }
        let secret: Data
        do {
            if pairingSecretRotationInProgress { _ = try pairingSecret() }
            let cached = _pairingSecret
            let loaded = try await sync.storage.perform { try cached ?? PairingSecretManager.loadOrGenerateSecret() }
            guard generation == snapshotLifecycleGeneration else { return nil }
            if pairingSecretRotationInProgress { _ = try pairingSecret() }
            secret = _pairingSecret ?? loaded
            _pairingSecret = secret
        } catch {
            guard generation == snapshotLifecycleGeneration else { return nil }
            syncError = "Snapshot pairing unavailable: \(error.localizedDescription)"
            return syncError
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
        if let failure = await createDirectories(directories, generation: generation) { return failure }
        guard generation == snapshotLifecycleGeneration else { return nil }

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
        await startSnapshotIntegrityFallback()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        startPresenceBeat()
        startCognitionSnapshotObservation()
        await startSchedulerSnapshotObservation()
        await startHelpersSnapshotObservation()
        await startConnectorsSnapshotObservation()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        startWorkActivityObservation()
        startLiveTurnRelay()
        startChatTranscriptSnapshotObservation()

        // Watch inbox for iOS-deposited action files
        startInboxQuery(docsURL: docsURL)

        // Immediate first snapshot, then one integrity pass on it.
        await writeSnapshots(forceHeavy: true)
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        requestSnapshotIntegrityPass(retrySkipped: true)

        // R11-N30: prune at startup, then schedule the exact earliest 7-day
        // retention crossing instead of waking every ten minutes.
        await startArchiveRetentionWatcher()
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        reconcileArchiveRetention(pruneFirst: true)
        return nil
    }


    /// A folder that cannot be made is a start that did not happen.
    private func createDirectories(_ directories: [URL], generation: UInt64) async -> String? {
        let failure = await sync.storage.perform { () -> String? in
            do {
                for directory in directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                return nil
            } catch { return error.localizedDescription }
        }
        guard generation == snapshotLifecycleGeneration, let failure else { return nil }
        syncError = "Phone sync folders could not be created: \(failure)"
        return syncError
    }

    func stop() {
        snapshotLifecycleGeneration &+= 1
        isActive = false
        inboxProcessingQueued = false
        // Do not cancel the processor's accepted action or active phone turns.
        // Their owners settle them; generation checks close further admission.
        workActivityObservationTask?.cancel()
        workActivityObservationTask = nil
        stopLiveTurnRelay()
        workActivityPublicationTask?.cancel()
        // The retiring publisher keeps admission until its physical write ends.
        workActivities.removeAll()
        activeDocsURL = nil
        snapshotIntegrityTask?.cancel()
        snapshotIntegrityTask = nil
        snapshotIntegrityWatcher?.cancel()
        snapshotIntegrityWatcher = nil
        snapshotIntegrityReconcileTask?.cancel()
        snapshotIntegrityReconcileQueued = false
        snapshotIntegrityRetryRequested = false
        snapshotIntegrityObservedSkips = nil
        configurePresenceBeat(enabled: false)
        cognitionSnapshotObservationTask?.cancel()
        cognitionSnapshotObservationTask = nil
        schedulerSnapshotWatcher?.cancel()
        schedulerSnapshotWatcher = nil
        helpersSnapshotWatcher?.cancel()
        helpersSnapshotWatcher = nil
        connectorsSnapshotWatcher?.cancel()
        connectorsSnapshotWatcher = nil
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
        snapshotWriteQueuedNeedsRepublish = false
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

    private func startSnapshotIntegrityFallback() async {
        snapshotIntegrityTask?.cancel()
        snapshotIntegrityWatcher?.cancel()
        guard let snapshotDir else { return }
        let generation = snapshotLifecycleGeneration
        let paths = NAMobileSnapshotGroup.allCases.flatMap(\.filenames).map {
            snapshotDir.appendingPathComponent($0)
        } + [ICloudSyncStatePaths.snapshotSkips(dataRoot: PersistenceCore.defaultDataRoot())]
        // Arm before the launch reconciliation. Exact file events own normal
        // integrity work; the slow clock remains a missed-event backstop.
        let watcher = await FileChangeWatcher.armed(paths: paths) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                self.requestSnapshotIntegrityPass()
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        snapshotIntegrityWatcher = watcher
        OrganPulse.recordStarting("snapshot_integrity", cadence: Self.snapshotIntegrityCadence)
        snapshotIntegrityTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.snapshotIntegrityCadence))
                guard !Task.isCancelled, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                self.requestSnapshotIntegrityPass(retrySkipped: true)
            }
        }
    }

    /// One coalesced reconciliation, including its writes. The snapshot writer
    /// wakes a queued observation at physical exit instead of racing its files.
    func requestSnapshotIntegrityPass(retrySkipped: Bool = false) {
        guard isActive else { return }
        snapshotIntegrityReconcileQueued = true
        snapshotIntegrityRetryRequested = snapshotIntegrityRetryRequested || retrySkipped
        guard snapshotIntegrityReconcileTask == nil, !snapshotWriteInFlight else { return }
        let generation = snapshotLifecycleGeneration
        snapshotIntegrityReconcileTask = Task {
            defer {
                snapshotIntegrityReconcileTask = nil
                if snapshotIntegrityReconcileQueued, isActive { requestSnapshotIntegrityPass() }
            }
            while snapshotIntegrityReconcileQueued, isActive, generation == snapshotLifecycleGeneration, !Task.isCancelled {
                guard !snapshotWriteInFlight else { return }
                snapshotIntegrityReconcileQueued = false
                let retry = snapshotIntegrityRetryRequested
                snapshotIntegrityRetryRequested = false
                await runSnapshotIntegrityPass(retrySkipped: retry)
            }
        }
    }

    private func startPresenceBeat() {
        configurePresenceBeat(enabled: true)
    }

    private func configurePresenceBeat(enabled: Bool) {
        guard enabled || presenceBeatEvents != nil || presenceBeatRegistrationTask != nil else { return }
        presenceBeatEvents?.finish()
        presenceBeatEvents = nil
        presenceBeatDue = enabled ? Date() : nil
        presenceBeatDelay = NAMacPresence.beat
        let generation = snapshotLifecycleGeneration
        let registration: LoopRegistration?
        if enabled {
            let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            presenceBeatEvents = events.continuation
            registration = .enabled(MacSyncPresenceBeat(engine: self, generation: generation, events: events.stream))
        } else {
            registration = nil
        }
        // Start/stop registration changes stay ordered even while the manager
        // drains a prior publication. Admission closed synchronously above.
        let previous = presenceBeatRegistrationTask
        let id = UUID()
        presenceBeatRegistrationID = id
        presenceBeatRegistrationTask = Task {
            defer { if presenceBeatRegistrationID == id { presenceBeatRegistrationTask = nil } }
            await previous?.value
            guard !enabled || (isActive && generation == snapshotLifecycleGeneration) else { return }
            await BackgroundLoopsManager.shared.restartLoop(id: "presence_beat") { @MainActor [self] in
                guard !enabled || (isActive && snapshotLifecycleGeneration == generation) else { return nil }
                return registration
            }
        }
    }

    fileprivate func presenceDeadline(after now: Date, generation: UInt64) -> Date? {
        guard isActive, generation == snapshotLifecycleGeneration, let presenceBeatDue, presenceBeatDue > now else { return nil }
        return presenceBeatDue
    }

    fileprivate func publishPresenceBeat(generation: UInt64) async -> LoopTickOutcome {
        guard !Task.isCancelled, isActive, generation == snapshotLifecycleGeneration else {
            return .skipped(reason: "Phone sync is not active.", healthNeutral: true)
        }
        guard let presenceBeatDue, presenceBeatDue <= Date() else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        let publication = await sync.bridge.publishMacPresence()
        guard !Task.isCancelled, isActive, generation == snapshotLifecycleGeneration else {
            return .skipped(reason: "Phone sync is not active.", healthNeutral: true)
        }
        defer { self.presenceBeatDue = Date().addingTimeInterval(presenceBeatDelay) }
        switch publication {
        case .ineligible:
            return .skipped(reason: "Mac presence is not eligible for this phone.", healthNeutral: true)
        case .published:
            OrganPulse.record("presence_beat", .worked, cadence: NAMacPresence.beat)
            presenceBeatDelay = NAMacPresence.beat
            return .completed(result: nil)
        case .failed:
            presenceBeatDelay = min(NAMacPresence.phoneWindow, presenceBeatDelay * 2)
            return .failed(error: "CloudKit has not accepted Mac presence.")
        }
    }

    /// Slow repair for a missed mutation edge or an externally modified
    /// snapshot.  Normal publications remain event-driven; this pass merely
    /// proves that every cached digest still matches the specific file iOS can
    /// consume before allowing the writer to skip it.
    private func runSnapshotIntegrityPass(retrySkipped: Bool) async {
        guard isActive, let snapshotDir else { return }
        let lifecycleGeneration = snapshotLifecycleGeneration
        let digests = snapshotFileDigests
        let dataRoot = PersistenceCore.defaultDataRoot()
        let (report, skippedGroups) = await Task.detached(priority: .utility) {
            let report = MacSyncSnapshotIntegrity.reconcile(digests: digests, in: snapshotDir)
            let skipsURL = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
            let skippedGroups: [String: String]?
            if FileManager.default.fileExists(atPath: skipsURL.path) {
                if let data = try? Data(contentsOf: skipsURL),
                   let skips = try? JSONDecoder().decode([String: String].self, from: data) {
                    let groups = skips.filter { !$0.key.hasPrefix("_") }
                    skippedGroups = groups.isEmpty ? nil : groups
                } else {
                    skippedGroups = ["_unreadable": "true"]
                }
            } else {
                skippedGroups = nil
            }
            return (report, skippedGroups)
        }.value
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive, !Task.isCancelled else { return }
        guard !snapshotWriteInFlight, digests == snapshotFileDigests else {
            requestSnapshotIntegrityPass(retrySkipped: retrySkipped)
            return
        }
        let retryChangedSkips = skippedGroups != nil && (retrySkipped || skippedGroups != snapshotIntegrityObservedSkips)
        snapshotIntegrityObservedSkips = skippedGroups
        let hasSkippedGroups = skippedGroups != nil

        if report.retainedDigests != snapshotFileDigests {
            snapshotFileDigests = report.retainedDigests
            await saveSnapshotDigests()
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive, !Task.isCancelled else { return }
        }
        let found = report.integrityFailures + (hasSkippedGroups ? ["skipped groups to republish"] : [])
        OrganPulse.record("snapshot_integrity", found: found.count, note: found.joined(separator: "; "),
                          cadence: Self.snapshotIntegrityCadence)
        if report.requiresRepair {
            syncError = "iPhone snapshot integrity check found \(report.integrityFailures.joined(separator: "; ")). Rebuilding the affected mobile snapshot groups."
            // A mismatch can belong to a heavyweight group (catalog, graph,
            // transcripts). A standard pass would retain that bad file forever,
            // so the integrity owner explicitly rebuilds all
            // active projections once.
            await writeSnapshots(forceHeavy: true)
        } else if retryChangedSkips {
            // Failed publications may have no cached digest left to reconcile.
            await writeSnapshots(forceHeavy: true)
        } else if retrySkipped {
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

    /// Connectors are a heavy group, so a light pass never rereads them: a Mac
    /// change to saved setup or a receipt-backed health edge rebuilds them.
    private func startConnectorsSnapshotObservation() async {
        connectorsSnapshotWatcher?.cancel()
        let root = PersistenceCore.defaultDataRoot()
        let generation = snapshotLifecycleGeneration
        connectorHealthState = nil
        let receipts = root.appendingPathComponent("connectors/actions/receipts.jsonl")
        let paths = ["connectors/registry.json", "connectors/slack/auth.json", "telegram/config.json"]
        let watcher = await FileChangeWatcher.armed(paths: paths.map { root.appendingPathComponent($0) } + [receipts]) { [weak self] path in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                await self.publishConnectorHealthChange(force: path != receipts, generation: generation)
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        connectorsSnapshotWatcher = watcher
        // Close the read-to-watch race with one checked projection after arming.
        await publishConnectorHealthChange(force: false, generation: generation)
    }

    private func publishConnectorHealthChange(force: Bool, generation: UInt64) async {
        let health: JSONValue
        do {
            let rows = try await sync.host.getConnectors()
            guard case .array(let values) = try JSONValue.parse(JSONEncoder().encode(rows)) else { return }
            health = .array(values.map { value in
                guard case .object(let row) = value else { return value }
                return .object(row.filter { ["id", "authState", "healthStatus"].contains($0.key) })
            })
        } catch { health = .null }
        guard isActive, generation == snapshotLifecycleGeneration else { return }
        guard force || health != connectorHealthState else { return }
        connectorHealthState = health
        await writeSnapshots(forceHeavy: true)
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

    /// The directory watch precedes discovery; reconciliation adds exact
    /// transaction files before reading them. Keep the old watch until the
    /// replacement is armed so downloads and in-place changes cannot be lost.
    @discardableResult
    func startArchiveRetentionWatcher(transactionDirectories: [URL] = []) async -> Bool {
        let generation = snapshotLifecycleGeneration
        let paths = MacSyncArchiveRetentionWatchPaths.resolve(
            inboxDirectory: inboxDir,
            responsesDirectory: responsesDir,
            transactionDirectory: transactionDir,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
        guard paths.count == (inboxDir == nil ? 5 : 7) else {
            syncError = "Archive retention unavailable: sync directories could not be opened."
            return false
        }
        let transactionFiles: [URL]
        do {
            transactionFiles = try await sync.storage.perform {
                try transactionDirectories.flatMap { directory in
                    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                }.filter { $0.pathExtension == "json" }
            }
        } catch {
            if !Task.isCancelled, isActive, generation == snapshotLifecycleGeneration {
                syncError = "Archive retention unavailable: sync directories could not be opened."
            }
            return false
        }
        let watcher = await FileChangeWatcher.armed(paths: paths + transactionFiles) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                self.reconcileArchiveRetention(pruneFirst: true)
            }
        }
        guard !Task.isCancelled, isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return false }
        archiveRetentionWatcher?.cancel()
        archiveRetentionWatcher = watcher
        return true
    }
}

/// Presence has no equivalent change event: a quiet Mac must keep proving it
/// is here. BackgroundLoops owns exact beat/backoff deadlines plus a
/// phone-window recovery check; the transport owns publication.
private struct MacSyncPresenceBeat: EventDeadlineLoopRunner {
    weak var engine: MacSyncEngine?
    let generation: UInt64
    let events: AsyncStream<Void>
    let loopId = "presence_beat"
    var interval: TimeInterval { NAMacPresence.phoneWindow }
    func physiologyEvents() -> AsyncStream<Void> { events }
    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        await engine?.presenceDeadline(after: now, generation: generation)
    }
    func tickOutcome() async -> LoopTickOutcome {
        await engine?.publishPresenceBeat(generation: generation) ?? .skipped(reason: "Phone sync is not active.", healthNeutral: true)
    }
}
