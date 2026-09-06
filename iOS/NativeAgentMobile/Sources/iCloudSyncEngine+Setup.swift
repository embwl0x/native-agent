// PATCH-2026-05-07: ios-parity iCloudSyncEngine — snapshot reader + inbox writer for iOS
// Architecture:
//   READ:  iCloud Drive `snapshots/*.json` — Mac's SnapshotWriter keeps these fresh.
//          KVS key `snapshot_updated` pings iOS when a snapshot changes.
//   WRITE: iOS drops an action envelope into `inbox/<msg_id>.json`.
//          MacSyncEngine validates it, dispatches into the in-process Swift runtime,
//          writes `responses/<msg_id>.json`, then pings `inbox_response_<msg_id>`.

import CryptoKit
import Foundation
import SwiftUI
import NativeAgentShared

extension iCloudSyncEngine {
    private enum KVSKey {
        static let snapshotUpdated = "snapshot_updated"
        static let inboxResponsePrefix = "inbox_response_"
    }

    private enum Folder {
        static let snapshots = "snapshots"
        static let inbox = "inbox"
        static let responses = "responses"
        static let transactions = "transactions/ios"
    }

    // 2026-09-06: the ephemeral-mailbox retention window and how often the
    // prune is allowed to run. See `pruneEphemeralDirectoriesIfDue`.
    static var ephemeralRetentionSeconds: TimeInterval { 14 * 24 * 60 * 60 }
    static var ephemeralPruneIntervalSeconds: TimeInterval { 24 * 60 * 60 }
    static var ephemeralPruneStampKey: String { "NativeAgentMobile.ephemeralPrunedAt" }

    // MARK: - Setup (called after iCloudBridge.setup() completes)

    func setup(docsURL: URL) {
        if isSetUp, snapshotDir?.deletingLastPathComponent() == docsURL {
            return
        }
        tearDown()
        lifecycleGeneration &+= 1
        isSetUp = true
        let fm = FileManager.default
        if prefersCloudKitSnapshotCache {
            let root = cloudKitCacheRoot()
            snapshotDir = root.appendingPathComponent(Folder.snapshots)
            inboxDir = nil
            responsesDir = root.appendingPathComponent(Folder.responses)
            transactionDir = root.appendingPathComponent("transactions", isDirectory: true)
        } else {
            snapshotDir = docsURL.appendingPathComponent(Folder.snapshots)
            inboxDir = docsURL.appendingPathComponent(Folder.inbox)
            responsesDir = docsURL.appendingPathComponent(Folder.responses)
            transactionDir = docsURL.appendingPathComponent(Folder.transactions)
        }

        for dir in [snapshotDir, inboxDir, responsesDir, transactionDir].compactMap({ $0 }) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if !prefersCloudKitSnapshotCache {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(kvsDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kvs
            )
            kvs.synchronize()
        }

        pruneEphemeralDirectoriesIfDue()

        // Initial load stays light. Heavy/tab-specific snapshots are loaded
        // by the visible tab on demand so launch cannot hydrate every chat
        // transcript or memory payload into iPhone RAM.
        Task { await refreshLightweightSnapshots() }
    }

