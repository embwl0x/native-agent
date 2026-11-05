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
// Blueprint: | `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`, `start`, `stop`; Transport-selected roots; one snapshot lifecycle. |

extension MacSyncEngine {
    /// Writer admission cannot prove repair; only its next health reading proves the postcondition.
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

    /// Republish all pages and presence on reclaim because another Mac may have overwritten unchanged local projections.
    func republishPhonePages() async {
        guard isActive, let snapshotDir else { return }
        sync.bridge.invalidateMobileSnapshotPublication()
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

    /// Drive and CloudKit supply different roots; nil means start succeeded or was superseded, never readiness.
    @discardableResult
    func start(docsURL driveDocsURL: URL? = nil) async -> String? {
        guard !Task.isCancelled else { return nil }
        let docsURL = driveDocsURL ?? PersistenceCore.defaultDataRoot()
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
        inboxDir = driveDocsURL?.appendingPathComponent(Folder.inbox)
        // Replay state must be restored before either inbox admits work.
        guard await restoreState(generation: generation) else {
            return generation == snapshotLifecycleGeneration && !Task.isCancelled ? syncError : nil
        }
        snapshotDir = docsURL.appendingPathComponent(Folder.snapshots, isDirectory: true)
        if driveDocsURL != nil {
            let secret: Data
            do {
                if pairingSecretRotationInProgress { _ = try pairingSecret() }
                let cached = _pairingSecret
                let publicationOwed = sync.bridge.pairingPublicationOwed
                let loaded = try await sync.storage.perform {
                    if let cached { return cached }
                    return try publicationOwed ? PairingSecret.requireExistingSecret() : PairingSecret.loadOrGenerateSecret()
                }
                guard generation == snapshotLifecycleGeneration else { return nil }
                if pairingSecretRotationInProgress { _ = try pairingSecret() }
                secret = _pairingSecret ?? loaded
                _pairingSecret = secret
            } catch {
                guard generation == snapshotLifecycleGeneration else { return nil }
                syncError = "Snapshot pairing unavailable: \(error.localizedDescription)"
                return syncError
            }
            // Match the phone's pairing-scoped cache so another pairing's snapshots cannot enter it.
            let fingerprint = SHA256.hash(data: secret).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            snapshotDir = docsURL.appendingPathComponent(Folder.snapshots)
                .appendingPathComponent("pairings", isDirectory: true)
                .appendingPathComponent(fingerprint, isDirectory: true)
        }
        responsesDir = docsURL.appendingPathComponent(Folder.responses)
        transactionDir = docsURL.appendingPathComponent(Folder.transactions)
        let inboxRejectedDir = driveDocsURL?.appendingPathComponent(Folder.inboxRejected)

        let directories = [snapshotDir, inboxDir, inboxRejectedDir, responsesDir, transactionDir].compactMap({ $0 })
        if let failure = await createDirectories(directories, generation: generation) { return failure }
        guard generation == snapshotLifecycleGeneration else { return nil }

        isActive = true

        if driveDocsURL != nil {
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
        } else {
            await startArchiveRetentionWatcher()
            guard generation == snapshotLifecycleGeneration, isActive else { return nil }
            reconcileArchiveRetention(pruneFirst: true)
        }

        // Exact file observation owns reconciliation, armed before first read.
        await startSnapshotIntegrityObservation()
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

        if driveDocsURL != nil { startInboxQuery(docsURL: docsURL) }

        await writeSnapshots(forceHeavy: true)
        guard generation == snapshotLifecycleGeneration, isActive else { return nil }
        if driveDocsURL == nil, let snapshotDir {
            let failures = await sync.bridge.publishMobileSnapshotStatus(
                groups: Set(NAMobileSnapshotGroup.allCases),
                snapshotDirectory: snapshotDir,
                shouldPublish: { self.snapshotLifecycleGeneration == generation && self.isActive }
            )
            guard generation == snapshotLifecycleGeneration, isActive else { return nil }
            sync.bridge.notePublication(failures)
        }
        requestSnapshotIntegrityPass(retrySkipped: true)

        if driveDocsURL != nil {
            await startArchiveRetentionWatcher()
            guard generation == snapshotLifecycleGeneration, isActive else { return nil }
            reconcileArchiveRetention(pruneFirst: true)
        }
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
        // Passive stop closes admission by generation; accepted actions and turns retain their settlement owners.
        workActivityObservationTask?.cancel()
        workActivityObservationTask = nil
        stopLiveTurnRelay()
        workActivityPublicationTask?.cancel()
        // The snapshot writer keeps admission until its physical write ends.
        activeDocsURL = nil
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
        if let pageFacePublishedObserver {
            NotificationCenter.default.removeObserver(pageFacePublishedObserver)
            self.pageFacePublishedObserver = nil
        }
        chatTranscriptSnapshotPublicationTask?.cancel()
        chatTranscriptSnapshotPublicationTask = nil
        chatSnapshotCoalescer.reset()
        // The retiring pass owns admission until its physical write returns.
        snapshotWriteQueuedScope = nil
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsRepublish = false
        snapshotWriteQueuedNeedsMemories = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        // Clear retired roots so post-stop calls cannot write to a superseded container, even beyond generation fences.
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

    private func startSnapshotIntegrityObservation() async {
        snapshotIntegrityWatcher?.cancel()
        guard let snapshotDir else { return }
        let generation = snapshotLifecycleGeneration
        let paths = NAMobileSnapshotGroup.allCases.flatMap(\.filenames).map {
            snapshotDir.appendingPathComponent($0)
        } + [ICloudSyncStatePaths.snapshotSkips(dataRoot: PersistenceCore.defaultDataRoot())]
        // Arm before the launch reconciliation, including failed publication state.
        let watcher = await FileChangeWatcher.armed(paths: paths) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                self.requestSnapshotIntegrityPass()
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        snapshotIntegrityWatcher = watcher
        OrganPulse.record("snapshot_integrity", .held, note: "observing snapshot files")
    }

    /// The writer wakes queued reconciliation at physical exit so observers cannot race snapshot files.
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
        // Keep registration changes ordered while a prior publication drains; admission is already closed.
        let previous = presenceBeatRegistrationTask
        let id = UUID()
        presenceBeatRegistrationID = id
        presenceBeatRegistrationTask = Task {
            defer { if presenceBeatRegistrationID == id { presenceBeatRegistrationTask = nil } }
            await previous?.value
            guard !enabled || (isActive && generation == snapshotLifecycleGeneration) else { return }
            await BackgroundLoopLifetimes.shared.restartLoop(id: "presence_beat") { @MainActor [self] in
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

    /// Integrity repair verifies exact phone-readable files before cached digests may suppress event-driven publication.
    private func runSnapshotIntegrityPass(retrySkipped: Bool) async {
        guard isActive, let snapshotDir else { return }
        let lifecycleGeneration = snapshotLifecycleGeneration
        let digests = snapshotFileDigests
        let dataRoot = PersistenceCore.defaultDataRoot()
        let result = await VolumeIO.result {
            let report = MacSyncSnapshotIntegrity.reconcile(digests: digests, in: snapshotDir)
            let skipsURL = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
            let skippedGroups: [String: String]?
            if FileManager.default.fileExists(atPath: skipsURL.path) {
                if let data = try? VolumeIO.contents(of: skipsURL),
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
        }
        let report: MacSyncSnapshotIntegrity.Report
        let skippedGroups: [String: String]?
        switch result {
        case .success(let value): (report, skippedGroups) = value
        case .failure(let error):
            syncError = "Snapshot integrity read did not finish: \(error.localizedDescription)"
            return
        }
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
                          cadence: nil)
        if report.requiresRepair {
            syncError = """
                iPhone snapshot integrity check found \(report.integrityFailures.joined(separator: "; ")). Rebuilding the affected mobile snapshot groups.
                """
            // Force heavy projections too; a light pass cannot repair their mismatched files.
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

    /// Setup mutations and receipt health edges must request heavy connector rebuilds; light passes omit them.
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
            health = .array(try await sync.host.getConnectors().map { row in
                .object(["id": row.id, "authState": row.authState, "healthStatus": row.healthStatus]
                    .compactMapValues { $0.map(JSONValue.string) })
            })
        } catch { health = .null }
        guard isActive, generation == snapshotLifecycleGeneration else { return }
        guard force || health != connectorHealthState else { return }
        connectorHealthState = health
        await writeSnapshots(forceHeavy: true)
    }

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
        // Transcript rewrites outside turns publish through the same completion coalescer.
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
        // A changed face rides the light work-activity pass, which carries faces like every pass. A pass refreshes every page itself, so a
        // face that changes during one is already in it and asks for no other.
        if let pageFacePublishedObserver {
            NotificationCenter.default.removeObserver(pageFacePublishedObserver)
        }
        pageFacePublishedObserver = NotificationCenter.default.addObserver(forName: .pageFacePublished, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.snapshotWriteInFlight else { return }
                self.requestWorkActivityPublication()
            }
        }
    }

    /// Completion bursts rebuild only sessions and transcripts, avoiding unrelated heavyweight projections.
    public func requestChatTranscriptSnapshotPublication() {
        requestChatSnapshotPublication(includeTranscripts: true)
    }

    /// One coalescer upgrades pending session-only work when transcript demand arrives, avoiding a second timer.
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

    /// Arm exact files before reads and retain the directory watch during discovery so downloads and in-place changes cannot be lost.
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

/// Presence has no change event: BackgroundLoops owns beat, backoff and phone-window deadlines; transport owns publication.
private struct MacSyncPresenceBeat: EventDeadlineLoopRunner {
    weak var engine: MacSyncEngine?
    let generation: UInt64
    let events: AsyncStream<Void>
    let loopId = "presence_beat"
    var wake: OrganWake { .every(NAMacPresence.phoneWindow) }
    func physiologyEvents() -> AsyncStream<Void> { events }
    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        await engine?.presenceDeadline(after: now, generation: generation)
    }
    func tickOutcome() async -> LoopTickOutcome {
        await engine?.publishPresenceBeat(generation: generation) ?? .skipped(reason: "Phone sync is not active.", healthNeutral: true)
    }
}
