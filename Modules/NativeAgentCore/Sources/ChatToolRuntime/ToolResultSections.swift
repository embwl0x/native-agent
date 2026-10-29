import Foundation
import PersistenceCore
// Blueprint: | `ToolResultSections.swift` | `ToolResultSections` enum; `pages`; complete line/value records, search records first and then shortest fields first (a result's verdict before its bulk), source-order query selection, oversized structured records expand by child path; raw references remain for oversized atoms |

/// Complete values and lines for reading; the retained byte stream remains
/// available separately for exact reconstruction, including unusually large atoms.
package enum ToolResultSections {
    package static let pageBudget = 24_000

    package static func projection(content: String, value: JSONValue?, budget: Int) -> [(value: JSONValue, text: String, bytes: Int)] {
        var sections: [(value: JSONValue, text: String, bytes: Int)] = []
        func append(_ value: JSONValue, path: [JSONValue], line: Int? = nil) {
            let encoded = (try? value.serialize(pretty: false)) ?? ""
            // A large structured section has named children. Page those
            // children instead of making the reader reconstruct raw JSON.
            if (value.objectValue != nil || value.arrayValue != nil),
               encoded.utf8.count > budget - 1_024 {
                visit(value, path: path)
                return
            }
            var row: [String: JSONValue] = ["path": .array(path), "value": value]
            if let line { row["line"] = .int(Int64(line)) }
            if encoded.utf8.count > budget - 1_024 {
                row.removeValue(forKey: "value")
                row["omitted_bytes"] = .int(Int64(encoded.utf8.count))
                row["detail"] = .string("This single value is too large for one page. Read the original with raw=true and follow next_page; no part of it was discarded.")
                var range = content.range(of: encoded)
                if range == nil, case .string(let text) = value {
                    range = content.range(of: String(encoded.dropFirst().dropLast())) ?? content.range(of: text)
                }
                if let range {
                    row["raw_byte_start"] = .int(Int64(content[..<range.lowerBound].utf8.count))
                    row["raw_byte_end"] = .int(Int64(content[..<range.upperBound].utf8.count))
                }
            }
            // Paths are source content too: a large key can outweigh its value.
            // Keep the exact location in raw recovery rather than exceed the page.
            var rowBytes = (try? JSONValue.object(row).serialize(pretty: false))?.utf8.count ?? 0
            if rowBytes > budget - 2 {
                row = [
                    "raw_byte_start": .int(0),
                    "raw_byte_end": .int(Int64(content.utf8.count)),
                    "detail": .string("This section and its location are too large for one page. Read the original with raw=true and follow next_page; nothing was discarded."),
                ]
                rowBytes = (try? JSONValue.object(row).serialize(pretty: false))?.utf8.count ?? 0
            }
            // Match actual Unicode words, not the transport's ASCII escapes.
            let searchable: String
            if case .string(let text) = value { searchable = text }
            else if let data = try? JSONEncoder().encode(value) {
                searchable = String(decoding: data, as: UTF8.self)
            } else { searchable = encoded }
            sections.append((.object(row), searchable, rowBytes + 1))
        }
        func visit(_ value: JSONValue, path: [JSONValue]) {
            switch value {
            case .string(let text):
                // Keep record separators, so joining restores the source text.
                var start = text.startIndex
                var line = 1
                while let range = text.rangeOfCharacter(from: .newlines, range: start..<text.endIndex) {
                    let end = text[range] == "\r" && range.upperBound < text.endIndex && text[range.upperBound] == "\n"
                        ? text.index(after: range.upperBound) : range.upperBound
                    append(.string(String(text[start..<end])), path: path, line: line)
                    line += 1
                    start = end
                }
                if start < text.endIndex || line == 1 {
                    append(.string(String(text[start...])), path: path, line: line)
                }
            case .array(let values):
                if values.isEmpty { append(value, path: path) }
                for (index, item) in values.enumerated() {
                    let itemPath = path + [.int(Int64(index))]
                    append(item, path: itemPath)
                }
            case .object(let fields):
                if fields.isEmpty { append(value, path: path) }
                // Search records precede metadata; their source ranking is preserved.
                // Then what happened (status, reason, error, its result), before
                // any echo of what was asked; the rest go shortest first, so the
                // first page says what the result is before the bulk it carries.
                let priority = ["results", "hits", "matches", "text", "content",
                                "status", "reason", "error", "detail", "message", "result"]
                let rank = Dictionary(uniqueKeysWithValues: fields.map { key, value in
                    (key, priority.firstIndex(of: key).map { ($0, 0) }
                        ?? (priority.count, (try? value.serialize(pretty: false))?.utf8.count ?? 0))
                })
                let keys = fields.keys.sorted { rank[$0]! == rank[$1]! ? $0 < $1 : rank[$0]! < rank[$1]! }
                for key in keys { visit(fields[key]!, path: path + [.string(key)]) }
            default: append(value, path: path)
            }
        }
        visit(value ?? .string(content), path: [])
        return sections
    }

    package static func pages(sections projection: [(value: JSONValue, text: String, bytes: Int)], query: String, budget: Int) -> [[JSONValue]] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var pages: [[JSONValue]] = [[]]
        var bytes = 2
        for section in projection where terms.allSatisfy({ section.text.localizedCaseInsensitiveContains($0) }) {
            if bytes + section.bytes > budget, !pages[pages.count - 1].isEmpty {
                pages.append([]); bytes = 2
            }
            pages[pages.count - 1].append(section.value)
            bytes += section.bytes
        }
        return pages
    }
}
