import Foundation
import Darwin
import Synchronization

// Blueprint: | `SnapshotTailOpLog.swift` | `SnapshotTailOpLog`: shared base-plus-tail replay, feed integrity and bounded compaction bookkeeping |

/// Shared replay and compaction; each store retains its persisted base layout and read-consistency rules.
public enum SnapshotTailOpLog {

    // Observation caches compare shared stat identities after their own admission checks. Absence is distinct from failed inspection, which cannot authorize a
    // hit.
    public enum FileStamp: Sendable, Equatable {
        case absent
        /// `changeSeconds`/`changeNanoseconds` are the status-change time, so a permission or ownership change counts as a change too.
        case present(device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int,
                     changeSeconds: Int, changeNanoseconds: Int)

        public init(_ info: stat) {
            self = .present(
                device: info.st_dev,
                inode: info.st_ino,
                size: Int64(info.st_size),
                seconds: info.st_mtimespec.tv_sec,
                nanoseconds: info.st_mtimespec.tv_nsec,
                changeSeconds: info.st_ctimespec.tv_sec,
                changeNanoseconds: info.st_ctimespec.tv_nsec
            )
        }
    }

    public struct FeedStamp: Sendable, Equatable {
        public let ops: FileStamp
        public let base: FileStamp

        public init(ops: FileStamp, base: FileStamp) {
            self.ops = ops
            self.base = base
        }
    }

