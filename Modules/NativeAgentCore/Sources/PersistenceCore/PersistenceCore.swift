import CryptoKit
import Foundation
import Darwin
import NativeAgentShared
// Blueprint: | `PersistenceCore.swift` | JSON/JSONL atomic and durable persistence, strict UTF-8 physical-line reads with integrity reporting and directory sync; bounded atomic `PhonePlaceHistory` written only by the Mac bridge |

/// Bounded, atomic source history; the Mac bridge is its sole writer.
public enum PhonePlaceHistory {
    public static func url(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("mobile/place-events.json") }
    public static func read(_ dataRoot: URL) throws -> [PhonePlaceEvent] {
        let file = url(dataRoot)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([PhonePlaceEvent].self, from: Data(contentsOf: file))
    }
    public static func record(_ event: PhonePlaceEvent, dataRoot: URL) throws {
        var events = try read(dataRoot)
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        events = Array(events.sorted { $0.timestamp < $1.timestamp }.suffix(64))
        let file = url(dataRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: file, options: .atomic)
    }
}

// MARK: - Errors

/// Errors raised by the persistence layer.
public enum PersistenceCoreError: Error, Equatable {
    case nonFiniteFloat(Double, path: String)
    case ioFailure(String)
    /// A JSON file exists but does not parse. The file is left where it is
    /// (the next successful write replaces it); `quarantine` is the copy of
    /// its bytes kept beside it, or nil if that copy could not be written.
    case corruptJSON(path: String, quarantine: String?)
}

extension PersistenceCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ioFailure(let message): return message
        case .nonFiniteFloat: return nil
        case .corruptJSON(let path, let quarantine):
            return "\(path) is not valid JSON; original retained; "
                + (quarantine.map { "quarantine copy: \($0)" } ?? "quarantine copy could not be written")
        }
    }
}

/// JSONL scan integrity, separating malformed rows from a tolerated trailing partial.
public struct JSONLReadReport: Sendable, Equatable {
    /// Lines rejected by decoding, excluding the tolerated trailing partial.
    public var malformedLineCount: Int
    /// A tolerated parse failure on the final, unterminated UTF-8 line.
    public var trailingPartialLine: Bool
    /// Every scanned physical line, decoded or not, for feed-size thresholds.
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

// MARK: - SwiftNative implementation

/// Stateless file operations; async entry points retain their executor boundary.
public enum SwiftNativePersistenceCore {

    /// Malformed JSON attempts a private quarantine copy before throwing;
    /// callers needing a nonmutating inspection must read and parse directly.
    public static func readJSON(_ path: URL, ifMissing: JSONValue) async throws -> JSONValue {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return ifMissing
        } catch {
            nativeLog("readJSON: %@ could not be read: %@", path.path, error.localizedDescription)
            throw PersistenceCoreError.ioFailure("read \(path.path) failed: \(error.localizedDescription)")
        }
        do {
            return try JSONValue.parse(data)
        } catch {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var copy = path.deletingLastPathComponent()
                .appendingPathComponent("\(path.lastPathComponent).corrupt-\(digest.prefix(12))")
            var quarantine: String?
            if Self.isPrivateQuarantine(copy, matching: data) {
                quarantine = copy.path
            } else {
                var info = stat()
                if lstat(copy.path, &info) == 0 || errno != ENOENT {
                    copy = copy.appendingPathExtension(UUID().uuidString.lowercased())
                }
                do {
                    try Self.writeDataAtomicDurable(data, to: copy)
                    quarantine = copy.path
                } catch { quarantine = nil }
            }
            nativeLog("readJSON: %@ is not valid JSON (%d bytes); bytes kept at %@",
                  path.path, data.count, quarantine ?? "nowhere (quarantine write failed)")
            throw PersistenceCoreError.corruptJSON(path: path.path, quarantine: quarantine)
        }
    }

    private static func isPrivateQuarantine(_ path: URL, matching data: Data) -> Bool {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size == data.count else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return (try? handle.readToEnd()) == data
    }

    public static func writeJSON(_ value: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try value.serializedData(pretty: true)
        try Self.atomicWrite(payload, to: path)
    }

    public static func writeDataAtomicDurableAsync(_ data: Data, to path: URL) async throws {
        try Self.writeDataAtomicDurable(data, to: path)
    }

