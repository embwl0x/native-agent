import Foundation
import PersistenceCore

public struct ShelfStore: Sendable {
    public static let maximumPageSize = 100
    private let disk: StandingBotsDisk
    public init(dataRoot: URL) { disk = StandingBotsDisk(dataRoot: dataRoot) }

    /// Logical append-only history. One indexed file per entry bounds append IO.
    /// A global append sequence (not run time) means late/backdated runs remain pageable.
    public func append(_ entry: ShelfEntry) throws {
        try disk.locked {
            let definition = try disk.definition(entry.botId)
            guard definition.audit.contains(where: { $0.definition.briefVersion == entry.briefVersion }) else {
                throw StandingBotsError.invalidValue("unknown brief version")
            }
            try validate(entry)
            var index = try loadIndex()
            guard try disk.bytes(at: indexedPath(entry.id)) == nil else {
                throw StandingBotsError.alreadyExists(entry.id)
            }
            let last = index.sequence
            guard last < UInt64.max else { throw StandingBotsError.invalidValue("sequence overflow") }
            let book = Book(sequence: last + 1, entry: entry)
            try disk.write(book, at: pendingPath)
            try apply(book, index: &index)
        }
    }

    /// Finalize only this run's provisional receipt, preserving append order.
    /// Sample after all run IO and lock acquisition; only receipt persistence
    /// itself follows the sample. A crash leaves an honest partial receipt.
    func finish(_ id: UUID, receipt: () -> ShelfEntry) throws -> ShelfEntry {
        try disk.locked {
            var index = try loadIndex()
            guard let book = try disk.read(Book.self, at: indexedPath(id)),
                  book.entry.uncertainties.contains("Run receipt pending finalization.") else {
                throw StandingBotsError.invalidValue("run receipt already finalized")
            }
            let final = receipt()
            guard final.id == id, final.botId == book.entry.botId else {
                throw StandingBotsError.invalidValue("final receipt identity")
            }
            let completed = Book(sequence: book.sequence, entry: final)
            try disk.write(completed, at: pendingPath)
            try apply(completed, index: &index)
            return final
        }
    }

    public func entry(_ id: UUID) throws -> ShelfEntry {
        try disk.locked {
            _ = try loadIndex()
            guard let book = try disk.read(Book.self, at: indexedPath(id)) else { throw StandingBotsError.notFound(id) }
            try validate(book.entry)
            return book.entry
        }
    }

    /// Last successful append, including a successful check that found nothing new.
    public func lastGood(bot: UUID) throws -> ShelfEntry? {
        try disk.locked {
            let index = try loadIndex()
            guard let id = index.lastGood[bot] else { return nil }
            guard let book = try disk.read(Book.self, at: indexedPath(id)), book.entry.botId == bot,
                  [.ok, .nothingNew].contains(book.entry.runHealth) else {
                throw StandingBotsError.corruptStore("last-good index")
            }
            try validate(book.entry)
            return book.entry
        }
    }

    /// Ascending append order. `since` is an exclusive run-time filter; `topic` is a literal,
    /// case-insensitive search of headline/findings/change/uncertainties. Cursors are query-bound.
    /// `readerId` selects unread entries for that reader only (e.g. "agent" vs "ui:user").
    /// Reads never acknowledge entries. Start with nil cursor to revisit unread holes or refresh.
    public func shelfRead(bot: UUID? = nil, since: Date? = nil, topic: String? = nil,
                          limit: Int = 20, cursor: String? = nil, readerId: String? = nil) throws -> ShelfReadPage {
        guard (1...Self.maximumPageSize).contains(limit) else { throw StandingBotsError.invalidValue("limit must be 1...100") }
        if let since, !since.timeIntervalSince1970.isFinite { throw StandingBotsError.invalidValue("since") }
        if let readerId { try validateReader(readerId) }
        let query = Query(bot: bot, since: since, topic: topic?.trimmingCharacters(in: .whitespacesAndNewlines), readerId: readerId)
        let after: UInt64
        if let cursor {
            guard let bytes = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode(PageCursor.self, from: bytes),
                  decoded.version == 1, decoded.query == query else { throw StandingBotsError.invalidCursor }
            after = decoded.after
        } else { after = 0 }
        return try disk.locked {
            let seen = try readerId.map { try readerState($0).readEntryIds } ?? []
            // Read one lookahead row; only returned rows can move the continuation boundary.
            let selected = try books().lazy.filter { book in
                let entry = book.entry
                return book.sequence > after && !seen.contains(entry.id)
                    && (bot == nil || entry.botId == bot)
                    && (since == nil || entry.runAt > since!)
                    && matches(entry, topic: query.topic)
            }.prefix(limit + 1)
            let candidates = Array(selected)
            let page = Array(candidates.prefix(limit))
            let rows = page.map { book in
                let entry = book.entry
                return ShelfIndexRow(id: entry.id, botId: entry.botId, briefVersion: entry.briefVersion,
                                     runAt: entry.runAt, coverageStart: entry.coverageStart, coverageEnd: entry.coverageEnd,
                                     headline: String(entry.headline.prefix(240)), headlineTruncated: entry.headline.count > 240,
                                     runHealth: entry.runHealth)
            }
            let hasMore = candidates.count > limit
            let next = try page.last.map { try disk.encode(PageCursor(version: 1, query: query, after: $0.sequence)).base64EncodedString() }
            // Even a terminal nonempty page has a continuation for later appends.
            return ShelfReadPage(rows: rows, nextCursor: next ?? cursor,
                                 truncated: hasMore || rows.contains(where: \.headlineTruncated))
        }
    }

