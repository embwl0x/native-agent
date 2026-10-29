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
import TurnTrace
// Blueprint: | `MobileSnapshotBuilder.swift` | Snapshot integrity vocabulary and bounded mobile projection construction |

/// Reconciles the persisted snapshot-digest cache against the files the iPhone
/// actually reads.  The digest cache is an optimization, never evidence that
/// a file remains intact: a same-name file can be truncated or replaced by an
/// out-of-process iCloud/crash-window event while its old digest still sits in
/// memory. Exact file observation and a slow missed-event fallback share this check.
struct SnapshotFileDigest: Codable, Equatable, Sendable {
    let payload: String
    let wire: String
}

enum MacSyncSnapshotIntegrity {
    static let maximumSnapshotBytes = 8 * 1024 * 1024

    struct Report: Equatable {
        let retainedDigests: [String: SnapshotFileDigest]
        let missingManagedFiles: [String]
        let mismatchedManagedFiles: [String]
        let unreadableManagedFiles: [String]
        let retiredDigestKeys: [String]

        var requiresRepair: Bool {
            !missingManagedFiles.isEmpty
                || !mismatchedManagedFiles.isEmpty
                || !unreadableManagedFiles.isEmpty
        }

        var integrityFailures: [String] {
            (missingManagedFiles.map { "\($0) is missing" }
                + mismatchedManagedFiles.map { "\($0) digest mismatch" }
                + unreadableManagedFiles.map { "\($0) unreadable" })
                .sorted()
        }
    }

    /// Only files carried by the current mobile snapshot manifest are repaired.
    /// A missing digest for a retired file is pruned without manufacturing a
    /// costly rebuild for a contract the phone no longer consumes.
    static func reconcile(
        digests: [String: SnapshotFileDigest],
        in directory: URL,
        managedFilenames: Set<String> = Set(NAMobileSnapshotGroup.allCases.flatMap(\.filenames))
    ) -> Report {
        let fileManager = FileManager.default
        var retained: [String: SnapshotFileDigest] = [:]
        var missing: [String] = []
        var mismatched: [String] = []
        var unreadable: [String] = []
        var retired: [String] = []

        for (filename, expectedDigest) in digests {
            let isManaged = managedFilenames.contains(filename)
            let url = directory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else {
                if isManaged { missing.append(filename) } else { retired.append(filename) }
                continue
            }
            guard isManaged else {
                // A stale key must not keep claiming a file that no longer
                // belongs to the mobile contract, even if a same-name artifact
                // happens to remain in the directory.
                retired.append(filename)
                continue
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let byteCount = attributes[.size] as? NSNumber,
                      byteCount.intValue >= 0,
                      byteCount.intValue <= maximumSnapshotBytes else {
                    unreadable.append(filename)
                    continue
                }
                let actualDigest = digest(try Data(contentsOf: url))
                guard actualDigest == expectedDigest.wire else {
                    mismatched.append(filename)
                    continue
                }
                retained[filename] = expectedDigest
            } catch {
                unreadable.append(filename)
            }
        }
        return Report(
            retainedDigests: retained,
            missingManagedFiles: missing.sorted(),
            mismatchedManagedFiles: mismatched.sorted(),
            unreadableManagedFiles: unreadable.sorted(),
            retiredDigestKeys: retired.sorted()
        )
    }

    static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One non-main executor for all snapshot CPU work, including bridge envelopes.
/// Jobs are synchronous within this actor: no suspension can interleave builds.
/// The engine retains ownership of demand, lifecycle fences and publication.
actor MobileSnapshotBuilder {
    static let shared = MobileSnapshotBuilder()

    func build<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value {
        try operation()
    }

    func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        try Self.encoder().encode(value)
    }

    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func inbox(_ items: [InboxItemRecord]) throws -> (data: Data, included: Int) {
        try MobileInbox.data(from: items, encoder: Self.encoder(), alreadyNewestFirst: true)
    }

