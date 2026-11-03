import CommonCrypto
import CryptoKit
import AppKit
import Foundation
import DeviceSyncState
import NativeAgentShared
import NativeAgentCore
import ChatSessionWork
import CognitiveSubstrate
import MemoryV2
import MacIntegration
import ApprovalInbox
import NotificationInbox
import PersistenceCore
import Desk
import Transcripts
import ProviderRouting
// Blueprint: | `MacSyncEngine+SnapshotFreshness.swift` | Manifest-derived stale-page accounting and group build outcomes; cancelled reads remain unavailable |

extension MacSyncEngine {
    /// The staleness marker the phone renders per screen.
    ///
    /// `snapshot_skips.json` is LOCAL Mac bookkeeping (Doctor reads it), so a
    /// skipped group was invisible on the device that was showing the stale
    /// rows. This publishes the same group→reason map into the snapshot bundle
    /// iOS already decodes.
    ///
    /// Deliberately carries NO timestamp: the file's digest drives snapshot
    /// publication, and a per-pass timestamp would wake the phone with a
    /// changed core group on every single tick. A healthy pass publishes `{}`
    /// rather than deleting the file, because the phone's CloudKit cache only
    /// ever gains files — a deleted marker would badge Memory as stale forever.
    nonisolated static let snapshotStalenessFilename = "snapshot_staleness.json"

    nonisolated static func snapshotStalenessMarkerData(
        unresolvedGroups: [String: String]
    ) -> Data? {
        var groups = unresolvedGroups.filter { !$0.key.hasPrefix("_") }
        for (group, message) in NAMobileSnapshotGroup.stalenessMessages(unresolvedGroups) {
            groups["_message.\(group)"] = message
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(groups)
    }

    /// Reconcile one pass with durable stale-state truth. A lightweight pass
    /// must not clear a heavyweight group's prior failure merely because that
    /// group was not attempted. Successfully attempted groups are cleared;
    /// current failures replace their prior reason.
    @discardableResult
    nonisolated static func updateSnapshotSkipState(
        currentSkips: [String: String],
        attemptedGroups: Set<String>,
        dataRoot: URL
    ) -> [String: String] {
        let url = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        var unresolved: [String: String] = [:]
        do {
            let data = try Data(contentsOf: url)
            let prior = try JSONDecoder().decode([String: String].self, from: data)
            unresolved = prior.filter { $0.key != "_observedAt" }
        } catch {
            if !Self.isNoSuchFileError(error) {
                // A current pass cannot prove recovery for groups whose prior
                // obligations are unreadable. Preserve that file unchanged.
                let reason = "Snapshot failure history is unavailable (\(error.localizedDescription)); restore access to icloud/snapshot_skips.json and rebuild phone snapshots."
                nativeLog("[MacSyncEngine] %@", reason)
                let stems = Set(NAMobileSnapshotGroup.allCases.flatMap(\.filenames).map {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                })
                return Dictionary(uniqueKeysWithValues: stems.map { ($0, reason) })
            }
        }
        for group in attemptedGroups {
            unresolved.removeValue(forKey: group)
            unresolved.removeValue(forKey: "_message.\(group)")
        }
        for (group, reason) in currentSkips where group != "_observedAt" {
            unresolved[group] = reason
        }
        persistSnapshotSkipState(unresolved, dataRoot: dataRoot)
        return unresolved
    }

    /// Full replacement helper retained for isolated callers and tests.
    nonisolated static func persistSnapshotSkipState(
        _ skips: [String: String],
        dataRoot: URL
    ) {
        let url = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        guard !skips.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var payload = skips
        payload["_observedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(payload), to: url)
        } catch {
            nativeLog("[MacSyncEngine] could not record snapshot skip state: %@", error.localizedDescription)
        }
    }
}

/// Skipped groups retain last-good files and name their staleness in syncError and Doctor's durable state.
enum SnapshotGroupBuild: Sendable {
    case built(Data)
    case skipped(String)
}
