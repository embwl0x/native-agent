import Foundation
import Darwin
import NativeAgentCore

// MARK: - Errors

/// Errors raised by the persistence layer.
public enum PersistenceCoreError: Error, Equatable {
    case nonFiniteFloat(Double, path: String)
    case ioFailure(String)
}

// MARK: - Protocol

/// Atomic JSON / JSONL file IO using the stable NativeAgent file shapes.
public protocol PersistenceCoreProtocol: Sendable {
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue
    func writeJSON(_ value: JSONValue, to path: URL) async throws
    func appendJSONL(_ record: JSONValue, to path: URL) async throws
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue]
    func tailJSONLReadReceipt(
        _ path: URL,
        limit: Int,
        maxBytes: Int?
    ) async throws -> SwiftNativePersistenceCore.JSONLTailReadReceipt
    func readJSONL(_ path: URL) async throws -> [JSONValue]
    func replaceJSONL(_ records: [JSONValue], to path: URL) async throws
    /// REQUIREMENTS, not just extension members: `SwiftNativeDeskStore` holds an
    /// `any PersistenceCoreProtocol`, and a protocol-extension-only method on an
    /// existential dispatches STATICALLY to the default — the real
    /// implementation would never run and every desk read would report a clean
    /// feed. Declaring them here makes the witness table carry them. Defaults
    /// live in the extension below, so no existing conformer breaks.
    func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport)
    func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws
    /// Atomic replacement of an ALREADY-SERIALIZED payload with the same
    /// durability guarantees `writeJSON` gets: temp file written + fsync'd,
    /// renamed, then the PARENT DIRECTORY fsync'd so power loss cannot forget
    /// the rename. Exists because callers that own their own byte formatting
    /// (the chat session index, which serializes through `ChatSessionIndexFile`
    /// so its on-disk shape is fixed) were reaching for bare
    /// `Data.write(.atomic)` — atomic against a crash, but NOT durable against
    /// power loss. A protocol requirement, not extension-only, so an
    /// existential dispatches to the real implementation.
    func writeDataAtomicDurable(_ data: Data, to path: URL) async throws
}

/// What a raw JSONL scan had to throw away (audit 2026-08-02, finding 2).
///
/// `readJSONL` drops any line it cannot parse. Tolerating a TORN TRAILING line
/// is right — an append that had not landed whole when we read will land, and
/// the writer re-appends. Silently dropping a malformed line in the MIDDLE of a
/// file is not: a desk that lost three ops looks byte-for-byte as healthy as one
/// that lost none. This carries the count back out so a store can say so.
public struct JSONLReadReport: Sendable, Equatable {
    /// Unparseable lines that are NOT the tolerated trailing partial. Real
    /// damage: bytes between two good lines that no longer decode.
    public var malformedLineCount: Int
    /// The file's last line was torn (no trailing newline). Tolerated, reported.
    public var trailingPartialLine: Bool
    /// PHYSICAL rows the scan walked — every non-empty line in the file,
    /// whether or not it parsed and whether or not this build understood it.
    ///
    /// WHY IT EXISTS (gpt-5.5 review 2026-08-02, finding 2): every op-log store
    /// thresholds compaction on how big the FEED is, and before this it counted
    /// DECODED entries. A stale binary facing 100k rows it cannot decode plus 10
    /// it can would compute a feed size of 10 — under every threshold — so the
    /// compaction path (and with it the loud "REFUSING to compact" warning that
    /// is the only product signal of the wedge) never ran at all, while the file
    /// grew without bound. The threshold has to key on bytes-on-disk, and this
    /// is the row-shaped proxy for them that the scan already computes.
    public var physicalLineCount: Int

    public init(
        malformedLineCount: Int = 0,
        trailingPartialLine: Bool = false,
        physicalLineCount: Int = 0
    ) {
        self.malformedLineCount = malformedLineCount
        self.trailingPartialLine = trailingPartialLine
        self.physicalLineCount = physicalLineCount
    }

    public static let clean = JSONLReadReport()
    public var isClean: Bool { malformedLineCount == 0 && !trailingPartialLine }
}