    func desk(_ items: [DeskItem], executions: [WorkshopTaskRecord]?) throws -> (data: Data, included: Int) {
        let evidence = executions?.map { DeskExecutionEvidence(deskHandle: $0.deskHandle, status: $0.status,
            updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt) }
        return try MobileDesk.data(from: items, evidence: evidence ?? [], encoder: Self.encoder())
    }

    func deskReadingCopies(_ items: [DeskItem]) throws -> (data: Data, included: Int) {
        try MobileDeskReadingCopy.data(from: items, encoder: Self.encoder())
    }

    func status(group: NAMobileSnapshotGroup, directory: URL, committed: [String: Data]) async throws -> String? {
        var files = try await VolumeIO.run {
            var files = committed.filter { group.filenames.contains($0.key) }
            for filename in group.filenames where files[filename] == nil {
                let url = directory.appendingPathComponent(filename)
                // Missing is optional; unreadable must fail and retain retry demand.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                files[filename] = try Data(contentsOf: url, options: [.mappedIfSafe])
            }
            return files
        }
        guard !files.isEmpty else { return nil }
        do {
            return try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
        } catch DeviceSyncError.payloadTooLarge {
            // Shed optional files to fit the shared envelope; retained phone copies keep their own capturedAt.
            for filename in group.trimmableFilenames {
                // Never shed the last file: an empty set is not a publishable
                // group, and the caller is owed the size failure, not a
                // different one.
                guard files.count > 1, files.removeValue(forKey: filename) != nil else { continue }
                nativeLog(
                    "[MacSyncEngine] mobile snapshot %@ exceeded the status envelope — trimmed %@ so the rest still publishes",
                    group.rawValue,
                    filename
                )
                if let value = try? NAMobileSnapshotStatusCodec.encode(group: group, files: files) {
                    return value
                }
            }
            // Nothing trimmable left: the authoritative rows themselves do not
            // fit, which is a real publication failure and keeps retry demand.
            return try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
        }
    }
}

enum MobileInbox {
    static let maximumRows = 300
    static let maximumActiveRows = 200
    static let maximumEncodedBytes = 384 * 1024

    static func data(
        from items: [InboxItemRecord],
        encoder: JSONEncoder,
        alreadyNewestFirst: Bool = false
    ) throws -> (data: Data, included: Int) {
        let sorted = alreadyNewestFirst ? items : items.sorted {
            if $0.created_at != $1.created_at { return $0.created_at > $1.created_at }
            return $0.id > $1.id
        }

        var active: [InboxItemRecord] = []
        var resolved: [InboxItemRecord] = []
        active.reserveCapacity(min(maximumActiveRows, sorted.count))
        resolved.reserveCapacity(min(maximumRows, sorted.count))
        for item in sorted {
            if item.isActivityPending {
                if active.count < maximumActiveRows { active.append(item) }
            } else if resolved.count < maximumRows {
                resolved.append(item)
            }
        }
        resolved = Array(resolved.prefix(max(0, maximumRows - active.count)))
        let projection = active + resolved
        return try EncodedPrefix.largestPrefix(
            count: projection.count, maximumEncodedBytes: maximumEncodedBytes
        ) { try encoder.encode(Array(projection.prefix($0))) }
    }
}

enum MobileDesk {
    static let maximumRows = MobileDeskProjectionBounds.maximumRows
    static let maximumNotesPerItem = 5
    static let maximumEncodedBytes = 512 * 1024

