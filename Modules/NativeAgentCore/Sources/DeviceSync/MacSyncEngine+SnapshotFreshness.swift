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
    /// Publish stale-group reasons to the phone without timestamps so unchanged failures do not wake it every pass. Publish {} on recovery: the phone's
    /// additive cache cannot clear a stale marker by deletion.
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

    /// A light pass cannot clear an unattempted heavy group's failure; only successful attempted groups prove recovery.
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
                // Unreadable prior obligations prevent proof of recovery; preserve their bytes.
                let reason = """
                    Snapshot failure history is unavailable (\(error.localizedDescription)); restore access to icloud/snapshot_skips.json and rebuild phone \
                    snapshots.
                    """
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

/// Retained snapshots must expose skipped-group staleness in syncError and durable diagnostic state.
enum SnapshotGroupBuild: Sendable {
    case built(Data)
    case skipped(String)
}