    /// Publish replacement bytes through a private 0600 temp file and temp/parent F_FULLFSYNC.
    public static func writeDataAtomicDurable(_ data: Data, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(data, to: path, fullFlush: true)
    }

    public static func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try appendRecords([record], to: path, durable: false)
    }

    /// Durable batch append — one write, one `F_FULLFSYNC`. Same contract as the
    /// single-record `appendJSONLDurable`; used by the op-log stores that commit
    /// a multi-op transaction under one flock.
    public static func appendJSONLDurable(_ records: [JSONValue], to path: URL) async throws {
        try appendRecords(records, to: path, durable: true)
    }

    private static func appendRecords(_ records: [JSONValue], to path: URL, durable: Bool) throws {
        guard !records.isEmpty else { return }
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.appendBytes(Self.serializeJSONL(records), to: path, durable: durable)
        _ = chmod(path.path, 0o600)
    }

    package static func serializeJSONL(_ records: [JSONValue]) throws -> Data {
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        return payload
    }

    /// Append a pre-serialized JSON line (no re-encode) with 0o666 create-mode
    /// (umask-derived 0644) and no chmod on an existing file.
    /// Used when the caller has already produced byte-exact output via
    /// `serializeOrderedObjectPython` and must NOT have it re-sorted by the
    /// `serialize` path. A trailing newline is appended (one row per line). The
    /// caller is responsible for holding `withFileLock` around this when the
    /// file has multiple writers.
    public static func appendAuditLineRaw(_ jsonLine: String, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = jsonLine + "\n"
        try Self.appendBytes(Data(line.utf8), to: path, createMode: 0o666)
    }

    public static func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await readJSONLReporting(path).rows
    }

    /// Read rows with the shared physical framing and integrity report.
    public static func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport) {
        guard FileManager.default.fileExists(atPath: path.path) else { return ([], .clean) }
        let data = try Data(contentsOf: path)
        return Self.decodeJSONL(data) { value, _ in value }
    }

    /// Shared physical framing for file reads and already-read JSONL bytes.
    /// Invalid UTF-8 is malformed; only a final unterminated JSON parse failure is tolerated.
    /// The row decoder receives the line byte count plus a newline allowance; nil marks a malformed row.
    public static func decodeJSONL<Row>(
        _ data: Data, row: (JSONValue, Int) -> Row?
    ) -> (rows: [Row], report: JSONLReadReport) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let endsWithNewline = data.last == 0x0A
        var rows: [Row] = []
        rows.reserveCapacity(lines.count)
        var malformed = 0
        var trailingPartial = false
        for (index, line) in lines.enumerated() {
            guard String(data: Data(line), encoding: .utf8) != nil else {
                malformed += 1
                continue
            }
            if let parsed = try? JSONValue.parse(Data(line)) {
                if let decoded = row(parsed, line.count + 1) { rows.append(decoded) }
                else { malformed += 1 }
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
            physicalLineCount: lines.count
        ))
    }

    /// Append a record with durability confirmed before returning; advisory appends do not flush.
    public static func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
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

    public static func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        let receipt = try await tailJSONLReadReceipt(path, limit: limit, maxBytes: maxBytes)
        return receipt.rows
    }

    /// Same bounded physical-line tail as `tailJSONL`, with enough receipt data
    /// for read-only evaluations to disclose skipped malformed input. The rows
    /// remain exactly the valid JSON values `tailJSONL` has always returned.
    public static func tailJSONLReadReceipt(
        _ path: URL,
        limit: Int,
        maxBytes: Int?
    ) async throws -> JSONLTailReadReceipt {
        let read = try Self.tailPhysicalLines(path, limit: limit, maxBytes: maxBytes) ?? ([], 0, false, false)
        let tail = read.lines.dropFirst(read.leadingFragment ? 1 : 0)
        var rows: [JSONValue] = []
        rows.reserveCapacity(tail.count)
        var malformedJSONRowCount = 0
        for line in tail {
            if String(data: line, encoding: .utf8) != nil, let row = try? JSONValue.parse(line) {
                rows.append(row)
            } else {
                malformedJSONRowCount += 1
            }
        }
        return JSONLTailReadReceipt(
            rows: rows,
            physicalRowsScanned: tail.count,
            malformedJSONRowCount: malformedJSONRowCount,
            bytesRead: read.bytesRead,
            truncatedToByteWindow: read.truncatedToByteWindow
        )
    }

    /// Raw physical rows with leading-fragment coverage; nil means the file is absent.
    public static func tailPhysicalLines(
        _ path: URL,
        limit: Int,
        maxBytes: Int?
    ) throws -> (lines: [Data], bytesRead: Int, truncatedToByteWindow: Bool, leadingFragment: Bool)? {
        guard limit > 0, maxBytes.map({ $0 > 0 }) ?? true else {
            return ([], 0, false, false)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        defer { try? handle.close() }
        // Size and bytes must belong to the same inode if a writer rotates it.
        let size = Int(try handle.seekToEnd())
        if size == 0 {
            return ([], 0, false, false)
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

        let lowerBound = size - toRead
        var offset = size
        var chunks: [Data] = []
        var newlineCount = 0
        var endsWithNewline = false
        // Read backward until the requested physical lines are complete. A nil
        // byte ceiling permits a long row, not a whole-file read for every tail.
        while offset > lowerBound {
            try Task.checkCancellation()
            let count = min(64 * 1024, offset - lowerBound)
            offset -= count
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: count) ?? Data()
            if chunks.isEmpty { endsWithNewline = chunk.last == 0x0A }
            chunks.append(chunk)
            newlineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            if endsWithNewline ? newlineCount > limit : newlineCount >= limit { break }
        }
        var data = Data()
        for chunk in chunks.reversed() { data.append(chunk) }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        // Consumers decide whether to discard a fragment that survived the row limit.
        return (parts.suffix(limit).map { Data($0) }, data.count, seekFromEnd,
                offset > 0 && !parts.isEmpty && parts.count <= limit)
    }

    /// Synchronous append of caller-serialized, newline-terminated lines, for a
    /// writer that must keep its bytes exact or cannot await. The same
    /// chokepoint as `appendJSONL` (torn-line repair, O_APPEND, 0600 create);
    /// the caller holds the feed's lock when it has more than one writer.
    public static func appendLines(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appendBytes(data, to: path)
    }

    /// `appendBytes` for stores outside this module that own their
    /// serialization and hold the feed's lock (chat session retention, Studio).
    public static func appendOwnedBytes(_ data: Data, to path: URL, durable: Bool = false) throws {
        try appendBytes(data, to: path, durable: durable)
    }

    /// Append with O_APPEND, creating the file if absent; durable writes flush before close.
    static func appendBytes(
        _ data: Data,
        to path: URL,
        createMode: mode_t = 0o600,
        durable: Bool = false
    ) throws {
        // Path-owned feeds accept bytes only inside the capped append's task-local permit.
        if !JSONLPathOwnedAppendPermit.isInsideCappedAppend,
           jsonlPathOwnedCapPolicy(for: path) != nil {
            throw JSONLPathOwnedAppendError.rawAppendToPathOwnedFeed(
                path.standardizedFileURL.path
            )
        }
        // Terminate a torn trailing line before appending, isolating it from the new record.
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
        defer { if !handedOff { _ = Darwin.close(fd) } }
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
        // Confirm durability on the throwing path before returning.
        handedOff = true
        try flushAndClose(fd: fd, path: path, durable: durable)
        if durable {
            // Also persist the entry if this append created the file, including
            // a retry after an earlier append failed to sync the directory.
            try syncDirectory(path.deletingLastPathComponent())
        }
    }

    /// Filesystem unsupported-operation errnos; a set accepts Darwin's aliased values.
    private static let fullFsyncUnsupportedErrnos: Set<Int32> =
        [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL, ENOSYS, ENODEV]

    /// Durable flush and close failures throw; non-durable close failures are logged.
    static func flushAndClose(
        fd: Int32,
        path: URL,
        durable: Bool
    ) throws {
        var flushError: PersistenceCoreError?
        if durable {
            do {
                try fullSync(fd: fd, path: path)
            } catch let error as PersistenceCoreError {
                flushError = error
            }
        }
        // Close once: Darwin releases the descriptor even when close reports EINTR.
        let closeErrno = Darwin.close(fd) == -1 ? errno : 0
        if let flushError { throw flushError }
        if closeErrno != 0 && closeErrno != EINTR {
            let message = "close(append \(path.lastPathComponent)) failed: \(String(cString: strerror(closeErrno)))"
            if durable { throw PersistenceCoreError.ioFailure(message) }
            FileHandle.standardError.write(Data("PersistenceCore: \(message)\n".utf8))
        }
    }

    /// Retry interrupted F_FULLFSYNC; use checked fsync only for unsupported-operation errnos.
    /// Any other flush failure, or exhausted retries, leaves durability unproven and throws.
    private static func fullSync(fd: Int32, path: URL) throws {
        var lastErrno: Int32 = 0
        for _ in 0..<8 {
            lastErrno = Darwin.fcntl(fd, F_FULLFSYNC) == -1 ? errno : 0
            if lastErrno == 0 { return }
            if lastErrno != EINTR { break }
        }
        if lastErrno == EINTR {
            throw PersistenceCoreError.ioFailure(
                "F_FULLFSYNC(\(path.lastPathComponent)) kept returning EINTR — durability unproven"
            )
        }
        guard fullFsyncUnsupportedErrnos.contains(lastErrno) else {
            throw PersistenceCoreError.ioFailure(
                "F_FULLFSYNC(\(path.lastPathComponent)) failed: \(String(cString: strerror(lastErrno)))"
            )
        }
        var fsyncErrno: Int32 = 0
        for _ in 0..<8 {
            fsyncErrno = Darwin.fsync(fd) == -1 ? errno : 0
            if fsyncErrno == 0 { return }
            if fsyncErrno != EINTR { break }
        }
        throw PersistenceCoreError.ioFailure(
            "F_FULLFSYNC unsupported (\(String(cString: strerror(lastErrno)))) and "
            + "fsync(\(path.lastPathComponent)) failed: \(String(cString: strerror(fsyncErrno)))"
        )
    }

    /// Replace relative to a borrowed parent descriptor, or open the pathname's parent.
    /// The private 0600 temp and parent use drive-cache syncs when fullFlush is true.
    package static func atomicWrite(_ data: Data, to path: URL, parentFD: Int32? = nil, fullFlush: Bool = false) throws {
        let dir = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let directoryFD = parentFD ?? open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw PersistenceCoreError.ioFailure("open(parent directory) failed: \(String(cString: strerror(errno)))")
        }
        defer { if parentFD == nil { _ = close(directoryFD) } }
        let tmpName = ".\(UUID().uuidString.lowercased()).tmp"
        let tmpPath = dir.appendingPathComponent(tmpName)

        let fd = openat(directoryFD, tmpName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
                _ = unlinkat(directoryFD, tmpName, 0)
            }
        }
        try data.withUnsafeBytes { raw in
            guard !raw.isEmpty else { return }
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = String(cString: strerror(errno))
                    throw PersistenceCoreError.ioFailure("write(tmp) failed: \(err)")
                }
                guard n > 0 else { throw PersistenceCoreError.ioFailure("write(tmp) made no progress") }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        _ = fchmod(fd, 0o600)
        // Sync and close the temp file before rename; either failure preserves the target.
        if fullFlush {
            try fullSync(fd: fd, path: tmpPath)
        } else if fsync(fd) != 0 {
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("fsync(tmp) failed: \(err)")
        }
        if close(fd) != 0 {
            fdClosed = true
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("close(tmp) failed: \(err)")
        }
        fdClosed = true
        if renameat(directoryFD, tmpName, directoryFD, name) != 0 {
            throw PersistenceCoreError.ioFailure("rename failed: \(String(cString: strerror(errno)))")
        }
        didRename = true
        // Sync the parent to persist the rename; failure leaves an uncertain commit to re-read.
        if fullFlush {
            try fullSync(fd: directoryFD, path: dir)
        } else if fsync(directoryFD) != 0 {
            throw PersistenceCoreError.ioFailure("fsync(parent directory) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Persist directory-entry changes before a transaction advances.
    public static func syncDirectory(_ dir: URL, fullFlush: Bool = true) throws {
        let directoryFD = open(dir.path, O_RDONLY)
        if directoryFD < 0 {
            throw PersistenceCoreError.ioFailure(
                "open(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(directoryFD) }
        if fullFlush {
            try fullSync(fd: directoryFD, path: dir)
        } else if fsync(directoryFD) != 0 {
            throw PersistenceCoreError.ioFailure(
                "fsync(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
    }
}
