import CryptoKit
import Darwin
import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
import Transcripts
import ToolRegistry
// Blueprint: | `ChatHistoryIndex.swift` | SQLite-owned content-addressed history; on-demand rows and receipts, semantics-versioned cancellable absorption, transactional manifest reference reclamation |

/// One durable index per history. Every transcript line is projected for
/// search once in its life and kept by the hash of its bytes, so a line that
/// moves to the archive, is copied into a compaction backup, or survives a
/// rewrite (a finished reply replacing its partial) is never parsed again. A
/// file that only grew is read past what was absorbed; any other change
/// rehashes its lines, which costs a read, and parses only lines never seen.
/// The turn that writes a transcript absorbs it and launch absorbs whatever
/// changed while she was away, so a read never replays history.
///
/// Derived and rebuildable: chat/index can be dropped at the cost of one
/// rebuild. SQLite owns cold rows, receipts and manifests; reads materialize
/// only the requested transcript. Storage failures surface to the reader.
/// SQLite/WAL/SHM are excluded from backup, export and phone sync; PrivacyMap: chat.
public final class ChatHistoryIndex: @unchecked Sendable {
    /// Bump only when row, receipt redaction or provenance semantics change.
    /// Old build identities are upgraded once; unrelated builds keep valid rows.
    static let projector = "history-projection-2"

    /// The stored table shapes; bump when the tables below change.
    static let schema = 3

    public static func shared(dataRoot: URL) -> ChatHistoryIndex {
        let root = dataRoot.resolvingSymlinksInPath().standardizedFileURL
        registryLock.lock()
        defer { registryLock.unlock() }
        if let index = registry[root.path] { return index }
        let index = ChatHistoryIndex(dataRoot: root)
        registry[root.path] = index
        return index
    }

    /// The writer's call: absorb a transcript it just committed, behind it.
    public static func absorb(_ file: URL, dataRoot: URL) {
        let index = shared(dataRoot: dataRoot)
        Task.detached(priority: .utility) {
            do { _ = try index.lines(at: file, current: true) }
            catch is CancellationError { }
            catch { index.noteStoreError(error) }
        }
    }

