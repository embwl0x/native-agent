import Foundation
import GRDB
import NativeAgentCore
// Blueprint: | `Detail.swift` | `ExperienceStore` detail grain: what the body noticed while a happening ran (a turn's steps, power draws, consent answers, organ beats), one ordered `detail` table in the same store, read by subject, kind and time, forgotten after `detailHorizon` |

/// The record has two grains in one store. An experience is a happening in the agent's life, kept by the law in `ExperienceStore`. A detail is what the body
/// noticed while it ran: written once, never folded, read by subject, kind or time, and forgotten after `detailHorizon`. It never copies substance.
extension ExperienceStore {
    public struct Detail: Sendable, Equatable {
        /// The record's order. Zero on a detail not yet written.
        public let seq: Int64
        /// The owner that wrote it ("trace", "trust", "body", ...); each owner reads its own, so another owner's detail is never misread.
        public let source: String
        public let at: Date
        /// The experience it is about (a turn's id is its heard experience's id), or empty when it is about none.
        public let subject: String
        public let kind: String
        /// The detail itself: one JSON object, bounded by `maxRowBytes`.
        public let row: Data
        /// A detail carrying a key is written at most once under it; a repeat with the same key writes nothing.
        public let once: String?

        public init(source: String, at: Date, subject: String, kind: String, row: Data, once: String? = nil) {
            (self.seq, self.source, self.at, self.subject, self.kind, self.row, self.once) = (0, source, at, subject, kind, row, once)
        }

        init(row: Row) {
            seq = row["seq"]
            source = row["source"]
            at = Date(timeIntervalSince1970: row["at"] as Double)
            subject = row["subject"]
            kind = row["kind"]
            self.row = Data((row["row"] as String).utf8)
            once = row["once"]
        }
    }

    public struct DetailQuery: Sendable {
        public var sources: [String]?
        public var subjects: [String]?
        public var kinds: [String]?
        public var from: Date?
        public var through: Date?
        /// Only details written after this sequence.
        public var after: Int64?
        /// Only details written before this sequence (a reader paging back from the newest).
        public var before: Int64?
        public var limit: Int?
        public var newestFirst: Bool

        public init(sources: [String]? = nil, subjects: [String]? = nil, kinds: [String]? = nil, from: Date? = nil, through: Date? = nil,
                    after: Int64? = nil, before: Int64? = nil, limit: Int? = nil, newestFirst: Bool = false) {
            (self.sources, self.subjects, self.kinds, self.from, self.through, self.after) = (sources, subjects, kinds, from, through, after)
            (self.before, self.limit, self.newestFirst) = (before, limit, newestFirst)
        }
    }