    /// 2026-09-06: `responses/` and `transactions/` are ephemeral mailboxes —
    /// a response is read once by the poll parked on it, a transaction row
    /// records one action that has already finished — and NOTHING ever deleted
    /// from either, so both grew for the life of the install. Prune what is
    /// past the retention window at setup, and at most once a day after that.
    ///
    /// 2026-09-06 (second pass): age alone was the wrong test. A response the
    /// poll had not read yet, and a transaction still `queued`/`sent`/
    /// `pending_approval`, were deleted purely for being old — the phone lost
    /// the answer it was parked on and the ledger row that says an action is
    /// still outstanding. Only TERMINAL transactions and CONSUMED responses go
    /// now: a response counts as consumed when a terminal transaction names it
    /// (by `msgId`, or by id for rows written before that field existed).
    ///
    /// Off the main actor, best effort: a file that will not stat or will not
    /// delete is left alone, and every removal re-stats first so a fresh file
    /// written into the same name between the scan and the unlink is not
    /// deleted in place of the old one. Snapshots and the inbox are untouched —
    /// those are live state with owners of their own.
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
            // Read the ledger BEFORE deleting anything from it: a response is
            // only prunable because some terminal row says it was answered.
            var terminalTransactions: [URL] = []
            var consumedResponseIDs = Set<String>()
            var ledgeredResponseIDs = Set<String>()
            if let transactions {
                for file in Self.prunableFiles(in: transactions) {
                    guard let data = try? Data(contentsOf: file),
                          let record = try? JSONDecoder().decode(
                              ICloudTransactionRecord.self, from: data
                          ) else { continue }
                    ledgeredResponseIDs.insert(record.msgId ?? record.id)
                    ledgeredResponseIDs.insert(record.id)
                    guard Self.isTerminalTransactionState(record.state) else { continue }
                    terminalTransactions.append(file)
                    consumedResponseIDs.insert(record.msgId ?? record.id)
                    consumedResponseIDs.insert(record.id)
                }
            }
            if let responses {
                for file in Self.prunableFiles(in: responses) {
                    let id = file.deletingPathExtension().lastPathComponent
                    // Consumed, or so old its terminal transaction was itself
                    // reaped by an earlier pass — every send writes a `queued`
                    // row before the response can exist, so a response with no
                    // ledger row at all is one whose row has already gone.
                    // Anything still ledgered non-terminally is left alone.
                    guard consumedResponseIDs.contains(id)
                            || !ledgeredResponseIDs.contains(id) else { continue }
                    Self.removeIfUnchanged(file, olderThan: cutoff)
                }
            }
            for file in terminalTransactions {
                Self.removeIfUnchanged(file, olderThan: cutoff)
            }
        }
    }

    /// Every regular file directly inside `directory`. Never recurses, never
    /// throws: an unreadable directory prunes nothing.
    private nonisolated static func prunableFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
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
    private nonisolated static func removeIfUnchanged(_ url: URL, olderThan cutoff: Date) {
        guard let before = Self.fileIdentity(url),
              before.modified < cutoff,
              Self.fileIdentity(url) == before else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct EphemeralFileIdentity: Equatable {
        let inode: UInt64
        let modified: Date
        let size: Int64
    }

    private nonisolated static func fileIdentity(_ url: URL) -> EphemeralFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        return EphemeralFileIdentity(inode: inode, modified: modified, size: size)
    }

    func tearDown() {
        lifecycleGeneration &+= 1
        snapshotRefreshGeneration &+= 1
        targetedRefreshGeneration &+= 1
        chatTranscriptsRefreshGeneration &+= 1
        chatSessionListRefreshGeneration &+= 1
        NotificationCenter.default.removeObserver(self)
        snapshotDir = nil
        inboxDir = nil
        responsesDir = nil
        transactionDir = nil
        isSetUp = false
        refreshInFlight = false
        refreshQueued = false
        syncError = nil
    }

    /// Select the local cache populated by bounded CloudKit NAStatus records.
    /// The bytes retain the existing snapshot contracts; only their transport
    /// changes for public Mac builds that cannot use CloudDocuments.
    func enableCloudKitSnapshotCache() {
        lifecycleGeneration &+= 1
        snapshotRefreshGeneration &+= 1
        targetedRefreshGeneration &+= 1
        chatTranscriptsRefreshGeneration &+= 1
        chatSessionListRefreshGeneration &+= 1
        refreshInFlight = false
        refreshQueued = false
        prefersCloudKitSnapshotCache = true
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        let root = cloudKitCacheRoot()
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        let transactions = root.appendingPathComponent("transactions", isDirectory: true)
        for directory in [snapshots, responses, transactions] {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        snapshotDir = snapshots
        inboxDir = nil
        responsesDir = responses
        transactionDir = transactions
        isSetUp = true
        pruneEphemeralDirectoriesIfDue()
        Task { await refreshLightweightSnapshots() }
    }

    /// 2026-09-06: returns whether the delivery was durably applied. The
    /// transport claims the peer's generation only on `true`; a failure — an
    /// undecodable payload, a write that could not land — now leaves the record
    /// eligible for the next drain instead of being marked seen and lost.
    /// A teardown between the decode and the write is not a failure to retry:
    /// the engine that would have used the files no longer exists.
    @discardableResult
    func applyCloudKitSnapshotStatus(
        _ value: String,
        group: NAMobileSnapshotGroup
    ) async -> Bool {
        let generation = lifecycleGeneration
        do {
            let files = try NAMobileSnapshotStatusCodec.decode(
                value,
                expectedGroup: group
            )
            let directory = cloudKitSnapshotCacheDirectory()
            try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for (filename, data) in files {
                    try data.write(
                        to: directory.appendingPathComponent(filename),
                        options: .atomic
                    )
                }
            }.value
            guard generation == lifecycleGeneration else { return true }
            prefersCloudKitSnapshotCache = true
            snapshotDir = directory
            await refreshSnapshotGroup(group)
            guard generation == lifecycleGeneration else { return true }
            lastSyncAt = Date()
            syncError = nil
            return true
        } catch {
            syncError = "CloudKit \(group.rawValue) snapshot failed: \(error.localizedDescription)"
            return false
        }
    }

    private func cloudKitSnapshotCacheDirectory() -> URL {
        cloudKitCacheRoot().appendingPathComponent("snapshots", isDirectory: true)
    }

    private func cloudKitCacheRoot() -> URL {
        if let cloudKitSnapshotCacheRootOverride {
            return cloudKitSnapshotCacheRootOverride
        }
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("NativeAgentMobile", isDirectory: true)
            .appendingPathComponent("CloudKitContinuity", isDirectory: true)
    }

    // MARK: - KVS ping handler

    // 2026-05-09: nonisolated — KVS callbacks fire on com.apple.kvs.client.callback,
    // not main.  Touching self.* on @MainActor class from off-main fatal-traps
    // (_swift_task_checkIsolatedSwift / EXC_BREAKPOINT).  Hop to MainActor inside.
    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            guard let changed, changed.contains(KVSKey.snapshotUpdated) else { return }
            let signal = self.kvs.string(forKey: KVSKey.snapshotUpdated)
            // Old Mac builds published only an ISO timestamp. Treat that as an
            // unknown group and do one targeted transcript read for continuity;
            // current builds name changed groups and avoid unrelated reads.
            if let groups = Self.snapshotSignalGroups(signal), !groups.isEmpty {
                for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
                    await self.refreshSnapshotGroup(group)
                }
            } else {
                // Legacy timestamp-only publishers did not identify the
                // changed group, so compatibility requires one complete read.
                await self.refreshSnapshots()
            }
        }
    }

    func refreshSnapshotGroup(_ group: NAMobileSnapshotGroup) async {
        // Every group refresh re-reads the Mac's staleness marker: the group
        // that went stale is often NOT the group being refreshed.
        await refreshSnapshotStaleness()
        switch group {
        case .core:
            await refreshLightweightSnapshots()
        case .catalog:
            await refreshCatalogSnapshot()
        case .chat:
            await refreshChatTranscriptsSnapshot()
        case .desk:
            await refreshDeskSnapshot()
        case .activity:
            await refreshActivitySnapshot()
        case .advanced:
            await refreshTurnSummariesSnapshot()
            await refreshRunsSnapshot()
        }
    }

    /// A snapshot signal names the groups whose files the Mac just published.
    /// It is only a complete description of that publication when this build
    /// understands every name in it. A Mac newer than this app can name a group
    /// this enum does not have — a rename or an addition — and silently
    /// dropping that name while refreshing the recognised siblings leaves the
    /// unrecognised group's data stale behind a signal that claimed to cover
    /// the whole write. That is how a phantom STALE badge survives a healthy
    /// Mac publication. An incompletely understood signal is therefore no
    /// signal: return nil so the caller performs the same complete read the
    /// legacy timestamp-only publishers already get.
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
