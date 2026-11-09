import Darwin
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
import SQLite3
// Blueprint: | `PartFileReads.swift` | `PartFileReads`: a part's readPaths admission, `files.query` over a private snapshot, `files.mime`'s budget |

/// The stem's file readers for a part: the part names a file its reach grants; the stem reads a consistent snapshot and returns what it read.
package enum PartFileReads {
    static let queryRows = 1...1000, querySeconds = 1...30

    /// A file the part's reach grants: computer_files, and a readPaths entry covering the resolved path (`*` is one component; a directory covers
    /// everything beneath it).
    static func admitted(_ given: JSONValue?, readPaths: [String], permissions: [String]) throws -> URL {
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
        return url
    }

    /// A message file read whole: a missing or unreadable file says which, before any decoding.
    static func mime(_ url: URL, _ arguments: [String: JSONValue]) throws -> JSONValue {
        let budget = try textBudget(arguments)
        do { return try PartMIMERead.read(url, maxTextBytes: budget) }
        catch let error as NSError {
            guard let path = error.userInfo[NSFilePathErrorKey] as? String else { throw error }
            throw reading(URL(fileURLWithPath: path), error)
        }
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

    /// One read-only statement over SQLite's consistent backup of a read-only source connection.
    static func query(_ url: URL, _ arguments: [String: JSONValue]) throws -> JSONValue {
        guard Set(arguments.keys).isSubset(of: ["path", "sql", "params", "limit", "seconds"]), case .string(let sql)? = arguments["sql"], !sql.isEmpty,
              !sql.utf8.contains(0) else {
            throw SenseFailure(code: "bad_input", message: "files.query takes {path, sql, params?, limit?, seconds?}.")
        }
        func bounded(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) throws -> Int {
            guard let given = arguments[key] else { return fallback }
            guard case .int(let value) = given, range.contains(Int(value)) else {
                throw SenseFailure(code: "bad_input", message: "\(key) is a whole number from \(range.lowerBound) through \(range.upperBound).")
            }
            return Int(value)
        }
        let limit = try bounded("limit", queryRows, 200), seconds = try bounded("seconds", querySeconds, 10)
        let params: [JSONValue] = if case .array(let list)? = arguments["params"] { list } else if arguments["params"] == nil { [] } else {
            throw SenseFailure(code: "bad_input", message: "params is a list of strings, numbers, Booleans or nulls.")
        }
        let watch = Watch(deadline: Date().addingTimeInterval(TimeInterval(seconds)))
        let db = try snapshot(url, watch: watch)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw SenseFailure(code: "sqlite_error", message: "The snapshot could not be held read-only. Nothing was read.")
        }
        foldedContains(db)
        let box = Unmanaged.passRetained(watch)
        defer { box.release() }
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<Watch>.fromOpaque(context).takeUnretainedValue().deadline < Date() || Task.isCancelled ? 1 : 0
        }, box.toOpaque())
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
                if step == SQLITE_INTERRUPT {
                    if Task.isCancelled { throw CancellationError() }
                    throw SenseFailure(code: "deadline", message: "The query ran past \(seconds) s and was stopped. Narrow it or raise seconds.")
                }
                throw SenseFailure(code: "sqlite_error", message: "The query failed: \(String(cString: sqlite3_errmsg(db))). Nothing more was read.")
            }
            guard rows.count < limit else { truncated = true; break }
            rows.append(.array((0..<Int32(columns.count)).map { cell(statement, $0) }))
        }
        return .object(["columns": .array(columns), "rows": .array(rows), "count": .int(Int64(rows.count)), "truncated": .bool(truncated),
                        "path": .string(url.path)])
    }

    /// SQLite's backup API reads one database generation, including committed WAL pages; no independently copied sidecars.
    /// Busy writers or a continually changing source spend the same deadline as the query, never an unbounded wait.
    private static func snapshot(_ url: URL, watch: Watch) throws -> OpaquePointer {
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
        do {
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
                let reason = String(cString: sqlite3_errmsg(destination))
                throw SenseFailure(code: "sqlite_error", message: "The snapshot could not start: \(reason). Nothing was read.")
            }
            var result: Int32 = SQLITE_OK
            do {
                repeat {
                    try Task.checkCancellation()
                    guard Date() < watch.deadline else {
                        throw SenseFailure(code: "deadline", message: "The SQLite snapshot exceeded the query deadline. Nothing was read.")
                    }
                    result = sqlite3_backup_step(backup, 128)
                    if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(10) }
                } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
            } catch {
                sqlite3_backup_finish(backup)
                throw error
            }
            let finished = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finished == SQLITE_OK else {
                throw SenseFailure(code: "sqlite_error", message: "The snapshot failed: \(String(cString: sqlite3_errmsg(destination))). Nothing was read.")
            }
            return destination
        } catch { sqlite3_close(destination); throw error }
    }

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

    private final class Watch: Sendable {
        let deadline: Date
        init(deadline: Date) { self.deadline = deadline }
    }
}