extension PersistenceCoreProtocol {
    /// Non-file-backed conformers have no physical JSONL rows beyond the
    /// bounded values they return. Native file persistence supplies the real
    /// malformed-row accounting through its witness.
    public func tailJSONLReadReceipt(
        _ path: URL,
        limit: Int,
        maxBytes: Int?
    ) async throws -> SwiftNativePersistenceCore.JSONLTailReadReceipt {
        let rows = try await tailJSONL(path, limit: limit, maxBytes: maxBytes)
        return SwiftNativePersistenceCore.JSONLTailReadReceipt(
            rows: rows,
            physicalRowsScanned: rows.count,
            malformedJSONRowCount: 0,
            bytesRead: 0,
            truncatedToByteWindow: false
        )
    }

    /// `readJSONL` plus what the scan discarded.
    ///
    /// THE DEFAULT NEVER CLAIMS A CLEAN SCAN IT HAS NOT PROVEN (gpt-5.5 review
    /// 2026-08-02, finding 4). The previous default hard-coded `.clean`, which
    /// is only true for a conformer with no file behind it. A file-backed
    /// wrapper — a decorator that implements `readJSONL` by delegating to
    /// `SwiftNativePersistenceCore` and simply never thinks about this method —
    /// inherited "clean" for a feed that had malformed rows on disk, and the
    /// compaction gate it feeds then rewrote the file and erased them. Nothing
    /// about that conformance is visibly wrong at the call site, which is
    /// exactly why the default has to be safe rather than convenient.
    ///
    /// So: if a real file exists at `path`, the report is derived from THOSE
    /// BYTES via the canonical scanner — the same bytes compaction is about to
    /// rewrite — and only a path with no file falls back to describing the rows
    /// the conformer returned. A delegating wrapper therefore reports honestly
    /// whether or not its author remembered this method; an in-memory shim
    /// still reports clean, because for it that IS the truth. The cost is one
    /// extra read for delegating conformers only; `SwiftNativePersistenceCore`
    /// overrides this method outright and never pays it.
    public func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport) {
        let rows = try await readJSONL(path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return (rows, JSONLReadReport(physicalLineCount: rows.count))
        }
        let fileReport = try await SwiftNativePersistenceCore().readJSONLReporting(path).report
        return (rows, fileReport)
    }

    /// Durable append: the bytes are on the platter before this returns.
    ///
    /// The default delegates to the plain `appendJSONL` — a shim with no real
    /// file has nothing to flush. `SwiftNativePersistenceCore` overrides it with
    /// an `F_FULLFSYNC` before the descriptor closes.
    public func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
        try await appendJSONL(record, to: path)
    }

    /// Durable atomic replacement of pre-serialized bytes.
    ///
    /// The default routes through the canonical writer rather than
    /// `Data.write(.atomic)` so a delegating wrapper that never thinks about
    /// this method still gets the temp-fsync + rename + parent-dir-fsync
    /// guarantees. An in-memory shim that wants different behavior overrides it.
    public func writeDataAtomicDurable(_ data: Data, to path: URL) async throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }
}

extension PersistenceCoreProtocol {
    /// Default tail: last 20 records, scanning up to 1 MiB from end of file.
    public func tailJSONL(_ path: URL) async throws -> [JSONValue] {
        try await tailJSONL(path, limit: 20, maxBytes: 1_048_576)
    }

    /// Default atomic JSONL replacement (op-log compaction truncate).
    ///
    /// A conformer that inherits this implementation must retain the same
    /// durability contract as the native writer. Compaction writes its base
    /// first; accepting a non-durable truncate afterward would make a power
    /// loss look like a successful commit while losing the replay tail.
    public func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        try await writeDataAtomicDurable(payload, to: path)
        _ = chmod(path.path, 0o600)
    }
}

// MARK: - SwiftNative implementation

/// Native Swift implementation. Pure file IO — stateless and implicitly Sendable.
public final class SwiftNativePersistenceCore: PersistenceCoreProtocol {
    public init() {}

    /// Observable only through task-local evaluation scope. Keeping the
    /// durability phases beside the real atomic writer lets a boundary eval
    /// distinguish a crash-atomic rename from the required parent-directory
    /// flush without changing the product's I/O path.
    enum AtomicWriteDurabilityPhase: Sendable, Equatable {
        case temporaryFileSynced
        case parentDirectorySynced
    }

