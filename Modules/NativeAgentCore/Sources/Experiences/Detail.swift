import Foundation
import GRDB
import NativeAgentCore
// Blueprint: | `Detail.swift` | `ExperienceStore`: ordered detail writes, checked durable flush and retained attention provenance |

/// The record has two grains in one store. An experience is a happening in the agent's life, kept by the law in `ExperienceStore`. A detail is what the body
/// noticed while it ran: written once and read by subject, kind or time. Attention membership is retained; other details have `detailHorizon`.
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
        public var subjectPrefix: String?
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
                    after: Int64? = nil, before: Int64? = nil, limit: Int? = nil, newestFirst: Bool = false, subjectPrefix: String? = nil) {
            (self.sources, self.subjects, self.kinds, self.from, self.through, self.after) = (sources, subjects, kinds, from, through, after)
            (self.before, self.limit, self.newestFirst) = (before, limit, newestFirst)
            self.subjectPrefix = subjectPrefix
        }
    }

    public enum DetailError: Error, LocalizedError {
        case tooLarge(String, Int)
        case missingTransactionResult
        case unreadableFullSync
        case fullSyncCleanup(committed: Bool, transaction: String?, cleanup: String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let kind, let bytes):
                "A \(kind) detail of \(bytes) bytes is not a detail; its owner keeps the substance and the detail points to it."
            case .missingTransactionResult: "The detail transaction returned without its result."
            case .unreadableFullSync: "SQLite did not return its fullfsync setting; the durable detail write did not run."
            case .fullSyncCleanup(let committed, let transaction, let cleanup):
                "The detail transaction \(committed ? "committed" : "did not commit"); fullfsync restoration failed: \(cleanup)."
                    + (transaction.map { " Transaction failure: " + $0 } ?? "")
            }
        }
    }

    /// Non-membership details have a two-week horizon; experiences and attention provenance are retained.
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
        if wrote { try forgetPastHorizon() }
        return wrote
    }

    /// One transaction; a durable one also syncs through the drive's cache, which SQLite's ordinary sync on macOS does not.
    private func write<T>(durable: Bool, _ body: (Database) throws -> T) throws -> T {
        guard durable else { return try database().write(body) }
        return try database().writeWithoutTransaction { db in
            guard let original = try Int.fetchOne(db, sql: "PRAGMA fullfsync"), original == 0 || original == 1 else {
                throw DetailError.unreadableFullSync
            }
            if original == 0 { try db.execute(sql: "PRAGMA fullfsync = ON") }
            var result: Result<T, Error>?
            var committed = false
            do {
                try db.inTransaction {
                    result = .success(try body(db))
                    return .commit
                }
                committed = true
            } catch { result = .failure(error) }
            do { if original == 0 { try db.execute(sql: "PRAGMA fullfsync = OFF") } } catch {
                let transaction: String?
                if let result, case .failure(let failure) = result { transaction = failure.localizedDescription } else { transaction = nil }
                throw DetailError.fullSyncCleanup(committed: committed, transaction: transaction, cleanup: error.localizedDescription)
            }
            guard let result else { throw DetailError.missingTransactionResult }
            return try result.get()
        }
    }

    public func details(_ query: DetailQuery) throws -> [Detail] {
        if query.sources?.isEmpty == true || query.subjects?.isEmpty == true || query.kinds?.isEmpty == true { return [] }
        return try database().read { try Self.selectDetails(query, in: $0).items }
    }

    /// A history page and its full match count share the store's read-only snapshot; reading never trims retained rows.
    public func recordedDetails(_ query: DetailQuery) throws -> (total: Int, items: [Detail]) {
        try readRecorded { try Self.selectDetails(query, in: $0, counting: true) }
    }

    /// The distinct strings one JSON path holds across the committed details a query matches, where each `holding` path holds exactly that JSON
    /// (`"\"end\""`, `"false"`), each `lacking` path is absent and each `bearing` path holds text. SQLite answers from the rows; none is decoded
    /// here. A store not yet written holds none, and reading never initializes it.
    public nonisolated func recordedDetailValues(_ query: DetailQuery, at value: String, holding: [String: String] = [:],
                                                 lacking: [String] = [], bearing: [String] = []) throws -> [String] {
        guard let found = Self.conditions(query) else { return [] }
        do { _ = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        var clauses = found.clauses, arguments = found.arguments
        clauses.append("json_type(row, ?) = 'text'")
        arguments += [value]
        for (key, json) in holding.sorted(by: { $0.key < $1.key }) {
            clauses.append("(row -> ?) = ?")
            arguments += [key, json]
        }
        for key in lacking {
            clauses.append("json_type(row, ?) IS NULL")
            arguments += [key]
        }
        for key in bearing {
            clauses.append("json_type(row, ?) = 'text'")
            arguments += [key]
        }
        let sql = "SELECT DISTINCT json_extract(row, ?) FROM detail WHERE " + clauses.joined(separator: " AND ")
        return try readRecorded { try String.fetchAll($0, sql: sql, arguments: StatementArguments([value]) + arguments) }
    }

    /// A query's conditions and their arguments; nil when an empty list in it matches nothing.
    private static func conditions(_ query: DetailQuery) -> (clauses: [String], arguments: StatementArguments)? {
        var clauses: [String] = [], arguments = StatementArguments()
        if let sources = query.sources {
            guard !sources.isEmpty else { return nil }
            clauses.append("source IN (" + Array(repeating: "?", count: sources.count).joined(separator: ",") + ")")
            arguments += StatementArguments(sources)
        }
        if let subjects = query.subjects {
            guard !subjects.isEmpty else { return nil }
            clauses.append("subject IN (" + Array(repeating: "?", count: subjects.count).joined(separator: ",") + ")")
            arguments += StatementArguments(subjects)
        }
        if let kinds = query.kinds {
            guard !kinds.isEmpty else { return nil }
            clauses.append("kind IN (" + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ")")
            arguments += StatementArguments(kinds)
        }
        if let prefix = query.subjectPrefix {
            clauses.append("substr(subject, 1, length(?)) = ?")
            arguments += [prefix, prefix]
        }
        if let from = query.from { clauses.append("at >= ?"); arguments += [from.timeIntervalSince1970] }
        if let through = query.through { clauses.append("at <= ?"); arguments += [through.timeIntervalSince1970] }
        if let after = query.after { clauses.append("seq > ?"); arguments += [after] }
        if let before = query.before { clauses.append("seq < ?"); arguments += [before] }
        return (clauses, arguments)
    }

    private static func selectDetails(_ query: DetailQuery, in db: Database,
                                      counting: Bool = false) throws -> (total: Int, items: [Detail]) {
        guard let found = conditions(query) else { return (0, []) }
        let clauses = found.clauses, arguments = found.arguments
        let matching = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let total: Int
        if counting {
            guard let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM detail" + matching, arguments: arguments) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            total = count
        } else { total = 0 }
        var sql = "SELECT * FROM detail" + matching
        sql += query.newestFirst ? " ORDER BY seq DESC" : " ORDER BY seq"
        if let limit = query.limit { sql += " LIMIT \(max(0, limit))" }
        let items = try Row.fetchAll(db, sql: sql, arguments: arguments).map(Detail.init(row:))
        return (counting ? total : items.count, items)
    }

    /// The newest sequence written, or nil when the record holds no detail.
    public func lastDetailSeq() throws -> Int64? {
        try database().read { try Int64.fetchOne($0, sql: "SELECT MAX(seq) FROM detail") }
    }

    static func insert(_ detail: Detail, _ db: Database) throws -> Int64? {
        if let once = detail.once,
           try Int64.fetchOne(db, sql: "SELECT seq FROM detail WHERE once = ?", arguments: [once]) != nil { return nil }
        try db.execute(sql: "INSERT INTO detail (source, at, subject, kind, row, once) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [detail.source, detail.at.timeIntervalSince1970, detail.subject, detail.kind,
                                   String(decoding: detail.row, as: UTF8.self), detail.once])
        return db.changesCount == 0 ? nil : db.lastInsertedRowID
    }

    /// Detail retention preserves attention's outstanding membership and consumption boundaries.
    private func forgetPastHorizon() throws {
        let now = Date()
        guard now.timeIntervalSince(detailsForgottenAt) >= 6 * 3_600 else { return }
        _ = try database().write { db in
            try db.execute(sql: """
                DELETE FROM detail WHERE at < ? AND NOT (source = ? AND kind IN (?, ?, ?, ?, ?, ?))
                """, arguments: [now.addingTimeInterval(-Self.detailHorizon).timeIntervalSince1970,
                                 Attention.detailSource, Attention.weighKind, Attention.igniteKind, Attention.restoreKind,
                                 Attention.batchKind, Attention.batchEndKind, Attention.nightKind])
        }
        detailsForgottenAt = now
    }

    static let detailSchema = """
        CREATE TABLE IF NOT EXISTS detail (seq INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, at REAL NOT NULL,
                                           subject TEXT NOT NULL, kind TEXT NOT NULL, row TEXT NOT NULL, once TEXT);
        CREATE INDEX IF NOT EXISTS detail_source_at ON detail(source, at);
        CREATE INDEX IF NOT EXISTS detail_subject ON detail(subject, seq);
        CREATE INDEX IF NOT EXISTS detail_kind_at ON detail(kind, at);
        CREATE INDEX IF NOT EXISTS detail_kind_seq ON detail(kind, seq);
        CREATE INDEX IF NOT EXISTS detail_at ON detail(at);
        CREATE UNIQUE INDEX IF NOT EXISTS detail_once ON detail(once) WHERE once IS NOT NULL;
        CREATE INDEX IF NOT EXISTS experience_kind_at ON experience(kind, at);
        """
}
