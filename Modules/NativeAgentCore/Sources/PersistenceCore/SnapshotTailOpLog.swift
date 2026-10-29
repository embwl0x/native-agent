import Foundation
import Darwin
import Synchronization

// Blueprint: | `SnapshotTailOpLog.swift` | `SnapshotTailOpLog`: shared base-plus-tail replay, feed integrity and bounded compaction bookkeeping |

/// Shared replay and compaction; each store retains its persisted base layout and read-consistency rules.
public enum SnapshotTailOpLog {

    // Observation caches compare shared stat identities after their own admission
    // checks. Absence is distinct from failed inspection, which cannot authorize a hit.
    public enum FileStamp: Sendable, Equatable {
        case absent
        /// `changeSeconds`/`changeNanoseconds` are the status-change time, so
        /// a permission or ownership change counts as a change too.
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

    /// What one op-log read could not use.
    public struct OpLogIntegrity: Sendable, Equatable {
        /// Lines that are not parseable JSON at all — EXCLUDING a tolerated
        /// torn trailing line (see `trailingPartialLine`).
        public var malformedLineCount: Int
        /// JSON rows whose op token this build does not recognize.
        public var undecodableRowCount: Int
        /// A tolerated torn trailing line, reported separately from unusable rows.
        public var trailingPartialLine: Bool
        /// Physical rows in the feed, including rows this build cannot use.
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

        /// Malformed and unknown rows; the tolerated trailing partial is excluded.
        public var unusableRowCount: Int { malformedLineCount + undecodableRowCount }

        /// True when no unusable row was skipped.
        public var isClean: Bool { unusableRowCount == 0 }

        /// Threshold on physical rows, at least the decoded count if a caller under-reports them.
        public func feedRowCount(decodedCount: Int) -> Int {
            max(decodedCount, physicalRowCount)
        }

        /// The same integrity after `count` rows were appended to the file this
        /// read described. Used by the in-lock append paths, which know the
        /// post-append file is the pre-append file plus their own rows.
        public func appendingRows(_ count: Int) -> OpLogIntegrity {
            var next = self
            next.physicalRowCount += count
            return next
        }

        public var summary: String {
            "malformedLines=\(malformedLineCount) undecodableRows=\(undecodableRowCount) trailingPartial=\(trailingPartialLine)"
        }
    }

    /// Feed integrity and physical size for Doctor's OpLogHealthCheck.
    public struct OpLogHealth: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            /// Nothing skipped and the feed is within its normal band.
            case ok
            /// The feed is bigger than a healthy compaction cycle should leave
            /// it, or a torn trailing line was seen. Not yet harmful.
            case warn
            /// Rows this build cannot use — compaction is REFUSING to run and
            /// the feed cannot shrink until a build that understands them runs.
            case blocked
        }

        public let feed: String
        public let path: URL
        /// Physical rows in the feed file right now.
        public let physicalRowCount: Int
        /// Bytes on disk. Zero when the feed file does not exist yet.
        public let byteCount: Int
        /// The row count at which this feed's store compacts.
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

        /// A feed that has grown past this multiple of its own compaction
        /// threshold is not merely "due for compaction" — a healthy store
        /// compacts at 1× and lands back under it, so 4× means compaction has
        /// not run in a long time. Warn early enough that growth is caught
        /// before it is felt, without crying wolf on a feed that is simply
        /// between cycles.
        public static let growthWarnMultiple = 4

        public var status: Status {
            if !integrity.isClean { return .blocked }
            if physicalRowCount >= compactionThreshold * Self.growthWarnMultiple { return .warn }
            if integrity.trailingPartialLine { return .warn }
            return .ok
        }

        /// One human-readable line per feed, for the Doctor detail body.
        public var detailLine: String {
            let kib = (byteCount + 1023) / 1024
            switch status {
            case .ok:
                return "\(feed): ok — \(physicalRowCount) row(s), \(kib) KiB"
            case .warn:
                return "\(feed): \(physicalRowCount) row(s), \(kib) KiB — "
                    + "over \(Self.growthWarnMultiple)× the \(compactionThreshold)-row compaction threshold"
                    + (integrity.trailingPartialLine ? " (last line torn — an append may be in flight)" : "")
            case .blocked:
                return "\(feed): COMPACTION BLOCKED — \(integrity.unusableRowCount) unusable row(s) "
                    + "(\(integrity.summary)); feed is \(physicalRowCount) row(s), \(kib) KiB and cannot shrink"
            }
        }

        /// Bytes + physical rows of a feed file, for a store assembling its own
        /// health value. A missing file is a genesis feed, not an error.
        public static func fileSize(_ path: URL) -> Int {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return 0 }
            return (attrs[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    /// Process-wide dedupe for the integrity log so a stale binary appending in
    /// a loop reports once per distinct signature instead of flooding stderr.
    /// Counts CHANGING re-arms it — new damage is new news.
    private static let loggedIntegritySignatures = Mutex<Set<String>>([])
    /// The dedupe memo is keyed on counts, so a feed accruing damage one line at
    /// a time mints a new signature each time. Cap it and start over rather than
    /// letting a long-lived process grow the set without bound — re-logging a
    /// signature is the harmless direction.
    private static let integrityLogMemoCap = 256

    /// Insert `signature`, returning true when it is new.
    private static func claimLogSlot(_ signature: String) -> Bool {
        loggedIntegritySignatures.withLock {
            if $0.count >= integrityLogMemoCap { $0.removeAll(keepingCapacity: true) }
            return $0.insert(signature).inserted
        }
    }

    /// Report an unclean read on stderr, once per distinct (feed, path, counts).
    /// Silent when the read was clean.
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

    /// Replay after the last occurrence of the compacted id; an absent id leaves ops unchanged.
    /// Prefix removal prevents double application after a crash between base and tail writes.
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