    /// Launch: absorb every transcript (the first launch with this index
    /// builds it, later launches read only what changed). Returns lines
    /// parsed and seconds taken.
    public func absorbAll() async -> (files: Int, parsed: Int, seconds: Double) {
        let started = Date()
        let listed: [(String, URL)]
        do {
            listed = try ChatSessionRetention.transcriptFiles(
                dataRoot: dataRoot, archived: ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot))
        } catch {
            OrganPulse.record("history_index", .skipped, note: "transcripts unlisted: \(error.localizedDescription)")
            return (0, 0, 0)
        }
        let before = parsedCount()
        do {
            try pruneMissingFiles()
            // One utility task leaves cores available to interaction. Projection
            // batches check cancellation; each transcript yields to other work.
            for (_, file) in listed {
                try Task.checkCancellation()
                do { _ = try lines(at: file, current: true) }
                catch is CancellationError { throw CancellationError() }
                catch { noteStoreError(error) }
                await Task.yield()
            }
        } catch is CancellationError {
            return (listed.count, parsedCount() - before, Date().timeIntervalSince(started))
        } catch { noteStoreError(error) }
        let parsed = parsedCount() - before
        let seconds = Date().timeIntervalSince(started)
        let storeError = lock.withLock { self.storeError }
        OrganPulse.record("history_index", found: parsed,
            note: "\(listed.count) transcripts, \(parsed) new lines, \(String(format: "%.1f", seconds)) s"
                + (storeError.map { "; not durable: \($0)" } ?? ""))
        return (listed.count, parsed, seconds)
    }

    // MARK: - Reading

    /// One conversation line as history holds it: who said it, when, the
    /// stored words. For the one reader outside the tool lane, the reading of
    /// her recent life into cares.
    public struct LivedLine: Sendable {
        public let conversation: String
        public let role: String
        public let messageId: String?
        /// The turn's run: a reply and the message it answers share it.
        public let runId: String?
        public let at: Date
        public let words: String
        public let author: String?
        public let peer: String?
        /// The writer marked it machinery, not something said.
        public let mechanical: Bool
    }

    /// Every user and assistant line since `since`, from every transcript and
    /// its archived copies, in file order per transcript. A line kept in both
    /// a transcript and an archive copy comes back once.
    public func livedLines(since: Date) throws -> [LivedLine] {
        let listed = try ChatSessionRetention.transcriptFiles(
            dataRoot: dataRoot, archived: ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot))
        var seen: Set<String> = []
        var out: [LivedLine] = []
        for (conversation, file) in listed {
            for row in try rows(at: file, receipts: false) {
                guard row.valid, row.shape == 2, let role = row.role, role == "user" || role == "assistant",
                      let at = row.instant, at >= since, let words = row.rawContent,
                      seen.insert("\(conversation)|\(row.messageId ?? row.identity)").inserted else { continue }
                out.append(LivedLine(conversation: conversation, role: role, messageId: row.messageId, runId: row.runId, at: at,
                                     words: words, author: row.author, peer: row.peer, mechanical: row.mechanical))
            }
        }
        return out
    }

    /// The rows of one transcript, in file order, with the receipt lane on
    /// tool rows when asked. Throws when the file cannot be read as UTF-8.
    func rows(at file: URL, receipts: Bool) throws -> [ChatHistorySearchRow] {
        absorption.lock()
        defer { absorption.unlock() }
        return try materialize(lines(at: file), receipts: receipts)
    }

    /// The transcript's line hashes, absorbing whatever changed since last read;
    /// `current` also upgrades rows with older projection semantics.
    private func lines(at file: URL, current: Bool = false) throws -> [Data] {
        absorption.lock()
        defer { absorption.unlock() }
        let path = key(file)
        var info = stat()
        func check() throws {
            guard stat(file.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
            // The index never answers for a transcript its reader may not open.
            guard access(file.path, R_OK) == 0 else { throw CocoaError(.fileReadNoPermission) }
        }
        try check()
        let previous = try manifest(path)
        let older = try current && previous.map { try known($0.lines, current: true).count != Set($0.lines).count } == true
        if let previous, previous.stamp == Stamp(info), !older { return previous.lines }
        // Changed: read what the open file's own stamp describes.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return try absorb(handle, path: path, stamp: Stamp(info), previous: older ? nil : previous, current: current)
    }

    // MARK: - Absorbing

    private func absorb(_ handle: FileHandle, path: String, stamp: Stamp, previous: Manifest?, current: Bool) throws -> [Data] {
        // Writers append or replace atomically (a new inode), so the same
        // inode at no smaller size only grew past what was absorbed.
        let grew = previous.map { $0.stamp.inode == stamp.inode && stamp.size >= $0.stamp.size } ?? false
        let start = grew ? previous!.absorbed : 0
        try handle.seek(toOffset: UInt64(start))
        // Exactly the bytes the stamp describes: a later append shows as growth.
        let data = try handle.read(upToCount: max(0, stamp.size - start)) ?? Data()
        var lines = grew ? Array(previous!.lines.prefix(previous!.terminated)) : []
        var terminated = lines.count
        var absorbed = start
        var unseen: [(hash: Data, bytes: Data)] = []
        var cursor = data.startIndex
        func take(_ bytes: Data) {
            let hash = Data(SHA256.hash(data: bytes).prefix(16))
            lines.append(hash)
            unseen.append((hash, bytes))
        }
        // Lines split as Swift strings split them: CR LF is one character, not a break.
        var search = cursor
        while let newline = data[search...].firstIndex(of: 0x0A) {
            search = data.index(after: newline)
            if newline > cursor, data[data.index(before: newline)] == 0x0D { continue }
            if newline > cursor { take(data[cursor..<newline]); terminated += 1 }
            cursor = search
            absorbed = start + data.distance(from: data.startIndex, to: cursor)
        }
        // An unfinished last line is read as it stands and read again once it grows.
        if cursor < data.endIndex { take(data[cursor...]) }

        var known = try known(unseen.map(\.hash), current: current)
        unseen.removeAll { known.contains($0.hash) }
        for batch in stride(from: 0, to: unseen.count, by: 64) {
            var projected: [Data: ChatHistorySearchRow] = [:]
            var receipts: [Data: Receipt] = [:]
            try AppActionBinding.withCatalog {
                for (hash, bytes) in unseen[batch..<min(batch + 64, unseen.count)] where !known.contains(hash) && projected[hash] == nil {
                    try Task.checkCancellation()
                    guard let line = String(data: bytes, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    let (row, receipt) = SwiftToolDispatcher.chatHistorySearchRow(line)
                    projected[hash] = row
                    if let receipt { receipts[hash] = try Receipt(receipt) }
                }
            }
            // Commit each bounded batch. Cancellation preserves completed work;
            // its path holds the hashes until the final manifest replaces them.
            try store(path: path, manifest: nil, projected: projected, receipts: receipts)
            known.formUnion(projected.keys)
        }
        let manifest = Manifest(stamp: stamp, absorbed: absorbed, terminated: terminated, lines: lines)
        try store(path: path, manifest: manifest, projected: [:], receipts: [:])
        return lines
    }

    private func materialize(_ lines: [Data], receipts: Bool) throws -> [ChatHistorySearchRow] {
        try openDatabase().read { db in
            var rows: [Data: ChatHistorySearchRow] = [:]
            for start in stride(from: 0, to: lines.count, by: 256) {
                let hashes = Array(lines[start..<min(start + 256, lines.count)])
                let marks = Array(repeating: "?", count: hashes.count).joined(separator: ",")
                let receiptColumns = receipts ? ", r.content AS receipt_content, r.searchable AS receipt_searchable, r.instant AS receipt_instant, r.peer AS receipt_peer" : ""
                let join = receipts ? " LEFT JOIN receipt r ON r.hash = l.hash" : ""
                for line in try Row.fetchAll(db, sql: "SELECT l.*\(receiptColumns) FROM line l\(join) WHERE l.hash IN (\(marks))",
                                             arguments: StatementArguments(hashes)) {
                    let role: String? = line["role"], messageId: String? = line["message_id"], raw: String? = line["raw_content"]
                    let content: String = line["content"] ?? (role?.lowercased() == "tool" ? "" : raw ?? "")
                    let searchable: String = line["searchable"] ?? content
                    var row = ChatHistorySearchRow(valid: line["valid"], identity: line["identity"] ?? messageId ?? "",
                        role: role, runId: line["run_id"], messageId: messageId, timestamp: line["timestamp"], rawContent: raw,
                        content: content, searchable: searchable, folded: searchable.lowercased(),
                        instant: (line["instant"] as Double?).map(Date.init(timeIntervalSince1970:)),
                        author: line["author"], route: line["route"], peer: line["peer"], tool: line["tool"],
                        displayPrefix: line["display_prefix"], shape: line["shape"], mechanical: line["mechanical"])
                    if receipts, row.isToolRow {
                        guard let content: Data = line["receipt_content"] else { throw CocoaError(.fileReadCorruptFile) }
                        row = try Receipt(content: content, searchable: line["receipt_searchable"],
                                          instant: line["receipt_instant"], peer: line["receipt_peer"]).applied(to: row)
                    }
                    rows[line["hash"]] = row
                }
            }
            return try lines.map {
                guard let row = rows[$0] else { throw CocoaError(.fileReadNoSuchFile) }
                return row
            }
        }
    }

    // MARK: - State

    struct Stamp: Equatable {
        var inode: UInt64
        var size: Int
        var modified: Double

        init(inode: UInt64, size: Int, modified: Double) {
            (self.inode, self.size, self.modified) = (inode, size, modified)
        }

        init(_ info: stat) {
            self.init(inode: UInt64(info.st_ino), size: Int(info.st_size),
                      modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        }
    }

    private struct Manifest {
        var stamp: Stamp
        /// Bytes through the last newline; `terminated` lines end there.
        var absorbed: Int
        var terminated: Int
        var lines: [Data]
    }

    /// A tool row's receipt lane, compressed: it is read only by receipt searches.
    private struct Receipt {
        var content: Data
        var searchable: String?
        var instant: Double?
        var peer: String?

        init(content: Data, searchable: String?, instant: Double?, peer: String?) {
            (self.content, self.searchable, self.instant, self.peer) = (content, searchable, instant, peer)
        }

        init(_ row: ChatHistorySearchRow) throws {
            try self.init(content: (Data(row.content.utf8) as NSData).compressed(using: .lzfse) as Data,
                          searchable: row.searchable == row.content ? nil : row.searchable,
                          instant: row.instant?.timeIntervalSince1970, peer: row.peer)
        }

        func applied(to row: ChatHistorySearchRow) throws -> ChatHistorySearchRow {
            var row = row
            row.content = String(decoding: try (content as NSData).decompressed(using: .lzfse) as Data, as: UTF8.self)
            row.searchable = searchable ?? row.content
            row.folded = row.searchable.lowercased()
            row.instant = instant.map(Date.init(timeIntervalSince1970:))
            row.peer = peer
            return row
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ChatHistoryIndex] = [:]

    private let dataRoot: URL
    private let lock = NSLock()
    /// Serial absorption keeps one transcript's projection in flight, and a
    /// manifest/row read cannot race reference reclamation by another writer.
    private let absorption = NSRecursiveLock()
    private var parsed = 0
    private var storeError: String?
    private var database: DatabaseQueue?

    private init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Paths inside the data root are kept relative, so a moved root keeps its index.
    private func key(_ file: URL) -> String {
        let path = file.standardizedFileURL.path
        guard let tail = NativeAgentWorkspaceRoot.relativePath(path, under: dataRoot.path), !tail.isEmpty else { return path }
        return tail
    }

    private func manifest(_ path: String) throws -> Manifest? {
        try openDatabase().read { db in
            guard let file = try Row.fetchOne(db, sql: "SELECT * FROM file WHERE path = ?", arguments: [path]) else { return nil }
            return Self.manifest(file)
        }
    }

    private static func manifest(_ file: Row) -> Manifest? {
        let packed: Data = file["lines"], size: Int = file["size"], absorbed: Int = file["absorbed"], terminated: Int = file["terminated"]
        guard packed.count % 16 == 0, 0 <= absorbed, absorbed <= size else { return nil }
        let lines = stride(from: 0, to: packed.count, by: 16).map { packed.subdata(in: $0..<$0 + 16) }
        guard 0 <= terminated, terminated <= lines.count else { return nil }
        return Manifest(stamp: Stamp(inode: UInt64(bitPattern: file["inode"]), size: size, modified: file["modified"]),
                        absorbed: absorbed, terminated: terminated, lines: lines)
    }

    /// Only hashes cross this read; receipt payloads stay in SQLite until requested.
    private func known(_ hashes: [Data], current: Bool) throws -> Set<Data> {
        try openDatabase().read { db in
            var found: Set<Data> = []
            for start in stride(from: 0, to: hashes.count, by: 256) {
                let batch = Array(hashes[start..<min(start + 256, hashes.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                var arguments = StatementArguments(batch)
                if current { arguments += [Self.projector] }
                found.formUnion(try Data.fetchAll(db, sql: """
                    SELECT l.hash FROM line l LEFT JOIN receipt r ON r.hash = l.hash
                    WHERE l.hash IN (\(marks)) AND (lower(coalesce(l.role, '')) != 'tool' OR r.hash IS NOT NULL)
                    \(current ? "AND l.projector = ?" : "")
                    """, arguments: arguments))
            }
            return found
        }
    }

    private func parsedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return parsed
    }

    // MARK: - Durable owner

    private func store(path: String, manifest: Manifest?, projected new: [Data: ChatHistorySearchRow],
                       receipts newReceipts: [Data: Receipt]) throws {
        try openDatabase().write { db in
            for (hash, row) in new {
                let content: String? = row.content == (row.isToolRow ? "" : row.rawContent ?? "") ? nil : row.content
                try db.execute(sql: """
                    INSERT OR REPLACE INTO line (hash, valid, identity, role, run_id, message_id, timestamp,
                        raw_content, content, searchable, instant, author, route, peer, tool, display_prefix, shape,
                        projector, mechanical)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [hash, row.valid, row.identity == row.messageId ? nil : row.identity,
                                     row.role, row.runId, row.messageId, row.timestamp, row.rawContent, content,
                                     row.searchable == row.content ? nil : row.searchable,
                                     row.instant?.timeIntervalSince1970, row.author, row.route, row.peer,
                                     row.tool, row.displayPrefix, row.shape, Self.projector, row.mechanical])
            }
            for (hash, receipt) in newReceipts {
                try db.execute(sql: "INSERT OR REPLACE INTO receipt (hash, content, searchable, instant, peer) VALUES (?, ?, ?, ?, ?)",
                               arguments: [hash, receipt.content, receipt.searchable, receipt.instant, receipt.peer])
            }
            guard let manifest else {
                for hash in new.keys {
                    try db.execute(sql: "INSERT OR IGNORE INTO held(path, hash) VALUES (?, ?)", arguments: [path, hash])
                }
                return
            }
            let previous = Set(try Data.fetchAll(db, sql: "SELECT hash FROM held WHERE path = ?", arguments: [path]))
            try db.execute(sql: """
                INSERT OR REPLACE INTO file (path, inode, size, modified, absorbed, terminated, lines)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [path, Int64(bitPattern: manifest.stamp.inode), manifest.stamp.size,
                                 manifest.stamp.modified, manifest.absorbed, manifest.terminated,
                                 manifest.lines.reduce(into: Data()) { $0.append($1) }])
            for hash in Set(manifest.lines).subtracting(previous) {
                try db.execute(sql: "INSERT INTO held(path, hash) VALUES (?, ?)", arguments: [path, hash])
            }
            for hash in previous.subtracting(manifest.lines) {
                try db.execute(sql: "DELETE FROM held WHERE path = ? AND hash = ?", arguments: [path, hash])
                try Self.reclaim(hash, db: db)
            }
        }
        lock.lock()
        parsed += new.count
        lock.unlock()
    }

    private func noteStoreError(_ error: Error) {
        lock.lock()
        storeError = error.localizedDescription
        lock.unlock()
        OrganPulse.record("history_index", .skipped, note: "not durable: \(error.localizedDescription)")
    }

    /// Open only the store. No transcript payload is retained by this owner.
    private func openDatabase() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        if let database { return database }
        let url = dataRoot.appendingPathComponent("chat/index/history.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version != Self.schema else { return }
            // Version 2's rows and packed manifests survive the one-time reference migration.
            // Older derived shapes are rebuilt, as before.
            if version != 2 {
                try db.execute(sql: """
                    DROP TABLE IF EXISTS meta; DROP TABLE IF EXISTS held;
                    DROP TABLE IF EXISTS line; DROP TABLE IF EXISTS receipt; DROP TABLE IF EXISTS file;
                    CREATE TABLE line (hash BLOB PRIMARY KEY, valid INTEGER NOT NULL, shape INTEGER NOT NULL, identity TEXT, role TEXT,
                        run_id TEXT, message_id TEXT, timestamp TEXT, raw_content TEXT, content TEXT,
                        searchable TEXT, instant REAL, author TEXT, route TEXT, peer TEXT, tool TEXT,
                        display_prefix TEXT NOT NULL, projector TEXT NOT NULL, mechanical INTEGER NOT NULL);
                    CREATE TABLE receipt (hash BLOB PRIMARY KEY, content BLOB NOT NULL, searchable TEXT,
                        instant REAL, peer TEXT);
                    CREATE TABLE file (path TEXT PRIMARY KEY, inode INTEGER NOT NULL, size INTEGER NOT NULL,
                        modified REAL NOT NULL, absorbed INTEGER NOT NULL, terminated INTEGER NOT NULL, lines BLOB NOT NULL);
                    """)
            }
            try db.execute(sql: """
                CREATE TABLE held (path TEXT NOT NULL, hash BLOB NOT NULL, PRIMARY KEY(path, hash));
                CREATE INDEX held_hash ON held(hash);
                """)
            for file in try Row.fetchAll(db, sql: "SELECT * FROM file") {
                guard let manifest = Self.manifest(file) else {
                    try db.execute(sql: "DELETE FROM file WHERE path = ?", arguments: [file["path"] as String])
                    continue
                }
                for hash in Set(manifest.lines) {
                    try db.execute(sql: "INSERT INTO held(path, hash) VALUES (?, ?)", arguments: [file["path"] as String, hash])
                }
            }
            try db.execute(sql: """
                DELETE FROM receipt WHERE NOT EXISTS (SELECT 1 FROM held WHERE held.hash = receipt.hash);
                DELETE FROM line WHERE NOT EXISTS (SELECT 1 FROM held WHERE held.hash = line.hash);
                PRAGMA user_version = \(Self.schema);
                """)
        }
        self.database = database
        return database
    }

    private static func reclaim(_ hash: Data, db: Database) throws {
        try db.execute(sql: "DELETE FROM receipt WHERE hash = ? AND NOT EXISTS (SELECT 1 FROM held WHERE hash = ?)",
                       arguments: [hash, hash])
        try db.execute(sql: "DELETE FROM line WHERE hash = ? AND NOT EXISTS (SELECT 1 FROM held WHERE hash = ?)",
                       arguments: [hash, hash])
    }

    /// Check manifests without loading any row or receipt body.
    private func pruneMissingFiles() throws {
        absorption.lock()
        defer { absorption.unlock() }
        try openDatabase().write { db in
            for path in try String.fetchAll(db, sql: "SELECT path FROM file UNION SELECT path FROM held") {
                let file = path.hasPrefix("/") ? path : dataRoot.appendingPathComponent(path).path
                guard !FileManager.default.fileExists(atPath: file) else { continue }
                let hashes = try Data.fetchAll(db, sql: "SELECT hash FROM held WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM file WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM held WHERE path = ?", arguments: [path])
                for hash in hashes { try Self.reclaim(hash, db: db) }
            }
        }
    }
}
