import CryptoKit
import Foundation
import Darwin
import Synchronization
import NativeAgentShared
// Blueprint: | `PersistenceCore.swift` | `PhonePlaceHistory`; Durable atomic storage and strict physical-line reads. |

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
        NotificationCenter.default.post(PhoneSenseHistory.Changed(dataRoot: dataRoot, source: nil, timestamp: nil), subject: dataRoot as NSURL)
    }
}

// MARK: - Errors

public enum PersistenceCoreError: Error, Equatable {
    case nonFiniteFloat(Double, path: String)
    case ioFailure(String)
    /// Preserve malformed source bytes; quarantine identifies a private copy when one could be written.
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
    public var malformedLineCount: Int
    public var trailingPartialLine: Bool
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

    public var isClean: Bool { malformedLineCount == 0 && !trailingPartialLine }
}

// MARK: - SwiftNative implementation

/// Stateless file operations; async entry points retain their executor boundary.
extension CocoaError {
    /// FileHandle and Data/FileManager use different Cocoa error codes for the same absence.
    public var isFileAbsent: Bool { code == .fileNoSuchFile || code == .fileReadNoSuchFile }
}

public enum SwiftNativePersistenceCore {

    /// Malformed JSON attempts a private quarantine copy before throwing; callers needing a nonmutating inspection must read and parse directly.
    @concurrent public static func readJSON(_ path: URL, ifMissing: JSONValue) async throws -> JSONValue {
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
                if unsafe lstat(copy.path, &info) == 0 || errno != ENOENT {
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
        guard unsafe fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size == data.count else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return (try? handle.readToEnd()) == data
    }

    @concurrent public static func writeJSON(_ value: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try value.serializedData(pretty: true)
        try Self.atomicWrite(payload, to: path)
    }

    @concurrent public static func writeDataAtomicDurableAsync(_ data: Data, to path: URL) async throws {
        try Self.writeDataAtomicDurable(data, to: path)
    }

    /// Publish replacement bytes through a private 0600 temp file and temp/parent F_FULLFSYNC.
    public static func writeDataAtomicDurable(_ data: Data, to path: URL) throws {
        _ = try writeDataAtomicDurable(data, to: path, trackingRevision: false)
    }

    package static func writeDataAtomicDurable(_ data: Data, to path: URL,
                                               trackingRevision: Bool) throws -> SnapshotTailOpLog.FileStamp? {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try atomicWrite(data, to: path, fullFlush: true, trackingRevision: trackingRevision)
    }

    @concurrent public static func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try appendRecords([record], to: path, durable: false)
    }

    /// Append a batch as one payload and fully flush it under the caller's flock.
    @concurrent public static func appendJSONLDurable(_ records: [JSONValue], to path: URL) async throws {
        try appendRecords(records, to: path, durable: true)
    }

    package struct AppendRevision {
        let before: SnapshotTailOpLog.FileStamp
        package let after: SnapshotTailOpLog.FileStamp

        package func extended(_ stamp: SnapshotTailOpLog.FileStamp) -> Bool {
            if stamp == before { return true }
            if stamp == .absent, case .present(_, _, 0, _, _, _, _) = before { return true }
            return false
        }
    }

    @discardableResult
    package static func appendRecords(_ records: [JSONValue], to path: URL, durable: Bool,
                                      trackingRevision: Bool = false) throws -> AppendRevision? {
        guard !records.isEmpty else { return nil }
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Self.appendBytes(Self.serializeJSONL(records), to: path, durable: durable,
                                    privateFile: true, trackingRevision: trackingRevision)
    }

    package static func serializeJSONL(_ records: [JSONValue]) throws -> Data {
        var payload = Data()
        for record in records {
            payload.append(try record.serializedData(pretty: false))
            payload.append(0x0A)
        }
        return payload
    }

