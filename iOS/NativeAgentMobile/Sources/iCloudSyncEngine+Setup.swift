import Foundation
import SwiftUI
import NativeAgentShared

extension iCloudSyncEngine {
    private nonisolated static func writeWorkOverviewCache(_ data: Data, to url: URL) throws {
        let incoming = try JSONDecoder().decode(WorkOverview.self, from: data)
        guard let incomingDate = DeskActivityState.movementDate(incoming.capturedAt) else {
            throw DeviceSyncError.underlying(message: "invalid work overview state-change time")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let currentData = try VolumeIO.contents(of: url)
            do {
                let current = try JSONDecoder().decode(WorkOverview.self, from: currentData)
                guard let currentDate = DeskActivityState.movementDate(current.capturedAt) else {
                    throw DeviceSyncError.underlying(message: "invalid cached overview state-change time")
                }
                if incomingDate <= currentDate {
                    if incomingDate < currentDate {
                        NSLog("[iCloudSync] work overview cache refused older capturedAt=%@ current=%@", incoming.capturedAt, current.capturedAt)
                    }
                    return
                }
            } catch {
                // This is a derived cache. Preserve unreadable bytes and repair from the checked Mac publication.
                try currentData.write(to: url.appendingPathExtension("unavailable"), options: .atomic)
                NSLog("[iCloudSync] repairing unreadable overview cache from Mac publication: %@", error.localizedDescription)
            }
        }
        try data.write(to: url, options: .atomic)
        NSLog("[iCloudSync] work overview cache wrote capturedAt=%@", incoming.capturedAt)
    }

    static var ephemeralRetentionSeconds: TimeInterval { 14 * 24 * 60 * 60 }
    static var ephemeralPruneIntervalSeconds: TimeInterval { 24 * 60 * 60 }
    static var ephemeralPruneStampKey: String { "NativeAgentMobile.ephemeralPrunedAt" }

    /// Prune off-main at most daily, using retained terminal consumption proof; keep unreadable/changed files and all nonterminal work.
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
                // Read the ledger before deleting responses; only terminal rows prove a response was consumed.
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
                    // Keep consumption proof while its response survives pruning.
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

    /// Unavailable ledger aborts retention before any response deletion.
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

    /// Prune terminal states only; queued, sent and pending_approval remain outstanding regardless of age.
    nonisolated static func isTerminalTransactionState(_ state: String) -> Bool {
        ["completed", "failed", "send_failed", "cancelled", "orphaned"]
            .contains(state.lowercased())
    }

    /// Recheck inode, mtime and size before removing an old file so replacements written under the same name survive.
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

    func connectionRepairMailboxes() -> (transactions: URL?, responses: URL?) {
        let root = cloudKitCacheRoot()
        let cachedTransactions = root.appendingPathComponent("transactions", isDirectory: true)
        let cachedResponses = root.appendingPathComponent("responses", isDirectory: true)
        return (
            transactionDir ?? (FileManager.default.fileExists(atPath: cachedTransactions.path) ? cachedTransactions : nil),
            responsesDir ?? (FileManager.default.fileExists(atPath: cachedResponses.path) ? cachedResponses : nil)
        )
    }

    func tearDown() {
        ActionResponseWaiters.shared.close()
        providerSignIns = [:]
        lifecycleGeneration &+= 1
        workOverview = nil
        snapshotReadRevisions.removeValue(forKey: "work_overview.json")
        snapshotReadRevisions.removeValue(forKey: "telegram.json")
        snapshotReadRevisions.removeValue(forKey: "organism_living_status.json")
        snapshotDir = nil
        helpersSnapshot = nil
        responsesDir = nil
        transactionDir = nil
        isSetUp = false
        refreshInFlight = false
        refreshQueued = false
        cloudKitCatchUpIncomplete = false
        cloudKitCatchUpFailure = nil
        syncError = nil
    }

    /// CloudKit's bounded NAStatus cache preserves the Mac snapshot byte contracts in the phone's local storage.
    func enableCloudKitSnapshotCache() async {
        lifecycleGeneration &+= 1
        refreshInFlight = false
        refreshQueued = false
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
        responsesDir = responses
        transactionDir = transactions
        isSetUp = true
        // What this phone last received opens first: the conversations and their chat are on disk, so Chat shows them before any network
        // or mailbox work, and later deliveries change only what changed.
        _ = await refreshSnapshotGroup(.core)
        _ = await refreshSnapshotGroup(.chat)
        pruneEphemeralDirectoriesIfDue()
        await settleUnobservedActionResponses()
    }

    /// Claim generation only after durable application and successful current-lifecycle refresh; failed/interrupted reads remain eligible.
    @discardableResult
    func applyCloudKitSnapshotStatus(
        _ value: String,
        group: NAMobileSnapshotGroup,
        originatingPairing: Data,
        writtenAt: Date? = nil,
        recovery: DeviceSyncRecovery = .init()
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
                        // Compare and write atomically so concurrent deliveries cannot replace a newer overview.
                        try Self.writeWorkOverviewCache(data, to: directory.appendingPathComponent(filename))
                        continue
                    }
                    let file = directory.appendingPathComponent(filename)
                    do {
                        if try VolumeIO.contents(of: file) == data { continue }
                    } catch {
                        let failure = error as NSError
                        // Only a missing cache permits creation; an unreadable cache retains its cause and bytes.
                        if failure.domain != NSCocoaErrorDomain
                            || (failure.code != NSFileNoSuchFileError && failure.code != NSFileReadNoSuchFileError) {
                            throw error
                        }
                    }
                    try data.write(to: file, options: .atomic)
                }
            }
            guard deliveryPairing == pairingStore?.iCloudPairingSecret else { return false }
            guard generation == lifecycleGeneration else { return false }
            snapshotDir = directory
            // Only successful group refresh accepts status and renews delivery age; failed reads remain eligible.
            let refreshed = await refreshSnapshotGroup(group, recovery: recovery)
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

    /// Freshness may advance only when this group's read reports successful adoption.
    @discardableResult
    func refreshSnapshotGroup(_ group: NAMobileSnapshotGroup, recovery: DeviceSyncRecovery = .init()) async -> Bool {
        // Reread Mac staleness on every group refresh because another group may have become stale.
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
        case .activity:
            return await refreshActivitySnapshot(recovery: recovery)
        case .work:
            return await refreshWorkActivitySnapshot()
        case .faces:
            return await refreshFacesSnapshot()
        case .advanced:
            let summaries = await refreshTurnSummariesSnapshot()
            let runs = await refreshRunsSnapshot().outcome == .refreshed
            let helpers = await refreshHelpersSnapshot()
            let graph = await refreshKnowledgeGraphSnapshot()
            return summaries && runs && helpers && graph
        }
    }

}
