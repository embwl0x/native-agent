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

/// Cached digests cannot prove file integrity after external replacement; reconcile exact phone-readable files on observation and repair.
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

    /// Repair only current manifest files; stale digest keys cannot justify rebuilding files outside the phone contract.
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
                // A stale digest cannot claim a file outside the mobile contract, even when a same-name artifact remains.
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
                let actualDigest = digest(try VolumeIO.contents(of: url))
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

/// Synchronous actor jobs serialize off-main snapshot CPU work; demand, fences and publication stay with the engine.
actor MobileSnapshotBuilder {
    static let shared = MobileSnapshotBuilder()

    struct CapturedClock: Decodable, Sendable {
        let capturedAt: String
    }

    struct GeneratedClock: Decodable, Sendable {
        let generatedAt: Date
    }

    func build<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value {
        try operation()
    }

    func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        try Self.encoder().encode(value)
    }

    /// Health contains launch facts. The committed elapsed sample required by installed phones changes only with those facts.
    func health(_ health: RuntimeHealth, storedAt url: URL, rebuilding: Bool) async throws -> Data {
        let data = try Self.encoder().encode(health)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidate = try decoder.decode(RuntimeHealth.self, from: data)
        let stored: Data? = try await VolumeIO.run {
            if rebuilding { return nil }
            do { return try VolumeIO.contents(of: url) }
            catch { if MacSyncEngine.isNoSuchFileError(error) { return nil }; throw error }
        }
        if let stored {
            let previous = try decoder.decode(RuntimeHealth.self, from: stored)
            if candidate == previous, case .object(let fields) = try JSONValue.parse(stored), fields["launchedAt"] != nil {
                return stored
            }
        }
        return data
    }

    /// A producer compares with the committed phone copy, including across launches. Only its observation clocks are ignored for equality.
    func state<Value: Codable & Equatable & Sendable>(
        _ candidate: Value, storedAt url: URL, rebuilding: Bool = false,
        retainingClocks: @Sendable (inout Value, Value) -> Void,
        stamp: @Sendable (inout Value, Value?, Date) throws -> Void
    ) async throws -> Value {
        try await state(candidate, storedAt: url, rebuilding: rebuilding, clock: Value.self,
            retainingClocks: retainingClocks, stamp: stamp)
    }

    /// Reconstruction reads change clocks independently of the payload; ordinary unreadable copies fail their build.
    func state<Value: Codable & Equatable & Sendable, Clock: Decodable & Sendable>(
        _ candidate: Value, storedAt url: URL, rebuilding: Bool = false, clock: Clock.Type,
        retainingClocks: @Sendable (inout Value, Value) -> Void,
        stamp: @Sendable (inout Value, Clock?, Date) throws -> Void
    ) async throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidate = try decoder.decode(Value.self, from: Self.encoder().encode(candidate))
        let stored: (value: Value?, clock: Clock?) = try await VolumeIO.run {
            let data: Data
            do { data = try VolumeIO.contents(of: url) }
            catch {
                if rebuilding || MacSyncEngine.isNoSuchFileError(error) { return (nil, nil) }
                throw error
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let storedClock: Clock?
            do { storedClock = try decoder.decode(clock, from: data) }
            catch {
                if !rebuilding { throw error }
                storedClock = nil
            }
            do {
                return (try decoder.decode(Value.self, from: data), storedClock)
            } catch {
                if rebuilding { return (nil, storedClock) }
                throw error
            }
        }
        if let previous = stored.value {
            var comparison = candidate
            retainingClocks(&comparison, previous)
            if comparison == previous { return previous }
        }
        var value = candidate
        try stamp(&value, stored.clock, Date())
        return value
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

    /// The jobs carrying Desk items are their movement on the phone, as on the Mac.
    func desk(_ items: [DeskItem], evidence: [DeskExecutionEvidence]?) throws -> (data: Data, included: Int) {
        try MobileDesk.data(from: items, evidence: evidence ?? [], encoder: Self.encoder())
    }

    func deskReadingCopies(_ items: [DeskItem]) throws -> (data: Data, included: Int) {
        try MobileDeskReadingCopy.data(from: items, encoder: Self.encoder())
    }

    /// Whole pages share the phone's file budget; a page that cannot fit carries its own unavailable cause.
    func faces(_ snapshots: [String: PartFaceSnapshot]) throws -> Data {
        let encoder = Self.encoder()
        var pages = try snapshots.map { id, snapshot in
            (id: id, key: try encoder.encode(id), snapshot: snapshot, data: try encoder.encode(snapshot))
        }.sorted { $0.id < $1.id }
        func file() -> Data {
            var data = Data("{".utf8)
            for page in pages {
                if data.count > 1 { data.append(contentsOf: ",".utf8) }
                data.append(page.key)
                data.append(contentsOf: ":".utf8)
                data.append(page.data)
            }
            data.append(contentsOf: "}".utf8)
            return data
        }
        var data = file()
        let maximumFileBytes = 4 * 1024 * 1024
        let largest = pages.sorted {
            $0.data.count == $1.data.count ? $0.id < $1.id : $0.data.count > $1.data.count
        }
        for page in largest where data.count > maximumFileBytes {
            let snapshot = page.snapshot
            let unavailable = PartFaceSnapshot(part: snapshot.part, version: snapshot.version, sourceEpoch: snapshot.sourceEpoch,
                status: .unavailable, face: nil, error: PartCallError(code: "face_budget_exceeded",
                    message: "This page needs \(page.data.count) bytes and doesn't fit with the other pages in the iPhone's 4 MiB page file. "
                        + "Open it on your Mac or reduce its page content."), owed: snapshot.owed)
            let replacement = try encoder.encode(unavailable)
            pages = pages.map { entry in
                entry.id == page.id ? (entry.id, entry.key, entry.snapshot, replacement) : entry
            }
            data = file()
        }
        guard data.count <= maximumFileBytes else {
            throw DeviceSyncError.payloadTooLarge(actualBytes: data.count, maximumBytes: maximumFileBytes)
        }
        _ = try NAMobileSnapshotStatusCodec.encode(group: .faces, files: ["faces.json": data])
        return data
    }

    func status(group: NAMobileSnapshotGroup, directory: URL, committed: [String: Data]) async throws -> String? {
        let files = try await VolumeIO.run {
            var files = committed.filter { group.filenames.contains($0.key) }
            for filename in group.filenames where files[filename] == nil {
                let url = directory.appendingPathComponent(filename)
                // Missing is optional; unreadable must fail and retain retry demand.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                files[filename] = try VolumeIO.contents(of: url, options: [.mappedIfSafe])
            }
            return files
        }
        guard !files.isEmpty else { return nil }
        return try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
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

/// Carry full priority-item text beside the compact board for offline reading; priority encoding drops least-needed copies first.
enum MobileDeskReadingCopy {
    static let maximumItems = 25
    static let maximumNotesPerItem = 60
    /// Reserve half the board budget: desk.json, bounds and copies share an 800 KiB envelope and need compression headroom.
    static let maximumEncodedBytes = 256 * 1024
    /// Per-string ceilings keep one pathological item from consuming the whole reading-copy file.
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
                    // Source timestamps expose copy age so offline material cannot appear live.
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