    @TaskLocal static var atomicWriteDurabilityObserver:
        (@Sendable (AtomicWriteDurabilityPhase) -> Void)?

    public func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        guard let data = try? Data(contentsOf: path) else { return defaultValue }
        guard let parsed = try? JSONValue.parse(data) else { return defaultValue }
        return parsed
    }

    public func writeJSON(_ value: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try value.serializedData(pretty: true)
        try Self.atomicWrite(payload, to: path)
    }

    public func writeDataAtomicDurable(_ data: Data, to path: URL) async throws {
        try Self.writeDataAtomicDurable(data, to: path)
    }

    /// Synchronous entry point for callers that own their serialization and
    /// hold a lock across the write (the chat session index). Same durability
    /// tail as `writeJSON`: tmp fsync → rename → parent-directory fsync.
    public static func writeDataAtomicDurable(_ data: Data, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(data, to: path)
    }

    public func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try appendRecords([record], to: path, durable: false)
    }

    /// Append a known transaction of JSONL records with one file write. The
    /// caller must hold the feed's cross-process lock. This keeps a projection
    /// refresh from turning one logical transaction into dozens of vnode edges.
    public func appendJSONL(_ records: [JSONValue], to path: URL) async throws {
        try appendRecords(records, to: path, durable: false)
    }

    /// Durable batch append — one write, one `F_FULLFSYNC`. Same contract as the
    /// single-record `appendJSONLDurable`; used by the op-log stores that commit
    /// a multi-op transaction under one flock.
    public func appendJSONLDurable(_ records: [JSONValue], to path: URL) async throws {
        try appendRecords(records, to: path, durable: true)
    }

    private func appendRecords(_ records: [JSONValue], to path: URL, durable: Bool) throws {
        guard !records.isEmpty else { return }
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.appendBytes(Self.serializeJSONL(records), to: path, durable: durable)
        _ = chmod(path.path, 0o600)
    }

    private static func serializeJSONL(_ records: [JSONValue]) throws -> Data {
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        return payload
    }

    /// Atomically REPLACES a JSONL file's entire contents (single rename —
    /// no window where the file is partially written). An empty `records`
    /// truncates the feed. For op-log compaction; the caller is responsible
    /// for holding the cross-process `withFileLock` around this when shared.
    public func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.atomicWrite(Self.serializeJSONL(records), to: path)
        _ = chmod(path.path, 0o600)
    }

    /// JSONL append that does NOT chmod the target and creates with
    /// umask-derived permissions. Used for audit-style files where an existing
    /// 0644 mode must be preserved rather than tightened to 0600.
    /// Identical to `appendJSONL` otherwise. Callers that own the file
    /// exclusively should prefer `appendJSONL`. The caller is responsible for
    /// holding the cross-process `withFileLock` around this when shared.
    public func appendAuditLine(_ record: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var line = try record.serialize(pretty: false)
        line += "\n"
        try Self.appendBytes(Data(line.utf8), to: path, createMode: 0o666)
    }

    /// Append a pre-serialized JSON line (no re-encode) under the SAME file-mode
    /// posture as `appendAuditLine` (0o666 create-mode ⇒ umask-derived 0644,
    /// no chmod on an existing file).
    /// Used when the caller has already produced byte-exact output via
    /// `serializeOrderedObjectPython` and must NOT have it re-sorted by the
    /// `serialize` path. A trailing newline is appended (one row per line). The
    /// caller is responsible for holding `withFileLock` around this when the
    /// file has multiple writers.
    public func appendAuditLineRaw(_ jsonLine: String, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = jsonLine + "\n"
        try Self.appendBytes(Data(line.utf8), to: path, createMode: 0o666)
    }

    public func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await readJSONLReporting(path).rows
    }

    /// The real scan behind `readJSONL`. Row-for-row IDENTICAL to what it always
    /// returned — the only addition is the accounting of what got dropped.
    ///
    /// A parse failure on the LAST line of a file that does not end in `\n` is a
    /// torn append still in flight: tolerated, flagged, not counted as damage.
    /// Every other parse failure — including a zero-filled or blank line between
    /// two good rows, which is what a crashed write leaves behind on APFS — is
    /// counted, because the caller needs to know it is looking at a feed with
    /// holes in it.
    public func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport) {
        guard FileManager.default.fileExists(atPath: path.path) else { return ([], .clean) }
        let data = try Data(contentsOf: path)
        let lines = Self.decodeLines(data, dropFirstPartial: false)
        let endsWithNewline = data.last == 0x0A
        var rows: [JSONValue] = []
        rows.reserveCapacity(lines.count)
        var malformed = 0
        var trailingPartial = false
        for (index, line) in lines.enumerated() {
            if let parsed = try? JSONValue.parse(Data(line.utf8)) {
                rows.append(parsed)
                continue
            }
            if index == lines.count - 1 && !endsWithNewline {
                trailingPartial = true
            } else {
                malformed += 1
            }
        }
        return (rows, JSONLReadReport(
            malformedLineCount: malformed,
            trailingPartialLine: trailingPartial,
            // Every physical line the file holds — decoded, malformed, or torn.
            // The op-log threshold keys on this, never on `rows.count`.
            physicalLineCount: lines.count
        ))
    }

    /// `appendJSONL` that does not return until the bytes are DURABLE.
    ///
    /// WHY THIS IS A SEPARATE ENTRY POINT rather than a change to `appendJSONL`
    /// (audit 2026-08-02, finding 2): `write(2)` returning success only means
    /// the kernel has the page, so a power loss between the append and the next
    /// flush loses an op that every caller was told had committed. The fix is
    /// `F_FULLFSYNC` — but it costs a real drive-cache flush (tens of ms on
    /// APFS), and `appendJSONL` is the shared write path for telemetry, turn
    /// traces and scheduler chatter, where a lost tail line costs nothing and a
    /// per-line barrier would be felt on every turn. So the canonical op-log
    /// stores — the ones whose feed IS the state of record — call this, and the
    /// advisory feeds keep the fast path. `appendAuditLine`/`appendAuditLineRaw`
    /// are deliberately NOT durable for the same reason: they are an audit
    /// trail, not a source of truth, and their loss window is one line.
    public func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
        try appendRecords([record], to: path, durable: true)
    }

    /// Bounded JSONL read result. Consumers which need to distinguish an empty
    /// trace from a malformed one can surface this receipt without changing the
    /// canonical tailing semantics used by the rest of the persistence layer.
    public struct JSONLTailReadReceipt: Sendable {
        public let rows: [JSONValue]
        public let physicalRowsScanned: Int
        public let malformedJSONRowCount: Int
        public let bytesRead: Int
        public let truncatedToByteWindow: Bool

        public init(
            rows: [JSONValue],
            physicalRowsScanned: Int,
            malformedJSONRowCount: Int,
            bytesRead: Int,
            truncatedToByteWindow: Bool
        ) {
            self.rows = rows
            self.physicalRowsScanned = physicalRowsScanned
            self.malformedJSONRowCount = malformedJSONRowCount
            self.bytesRead = bytesRead
            self.truncatedToByteWindow = truncatedToByteWindow
        }
    }

    public func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        let receipt = try await tailJSONLReadReceipt(path, limit: limit, maxBytes: maxBytes)
        return receipt.rows
    }

    /// Same bounded physical-line tail as `tailJSONL`, with enough receipt data
    /// for read-only evaluations to disclose skipped malformed input. The rows
    /// remain exactly the valid JSON values `tailJSONL` has always returned.
    public func tailJSONLReadReceipt(
        _ path: URL,
        limit: Int,
        maxBytes: Int?
    ) async throws -> JSONLTailReadReceipt {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return JSONLTailReadReceipt(
                rows: [],
                physicalRowsScanned: 0,
                malformedJSONRowCount: 0,
                bytesRead: 0,
                truncatedToByteWindow: false
            )
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 {
            return JSONLTailReadReceipt(
                rows: [],
                physicalRowsScanned: 0,
                malformedJSONRowCount: 0,
                bytesRead: 0,
                truncatedToByteWindow: false
            )
        }

        let toRead: Int
        let seekFromEnd: Bool
        if let maxBytes, size > maxBytes {
            toRead = maxBytes
            seekFromEnd = true
        } else {
            toRead = size
            seekFromEnd = false
        }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        if seekFromEnd {
            try handle.seek(toOffset: UInt64(size - toRead))
        }
        let data = handle.readData(ofLength: toRead)
        let lines = Self.decodeLines(data, dropFirstPartial: seekFromEnd)
        // Match Python's tail_jsonl: take the last N PHYSICAL lines first, then
        // parse and skip malformed entries. So when some of the trailing lines
        // are malformed the return count is < limit (matches Python).
        let tail = lines.suffix(limit)
        var rows: [JSONValue] = []
        rows.reserveCapacity(tail.count)
        var malformedJSONRowCount = 0
        for line in tail {
            if let row = try? JSONValue.parse(Data(line.utf8)) {
                rows.append(row)
            } else {
                malformedJSONRowCount += 1
            }
        }
        return JSONLTailReadReceipt(
            rows: rows,
            physicalRowsScanned: tail.count,
            malformedJSONRowCount: malformedJSONRowCount,
            bytesRead: data.count,
            truncatedToByteWindow: seekFromEnd
        )
    }

    /// Decode utf-8 with replacement, split on `\n`, drop trailing empty line, and
    /// (when scanning from the middle of a file) drop the first possibly-partial
    /// line to match Python's `tail_jsonl` behavior.
    private static func decodeLines(_ data: Data, dropFirstPartial: Bool) -> [String] {
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Match Python's errors="replace" semantics for tail_jsonl.
            text = String(decoding: data, as: UTF8.self)
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        if dropFirstPartial && !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    /// Append bytes to a file, creating it if absent. Uses POSIX open(O_APPEND)
    /// so concurrent appenders interleave at line boundaries.
    /// `durable: true` adds an `F_FULLFSYNC` before the descriptor closes —
    /// the only macOS call that flushes the DRIVE's write cache (plain
    /// `fsync(2)` returns once the data reaches that cache and is still lost on
    /// power loss). Falls back to `fsync` where the filesystem rejects it
    /// (ENOTSUP on some network/virtual filesystems), which is still strictly
    /// better than nothing.
    static func appendBytes(
        _ data: Data,
        to path: URL,
        createMode: mode_t = 0o600,
        durable: Bool = false,
        syscalls: FlushSyscalls = .system
    ) throws {
        // F2 (2026-08-28) — THE cap chokepoint. Every JSONL append variant
        // (`appendJSONL`, the batch form, `appendJSONLDurable`, `appendAuditLine`,
        // `appendAuditLineRaw`) funnels its bytes through here, so a file whose
        // retention is owned by `jsonlPathOwnedCapPolicy` cannot be grown by a
        // writer that skipped `appendPathOwnedJSONL`/`appendJSONLCapped`. The
        // capped route sets the task-local permit around its inner append.
        if !JSONLPathOwnedAppendPermit.isInsideCappedAppend,
           jsonlPathOwnedCapPolicy(for: path) != nil {
            throw JSONLPathOwnedAppendError.rawAppendToPathOwnedFeed(
                path.standardizedFileURL.path
            )
        }
        // 2026-09-06: every caller here writes newline-terminated lines, so a
        // file that does NOT end in a newline is a torn append (a crash or a
        // short write mid-line). Appending straight onto it fuses the torn
        // bytes with the next record: the reader then sees one malformed line
        // and drops BOTH — the torn row was already lost, but the new one need
        // not be. Close the torn line first so only the torn row is lost.
        var payload = data
        if let size = (try? FileManager.default.attributesOfItem(atPath: path.path))
            .flatMap({ ($0[.size] as? NSNumber)?.intValue }), size > 0 {
            let probeFD = open(path.path, O_RDONLY)
            if probeFD >= 0 {
                var lastByte: UInt8 = 0
                let read = pread(probeFD, &lastByte, 1, off_t(size - 1))
                _ = Darwin.close(probeFD)
                if read == 1 && lastByte != 0x0A {
                    payload = Data([0x0A]) + data
                }
            }
        }
        let fd = open(path.path, O_WRONLY | O_CREAT | O_APPEND, createMode)
        if fd < 0 {
            throw PersistenceCoreError.ioFailure("open(append) failed: \(String(cString: strerror(errno)))")
        }
        var handedOff = false
        defer { if !handedOff { _ = syscalls.close(fd) } }
        try payload.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceCoreError.ioFailure("write failed: \(String(cString: strerror(errno)))")
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        // The write landed in the page cache. Everything that makes this append
        // DURABLE happens below, BEFORE we return — never in a defer.
        handedOff = true
        try flushAndClose(fd: fd, path: path, durable: durable, syscalls: syscalls)
    }

    /// The three syscalls the durability tail depends on, behind a seam so a
    /// test can make them FAIL. Each closure returns 0 on success or the errno
    /// it failed with — the real ones read the global `errno` immediately, so
    /// nothing downstream depends on a global that a later call may clobber.
    struct FlushSyscalls: Sendable {
        var fullFsync: @Sendable (Int32) -> Int32
        var fsync: @Sendable (Int32) -> Int32
        var close: @Sendable (Int32) -> Int32

        static let system = FlushSyscalls(
            fullFsync: { fd in Darwin.fcntl(fd, F_FULLFSYNC) == -1 ? errno : 0 },
            fsync: { fd in Darwin.fsync(fd) == -1 ? errno : 0 },
            close: { fd in Darwin.close(fd) == -1 ? errno : 0 }
        )
    }

    /// errnos that mean "this filesystem does not implement `F_FULLFSYNC`",
    /// the ONLY case in which degrading to plain `fsync` is legitimate. A
    /// Set because `ENOTSUP` and `EOPNOTSUPP` are the same value on Darwin and
    /// a `switch` over both would not compile.
    private static let fullFsyncUnsupportedErrnos: Set<Int32> =
        [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL, ENOSYS, ENODEV]

    /// Flush (when `durable`) and close, reporting every failure by THROWING.
    ///
    /// WHY THIS IS NOT A `defer` (gpt-5.5 review 2026-08-02, BLOCKING 1): the
    /// old code ran the flush inside a non-throwing `defer` and discarded the
    /// fallback `fsync`'s return value, so `appendJSONLDurable` returned
    /// SUCCESS after a failed `F_FULLFSYNC` *and* a failed `fsync` — EIO on a
    /// dying disk, ENOSPC on a full one. The caller then wrote derived state or
    /// compacted the feed on the strength of an op that was never durable,
    /// which is the exact class of loss the durable path exists to prevent. A
    /// durable append that cannot prove durability must fail loudly instead.
    ///
    /// Rules: EINTR retries (a signal is not a durability failure); a genuine
    /// "unsupported" errno degrades to `fsync` and only then; a failed fallback
    /// throws; a failed close throws on the durable path, because on a
    /// writeback filesystem close(2) is where a deferred write error surfaces.
    /// Non-durable appends keep their historical best-effort close (reported on
    /// stderr, not thrown) — they are telemetry and turn traces, whose contract
    /// never promised the bytes were on the platter.
    static func flushAndClose(
        fd: Int32,
        path: URL,
        durable: Bool,
        syscalls: FlushSyscalls = .system
    ) throws {
        var flushError: PersistenceCoreError?
        if durable {
            do {
                try fullSync(fd: fd, path: path, syscalls: syscalls)
            } catch let error as PersistenceCoreError {
                flushError = error
            }
        }
        // Close EXACTLY ONCE regardless — retrying close(2) on EINTR is a
        // double-close on Darwin (the descriptor is already gone) and could
        // close a descriptor another thread has since been handed.
        let closeErrno = syscalls.close(fd)
        if let flushError { throw flushError }
        if closeErrno != 0 && closeErrno != EINTR {
            let message = "close(append \(path.lastPathComponent)) failed: \(String(cString: strerror(closeErrno)))"
            if durable { throw PersistenceCoreError.ioFailure(message) }
            FileHandle.standardError.write(Data("PersistenceCore: \(message)\n".utf8))
        }
    }

    /// `F_FULLFSYNC`, with the ONE legitimate fallback. Throws when the bytes
    /// cannot be proven durable.
    private static func fullSync(fd: Int32, path: URL, syscalls: FlushSyscalls) throws {
        var lastErrno: Int32 = 0
        for _ in 0..<8 {
            lastErrno = syscalls.fullFsync(fd)
            if lastErrno == 0 { return }
            if lastErrno != EINTR { break }
        }
        if lastErrno == EINTR {
            throw PersistenceCoreError.ioFailure(
                "F_FULLFSYNC(\(path.lastPathComponent)) kept returning EINTR — durability unproven"
            )
        }
        guard fullFsyncUnsupportedErrnos.contains(lastErrno) else {
            // A REAL flush failure (EIO, ENOSPC, EDQUOT …). Falling back to
            // fsync here would just ask the same broken device again and let a
            // lost write masquerade as a commit.
            throw PersistenceCoreError.ioFailure(
                "F_FULLFSYNC(\(path.lastPathComponent)) failed: \(String(cString: strerror(lastErrno)))"
            )
        }
        // The filesystem has no drive-cache flush (some network/virtual
        // filesystems). Plain fsync is strictly better than nothing — but its
        // result is now CHECKED.
        var fsyncErrno: Int32 = 0
        for _ in 0..<8 {
            fsyncErrno = syscalls.fsync(fd)
            if fsyncErrno == 0 { return }
            if fsyncErrno != EINTR { break }
        }
        throw PersistenceCoreError.ioFailure(
            "F_FULLFSYNC unsupported (\(String(cString: strerror(lastErrno)))) and "
            + "fsync(\(path.lastPathComponent)) failed: \(String(cString: strerror(fsyncErrno)))"
        )
    }

    /// Write `data` to `path` atomically via a side temp file + rename(2),
    /// using the NativeAgent temp-name convention and 0600 mode.
    /// Internal (not private) so the JSONL cap helpers below share the same
    /// fsync-before-rename + parent-dir-fsync durability; their previous
    /// bare `Data.write(.atomic)` + replaceItemAt could lose the whole feed
    /// on power loss mid-trim (sweep 2026-08-21).
    static func atomicWrite(_ data: Data, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let pid = getpid()
        // pthread_self() returns an opaque pointer; take its raw bit pattern.
        let tidPtr = pthread_self()
        let tid = UInt64(UInt(bitPattern: OpaquePointer(tidPtr)))
        let uuid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let tmpName = ".\(name).\(pid).\(tid).\(uuid).tmp"
        let tmpPath = dir.appendingPathComponent(tmpName)

        let fd = open(tmpPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            throw PersistenceCoreError.ioFailure("open(tmp) failed: \(String(cString: strerror(errno)))")
        }
        var fdClosed = false
        var didRename = false
        defer {
            if !fdClosed {
                if close(fd) != 0 {
                    let err = String(cString: strerror(errno))
                    FileHandle.standardError.write(Data("PersistenceCore: close(tmp fd) failed: \(err)\n".utf8))
                }
            }
            if !didRename {
                _ = unlink(tmpPath.path)
            }
        }
        try data.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = String(cString: strerror(errno))
                    throw PersistenceCoreError.ioFailure("write(tmp) failed: \(err)")
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        // Flush file data before rename — the Python _atomic_write_text this
        // layer mirrors fsync'd before renaming. Without it, power loss can
        // commit the rename before the data blocks, leaving the target
        // truncated with the OLD contents already gone (audit 2026-06-09).
        // A failed fsync/close means the data may NOT be durable — throwing
        // (instead of logging) keeps the old file intact and lets the defer
        // unlink the temp (gpt-5.5 review: never rename over good data after
        // the OS reported writeback failure).
        if fsync(fd) != 0 {
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("fsync(tmp) failed: \(err)")
        }
        atomicWriteDurabilityObserver?(.temporaryFileSynced)
        if close(fd) != 0 {
            fdClosed = true
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("close(tmp) failed: \(err)")
        }
        fdClosed = true
        _ = chmod(tmpPath.path, 0o600)
        if rename(tmpPath.path, path.path) != 0 {
            throw PersistenceCoreError.ioFailure("rename failed: \(String(cString: strerror(errno)))")
        }
        didRename = true
        _ = chmod(path.path, 0o600)
        // fsyncing the temporary file makes its bytes durable; fsyncing the
        // parent directory makes the rename itself durable. Without the second
        // barrier a power loss may forget the new directory entry even though
        // the file contents reached storage. Callers receive an error on an
        // uncertain commit and can re-read the canonical path before retrying.
        let directoryFD = open(dir.path, O_RDONLY)
        if directoryFD < 0 {
            throw PersistenceCoreError.ioFailure(
                "open(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(directoryFD) }
        if fsync(directoryFD) != 0 {
            throw PersistenceCoreError.ioFailure(
                "fsync(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
        atomicWriteDurabilityObserver?(.parentDirectorySynced)
    }
}

// MARK: - Factory

/// Returns the SwiftNative impl unconditionally — persistence is the foundation
/// every other migrated subsystem builds on, so it migrates first and stays migrated.
public func makePersistenceCore() -> any PersistenceCoreProtocol {
    return SwiftNativePersistenceCore()
}

/// Append `record` to a JSONL feed ONLY if no existing row shares its
/// `idKey` value — the "idempotent inbox card" pattern extracted from the two
/// byte-identical MemoryV2 stagers (kind-backfill + consolidation gate), each of
/// which slurped the ENTIRE inbox (`tailJSONL` limit `Int.max`) under the lock
/// on every append.
///
/// SCAN BOUND: the existence check reads the newest `scanLimit` rows, not the
/// whole file. The dedup these stagers need is against a RECENT re-stage (a
/// crash/retry re-emitting the SAME approval id, which happens within a few
/// appends), and the card ids are pass-unique — so a same-id row older than
/// `scanLimit` newer rows does not occur in practice. kind-backfill additionally
/// guards re-staging with a durable stamp file, so this scan is a second layer.
/// The default (4096) dwarfs any realistic re-stage window while bounding the
/// per-append read on the uncapped, multi-writer inbox feed.
///
/// LOCKING: takes `withFileLock(path)` when `persistence` is the SwiftNative impl
/// (so the check-then-append is atomic against a concurrent unique-append);
/// no-op locking otherwise (tests / HTTP-backed persistence). A record with no
/// decodable `idKey` value is appended unconditionally (nothing to dedup on).
///
/// BOUNDED UNIQUENESS — a declared trade, not an oversight (gpt-5.5 review,
/// 2026-07-17): the existence check scans only the newest `scanLimit` rows, so
/// a duplicate id OLDER than the window can be re-appended. This replaced an
/// O(file) whole-inbox slurp per append. Safe for the current callers because
/// both carry their own primary re-stage guards (kind-backfill's durable stamp
/// file; consolidation's pending-proposal dedup) and re-stages land within a
/// few appends of the original. A caller that needs TRUE uniqueness over
/// unbounded history must not use this helper — use an id-index store instead.
public func appendUniqueById(
    _ record: JSONValue,
    to path: URL,
    idKey: String = "id",
    using persistence: any PersistenceCoreProtocol,
    scanLimit: Int = 4096
) async throws {
    let id: @Sendable (JSONValue) -> String? = { value in
        guard case .object(let obj) = value, case .string(let s)? = obj[idKey] else { return nil }
        return s
    }
    let work: @Sendable () async throws -> Void = {
        guard let targetId = id(record) else {
            try await persistence.appendJSONL(record, to: path)
            return
        }
        let recent = try await persistence.tailJSONL(path, limit: scanLimit, maxBytes: nil)
        if recent.contains(where: { id($0) == targetId }) { return }
        try await persistence.appendJSONL(record, to: path)
    }
    // Same L7 correction as `appendJSONLCapped`: `withFileLock` is a
    // PersistenceCoreProtocol extension, so the downcast that used to guard this
    // only had the effect of silently running the tail-then-append read-modify
    // -write UNLOCKED for every non-SwiftNative conformer — two racing callers
    // both see no match and both append, defeating the idempotency this function
    // exists to provide. Lock uniformly.
    try await persistence.withFileLock(path, work)
}