    public static func fileStamp(_ url: URL) -> FileStamp? {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return FileStamp(info)
        }
        return errno == ENOENT ? .absent : nil
    }

    public struct OpLogIntegrity: Sendable, Equatable {
        /// Exclude the tolerated torn trailing line from unusable-row counts.
        public var malformedLineCount: Int
        public var undecodableRowCount: Int
        public var trailingPartialLine: Bool
        public var physicalRowCount: Int

        public init(
            malformedLineCount: Int = 0,
            undecodableRowCount: Int = 0,
            trailingPartialLine: Bool = false,
            physicalRowCount: Int = 0
        ) {
            self.malformedLineCount = malformedLineCount
            self.undecodableRowCount = undecodableRowCount
            self.trailingPartialLine = trailingPartialLine
            self.physicalRowCount = physicalRowCount
        }

        public static let clean = OpLogIntegrity()

        public var unusableRowCount: Int { malformedLineCount + undecodableRowCount }

        public var isClean: Bool { unusableRowCount == 0 }

        /// Threshold on physical rows, at least the decoded count if a caller under-reports them.
        public func feedRowCount(decodedCount: Int) -> Int {
            max(decodedCount, physicalRowCount)
        }

        /// Locked append paths can extend this receipt because they know exactly which rows followed the read.
        public func appendingRows(_ count: Int) -> OpLogIntegrity {
            var next = self
            next.physicalRowCount += count
            return next
        }

        public var summary: String {
            "malformedLines=\(malformedLineCount) undecodableRows=\(undecodableRowCount) trailingPartial=\(trailingPartialLine)"
        }
    }

    public struct OpLogHealth: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            case ok
            /// Excess size or a torn tail warrants attention before data becomes unusable.
            case warn
            /// Unusable rows block compaction to preserve evidence until a reader understands them.
            case blocked
        }

        public let feed: String
        public let path: URL
        public let physicalRowCount: Int
        /// Missing feeds have zero bytes.
        public let byteCount: Int
        public let compactionThreshold: Int
        public let integrity: OpLogIntegrity

        public init(
            feed: String,
            path: URL,
            physicalRowCount: Int,
            byteCount: Int,
            compactionThreshold: Int,
            integrity: OpLogIntegrity
        ) {
            self.feed = feed
            self.path = path
            self.physicalRowCount = physicalRowCount
            self.byteCount = byteCount
            self.compactionThreshold = compactionThreshold
            self.integrity = integrity
        }

        /// Four times the compaction threshold signals sustained missed compaction while tolerating ordinary between-cycle growth.
        public static let growthWarnMultiple = 4

        public var status: Status {
            if !integrity.isClean { return .blocked }
            if physicalRowCount >= compactionThreshold * Self.growthWarnMultiple { return .warn }
            if integrity.trailingPartialLine { return .warn }
            return .ok
        }

        public var detailLine: String {
            let kib = (byteCount + 1023) / 1024
            switch status {
            case .ok:
                return "\(feed): ok — \(physicalRowCount) row(s), \(kib) KiB"
            case .warn:
                var warnings: [String] = []
                if physicalRowCount >= compactionThreshold * Self.growthWarnMultiple {
                    warnings.append("at least \(Self.growthWarnMultiple)× the \(compactionThreshold)-row compaction threshold")
                }
                if integrity.trailingPartialLine {
                    warnings.append("last line torn — an append may be in flight")
                }
                return "\(feed): \(physicalRowCount) row(s), \(kib) KiB — "
                    + warnings.joined(separator: "; ")
            case .blocked:
                return "\(feed): COMPACTION BLOCKED — \(integrity.unusableRowCount) unusable row(s) "
                    + "(\(integrity.summary)); feed is \(physicalRowCount) row(s), \(kib) KiB and cannot shrink"
            }
        }

        /// Missing files are genesis feeds, not read failures.
        public static func fileSize(_ path: URL) throws -> Int {
            let attrs: [FileAttributeKey: Any]
            do { attrs = try FileManager.default.attributesOfItem(atPath: path.path) }
            catch CocoaError.fileReadNoSuchFile { return 0 }
            guard let bytes = attrs[.size] as? NSNumber else {
                throw PersistenceCoreError.ioFailure("File size is unavailable at \(path.path). Repair access before grading feed health.")
            }
            return bytes.intValue
        }
    }

    /// Log once per integrity signature so unchanged damage cannot flood stderr; changed counts report new evidence.
    private static let loggedIntegritySignatures = Mutex<Set<String>>([])
    /// Bound signatures because damage can grow one row at a time; eviction only causes harmless re-logging.
    private static let integrityLogMemoCap = 256

    private static func claimLogSlot(_ signature: String) -> Bool {
        loggedIntegritySignatures.withLock {
            if $0.count >= integrityLogMemoCap { $0.removeAll(keepingCapacity: true) }
            return $0.insert(signature).inserted
        }
    }

    public static func noteIntegrity(_ integrity: OpLogIntegrity, feed: String, path: URL) {
        guard !integrity.isClean || integrity.trailingPartialLine else { return }
        guard claimLogSlot("\(feed)|\(path.path)|\(integrity.summary)") else { return }
        let severity = integrity.isClean ? "note" : "WARNING"
        FileHandle.standardError.write(Data(
            "\(feed): \(severity) op-log rows skipped at \(path.path) — \(integrity.summary)\n".utf8
        ))
    }

    /// Refuse and report compaction while any row is unusable, preserving its original bytes and order.
    public static func mayCompact(_ integrity: OpLogIntegrity, feed: String, path: URL) -> Bool {
        guard !integrity.isClean else { return true }
        if claimLogSlot("refuse|\(feed)|\(path.path)|\(integrity.summary)") {
            FileHandle.standardError.write(Data(
                """
                \(feed): REFUSING to compact \(path.path) — \(integrity.unusableRowCount) row(s) \
                this build cannot decode (\(integrity.summary)). Compacting would delete them \
                permanently. The feed will keep growing until a build that understands them runs.

                """.utf8
            ))
        }
        return false
    }

    /// Drop the prefix through the last compacted id to prevent double application across a base/tail crash gap.
    public static func dropCompactedPrefix<Op>(
        _ ops: [Op],
        lastCompactedOpId: String,
        id: (Op) -> String
    ) -> [Op] {
        guard let idx = ops.lastIndex(where: { id($0) == lastCompactedOpId }) else { return ops }
        return Array(ops[(idx + 1)...])
    }

    /// Durably write the base before replacing the tail; the caller holds the ops flock.
    public static func commitCompaction(
        baseJSON: JSONValue,
        tailRows: [JSONValue],
        basePath: URL,
        opsPath: URL
    ) async throws {
        let baseData = try baseJSON.serializedData(pretty: true)
        let tailData = try SwiftNativePersistenceCore.serializeJSONL(tailRows)
        try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(baseData, to: basePath)
        try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(tailData, to: opsPath)
    }
}
