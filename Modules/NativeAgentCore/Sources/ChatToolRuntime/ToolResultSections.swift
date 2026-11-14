import Foundation
import PersistenceCore
// Blueprint: | `ToolResultSections.swift` | `ToolResultSections`, `pages`; lossless paging; small fields before bulk; long strings in ordered pieces |

/// Complete values, lines and ordered pieces of long strings for reading; the retained byte stream remains available separately for exact reconstruction.
package enum ToolResultSections {
    /// Three full pages join in one answer under `ProviderToolResultPage.defaultMaxUTF8Bytes`, with its envelope.
    package static let pageBudget = 12_000
    /// The largest single value a page shows whole. It is not tied to the page size: a long line takes a page of its own, and a
    /// string past this is read in ordered pieces.
    package static let largestValue = 24_000

    package static func projection(content: String, value: JSONValue?, budget: Int) throws -> [(value: JSONValue, text: String, bytes: Int)] {
        var sections: [(value: JSONValue, text: String, bytes: Int)] = []
        func append(_ value: JSONValue, path: [JSONValue], line: Int? = nil) throws {
            let encoded = try value.serialize(pretty: false)
            // A large structured section has named children. Page those children instead of making the reader reconstruct raw JSON.
            if (value.objectValue != nil || value.arrayValue != nil),
               encoded.utf8.count > max(budget, largestValue) - 1_024 {
                try visit(value, path: path)
                return
            }
            // A long string is read as ordered pieces at its own path, cut between scalars at their serialized cost, so they join back to it exactly.
            if case .string(let text) = value, encoded.utf8.count > max(budget, largestValue) - 1_024 {
                var piece = "", bytes = 2
                for scalar in text.unicodeScalars {
                    let cost = ProviderToolResultRecoveryStore.jsonEscapedByteCount(scalar.value)
                    if bytes + cost > budget - 1_024, !piece.isEmpty {
                        try append(.string(piece), path: path, line: line)
                        piece = ""; bytes = 2
                    }
                    piece.unicodeScalars.append(scalar)
                    bytes += cost
                }
                try append(.string(piece), path: path, line: line)
                return
            }
            var row: [String: JSONValue] = ["path": .array(path), "value": value]
            if let line { row["line"] = .int(Int64(line)) }
            // Paths are source content too: a large key can outweigh its value. Keep the exact location in raw recovery rather than exceed the page.
            var rowBytes = try JSONValue.object(row).serialize(pretty: false).utf8.count
            if rowBytes > max(budget, largestValue) - 2 {
                row = [
                    "raw_byte_start": .int(0),
                    "raw_byte_end": .int(Int64(content.utf8.count)),
                    "detail": .string("""
                        This section and its location are too large for one page. Read the original with raw=true and follow next_page; nothing \
                        was discarded.
                        """),
                ]
                rowBytes = try JSONValue.object(row).serialize(pretty: false).utf8.count
            }
            // Match actual Unicode words, not the transport's ASCII escapes.
            let searchable: String
            if case .string(let text) = value { searchable = text }
            else { searchable = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            sections.append((.object(row), searchable, rowBytes + 1))
        }
        func visit(_ value: JSONValue, path: [JSONValue]) throws {
            switch value {
            case .string(let text):
                // Keep record separators, so joining restores the source text.
                var start = text.startIndex
                var line = 1
                while let range = text.rangeOfCharacter(from: .newlines, range: start..<text.endIndex) {
                    let end = text[range] == "\r" && range.upperBound < text.endIndex && text[range.upperBound] == "\n"
                        ? text.index(after: range.upperBound) : range.upperBound
                    try append(.string(String(text[start..<end])), path: path, line: line)
                    line += 1
                    start = end
                }
                if start < text.endIndex || line == 1 {
                    try append(.string(String(text[start...])), path: path, line: line)
                }
            case .array(let values):
                if values.isEmpty { try append(value, path: path) }
                for (index, item) in values.enumerated() {
                    let itemPath = path + [.int(Int64(index))]
                    try append(item, path: itemPath)
                }
            case .object(let fields):
                if fields.isEmpty { try append(value, path: path) }
                // Small fields lead, so a source's own state and continuation precede its bulk instead of trailing it as if they were content;
                // then search ranking, verdict fields, and the shortest remaining fields keep other bulk off the first page.
                let priority = ["results", "hits", "matches", "text", "content",
                                "status", "reason", "error", "detail", "message", "result"]
                let rank = Dictionary(uniqueKeysWithValues: try fields.map { key, value in
                    let bytes = try value.serialize(pretty: false).utf8.count
                    return (key, bytes <= 1_024 ? (0, bytes) : priority.firstIndex(of: key).map { (1, $0) } ?? (2, bytes))
                })
                let keys = fields.keys.sorted { rank[$0]! == rank[$1]! ? $0 < $1 : rank[$0]! < rank[$1]! }
                for key in keys { try visit(fields[key]!, path: path + [.string(key)]) }
            default: try append(value, path: path)
            }
        }
        try visit(value ?? .string(content), path: [])
        return sections
    }

    /// A query's terms are its whitespace-separated words. A query with none reads every section whole.
    package static func queryTerms(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// The most a match's own text costs serialized: a line within it is shown whole, a longer one as a window of it around the match.
    static let matchWindow = 400
    /// The most each adjacent line costs serialized; the part nearest the match is kept.
    static let contextWindow = 200
    /// The reader adds raw_first_page and raw_last_page to a raw-bytes pointer after paging; two such fields fit in this.
    static let pointerFields = 96

    /// A reading without query: every section whole in order, so the pages join back to the result exactly.
    package static func pages(sections projection: [(value: JSONValue, text: String, bytes: Int)], budget: Int) -> [[JSONValue]] {
        var pages: [[JSONValue]] = [[]]
        var bytes = 2
        for section in projection {
            if bytes + section.bytes > budget, !pages[pages.count - 1].isEmpty {
                pages.append([]); bytes = 2
            }
            pages[pages.count - 1].append(section.value)
            bytes += section.bytes
        }
        return pages
    }

    /// A search inside a kept result returns where its terms are, not everything around them. It reads sections in order only as far as
    /// the page asked for, and stops once that page is full; a line gives at most one row, its first match, and the rest of the line is
    /// passed by its location alone. So the work of one read follows the bytes it reads, never matches times pieces.
    ///
    /// A section matches when it holds every term (the AND rule), where a term cut by the seam between two pieces of one long string
    /// counts in both. Its row: `path`; `line`, 1-based within the string at that path, where the section is a line; `offset`, in Unicode
    /// scalars from the start of the line (or of the value, where it has no lines) to where `text` starts, unless `text` is the whole
    /// line; `text`, the line, or a window of it around the match cut between scalars; `before` and `after`, the adjacent lines, each cut
    /// to the part nearest the match; and `section_page`, the page of a reading without query that shows the whole section.
    package struct Search: Sendable {
        package typealias Section = (value: JSONValue, text: String, bytes: Int)
        package let query: String
        private let terms: [String]
        private let budget: Int
        /// Pages found so far; the last may still be filling.
        package private(set) var pages: [[JSONValue]] = [[]]
        /// How many sections the search has read, and whether it has read them all.
        package private(set) var searched = 0
        package private(set) var complete = false
        private var bytes = 2
        private var lastRow: JSONValue?
        // The packing of a reading without query, followed section by section as the search passes them.
        private var wholePage = 0, wholeBytes = 2, wholeHeld = 0

        package init(query: String, budget: Int) {
            self.query = query
            self.terms = ToolResultSections.queryTerms(query)
            self.budget = budget
        }

        /// Read on until `page` is closed by a row on the page after it, or the sections end.
        package mutating func fill(through page: Int, _ projection: [Section]) {
            while !complete, pages.count - 1 <= page { step(projection) }
        }

        /// Read one unit: the pieces of one string that share its path and line (one line, or one string where it has no lines).
        private mutating func step(_ projection: [Section]) {
            guard searched < projection.count else { complete = true; return }
            let start = searched
            var end = start + 1
            while end < projection.count, ToolResultSections.continues(end, projection) { end += 1 }
            searched = end
            var whole: [Int] = []
            for index in start..<end {
                if wholeBytes + projection[index].bytes > budget, wholeHeld > 0 { wholePage += 1; wholeBytes = 2; wholeHeld = 0 }
                whole.append(wholePage)
                wholeBytes += projection[index].bytes; wholeHeld += 1
            }
            guard let row = ToolResultSections.firstMatch(in: start..<end, projection, terms: terms, sectionPages: whole, budget: budget),
                  row.value != lastRow else { return }
            lastRow = row.value
            if bytes + row.bytes > budget, !pages[pages.count - 1].isEmpty {
                pages.append([]); bytes = 2
            }
            pages[pages.count - 1].append(row.value)
            bytes += row.bytes
        }
    }

    /// Whether a section is the next piece of the string before it: both strings, at one path, with one line (or none).
    private static func continues(_ index: Int, _ projection: [Search.Section]) -> Bool {
        func field(_ index: Int, _ key: String) -> JSONValue? { projection[index].value.objectValue?[key] }
        guard index > 0, let path = field(index, "path"), path == field(index - 1, "path"),
              field(index, "value")?.stringValue != nil, field(index - 1, "value")?.stringValue != nil else { return false }
        return field(index, "line") == field(index - 1, "line")
    }

    /// The row for a unit's first matching piece, reading the pieces before it and at most the one after; none when no piece matches.
    private static func firstMatch(in unit: Range<Int>, _ projection: [Search.Section], terms: [String], sectionPages: [Int],
                                   budget: Int) -> (value: JSONValue, bytes: Int)? {
        func field(_ index: Int, _ key: String) -> JSONValue? { projection[index].value.objectValue?[key] }
        func seam(_ left: Int, _ term: String) -> Bool {
            guard left >= 0, left + 1 < projection.count, term.count > 1, let shared = field(left, "path"), shared == field(left + 1, "path")
            else { return false }
            let joined = String(projection[left].text.suffix(term.count - 1)) + String(projection[left + 1].text.prefix(term.count - 1))
            return joined.localizedCaseInsensitiveContains(term)
        }
        // Scalars of the unit before the piece being read, and of the piece before it.
        var lineOffset = 0, previous = 0
        for index in unit {
            let text = projection[index].text, count = text.unicodeScalars.count
            defer { previous = count; lineOffset += count }
            guard terms.allSatisfy({ text.localizedCaseInsensitiveContains($0) || seam(index - 1, $0) || seam(index, $0) }) else { continue }
            guard let path = field(index, "path") else {
                // A section too large to show with its location is already a pointer to the raw pages; it stays one.
                return (value: projection[index].value, bytes: size(projection[index].value.objectValue ?? [:], budget) + pointerFields)
            }
            let line = field(index, "line")
            // The piece with its neighbours in the unit: enough for a window on each side and for a term cut by either seam.
            let lower = index > unit.lowerBound ? index - 1 : index, upper = min(unit.upperBound - 1, index + 1)
            var scalars: [Unicode.Scalar] = []
            for piece in lower...upper { scalars.append(contentsOf: projection[piece].text.unicodeScalars) }
            // A line is shown without its own line break.
            if line != nil { while let end = scalars.last, CharacterSet.newlines.contains(end) { scalars.removeLast() } }
            let base = lineOffset - (lower < index ? previous : 0)
            let pieceStart = lower < index ? previous : 0
            let pieceEnd = pieceStart + count
            // Search from just before the piece, as far back as a seam-cut term can start, so only a few earlier matches are passed.
            let back = lower < index ? terms.map { projection[lower].text.suffix(max(0, $0.count - 1)).unicodeScalars.count }.max() ?? 0 : 0
            let from = min(pieceStart - back, scalars.count)
            guard let match = earliest(of: terms, in: scalars, from: from, overlapping: pieceStart..<pieceEnd) else { continue }
            let window = unit.count == 1 && cost(scalars[...]) <= matchWindow ? 0..<scalars.count : around(match, in: scalars)
            let piece = match.lowerBound < pieceStart ? lower : match.lowerBound >= pieceEnd ? upper : index
            var row: [String: JSONValue] = ["path": path, "text": .string(string(scalars[window])),
                                            "section_page": .int(Int64(sectionPages[piece - unit.lowerBound]))]
            if let line { row["line"] = line }
            if line == nil || window != 0..<scalars.count || unit.count > 1 { row["offset"] = .int(Int64(base + window.lowerBound)) }
            if case .int(let number)? = line {
                let before = unit.lowerBound - 1
                if before >= 0, field(before, "path") == path, field(before, "line") == .int(number - 1) {
                    // The previous line's last two pieces hold more than its tail shows, however short its last piece is.
                    let head = before > 0 && continues(before, projection) ? before - 1 : before
                    row["before"] = .string(edge(lines(head...before, projection), tail: true))
                }
                let after = unit.upperBound
                if after < projection.count, field(after, "path") == path, field(after, "line") == .int(number + 1) {
                    row["after"] = .string(edge(lines(after...after, projection), tail: false))
                }
            }
            // Every row fits a page: context goes first, then a path too large to show, which section_page still reaches.
            var bytes = size(row, budget)
            if bytes > budget - 2 {
                row["before"] = nil; row["after"] = nil
                bytes = size(row, budget)
            }
            if bytes > budget - 2 {
                row["path"] = nil
                row["detail"] = .string("This match's path is too large to show here; section_page reads its whole section.")
                bytes = size(row, budget)
            }
            return (value: .object(row), bytes: bytes)
        }
        return nil
    }

    /// The earliest match of any term that overlaps `piece`, searching from `from`; a term stops at its first such match, or past the piece.
    private static func earliest(of terms: [String], in scalars: [Unicode.Scalar], from: Int, overlapping piece: Range<Int>) -> Range<Int>? {
        let text = string(scalars[max(0, from)...])
        var best: Range<Int>?
        for term in terms {
            var cursor = text.startIndex, at = max(0, from)
            while cursor < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive, range: cursor..<text.endIndex, locale: .current),
                  !range.isEmpty {
                let lower = at + text.unicodeScalars.distance(from: cursor, to: range.lowerBound)
                if lower >= min(piece.upperBound, best?.lowerBound ?? piece.upperBound) { break }
                let upper = lower + text.unicodeScalars.distance(from: range.lowerBound, to: range.upperBound)
                if upper > piece.lowerBound { best = lower..<max(upper, lower + 1); break }
                // A match that ends before the piece: look again one character on, since matches may overlap.
                cursor = text.index(after: range.lowerBound)
                at = lower + text.unicodeScalars.distance(from: range.lowerBound, to: cursor)
            }
        }
        return best
    }

    /// The scalars of consecutive line pieces, without the line break.
    private static func lines(_ pieces: ClosedRange<Int>, _ projection: [Search.Section]) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        for piece in pieces { scalars.append(contentsOf: projection[piece].text.unicodeScalars) }
        while let end = scalars.last, CharacterSet.newlines.contains(end) { scalars.removeLast() }
        return scalars
    }

    private static func cost(_ scalar: Unicode.Scalar) -> Int { ProviderToolResultRecoveryStore.jsonEscapedByteCount(scalar.value) }

    private static func cost(_ scalars: ArraySlice<Unicode.Scalar>) -> Int { scalars.reduce(0) { $0 + cost($1) } }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// A page serializes as "[" rows joined by ", " "]": each row costs its own bytes and the two of the separator, so a page that starts
    /// at 2 and adds every row's cost never undercounts what it serializes to.
    private static func size(_ row: [String: JSONValue], _ budget: Int) -> Int {
        ((try? JSONValue.object(row).serialize(pretty: false))?.utf8.count ?? budget) + 2
    }

    /// The match first, then a scalar at a time on each side while the window's serialized cost allows.
    private static func around(_ match: Range<Int>, in scalars: [Unicode.Scalar]) -> Range<Int> {
        var lower = match.lowerBound, upper = match.lowerBound, spent = 0
        func take(_ index: Int) -> Bool {
            let next = spent + cost(scalars[index])
            guard next <= matchWindow else { return false }
            spent = next
            return true
        }
        while upper < min(match.upperBound, scalars.count), take(upper) { upper += 1 }
        var growing = true
        while growing {
            growing = false
            if lower > 0, take(lower - 1) { lower -= 1; growing = true }
            if upper < scalars.count, take(upper) { upper += 1; growing = true }
        }
        return lower..<upper
    }

    /// An adjacent line cut to the part nearest the match: its end before it, its start after it.
    private static func edge(_ scalars: [Unicode.Scalar], tail: Bool) -> String {
        var kept = 0, spent = 0
        while kept < scalars.count {
            let next = spent + cost(scalars[tail ? scalars.count - 1 - kept : kept])
            guard next <= contextWindow else { break }
            spent = next; kept += 1
        }
        return string(tail ? scalars.suffix(kept) : scalars.prefix(kept))
    }
}