    public enum DetailError: Error, LocalizedError {
        case tooLarge(String, Int)
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let kind, let bytes):
                "A \(kind) detail of \(bytes) bytes is not a detail; its owner keeps the substance and the detail points to it."
            }
        }
    }

    /// The body keeps what it noticed for two weeks; the agent's experiences have no horizon.
    public static let detailHorizon: TimeInterval = 14 * 86_400
    /// The largest row any writer may build: a model call's trace (FeedPolicy.traceMaximumBytes).
    public static let maxRowBytes = 8 << 20

    /// Write details in one transaction, in order. Returns each one's sequence, or nil for a repeat of a `once` key. A `durable` write is flushed
    /// through the drive's cache (F_FULLFSYNC) before it returns, for a detail something else will be removed on the strength of.
    @discardableResult
    public func note(_ details: [Detail], durable: Bool = false) throws -> [Int64?] {
        guard !details.isEmpty else { return [] }
        for detail in details where detail.row.count > Self.maxRowBytes { throw DetailError.tooLarge(detail.kind, detail.row.count) }
        let written = try write(durable: durable) { db in try details.map { try Self.insert($0, db) } }
        try forgetPastHorizon()
        return written
    }

    /// Write one detail unless the details its owner already wrote about its subject say it is not needed; the read and the write are one
    /// transaction.
    @discardableResult
    public func note(_ detail: Detail, durable: Bool = false, unless already: @Sendable ([Detail]) throws -> Bool) throws -> Bool {
        guard detail.row.count <= Self.maxRowBytes else { throw DetailError.tooLarge(detail.kind, detail.row.count) }
        let wrote = try write(durable: durable) { db -> Bool in
            let existing = try Row.fetchAll(db, sql: "SELECT * FROM detail WHERE subject = ? AND source = ? ORDER BY seq",
                                            arguments: [detail.subject, detail.source]).map(Detail.init(row:))
            guard try !already(existing) else { return false }
            return try Self.insert(detail, db) != nil
        }
        try forgetPastHorizon()
        return wrote
    }

    /// One transaction; a durable one also syncs through the drive's cache, which SQLite's ordinary sync on macOS does not.
    private func write<T>(durable: Bool, _ body: (Database) throws -> T) throws -> T {
        guard durable else { return try database().write(body) }
        return try database().writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA fullfsync = ON")
            defer { try? db.execute(sql: "PRAGMA fullfsync = OFF") }
            var result: T?
            try db.inTransaction {
                result = try body(db)
                return .commit
            }
            return result!
        }
    }

    public func details(_ query: DetailQuery) throws -> [Detail] {
        var clauses: [String] = [], arguments = StatementArguments()
        if let sources = query.sources {
            guard !sources.isEmpty else { return [] }
            clauses.append("source IN (" + Array(repeating: "?", count: sources.count).joined(separator: ",") + ")")
            arguments += StatementArguments(sources)
        }
        if let subjects = query.subjects {
            guard !subjects.isEmpty else { return [] }
            clauses.append("subject IN (" + Array(repeating: "?", count: subjects.count).joined(separator: ",") + ")")
            arguments += StatementArguments(subjects)
        }
        if let kinds = query.kinds {
            guard !kinds.isEmpty else { return [] }
            clauses.append("kind IN (" + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ")")
            arguments += StatementArguments(kinds)
        }
        if let from = query.from { clauses.append("at >= ?"); arguments += [from.timeIntervalSince1970] }
        if let through = query.through { clauses.append("at <= ?"); arguments += [through.timeIntervalSince1970] }
        if let after = query.after { clauses.append("seq > ?"); arguments += [after] }
        if let before = query.before { clauses.append("seq < ?"); arguments += [before] }
        var sql = "SELECT * FROM detail"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += query.newestFirst ? " ORDER BY seq DESC" : " ORDER BY seq"
        if let limit = query.limit { sql += " LIMIT \(max(0, limit))" }
        return try database().read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map(Detail.init(row:))
        }
    }

    /// The newest sequence written, or nil when the record holds no detail.
    public func lastDetailSeq() throws -> Int64? {
        try database().read { try Int64.fetchOne($0, sql: "SELECT MAX(seq) FROM detail") }
    }

    private static func insert(_ detail: Detail, _ db: Database) throws -> Int64? {
        try db.execute(sql: "INSERT OR IGNORE INTO detail (source, at, subject, kind, row, once) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [detail.source, detail.at.timeIntervalSince1970, detail.subject, detail.kind,
                                   String(decoding: detail.row, as: UTF8.self), detail.once])
        return db.changesCount == 0 ? nil : db.lastInsertedRowID
    }

    /// At most four times a day, after a write, the details older than the horizon go. Experiences are never touched.
    private func forgetPastHorizon() throws {
        let now = Date()
        guard now.timeIntervalSince(detailsForgottenAt) >= 6 * 3_600 else { return }
        detailsForgottenAt = now
        _ = try database().write { db in
            try db.execute(sql: "DELETE FROM detail WHERE at < ?", arguments: [now.addingTimeInterval(-Self.detailHorizon).timeIntervalSince1970])
        }
    }

    static let detailSchema = """
        CREATE TABLE IF NOT EXISTS detail (seq INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, at REAL NOT NULL,
                                           subject TEXT NOT NULL, kind TEXT NOT NULL, row TEXT NOT NULL, once TEXT);
        CREATE INDEX IF NOT EXISTS detail_source_at ON detail(source, at);
        CREATE INDEX IF NOT EXISTS detail_subject ON detail(subject, seq);
        CREATE INDEX IF NOT EXISTS detail_kind_at ON detail(kind, at);
        CREATE INDEX IF NOT EXISTS detail_at ON detail(at);
        CREATE UNIQUE INDEX IF NOT EXISTS detail_once ON detail(once) WHERE once IS NOT NULL;
        CREATE INDEX IF NOT EXISTS experience_kind_at ON experience(kind, at);
        """
}
