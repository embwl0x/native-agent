import Foundation
import SwiftUI
import NativeAgentShared

extension iCloudSyncEngine {
    private nonisolated static func writeWorkOverviewCache(_ data: Data, to url: URL) throws {
        let incoming = try JSONDecoder().decode(WorkOverview.self, from: data)
        guard let incomingDate = DeskActivityState.movementDate(incoming.capturedAt) else {
            throw DeviceSyncError.underlying(message: "invalid work overview capture time")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let currentData = try VolumeIO.contents(of: url)
            if let current = try? JSONDecoder().decode(WorkOverview.self, from: currentData),
               let currentDate = DeskActivityState.movementDate(current.capturedAt),
               incomingDate <= currentDate { return }
        }
        try data.write(to: url, options: .atomic)
    }

    private enum KVSKey {
        static let snapshotUpdated = "snapshot_updated"
    }

    private enum Folder {
        static let snapshots = "snapshots"
        static let inbox = "inbox"
        static let responses = "responses"
        static let transactions = "transactions/ios"
    }

    // Ephemeral-mailbox retention and prune cadence.
    static var ephemeralRetentionSeconds: TimeInterval { 14 * 24 * 60 * 60 }
    static var ephemeralPruneIntervalSeconds: TimeInterval { 24 * 60 * 60 }
    static var ephemeralPruneStampKey: String { "NativeAgentMobile.ephemeralPrunedAt" }

    // MARK: - Drive setup

    func setup(docsURL: URL) async {
        if isSetUp, driveSnapshotRoot == docsURL.appendingPathComponent(Folder.snapshots) {
            return
        }
        tearDown()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let driveRoot = docsURL.appendingPathComponent(Folder.snapshots)
        let secret = pairingStore?.iCloudPairingSecret
        let snapshot = AgentNameCache.fingerprint(secret) == nil
            ? nil : Self.cachedSnapshotDirectory(in: driveRoot, pairing: secret)
        let inbox = docsURL.appendingPathComponent(Folder.inbox)
        let responses = docsURL.appendingPathComponent(Folder.responses)
        let transactions = docsURL.appendingPathComponent(Folder.transactions)
        let directories = [snapshot, inbox, responses, transactions].compactMap { $0 }
        do {
            try await VolumeIO.run {
                for directory in directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            }
        } catch { syncError = error.localizedDescription; return }
        guard generation == lifecycleGeneration else { return }
        snapshotDir = snapshot
        inboxDir = inbox
        responsesDir = responses
        transactionDir = transactions
        driveSnapshotRoot = driveRoot
        isSetUp = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        Task { await PairingStore.synchronizeKVSWithTimeout() }

        pruneEphemeralDirectoriesIfDue()

        // Initial load stays light. Heavy/tab-specific snapshots are loaded
        // by the visible tab on demand so launch cannot hydrate every chat
        // transcript or memory payload into iPhone RAM.
    }

