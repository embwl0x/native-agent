import Darwin
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
import SQLite3
import struct NativeAgentShared.ModuleLog
import TrustCenter
// Blueprint: | `PartFileReads.swift` | `PartFileReads`: readPaths admission; `files.query` over a private snapshot, `files.mime`'s budget, `files.names` |

/// The stem's file readers for a part: the part names a file its reach grants; the stem reads a consistent snapshot and returns what it read.
package enum PartFileReads {
    static let queryRows = 1...1000

    /// A file the part's reach grants: computer_files, and a readPaths entry covering the resolved path (`*` is one component; a directory covers
    /// everything beneath it), excluding credentials and the admission signing key.
    static func admitted(_ given: JSONValue?, readPaths: [String], permissions: [String], dataRoot: URL) throws -> URL {
        guard case .string(let raw)? = given, !raw.isEmpty else { throw SenseFailure(code: "bad_input", message: "path names the file to read.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func expanded(_ path: String) -> String { path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path }
        let url = URL(fileURLWithPath: expanded(raw)).standardizedFileURL.resolvingSymlinksInPath()
        guard raw.hasPrefix("/") || raw.hasPrefix("~/"), permissions.contains("computer_files") else {
            throw SenseFailure(code: "undeclared_path", message: "A file read takes an absolute or ~/ path and computer_files reach.")
        }
        let parts = url.pathComponents
        let covered = readPaths.contains { entry in
            let pattern = URL(fileURLWithPath: expanded(entry)).standardizedFileURL.pathComponents
            return pattern.count <= parts.count && zip(pattern, parts).allSatisfy { fnmatch($0, $1, 0) == 0 }
        }
        guard covered else {
            throw SenseFailure(code: "undeclared_path", message: "\(url.path) is not under this part's readPaths; declare it in reach.readPaths.")
        }
        guard try !MacControlSensitivePathFence.isCredentialPath(url, dataRoot: dataRoot) else {
            throw SenseFailure(code: "source_denied", message: "A part cannot read credentials or the admission signing key.")
        }
        return url
    }

    /// A message file read whole: a missing or unreadable file says which, before any decoding.
    static func mime(_ url: URL, _ arguments: [String: JSONValue], readPaths: [String], permissions: [String], dataRoot: URL) throws -> JSONValue {
        let budget = try textBudget(arguments)
        do { return try PartMIMERead.read(url, maxTextBytes: budget, readPaths: readPaths, permissions: permissions, dataRoot: dataRoot) }
        catch let error as NSError {
            guard let path = error.userInfo[NSFilePathErrorKey] as? String else { throw error }
            throw reading(URL(fileURLWithPath: path), error)
        }
    }

    /// A directory's immediate names, sorted; nothing beneath it is opened.
    static func names(_ url: URL, _ arguments: [String: JSONValue]) throws -> JSONValue {
        guard Set(arguments.keys) == ["path"] else { throw SenseFailure(code: "bad_input", message: "files.names takes {path}.") }
        do { return .object(["names": .array(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map { .string($0) })]) }
        catch { throw reading(url, error) }
    }

    /// files.mime's text budget: max_text_bytes from 1 KiB through 16 MiB, 1 MiB when omitted.
    private static func textBudget(_ arguments: [String: JSONValue]) throws -> Int {
        guard Set(arguments.keys).isSubset(of: ["path", "max_text_bytes"]) else {
            throw SenseFailure(code: "bad_input", message: "files.mime takes {path, max_text_bytes?}.")
        }
        guard let given = arguments["max_text_bytes"] else { return 1 << 20 }
        guard case .int(let bytes) = given, (1024...(16 << 20)).contains(Int(bytes)) else {
            throw SenseFailure(code: "bad_input", message: "max_text_bytes is a whole number from 1024 through 16777216.")
        }
        return Int(bytes)
    }

    /// The failed read owns the cause; a later existence probe cannot turn an I/O error into absence.
    static func reading(_ url: URL, _ error: Error) -> SenseFailure {
        let ns = error as NSError, underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let denied = ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(ns.code)
            || underlying.map { $0.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains($0.code) } == true
        if denied {
            return SenseFailure(code: "not_permitted",
                message: "macOS did not let NativeAgent read \(url.path). It may need Full Disk Access. Nothing was read.",
                remedy: MacFourVerbsReply.permissionRemedy("privacy:fullDiskAccess", name: "Full Disk Access"))
        }
        let missing = ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)
            || underlying.map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT) } == true
        if missing {
            return SenseFailure(code: "not_found", message: "\(url.path) does not exist.",
                remedy: VerifiedPath.missingReadEvidence(url)["remedy"])
        }
        return SenseFailure(code: "read_failed", message: "Could not read \(url.path): \(error.localizedDescription). Nothing was read.")
    }

    /// One read-only statement over a private point-in-time clone of the source and its journal files.
    static func query(_ url: URL, _ arguments: [String: JSONValue]) throws -> JSONValue {
        guard Set(arguments.keys).isSubset(of: ["path", "sql", "params", "limit"]), case .string(let sql)? = arguments["sql"], !sql.isEmpty,
              !sql.utf8.contains(0) else {
            throw SenseFailure(code: "bad_input", message: "files.query takes {path, sql, params?, limit?}.")
        }
        func bounded(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) throws -> Int {
            guard let given = arguments[key] else { return fallback }
            guard case .int(let value) = given, range.contains(Int(value)) else {
                throw SenseFailure(code: "bad_input", message: "\(key) is a whole number from \(range.lowerBound) through \(range.upperBound).")
            }
            return Int(value)
        }
        let limit = try bounded("limit", queryRows, 200)
        let params: [JSONValue] = if case .array(let list)? = arguments["params"] { list } else if arguments["params"] == nil { [] } else {
            throw SenseFailure(code: "bad_input", message: "params is a list of strings, numbers, Booleans or nulls.")
        }
        let (db, folder) = try snapshot(url)
        func read() throws -> [String: JSONValue] {
            guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
                throw SenseFailure(code: "sqlite_error", message: "The snapshot could not be held read-only. Nothing was read.")
            }
            foldedContains(db)
            sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            var statement: OpaquePointer?
            // SQLite's tail borrows sql's C buffer. Copy it while that buffer is alive.
            let (prepared, remainder) = sql.withCString { source in
                var tail: UnsafePointer<CChar>?
                let result = sqlite3_prepare_v2(db, source, -1, &statement, &tail)
                return (result, tail.map { String(cString: $0) })
            }
            defer { sqlite3_finalize(statement) }
            guard prepared == SQLITE_OK, let statement else {
                throw SenseFailure(code: "sqlite_error", message: "The query did not prepare: \(String(cString: sqlite3_errmsg(db))). Nothing was read.")
            }
            guard let remainder, remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty,
                  sqlite3_stmt_readonly(statement) != 0 else {
                throw SenseFailure(code: "not_read_only", message: "files.query runs one read-only statement. Nothing was read.")
            }
            let slots = sqlite3_bind_parameter_count(statement)
            guard Int(slots) == params.count else {
                throw SenseFailure(code: "sqlite_error", message: "The query requires \(slots) parameter slots and received \(params.count). Nothing was read.")
            }
            for (index, value) in params.enumerated() {
                let slot = Int32(index + 1)
                switch value {
                case .string(let text): sqlite3_bind_text(statement, slot, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case .int(let number): sqlite3_bind_int64(statement, slot, number)
                case .double(let number): sqlite3_bind_double(statement, slot, number)
                case .bool(let flag): sqlite3_bind_int64(statement, slot, flag ? 1 : 0)
                case .null: sqlite3_bind_null(statement, slot)
                default: throw SenseFailure(code: "bad_input", message: "params[\(index)] is not a string, number, Boolean or null.")
                }
            }
            let columns = (0..<sqlite3_column_count(statement)).map { JSONValue.string(String(cString: sqlite3_column_name(statement, $0))) }
            var rows: [JSONValue] = [], truncated = false
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    if step == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
                    throw SenseFailure(code: "sqlite_error", message: "The query failed: \(String(cString: sqlite3_errmsg(db))). Nothing more was read.")
                }
                guard rows.count < limit else { truncated = true; break }
                rows.append(.array((0..<Int32(columns.count)).map { cell(statement, $0) }))
            }
            return ["columns": .array(columns), "rows": .array(rows), "count": .int(Int64(rows.count)), "truncated": .bool(truncated),
                    "path": .string(url.path), "snapshot": .string(folder == nil ? "sqlite_backup" : "file_clone")]
        }
        let outcome = Result(catching: read)
        sqlite3_close(db)
        let left = folder.flatMap(discard)
        if case .failure = outcome, let left { log("files.query: the private snapshot was not removed: %@", left) }
        var reply = try outcome.get()
        // A clone that could not be removed is part of what happened, beside the rows it gave.
        if let left {
            reply["snapshot_left"] = .string(left)
            log("files.query: the private snapshot was not removed: %@", left)
        }
        return .object(reply)
    }

    /// SQLite's backup API copies one consistent generation (committed WAL pages included) in a single read transaction. A source its app
    /// holds under an exclusive lock (Chrome's History while Chrome runs) refuses that read; then the file and its journal are cloned
    /// instead: APFS clonefile is instant copy-on-write and takes no SQLite lock. The database is cloned before its journal, so a hot
    /// journal rolls the clone back to its last committed state when SQLite opens it; the clone opens read-write only for that recovery.
    /// A source that can be neither read nor cloned reports the lock by name.
    private static func snapshot(_ url: URL) throws -> (db: OpaquePointer, folder: URL?) {
        do { try FileHandle(forReadingFrom: url).close() } catch { throw reading(url, error) }
        var source: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let source else {
            let detail = source.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection."
            sqlite3_close(source)
            throw SenseFailure(code: "sqlite_error", message: "The read-only source could not open: \(detail). Nothing was read.")
        }
        defer { sqlite3_close(source) }
        var destination: OpaquePointer?
        // An empty filename is SQLite's private temporary database, removed when closed; large Mail databases need not fit in RAM.
        guard sqlite3_open_v2("", &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let destination else {
            sqlite3_close(destination)
            throw SenseFailure(code: "sqlite_error", message: "The private SQLite snapshot could not open. Nothing was read.")
        }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            let reason = String(cString: sqlite3_errmsg(destination))
            sqlite3_close(destination)
            throw SenseFailure(code: "sqlite_error", message: "The snapshot could not start: \(reason). Nothing was read.")
        }
        do { try Task.checkCancellation() } catch { sqlite3_backup_finish(backup); sqlite3_close(destination); throw error }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        if result == SQLITE_DONE, finished == SQLITE_OK { return (destination, nil) }
        sqlite3_close(destination)
        guard result == SQLITE_BUSY || result == SQLITE_LOCKED else {
            let code = result == SQLITE_DONE ? finished : result
            throw SenseFailure(code: "sqlite_error", message: "The snapshot failed: \(String(cString: sqlite3_errstr(code))). Nothing was read.")
        }
        return try clone(url)
    }

    private static func clone(_ url: URL) throws -> (db: OpaquePointer, folder: URL?) {
        func failed(_ why: String) -> SenseFailure {
            SenseFailure(code: "sqlite_error", message: """
                \(url.lastPathComponent) is locked by the app that writes it and \(why), so no snapshot was taken. Nothing was read.
                """)
        }
        // SQLite's header change counter moves on every commit: the same value before and after the clones proves they are one generation.
        func generation() throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            let counter: Data
            do {
                try handle.seek(toOffset: 24)
                counter = try handle.read(upToCount: 4) ?? Data()
            } catch {
                try handle.close()
                throw error
            }
            try handle.close()
            return counter
        }
        let before: Data
        do { before = try generation() } catch { throw reading(url, error) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("files-query-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            for suffix in ["", "-journal", "-wal"] {
                // clonefile only: an ordinary copy is neither instant nor a single instant's bytes.
                if clonefile(url.path + suffix, copy.path + suffix, 0) != 0 {
                    let code = errno
                    if !suffix.isEmpty, code == ENOENT { continue }
                    throw failed("its \(suffix.isEmpty ? "file" : String(suffix.dropFirst())) could not be cloned (\(String(cString: strerror(code))))")
                }
            }
            let after: Data
            do { after = try generation() } catch { throw reading(url, error) }
            guard after == before else { throw failed("committed a change while it was being cloned; read it again") }
            try Task.checkCancellation()
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
                let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection."
                sqlite3_close(db)
                throw SenseFailure(code: "sqlite_error", message: "The clone of \(url.lastPathComponent) could not open: \(detail). Nothing was read.")
            }
            return (db, folder)
        } catch {
            if let left = discard(folder) { log("files.query: the private snapshot was not removed: %@", left) }
            throw error
        }
    }

    /// The clone's removal; a failure names the folder and its cause for the caller to report.
    private static func discard(_ folder: URL) -> String? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        do { try FileManager.default.removeItem(at: folder); return nil }
        catch { return folder.path + ": " + error.localizedDescription }
    }
    private static let log = ModuleLog(category: "ToolExecution")

    /// Each cell as read: text as text, a blob as its bytes in base64.
    private static func cell(_ statement: OpaquePointer, _ column: Int32) -> JSONValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
        case SQLITE_NULL: return .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            let bytes = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()
            return .object(["base64": .string(bytes.base64EncodedString())])
        default:
            let count = Int(sqlite3_column_bytes(statement, column))
            let text = sqlite3_column_text(statement, column).map { String(decoding: UnsafeBufferPointer(start: $0, count: count), as: UTF8.self) } ?? ""
            return .string(text)
        }
    }

    /// folded_contains(text_or_blob, needle): containment that ignores case, diacritics and character width; a blob is read as UTF-8.
    private static func foldedContains(_ db: OpaquePointer) {
        sqlite3_create_function_v2(db, "folded_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            func text(_ value: OpaquePointer?) -> String? {
                guard let value, sqlite3_value_type(value) != SQLITE_NULL else { return nil }
                let count = Int(sqlite3_value_bytes(value))
                if sqlite3_value_type(value) == SQLITE_BLOB {
                    return sqlite3_value_blob(value).map { String(decoding: Data(bytes: $0, count: count), as: UTF8.self) } ?? ""
                }
                return sqlite3_value_text(value).map { String(decoding: UnsafeBufferPointer(start: $0, count: count), as: UTF8.self) } ?? ""
            }
            guard let values, let haystack = text(values[0]), let needle = text(values[1]), !needle.isEmpty else {
                sqlite3_result_int(context, 0); return
            }
            let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
            sqlite3_result_int(context, fold(haystack).contains(fold(needle)) ? 1 : 0)
        }, nil, nil, nil)
    }

}