    static func data(from items: [DeskItem], evidence: [DeskExecutionEvidence], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        let latest = Dictionary(grouping: evidence.compactMap { row in
            row.deskHandle.map { ($0, row) }
        }, by: { $0.0 }).compactMapValues {
            $0.map(\.1).max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
        }
        let records = items.sorted {
            if $0.status.isTerminal != $1.status.isTerminal { return !$0.status.isTerminal }
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }.prefix(maximumRows).map { item in
            MobileDeskItem(
                handle: item.handle,
                alias: item.alias,
                parent: item.parent,
                kind: item.kind.rawValue,
                status: item.status.rawValue,
                project: String(item.project.prefix(200)),
                title: String(item.title.prefix(500)),
                summary: item.summary.map {
                    MobileDeskProjectionBounds.clipped(
                        $0, to: MobileDeskProjectionBounds.maximumSummaryCharacters)
                },
                openedAt: item.openedAt,
                updatedAt: item.updatedAt,
                closedAt: item.closedAt,
                pinned: item.pinned,
                blockedReason: item.blockedReason.map { String($0.prefix(1_000)) },
                waitingOn: item.waitingOn.map { String($0.prefix(200)) },
                blockedOn: Array(item.blockedOn.prefix(25)),
                deferUntil: item.deferUntil,
                origin: item.origin.rawValue,
                requiresOwnerInput: item.requiresOwnerInput,
                recentNotes: item.notes.suffix(maximumNotesPerItem).map {
                    MobileDeskNote(
                        timestamp: $0.ts,
                        text: MobileDeskProjectionBounds.clipped(
                            $0.text, to: MobileDeskProjectionBounds.maximumNoteCharacters))
                },
                executionEvidence: latest[item.handle]
            )
        }
        return try EncodedPrefix.largestPrefix(
            count: records.count, maximumEncodedBytes: maximumEncodedBytes
        ) { try encoder.encode(Array(records.prefix($0))) }
    }
}

/// Complete reading copies of the few Desk items worth having in a pocket. The
/// compact board (`desk.json`) is unchanged and still carries every row; this
/// rides beside it and carries the UNCLIPPED text of the items you are most
/// likely to open away from the Mac — the ones waiting on you, the pinned
/// active ones, and then the most recently touched ones. Priority order is also
/// the encoding order, so the size bound drops the least-wanted copies first.
enum MobileDeskReadingCopy {
    static let maximumItems = 25
    static let maximumNotesPerItem = 60
    /// Half the compact board's bound, because the two travel together: the
    /// .desk group packs desk.json, desk_bounds.json and this file into a
    /// single 800 KiB status envelope. At 512 KiB each, an ordinary pair of
    /// full files left the envelope no margin at all; at 256 KiB the copies
    /// still carry ~10 KiB per item, which is a long note, not a clipped one.
    static let maximumEncodedBytes = 256 * 1024
    /// Generous per-string ceilings. These exist so one pathological item
    /// cannot consume the whole file, not to clip ordinary reading material.
    static let maximumTextCharacters = 20_000

    static func priorityRank(requiresOwnerInput: Bool, pinned: Bool) -> Int {
        if requiresOwnerInput { return 0 }
        if pinned { return 1 }
        return 2
    }

    static func data(from items: [DeskItem], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        let records = items
            .filter { !$0.status.isTerminal }
            .sorted { lhs, rhs in
                let lhsRank = priorityRank(requiresOwnerInput: lhs.requiresOwnerInput, pinned: lhs.pinned)
                let rhsRank = priorityRank(requiresOwnerInput: rhs.requiresOwnerInput, pinned: rhs.pinned)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.handle < rhs.handle
            }
            .prefix(maximumItems)
            .map { item in
                MobileDeskItemReadingCopy(
                    handle: item.handle,
                    // The source timestamp of the copy, so the phone can say how
                    // old this reading material is rather than imply it is live.
                    capturedAt: item.updatedAt,
                    summary: item.summary.map { String($0.prefix(maximumTextCharacters)) },
                    blockedReason: item.blockedReason.map { String($0.prefix(maximumTextCharacters)) },
                    notes: item.notes.suffix(maximumNotesPerItem).map {
                        MobileDeskNote(
                            timestamp: $0.ts,
                            text: String($0.text.prefix(maximumTextCharacters))
                        )
                    }
                )
            }
        return try EncodedPrefix.largestPrefix(
            count: records.count, maximumEncodedBytes: maximumEncodedBytes
        ) { try encoder.encode(Array(records.prefix($0))) }
    }
}

enum SnapshotFileWriteResult: Equatable {
    case unchanged
    case changed(Data)
    case failed(String)
}
