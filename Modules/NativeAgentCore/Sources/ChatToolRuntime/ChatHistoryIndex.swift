import CryptoKit
import Darwin
import Foundation
import GRDB
import NativeAgentCore
import Transcripts
// Blueprint: | `ChatHistoryIndex.swift` | `ChatHistoryIndex` class; `shared`, `absorb`, `absorbAll`, `livedLines`; durable content-addressed index of transcript lines for history search (chat/index/history.sqlite) |

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
/// rebuild. The database mirrors the in-memory index; a database that cannot
/// open or write leaves search working from memory and says so in her pulse.
/// SQLite/WAL/SHM are excluded from backup, export and phone sync; PrivacyMap: chat.
public final class ChatHistoryIndex: @unchecked Sendable {
    /// The code that projects rows. Projection applies redaction, peer
    /// provenance and tool names owned elsewhere, so each row carries the build
    /// that projected it: reads keep serving an older build's rows while this
    /// build's first launch projects them again behind her.
    static let projector: String = {
        let build = NativeAgentBuildIdentity.current
        return build.sourceContentID ?? build.sourceRevision.map { "\($0) \(build.build)" } ?? "\(build.version) \(build.build)"
    }()

    /// The stored table shapes; bump when the tables below change.
    static let schema = 2

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
        Task.detached(priority: .utility) { _ = try? index.lines(at: file, current: true) }
    }

    /// Launch: absorb every transcript (the first launch with this index
    /// builds it, later launches read only what changed). Returns lines
    /// parsed and seconds taken.
    public func absorbAll() -> (files: Int, parsed: Int, seconds: Double) {
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
        // Transcripts absorb independently, so a build's first launch uses every core once.
        DispatchQueue.concurrentPerform(iterations: listed.count) { _ = try? lines(at: listed[$0].1, current: true) }
        let parsed = parsedCount() - before
        let seconds = Date().timeIntervalSince(started)
        lock.lock()
        let storeError = self.storeError
        lock.unlock()
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
        try materialize(lines(at: file), receipts: receipts)
    }

    /// The transcript's line hashes, absorbing whatever changed since last read;
    /// `current` also re-projects lines an older build projected.
    private func lines(at file: URL, current: Bool = false) throws -> [Data] {
        let path = key(file)
        var info = stat()
        func check() throws {
            guard stat(file.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
            // The index never answers for a transcript its reader may not open.
            guard access(file.path, R_OK) == 0 else { throw CocoaError(.fileReadNoPermission) }
        }
        try check()
        // A read serves the index as it stands, never waiting behind an absorber.
        if !current, let previous = manifest(path), previous.stamp == Stamp(info) { return previous.lines }
        let fileLock = lock(for: path)
        fileLock.lock()
        defer { fileLock.unlock() }
        try check()
        let previous = manifest(path)
        let older = current && previous.map { holdsOlder($0.lines) } == true
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
            if !known(hash, current: current) { unseen.append((hash, bytes)) }
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

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        var projected: [Data: ChatHistorySearchRow] = [:]
        var receipts: [Data: Receipt] = [:]
        for (hash, bytes) in unseen where projected[hash] == nil {
            // A file that is not UTF-8 stays unreadable, as it was before the index.
            guard let line = String(data: bytes, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let (row, receipt) = SwiftToolDispatcher.chatHistorySearchRow(line, fractional: fractional, whole: whole)
            projected[hash] = row
            if let receipt { receipts[hash] = try Receipt(receipt) }
        }
        let manifest = Manifest(stamp: stamp, absorbed: absorbed, terminated: terminated, lines: lines)
        store(path: path, manifest: manifest, projected: projected, receipts: receipts)
        return lines
    }

    private func materialize(_ lines: [Data], receipts: Bool) throws -> [ChatHistorySearchRow] {
        lock.lock()
        let rows = lines.map { (projected[$0], self.receipts[$0]) }
        lock.unlock()
        return try rows.map { row, receipt in
            // Only a transcript deleted mid-read loses its lines here.
            guard let row else { throw CocoaError(.fileReadNoSuchFile) }
            guard receipts, row.isToolRow else { return row }
            guard let receipt else { throw CocoaError(.fileReadCorruptFile) }
            return try receipt.applied(to: row)
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
    private var loaded = false
    private var parsed = 0
    private var storeError: String?
    private var database: DatabaseQueue?
    private var projected: [Data: ChatHistorySearchRow] = [:]
    private var receipts: [Data: Receipt] = [:]
    /// Lines an older build projected: still served, projected again at launch.
    private var older: Set<Data> = []
    private var manifests: [String: Manifest] = [:]
    private var fileLocks: [String: NSLock] = [:]

    private init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Paths inside the data root are kept relative, so a moved root keeps its index.
    private func key(_ file: URL) -> String {
        let path = file.standardizedFileURL.path, root = dataRoot.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func lock(for path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = fileLocks[path] { return existing }
        let created = NSLock()
        fileLocks[path] = created
        return created
    }

    private func manifest(_ path: String) -> Manifest? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return manifests[path]
    }

    /// Projected already; with `current`, by this build.
    private func known(_ hash: Data, current: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let row = projected[hash], !(current && older.contains(hash)) else { return false }
        return !row.isToolRow || receipts[hash] != nil
    }

    private func holdsOlder(_ lines: [Data]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !older.isEmpty && lines.contains(where: older.contains)
    }

    private func parsedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return parsed
    }

    // MARK: - Durable mirror

    private func store(path: String, manifest: Manifest, projected new: [Data: ChatHistorySearchRow],
                       receipts newReceipts: [Data: Receipt]) {
        lock.lock()
        projected.merge(new) { _, fresh in fresh }
        receipts.merge(newReceipts) { _, fresh in fresh }
        older.subtract(new.keys)
        manifests[path] = manifest
        parsed += new.count
        let database = database
        lock.unlock()
        guard let database else { return }
        do {
            try database.write { db in
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
                try db.execute(sql: """
                    INSERT OR REPLACE INTO file (path, inode, size, modified, absorbed, terminated, lines)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [path, Int64(bitPattern: manifest.stamp.inode), manifest.stamp.size,
                                     manifest.stamp.modified, manifest.absorbed, manifest.terminated,
                                     manifest.lines.reduce(into: Data()) { $0.append($1) }])
            }
        } catch {
            noteStoreError(error)
        }
    }

    private func noteStoreError(_ error: Error) {
        lock.lock()
        storeError = error.localizedDescription
        lock.unlock()
        OrganPulse.record("history_index", .skipped, note: "not durable: \(error.localizedDescription)")
    }

    /// Caller holds `lock`. Opens the mirror and loads it whole, once.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            let url = dataRoot.appendingPathComponent("chat/index/history.sqlite")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.busyMode = .timeout(2)
            configuration.prepareDatabase { db in
                // Rebuildable: a power cut may cost the newest absorbs, never correctness.
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            try database.write { db in
                // The table shapes are this file's; a different shape starts over.
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") != Self.schema else { return }
                try db.execute(sql: """
                    DROP TABLE IF EXISTS meta; DROP TABLE IF EXISTS line; DROP TABLE IF EXISTS receipt; DROP TABLE IF EXISTS file;
                    CREATE TABLE line (hash BLOB PRIMARY KEY, valid INTEGER NOT NULL, shape INTEGER NOT NULL, identity TEXT, role TEXT,
                        run_id TEXT, message_id TEXT, timestamp TEXT, raw_content TEXT, content TEXT,
                        searchable TEXT, instant REAL, author TEXT, route TEXT, peer TEXT, tool TEXT,
                        display_prefix TEXT NOT NULL, projector TEXT NOT NULL, mechanical INTEGER NOT NULL);
                    CREATE TABLE receipt (hash BLOB PRIMARY KEY, content BLOB NOT NULL, searchable TEXT,
                        instant REAL, peer TEXT);
                    CREATE TABLE file (path TEXT PRIMARY KEY, inode INTEGER NOT NULL, size INTEGER NOT NULL,
                        modified REAL NOT NULL, absorbed INTEGER NOT NULL, terminated INTEGER NOT NULL,
                        lines BLOB NOT NULL);
                    PRAGMA user_version = \(Self.schema);
                    """)
            }
            try database.read { db in
                let lines = try Row.fetchCursor(db, sql: """
                    SELECT hash, valid, identity, role, run_id, message_id, timestamp, raw_content, content,
                        searchable, instant, author, route, peer, tool, display_prefix, shape, projector, mechanical FROM line
                    """)
                while let line = try lines.next() {
                    let role: String? = line[3], messageId: String? = line[5], rawContent: String? = line[7]
                    let isTool = role?.lowercased() == "tool"
                    let content: String = line[8] ?? (isTool ? "" : rawContent ?? "")
                    let searchable: String = line[9] ?? content
                    let hash: Data = line[0]
                    if line[17] as String != Self.projector { older.insert(hash) }
                    projected[hash] = ChatHistorySearchRow(
                        valid: line[1], identity: line[2] ?? messageId ?? "", role: role, runId: line[4],
                        messageId: messageId, timestamp: line[6], rawContent: rawContent, content: content,
                        searchable: searchable, folded: searchable.lowercased(),
                        instant: (line[10] as Double?).map(Date.init(timeIntervalSince1970:)),
                        author: line[11], route: line[12], peer: line[13], tool: line[14], displayPrefix: line[15],
                        shape: line[16], mechanical: line[18])
                }
                let receiptRows = try Row.fetchCursor(db, sql: "SELECT hash, content, searchable, instant, peer FROM receipt")
                while let receipt = try receiptRows.next() {
                    receipts[receipt[0]] = Receipt(content: receipt[1], searchable: receipt[2],
                                                   instant: receipt[3], peer: receipt[4])
                }
                let files = try Row.fetchCursor(db, sql: "SELECT path, inode, size, modified, absorbed, terminated, lines FROM file")
                while let file = try files.next() {
                    let packed: Data = file[6], size: Int = file[2], absorbed: Int = file[4], terminated: Int = file[5]
                    // A manifest that does not decode, or names a line the mirror lost, is re-read whole.
                    guard packed.count % 16 == 0, 0 <= absorbed, absorbed <= size else { continue }
                    let lines = stride(from: 0, to: packed.count, by: 16).map {
                        packed.subdata(in: packed.startIndex + $0 ..< packed.startIndex + $0 + 16)
                    }
                    guard 0 <= terminated, terminated <= lines.count, lines.allSatisfy({ hash in
                        projected[hash].map { !$0.isToolRow || receipts[hash] != nil } ?? false
                    }) else { continue }
                    manifests[file[0]] = Manifest(
                        stamp: Stamp(inode: UInt64(bitPattern: file[1]), size: size, modified: file[3]),
                        absorbed: absorbed, terminated: terminated, lines: lines)
                }
            }
            // Before this process absorbs anything: forget transcripts that are
            // gone and lines no transcript holds, so no read races the sweep.
            let gone = manifests.keys.filter {
                !FileManager.default.fileExists(atPath: $0.hasPrefix("/") ? $0 : dataRoot.appendingPathComponent($0).path)
            }
            for path in gone { manifests.removeValue(forKey: path) }
            let held = Set(manifests.values.flatMap(\.lines))
            let orphans = projected.keys.filter { !held.contains($0) }
            for hash in orphans {
                projected.removeValue(forKey: hash)
                receipts.removeValue(forKey: hash)
                older.remove(hash)
            }
            do {
                try database.write { db in
                    for path in gone { try db.execute(sql: "DELETE FROM file WHERE path = ?", arguments: [path]) }
                    for hash in orphans {
                        try db.execute(sql: "DELETE FROM line WHERE hash = ?", arguments: [hash])
                        try db.execute(sql: "DELETE FROM receipt WHERE hash = ?", arguments: [hash])
                    }
                }
            } catch {
                // Leftover rows cost space, never correctness; the next launch sweeps again.
                storeError = error.localizedDescription
                OrganPulse.record("history_index", .skipped, note: "not swept: \(error.localizedDescription)")
            }
            self.database = database
        } catch {
            storeError = error.localizedDescription
            OrganPulse.record("history_index", .skipped, note: "not durable: \(error.localizedDescription)")
        }
    }
}