    @concurrent public static func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try readJSONL(path, at: nil, parse: JSONValue.parse).rows
    }

    package static func readJSONL(_ path: URL, at stamp: SnapshotTailOpLog.FileStamp?,
                                  parse: (Data) throws -> JSONValue) throws -> (rows: [JSONValue], stamp: SnapshotTailOpLog.FileStamp?) {
        let read = try readJSONLReporting(path, at: stamp, parse: parse)
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine else {
            throw PersistenceCoreError.ioFailure("""
                JSONL evidence is incomplete at \(path.path): \(read.report.malformedLineCount) malformed row(s), \
                trailingPartial=\(read.report.trailingPartialLine). Repair the feed or use the reporting reader to retain its integrity receipt.
                """)
        }
        return (read.rows, read.stamp)
    }

    @concurrent public static func readJSONLReporting(_ path: URL) async throws -> (rows: [JSONValue], report: JSONLReadReport) {
        let read = try readJSONLReporting(path, at: nil, parse: JSONValue.parse)
        return (read.rows, read.report)
    }

    private static func readJSONLReporting(_ path: URL, at stamp: SnapshotTailOpLog.FileStamp?,
                                           parse: (Data) throws -> JSONValue) throws
        -> (rows: [JSONValue], report: JSONLReadReport, stamp: SnapshotTailOpLog.FileStamp?) {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { data = Data() }
        let read = Self.decodeJSONL(data, parse: parse) { value, _ in value }
        if let stamp, stamp != SnapshotTailOpLog.fileStamp(path) {
            throw PersistenceCoreError.ioFailure("Transcript changed while reading \(path.path)")
        }
        guard read.report.trailingPartialLine, FileLockScope.heldLockPaths.contains(path.path + ".lock") else {
            return (read.rows, read.report, stamp)
        }
        let complete = Data(data[..<(data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex)])
        let repaired = try Self.writeDataAtomicDurable(complete, to: path, trackingRevision: stamp != nil)
        var report = read.report
        report.trailingPartialLine = false
        report.physicalLineCount -= 1
        return (read.rows, report, repaired)
    }

    /// Invalid UTF-8 is malformed; only the final unterminated parse failure is tolerated in shared physical framing.
    public static func decodeJSONL<Row>(
        _ data: Data, row: (JSONValue, Int) -> Row?
    ) -> (rows: [Row], report: JSONLReadReport) {
        decodeJSONL(data, parse: JSONValue.parse, row: row)
    }

    private static func decodeJSONL<Row>(
        _ data: Data, parse: (Data) throws -> JSONValue, row: (JSONValue, Int) -> Row?
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
            do {
                let parsed = try parse(line)
                if let decoded = row(parsed, line.count + 1) { rows.append(decoded) }
                else { malformed += 1 }
            } catch CocoaError.fileReadCorruptFile {
                malformed += 1
            } catch {
                if index == lines.count - 1 && !endsWithNewline {
                    trailingPartial = true
                } else {
                    malformed += 1
                }
            }
        }
        return (rows, JSONLReadReport(
            malformedLineCount: malformed,
            trailingPartialLine: trailingPartial,
            physicalLineCount: lines.count
        ))
    }

    /// Append a record with durability confirmed before returning; advisory appends do not flush.
    @concurrent public static func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
        try appendRecords([record], to: path, durable: true)
    }

    /// Preserve integrity evidence so bounded readers can distinguish empty from malformed input.
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
        guard receipt.malformedJSONRowCount == 0 else {
            throw PersistenceCoreError.ioFailure("""
                JSONL tail evidence is incomplete at \(path.path): \(receipt.malformedJSONRowCount) malformed row(s). Repair the feed or use the \
                receipt reader to disclose the source gap.
                """)
        }
        return receipt.rows
    }

    /// Keep the bounded tail's valid rows while disclosing skipped malformed input to read-only consumers.
    @concurrent public static func tailJSONLReadReceipt(
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
        catch let error as CocoaError where error.isFileAbsent { return nil }
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
        var delimitersNeeded = limit
        var foundStart = false
        // Read backward until the requested physical lines are complete. A nil byte ceiling permits a long row, not a whole-file read for every tail.
        while offset > lowerBound {
            try Task.checkCancellation()
            let count = min(64 * 1024, offset - lowerBound)
            offset -= count
            var chunk = Data(count: count)
            try unsafe chunk.withUnsafeMutableBytes { raw in
                var filled = 0
                while filled < count {
                    let n = unsafe pread(handle.fileDescriptor, raw.baseAddress!.advanced(by: filled),
                                  count - filled, off_t(offset + filled))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else {
                        throw PersistenceCoreError.ioFailure("Cannot read tail at \(path.path): \(n == 0 ? "file shortened" : unsafe String(cString: strerror(errno)))")
                    }
                    filled += n
                }
            }
            let skipFinalLF = chunks.isEmpty && chunk.last == 10
            let start = unsafe chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
                var end = raw.count - (skipFinalLF ? 1 : 0)
                while end >= 16 {
                    let begin = end - 16
                    let block = unsafe raw.loadUnaligned(fromByteOffset: begin, as: SIMD16<UInt8>.self)
                    let matches = block .== SIMD16<UInt8>(repeating: 10)
                    let count = Int(SIMD16<UInt8>(repeating: 0).replacing(with: 1, where: matches).wrappedSum())
                    if count >= delimitersNeeded { break }
                    delimitersNeeded -= count
                    end = begin
                }
                while end > 0 {
                    end -= 1
                    if unsafe raw[end] == 10 {
                        delimitersNeeded -= 1
                        if delimitersNeeded == 0 { return end + 1 }
                    }
                }
                return nil
            }
            if let start {
                chunks.append(chunk[start...])
                foundStart = true
                break
            }
            chunks.append(chunk)
        }
        var data = Data()
        for chunk in chunks.reversed() { data.append(chunk) }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        // Consumers decide whether to discard a fragment that survived the row limit.
        return (parts.map { Data($0) }, size - offset, seekFromEnd,
                offset > 0 && !foundStart && !parts.isEmpty)
    }

    /// Synchronous writers preserve exact serialized bytes through shared torn-line repair; multiple writers require the feed lock.
    public static func appendLines(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appendBytes(data, to: path)
    }

    /// External stores own serialization and must hold the feed lock.
    public static func appendOwnedBytes(_ data: Data, to path: URL, durable: Bool = false) throws {
        try appendBytes(data, to: path, durable: durable)
    }

    /// Append with O_APPEND, creating the file if absent; durable writes flush before close.
    @discardableResult
    static func appendBytes(
        _ data: Data,
        to path: URL,
        durable: Bool = false,
        privateFile: Bool = false,
        trackingRevision: Bool = false
    ) throws -> AppendRevision? {
        // Path-owned feeds accept bytes only inside the capped append's task-local permit.
        if !JSONLPathOwnedAppendPermit.isInsideCappedAppend,
           jsonlPathOwnedCapPolicy(for: path) != nil {
            throw JSONLPathOwnedAppendError.rawAppendToPathOwnedFeed(
                path.standardizedFileURL.path
            )
        }
        let directory = path.deletingLastPathComponent()
        let parentFD = durable ? open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC) : AT_FDCWD
        if durable && parentFD < 0 {
            throw PersistenceCoreError.ioFailure("Cannot open append directory at \(directory.path): \(unsafe String(cString: strerror(errno)))")
        }
        defer { if durable { _ = close(parentFD) } }
        let fd = openat(parentFD, durable ? path.lastPathComponent : path.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw PersistenceCoreError.ioFailure("open(append) failed: \(unsafe String(cString: strerror(errno)))")
        }
        var handedOff = false
        defer { if !handedOff { _ = Darwin.close(fd) } }
        var info = stat()
        guard unsafe fstat(fd, &info) == 0 else {
            throw PersistenceCoreError.ioFailure("Cannot inspect append framing at \(path.path): \(unsafe String(cString: strerror(errno)))")
        }
        var payload = data
        if info.st_size > 0 {
            var lastByte: UInt8 = 0
            var count: Int
            repeat { count = unsafe pread(fd, &lastByte, 1, info.st_size - 1) } while count < 0 && errno == EINTR
            guard count == 1 else {
                throw PersistenceCoreError.ioFailure("Cannot read append framing at \(path.path): \(count == 0 ? "file shortened" : unsafe String(cString: strerror(errno)))")
            }
            if lastByte != 10 { payload = Data([10]) + data }
        }
        try unsafe payload.withUnsafeBytes { raw in
            guard var ptr = unsafe raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = unsafe write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceCoreError.ioFailure("write failed: \(unsafe String(cString: strerror(errno)))")
                }
                guard n > 0 else { throw PersistenceCoreError.ioFailure("append made no progress") }
                unsafe ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        if privateFile { _ = fchmod(fd, 0o600) }
        var after = stat()
        let revision = trackingRevision && (unsafe fstat(fd, &after)) == 0 && after.st_size == info.st_size + off_t(payload.count)
            ? AppendRevision(before: .init(info), after: .init(after)) : nil
        // Confirm durability on the throwing path before returning.
        handedOff = true
        try flushAndClose(fd: fd, path: path, durable: durable)
        if durable {
            // Persist a newly created entry, including retries after directory-sync failure.
            try syncAppendDirectory(parentFD, path: path, file: info)
        }
        return revision
    }

    private struct SyncedAppendEntry: Equatable {
        let device: dev_t
        let inode: ino_t
        let directory: SnapshotTailOpLog.FileStamp
    }

    private static let syncedEntries = Mutex<[String: SyncedAppendEntry]>([:])

    private static func syncAppendDirectory(_ fd: Int32, path: URL, file: stat) throws {
        var directory = stat()
        guard unsafe fstat(fd, &directory) == 0 else {
            throw PersistenceCoreError.ioFailure("Cannot inspect directory for \(path.path): \(unsafe String(cString: strerror(errno)))")
        }
        let entry = SyncedAppendEntry(device: file.st_dev, inode: file.st_ino, directory: .init(directory))
        let key = path.standardizedFileURL.path
        if syncedEntries.withLock({ $0[key] == entry }) { return }
        try syncDescriptor(fd: fd, path: path.deletingLastPathComponent(), driveCache: false)
        syncedEntries.withLock { $0[key] = entry }
    }

    /// Durable flush and close failures throw; non-durable close failures are logged.
    static func flushAndClose(
        fd: Int32,
        path: URL,
        durable: Bool
    ) throws {
        var flushError: PersistenceCoreError?
        if durable {
            do {
                try syncDescriptor(fd: fd, path: path, driveCache: true)
            } catch let error as PersistenceCoreError {
                flushError = error
            }
        }
        // Close once: Darwin releases the descriptor even when close reports EINTR.
        let closeErrno = Darwin.close(fd) == -1 ? errno : 0
        if let flushError { throw flushError }
        if closeErrno != 0 && closeErrno != EINTR {
            let message = "close(append \(path.lastPathComponent)) failed: \(unsafe String(cString: strerror(closeErrno)))"
            if durable { throw PersistenceCoreError.ioFailure(message) }
            FileHandle.standardError.write(Data("PersistenceCore: \(message)\n".utf8))
        }
    }

    /// Files need drive-cache flush and directories need namespace fsync; unsupported guarantees fail without a weaker mechanism.
    private static func syncDescriptor(fd: Int32, path: URL, driveCache: Bool) throws {
        var code: Int32 = 0
        for _ in 0..<8 {
            let result = driveCache ? Darwin.fcntl(fd, F_FULLFSYNC) : Darwin.fsync(fd)
            code = result == -1 ? errno : 0
            if code == 0 { return }
            if code != EINTR { break }
        }
        let operation = driveCache ? "F_FULLFSYNC" : "fsync"
        throw PersistenceCoreError.ioFailure(
            "\(operation)(\(path.lastPathComponent)) failed: \(unsafe String(cString: strerror(code))) — durability unproven"
        )
    }

    /// Replace relative to a borrowed parent descriptor, or open the pathname's parent. The private 0600 temp uses a drive-cache flush when fullFlush is true;
    /// its parent always uses a checked namespace fsync.
    @discardableResult
    package static func atomicWrite(_ data: Data, to path: URL, parentFD: Int32? = nil, fullFlush: Bool = false,
                                    trackingRevision: Bool = false) throws -> SnapshotTailOpLog.FileStamp? {
        let dir = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let directoryFD = parentFD ?? open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw PersistenceCoreError.ioFailure("open(parent directory) failed: \(unsafe String(cString: strerror(errno)))")
        }
        defer { if parentFD == nil { _ = close(directoryFD) } }
        let tmpName = ".\(UUID().uuidString.lowercased()).tmp"
        let tmpPath = dir.appendingPathComponent(tmpName)

        let fd = openat(directoryFD, tmpName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw PersistenceCoreError.ioFailure("open(tmp) failed: \(unsafe String(cString: strerror(errno)))")
        }
        var fdClosed = false
        var didRename = false
        defer {
            if !fdClosed {
                if close(fd) != 0 {
                    let err = unsafe String(cString: strerror(errno))
                    FileHandle.standardError.write(Data("PersistenceCore: close(tmp fd) failed: \(err)\n".utf8))
                }
            }
            if !didRename {
                _ = unlinkat(directoryFD, tmpName, 0)
            }
        }
        try unsafe data.withUnsafeBytes { raw in
            guard !raw.isEmpty else { return }
            var ptr = unsafe raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = unsafe write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = unsafe String(cString: strerror(errno))
                    throw PersistenceCoreError.ioFailure("write(tmp) failed: \(err)")
                }
                guard n > 0 else { throw PersistenceCoreError.ioFailure("write(tmp) made no progress") }
                unsafe ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        _ = fchmod(fd, 0o600)
        // Sync and close the temp file before rename; either failure preserves the target.
        if fullFlush {
            try syncDescriptor(fd: fd, path: tmpPath, driveCache: true)
        } else if fsync(fd) != 0 {
            let err = unsafe String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("fsync(tmp) failed: \(err)")
        }
        var original = stat()
        if trackingRevision && (unsafe fstat(fd, &original)) != 0 {
            throw PersistenceCoreError.ioFailure("Cannot identify replacement for \(path.path): \(unsafe String(cString: strerror(errno)))")
        }
        if close(fd) != 0 {
            fdClosed = true
            let err = unsafe String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("close(tmp) failed: \(err)")
        }
        fdClosed = true
        if renameat(directoryFD, tmpName, directoryFD, name) != 0 {
            throw PersistenceCoreError.ioFailure("rename failed: \(unsafe String(cString: strerror(errno)))")
        }
        didRename = true
        // Rename may already have committed if this namespace sync fails.
        try syncDescriptor(fd: directoryFD, path: dir, driveCache: false)
        guard trackingRevision else { return nil }
        var current = stat()
        guard unsafe fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino,
              original.st_size == current.st_size,
              original.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
              original.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec else {
            throw PersistenceCoreError.ioFailure("The published replacement at \(path.path) changed before confirmation.")
        }
        return SnapshotTailOpLog.FileStamp(current)
    }

    /// Persist directory-entry changes before a transaction advances.
    public static func syncDirectory(_ dir: URL) throws {
        let directoryFD = open(dir.path, O_RDONLY)
        if directoryFD < 0 {
            throw PersistenceCoreError.ioFailure(
                "open(parent directory) failed: \(unsafe String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(directoryFD) }
        // Directories have namespace durability, never a drive-cache contract.
        try syncDescriptor(fd: directoryFD, path: dir, driveCache: false)
    }
}