    /// Prune old terminal transactions and consumed responses off-main, at setup and at most daily.
    /// Only a retained terminal response receipt proves consumption.
    /// Recheck file identity before removal; unreadable or changed files survive.
    /// Nonterminal transactions, snapshots and inbox files remain untouched.
    func pruneEphemeralDirectoriesIfDue(force: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: Self.ephemeralPruneStampKey)
        guard force || last <= 0 || now - last >= Self.ephemeralPruneIntervalSeconds else { return }
        let responses = responsesDir
        let transactions = transactionDir
        guard responses != nil || transactions != nil else { return }
        defaults.set(now, forKey: Self.ephemeralPruneStampKey)
        let cutoff = Date(timeIntervalSince1970: now - Self.ephemeralRetentionSeconds)
        Task.detached(priority: .utility) {
            let result = await VolumeIO.result {
                // Read the ledger BEFORE deleting anything from it: a response is
                // only prunable because some terminal row says it was answered.
                var terminalTransactions: [URL] = []
                var consumedResponseIDs = Set<String>()
                if let transactions {
                    for file in try Self.prunableFiles(in: transactions) {
                        let data = try VolumeIO.contents(of: file)
                        let record = try JSONDecoder().decode(ICloudTransactionRecord.self, from: data)
                        guard Self.isTerminalTransactionState(record.state),
                              let receipt = record.response, let messageID = record.msgId,
                              receipt["msgId"] == messageID, receipt["transactionId"] == record.id,
                              receipt["action"] == record.action,
                              InboxAction.responseTransactionState(receipt) == record.state else { continue }
                        terminalTransactions.append(file)
                        consumedResponseIDs.insert(messageID)
                    }
                }
                if let responses {
                    for file in try Self.prunableFiles(in: responses) {
                        let id = file.deletingPathExtension().lastPathComponent
                        guard consumedResponseIDs.contains(id) else { continue }
                        try Self.removeIfUnchanged(file, olderThan: cutoff)
                    }
                }
                for file in terminalTransactions {
                    let record = try JSONDecoder().decode(ICloudTransactionRecord.self, from: VolumeIO.contents(of: file))
                    // Keep the consumption proof while its response survives
                    // (too young, changed, or not removed).
                    guard let messageID = record.msgId else { continue }
                    if let responses,
                       try Self.readActionMailboxFile(at: responses.appendingPathComponent("\(messageID).json")) != nil {
                        continue
                    }
                    try Self.removeIfUnchanged(file, olderThan: cutoff)
                }
            }
            if case .failure(let error) = result {
                NSLog("[iCloudSync] ledger retention did not finish: %@; unreadable evidence cannot authorize response deletion", error.localizedDescription)
                await MainActor.run {
                    self.syncError = "Action mailbox retention did not finish: \(error.localizedDescription). Unconsumed response evidence was retained."
                }
            }
        }
    }

    /// Every non-directory entry directly inside `directory`. An unavailable
    /// ledger aborts retention before any response deletion.
    private nonisolated static func prunableFiles(in directory: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try files.filter { url in
            try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true
        }
    }

    /// The states after which nothing more will happen to a transaction. A row
    /// in any other state (`queued`, `sent`, `pending_approval`) is still
    /// outstanding and is never pruned, however old it is.
    nonisolated static func isTerminalTransactionState(_ state: String) -> Bool {
        ["completed", "failed", "send_failed", "cancelled", "orphaned"]
            .contains(state.lowercased())
    }

    /// Delete `url` only if it is older than `cutoff` AND is still the same
    /// file it was when that was measured — same inode, same modification date,
    /// same size. A replacement written into the same name between the two
    /// stats survives.
    private nonisolated static func removeIfUnchanged(_ url: URL, olderThan cutoff: Date) throws {
        let before = try Self.fileIdentity(url)
        guard
              before.modified < cutoff,
              try Self.fileIdentity(url) == before else { return }
        try FileManager.default.removeItem(at: url)
    }

    private struct EphemeralFileIdentity: Equatable {
        let inode: UInt64
        let modified: Date
        let size: Int64
    }

    private nonisolated static func fileIdentity(_ url: URL) throws -> EphemeralFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw SyncError.persistence("Mailbox retention could not identify \(url.lastPathComponent); its evidence was retained.")
        }
        return EphemeralFileIdentity(inode: inode, modified: modified, size: size)
    }

    func connectionRepairMailboxes() -> (transactions: URL?, responses: URL?, inbox: URL?) {
        let root = cloudKitCacheRoot()
        let cachedTransactions = root.appendingPathComponent("transactions", isDirectory: true)
        let cachedResponses = root.appendingPathComponent("responses", isDirectory: true)
        return (
            transactionDir ?? (FileManager.default.fileExists(atPath: cachedTransactions.path) ? cachedTransactions : nil),
            responsesDir ?? (FileManager.default.fileExists(atPath: cachedResponses.path) ? cachedResponses : nil),
            inboxDir
        )
    }

    func tearDown() {
        providerSignIns = [:]
        lifecycleGeneration &+= 1
        schedulerSnapshot = nil
        workOverview = nil
        schedulerJobReceiptTimes = [:]
        schedulerError = nil
        NotificationCenter.default.removeObserver(self)
        snapshotDir = nil
        driveSnapshotRoot = nil
        helpersSnapshot = nil
        inboxDir = nil
        responsesDir = nil
        transactionDir = nil
        isSetUp = false
        refreshInFlight = false
        refreshQueued = false
        cloudKitCatchUpIncomplete = false
        cloudKitCatchUpFailed = false
        syncError = nil
    }

    /// Select the local cache populated by bounded CloudKit NAStatus records.
    /// The bytes retain the existing snapshot contracts; only their transport
    /// changes for public Mac builds that cannot use CloudDocuments.
    func enableCloudKitSnapshotCache() async {
        lifecycleGeneration &+= 1
        refreshInFlight = false
        refreshQueued = false
        prefersCloudKitSnapshotCache = true
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        let root = cloudKitCacheRoot()
        let snapshots = cloudKitSnapshotCacheDirectory(pairing: pairingStore?.iCloudPairingSecret)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        let transactions = root.appendingPathComponent("transactions", isDirectory: true)
        let generation = lifecycleGeneration
        do {
            try await VolumeIO.run {
                for directory in [snapshots, responses, transactions] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
            }
        } catch { isSetUp = false; syncError = error.localizedDescription; return }
        guard generation == lifecycleGeneration else { return }
        snapshotDir = snapshots
        inboxDir = nil
        responsesDir = responses
        transactionDir = transactions
        isSetUp = true
        pruneEphemeralDirectoriesIfDue()
        await settleUnobservedActionResponses()
    }

    /// Claim a status generation only after durable application and a successful
    /// current-lifecycle refresh; interrupted or failed reads remain eligible.
    @discardableResult
    func applyCloudKitSnapshotStatus(
        _ value: String,
        group: NAMobileSnapshotGroup,
        originatingPairing: Data,
        writtenAt: Date? = nil
    ) async -> Bool {
        let generation = lifecycleGeneration
        let deliveryPairing = originatingPairing
        // Leave deliveries eligible for retry until pairing is installed.
        guard deliveryPairing.count == 32,
              deliveryPairing == pairingStore?.iCloudPairingSecret else { return false }
        do {
            let directory = cloudKitSnapshotCacheDirectory(pairing: deliveryPairing)
            try await VolumeIO.run {
                let files = try NAMobileSnapshotStatusCodec.decode(
                    value,
                    expectedGroup: group
                )
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for (filename, data) in files {
                    if filename == "work_overview.json" {
                        // Compare and write together so concurrent deliveries
                        // cannot undo a newer overview.
                        try Self.writeWorkOverviewCache(data, to: directory.appendingPathComponent(filename))
                        continue
                    }
                    try data.write(
                        to: directory.appendingPathComponent(filename),
                        options: .atomic
                    )
                }
            }
            guard deliveryPairing == pairingStore?.iCloudPairingSecret else { return false }
            guard generation == lifecycleGeneration else { return false }
            prefersCloudKitSnapshotCache = true
            snapshotDir = directory
            // Only an explicitly successful group refresh accepts this status
            // and renews its delivery clock; keep failed reads eligible for retry.
            let refreshed = await refreshSnapshotGroup(group)
            guard deliveryPairing == pairingStore?.iCloudPairingSecret else { return false }
            guard generation == lifecycleGeneration else { return false }
            if refreshed {
                if let writtenAt {
                    iCloudBridge.shared.recordMacConfirmation(at: writtenAt)
                }
                noteTransportDelivery(groups: [group])
                noteRefreshSucceeded()
            }
            return refreshed
        } catch {
            guard generation == lifecycleGeneration else { return false }
            NSLog("[iCloudSyncEngine] %@ snapshot failed: %@", group.rawValue, error.localizedDescription)
            syncError = "Mac updates could not be received. The last received data is still available. Open Connection in Settings to check the Mac link."
            return false
        }
    }

    func cloudKitSnapshotCacheDirectory(pairing secret: Data?) -> URL {
        Self.cachedSnapshotDirectory(
            in: cloudKitCacheRoot().appendingPathComponent("snapshots", isDirectory: true),
            pairing: secret
        )
    }

    private func cloudKitCacheRoot() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("NativeAgentMobile", isDirectory: true)
            .appendingPathComponent("CloudKitContinuity", isDirectory: true)
    }

    // MARK: - KVS ping handler

    // KVS callbacks arrive off-main; only the MainActor hop may touch engine state.
    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            for key in changed ?? [] where key.hasPrefix("inbox_response_") {
                do {
                    _ = try await self.pollResponse(msgId: String(key.dropFirst("inbox_response_".count)))
                } catch {
                    NSLog("[iCloudSync] response arrival did not settle: %@", error.localizedDescription)
                }
            }
            guard let changed, changed.contains(KVSKey.snapshotUpdated) else { return }
            let signal = self.kvs.string(forKey: KVSKey.snapshotUpdated)
            let writtenAt = signal?.components(separatedBy: "|").first.flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            // The ping says the Mac published; only the group read that
            // actually landed is evidence THAT group's rows arrived, so each
            // group renews its own delivery clock on its own success.
            if let groups = Self.snapshotSignalGroups(signal), !groups.isEmpty {
                for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
                    if await self.refreshSnapshotGroup(group) {
                        if let writtenAt {
                            iCloudBridge.shared.recordMacConfirmation(at: writtenAt)
                        }
                        self.noteTransportDelivery(groups: [group])
                    }
                }
            } else {
                guard signal != nil else { return }
                self.syncError = "The Mac's snapshot signal names no supported publication group. Refresh the Mac's phone snapshots to repair this signal."
            }
        }
    }

    /// Returns whether this group's read landed. The caller claims freshness
    /// from this value alone.
    @discardableResult
    func refreshSnapshotGroup(_ group: NAMobileSnapshotGroup) async -> Bool {
        // Every group refresh re-reads the Mac's staleness marker: the group
        // that went stale is often NOT the group being refreshed.
        await refreshSnapshotStaleness()
        switch group {
        case .core:
            return await refreshLightweightSnapshots()
        case .catalog:
            return await refreshCatalogSnapshot()
        case .chat:
            return await refreshChatTranscriptsSnapshot()
        case .desk:
            return await refreshDeskSnapshot()
        case .scheduler:
            return await refreshSchedulerSnapshot()
        case .activity:
            return await refreshActivitySnapshot()
        case .work:
            return await refreshWorkActivitySnapshot()
        case .advanced:
            let summaries = await refreshTurnSummariesSnapshot()
            let runs = await refreshRunsSnapshot().outcome == .refreshed
            let helpers = await refreshHelpersSnapshot()
            let graph = await refreshKnowledgeGraphSnapshot()
            return summaries && runs && helpers && graph
        }
    }

    /// A publication names only current groups; malformed/unknown signals are refused.
    nonisolated static func snapshotSignalGroups(
        _ value: String?
    ) -> Set<NAMobileSnapshotGroup>? {
        guard let value,
              let marker = value.range(of: "|groups=") else { return nil }
        var groups: Set<NAMobileSnapshotGroup> = []
        for token in value[marker.upperBound...].split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces)
            // An empty slot names nothing; it does not make the signal unknown.
            guard !name.isEmpty else { continue }
            guard let group = NAMobileSnapshotGroup(rawValue: name) else { return nil }
            groups.insert(group)
        }
        return groups
    }
}