    public func readCursor(readerId: String) throws -> ShelfReaderCursor {
        try validateReader(readerId)
        return try disk.locked { try readerState(readerId) }
    }

    /// Acknowledge exactly the IDs actually consumed, never a high-water mark or an entire page token.
    /// Repeated acknowledgement is idempotent; unknown IDs reject the whole transaction.
    public func acknowledge(readerId: String, entryIds: [UUID]) throws {
        try validateReader(readerId)
        try disk.locked {
            let known = Set(try books().map { $0.entry.id })
            if let unknown = entryIds.first(where: { !known.contains($0) }) { throw StandingBotsError.notFound(unknown) }
            var readers = try disk.read([String: ShelfReaderCursor].self, at: cursorsPath) ?? [:]
            try validateReaders(readers)
            var state = readers[readerId] ?? ShelfReaderCursor(readerId: readerId, readEntryIds: [])
            state.readEntryIds.formUnion(entryIds)
            readers[readerId] = state
            try disk.write(readers, at: cursorsPath)
        }
    }

    private var cursorsPath: URL { disk.root.appendingPathComponent("cursors.json") }

    private func readerState(_ readerId: String) throws -> ShelfReaderCursor {
        let readers = try disk.read([String: ShelfReaderCursor].self, at: cursorsPath) ?? [:]
        try validateReaders(readers)
        return readers[readerId] ?? ShelfReaderCursor(readerId: readerId, readEntryIds: [])
    }

    private func validateReaders(_ readers: [String: ShelfReaderCursor]) throws {
        for (key, value) in readers {
            try validateReader(key)
            guard key == value.readerId else { throw StandingBotsError.corruptStore("reader ID mismatch") }
        }
    }

    private func validateReader(_ readerId: String) throws {
        guard !readerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, readerId.utf8.count <= 256 else {
            throw StandingBotsError.invalidValue("readerId")
        }
    }

    private func matches(_ entry: ShelfEntry, topic: String?) -> Bool {
        guard let topic, !topic.isEmpty else { return true }
        return ([entry.headline, entry.findings, entry.changedSinceLastGood] + entry.uncertainties)
            .contains { $0.range(of: topic, options: [.caseInsensitive]) != nil }
    }

