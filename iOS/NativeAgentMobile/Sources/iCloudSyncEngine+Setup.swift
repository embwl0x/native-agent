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
            let root = Self.cloudKitCacheRoot()
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

        // Initial load stays light. Heavy/tab-specific snapshots are loaded
        // by the visible tab on demand so launch cannot hydrate every chat
        // transcript or memory payload into iPhone RAM.
        Task { await refreshLightweightSnapshots() }
    }

    func tearDown() {
        lifecycleGeneration &+= 1
        snapshotRefreshGeneration &+= 1
        targetedRefreshGeneration &+= 1
        chatTranscriptsRefreshGeneration &+= 1
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
        refreshInFlight = false
        refreshQueued = false
        prefersCloudKitSnapshotCache = true
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        let root = Self.cloudKitCacheRoot()
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
        Task { await refreshLightweightSnapshots() }
    }

    func applyCloudKitSnapshotStatus(
        _ value: String,
        group: NAMobileSnapshotGroup
    ) async {
        let generation = lifecycleGeneration
        do {
            let files = try NAMobileSnapshotStatusCodec.decode(
                value,
                expectedGroup: group
            )
            let directory = Self.cloudKitSnapshotCacheDirectory()
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
            guard generation == lifecycleGeneration else { return }
            prefersCloudKitSnapshotCache = true
            snapshotDir = directory
            await refreshSnapshotGroup(group)
            guard generation == lifecycleGeneration else { return }
            lastSyncAt = Date()
            syncError = nil
        } catch {
            syncError = "CloudKit \(group.rawValue) snapshot failed: \(error.localizedDescription)"
        }
    }

    nonisolated private static func cloudKitSnapshotCacheDirectory() -> URL {
        cloudKitCacheRoot().appendingPathComponent("snapshots", isDirectory: true)
    }

    nonisolated private static func cloudKitCacheRoot() -> URL {
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
        switch group {
        case .core:
            await refreshLightweightSnapshots()
        case .catalog:
            await refreshCatalogSnapshot()
        case .chat:
            await refreshChatTranscriptsSnapshot()
        case .activity:
            await refreshActivitySnapshot()
        case .advanced:
            await refreshTurnSummariesSnapshot()
            await refreshRunsSnapshot()
        }
    }

    nonisolated static func snapshotSignalGroups(
        _ value: String?
    ) -> Set<NAMobileSnapshotGroup>? {
        guard let value,
              let marker = value.range(of: "|groups=") else { return nil }
        let rawGroups = value[marker.upperBound...]
        return Set(
            rawGroups
                .split(separator: ",")
                .compactMap { NAMobileSnapshotGroup(rawValue: String($0)) }
        )
    }
}