    private func bookPath(_ entry: ShelfEntry) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return disk.root.appendingPathComponent("shelf").appendingPathComponent(entry.botId.uuidString)
            .appendingPathComponent(formatter.string(from: entry.runAt) + ".jsonl")
    }

    private struct Index: Codable {
        var sequence: UInt64 = 0
        var lastGood: [UUID: UUID] = [:]
        var lastEntry: UUID? = nil
    }
    private var indexPath: URL { disk.root.appendingPathComponent("shelf-index.json") }
    private var pendingPath: URL { disk.root.appendingPathComponent("shelf-pending.json") }
    private var indexedDirectory: URL { disk.root.appendingPathComponent("shelf-entries") }
    private func indexedPath(_ id: UUID) -> URL { indexedDirectory.appendingPathComponent(id.uuidString + ".json") }

    // One-time checked migration preserves legacy daily books byte-for-byte.
    // A pending append is replayed under the store lock before any reader sees it.
    private func loadIndex() throws -> Index {
        var index: Index
        if let saved = try disk.read(Index.self, at: indexPath) { index = saved }
        else {
            index = Index()
            for book in try legacyBooks() {
                try disk.write(book, at: indexedPath(book.entry.id))
                index.sequence = book.sequence
                index.lastEntry = book.entry.id
                if [.ok, .nothingNew].contains(book.entry.runHealth) { index.lastGood[book.entry.botId] = book.entry.id }
            }
            try disk.write(index, at: indexPath)
        }
        if let pending = try disk.read(Book.self, at: pendingPath) {
            guard pending.sequence <= index.sequence || (index.sequence < UInt64.max && pending.sequence == index.sequence + 1) else {
                throw StandingBotsError.corruptStore("pending shelf sequence")
            }
            try apply(pending, index: &index)
        }
        if let id = index.lastEntry {
            guard let last = try disk.read(Book.self, at: indexedPath(id)),
                  last.entry.id == id, last.sequence == index.sequence else {
                throw StandingBotsError.corruptStore("latest shelf entry")
            }
            try validate(last.entry)
        }
        return index
    }

    private func apply(_ book: Book, index: inout Index) throws {
        try validate(book.entry)
        try disk.write(book, at: indexedPath(book.entry.id))
        if book.sequence >= index.sequence { index.sequence = book.sequence; index.lastEntry = book.entry.id }
        if [.ok, .nothingNew].contains(book.entry.runHealth) {
            let previous = try index.lastGood[book.entry.botId].flatMap { try disk.read(Book.self, at: indexedPath($0)) }
            if previous == nil || previous!.sequence <= book.sequence { index.lastGood[book.entry.botId] = book.entry.id }
        }
        try disk.write(index, at: indexPath)
        try disk.validatePath(pendingPath)
        try FileManager.default.removeItem(at: pendingPath)
    }

    private func books() throws -> [Book] {
        let index = try loadIndex()
        var sequences = Set<UInt64>()
        return try disk.files(at: indexedDirectory, extension: "json").map { path in
            guard let book = try disk.read(Book.self, at: path),
                  indexedPath(book.entry.id).standardizedFileURL.path == path.standardizedFileURL.path,
                  book.sequence > 0, book.sequence <= index.sequence, sequences.insert(book.sequence).inserted else {
                throw StandingBotsError.corruptStore("indexed book identity/sequence mismatch")
            }
            try validate(book.entry)
            return book
        }.sorted { $0.sequence < $1.sequence }
    }

    private func legacyBooks() throws -> [Book] {
        let directory = disk.root.appendingPathComponent("shelf")
        let children = try disk.files(at: directory, extension: "")
        var result: [Book] = []
        var ids = Set<UUID>()
        var sequences = Set<UInt64>()
        for child in children {
            guard let botId = UUID(uuidString: child.lastPathComponent) else {
                throw StandingBotsError.corruptStore("invalid shelf directory")
            }
            for path in try disk.files(at: child, extension: "jsonl") {
                guard let bytes = try disk.bytes(at: path) else { throw StandingBotsError.corruptStore("missing book file") }
                guard bytes.isEmpty || bytes.last == 0x0A else { throw StandingBotsError.corruptStore("incomplete book line") }
                for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                    let book = try JSONDecoder().decode(Book.self, from: Data(line))
                    try validate(book.entry)
                    // Directory enumeration may return a URL relative to its directory;
                    // compare normalized filesystem paths, not URL base representations.
                    guard book.entry.botId == botId,
                          bookPath(book.entry).standardizedFileURL.path == path.standardizedFileURL.path,
                          book.sequence > 0, ids.insert(book.entry.id).inserted,
                          sequences.insert(book.sequence).inserted else { throw StandingBotsError.corruptStore("book identity/sequence mismatch") }
                    result.append(book)
                }
            }
        }
        return result.sorted { $0.sequence < $1.sequence }
    }

    private func validate(_ entry: ShelfEntry) throws {
        let dates = [entry.runAt, entry.coverageStart, entry.coverageEnd] + entry.sourceLinks.map(\.datedAt)
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }), entry.coverageStart <= entry.coverageEnd,
              entry.briefVersion > 0, !entry.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.spend.tokens >= 0, entry.spend.seconds.isFinite, entry.spend.seconds >= 0 else {
            throw StandingBotsError.invalidValue("book")
        }
    }
}

private struct Book: Codable {
    let sequence: UInt64
    let entry: ShelfEntry
}

private struct Query: Codable, Equatable {
    let bot: UUID?
    let since: Date?
    let topic: String?
    let readerId: String?
}

private struct PageCursor: Codable {
    let version: Int
    let query: Query
    let after: UInt64
}
