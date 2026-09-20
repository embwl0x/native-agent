import Foundation
import PersistenceCore

/// Complete values and paragraphs for reading; the retained byte stream remains
/// available separately for exact reconstruction, including unusually large atoms.
enum ToolResultSections {
    static let pageBudget = 24_000

    static func pages(content: String, query: String = "", budget: Int = pageBudget) -> [[JSONValue]] {
        var sections: [(value: JSONValue, text: String)] = []
        func append(_ value: JSONValue, path: [JSONValue], paragraph: Int? = nil, sentence: Int? = nil) {
            var row: [String: JSONValue] = ["path": .array(path), "value": value]
            if let paragraph { row["paragraph"] = .int(Int64(paragraph)) }
            if let sentence { row["sentence"] = .int(Int64(sentence)) }
            let encoded = (try? value.serialize(pretty: false)) ?? ""
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
            if ((try? JSONValue.object(row).serialize(pretty: false))?.utf8.count ?? 0) > budget - 2 {
                row = [
                    "raw_byte_start": .int(0),
                    "raw_byte_end": .int(Int64(content.utf8.count)),
                    "detail": .string("This section and its location are too large for one page. Read the original with raw=true and follow next_page; nothing was discarded."),
                ]
            }
            // Match actual Unicode words, not the transport's ASCII escapes.
            let searchable: String
            if case .string(let text) = value { searchable = text }
            else if !query.isEmpty, let data = try? JSONEncoder().encode(value) {
                searchable = String(decoding: data, as: UTF8.self)
            } else { searchable = encoded }
            sections.append((.object(row), searchable))
        }
        func appendParagraph(_ text: String, path: [JSONValue], paragraph: Int) {
            if ((try? JSONValue.string(text).serialize(pretty: false))?.utf8.count ?? 0) <= budget - 1_024 {
                append(.string(text), path: path, paragraph: paragraph)
                return
            }
            // Very long paragraphs can still be read as whole sentences.
            var sentence = 0
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, _, range, _ in
                append(.string(String(text[range])), path: path, paragraph: paragraph, sentence: sentence)
                sentence += 1
            }
            if sentence == 0 { append(.string(text), path: path, paragraph: paragraph) }
        }
        func visit(_ value: JSONValue, path: [JSONValue]) {
            switch value {
            case .string(let text):
                // Preserve separators in their paragraph, so joining restores text.
                var start = text.startIndex
                var paragraph = 0
                while let range = text.range(of: "\n\n", range: start..<text.endIndex) {
                    appendParagraph(String(text[start..<range.upperBound]), path: path, paragraph: paragraph)
                    paragraph += 1
                    start = range.upperBound
                }
                if start < text.endIndex || paragraph == 0 {
                    appendParagraph(String(text[start...]), path: path, paragraph: paragraph)
                }
            case .array(let values):
                if values.isEmpty { append(value, path: path) }
                for (index, item) in values.enumerated() {
                    let itemPath = path + [.int(Int64(index))]
                    if ((try? item.serialize(pretty: false))?.utf8.count ?? 0) <= budget - 1_024 {
                        append(item, path: itemPath)
                    } else { visit(item, path: itemPath) }
                }
            case .object(let fields):
                if fields.isEmpty { append(value, path: path) }
                // Search records precede metadata; their source ranking is preserved.
                let keys = fields.keys.sorted {
                    let priority = ["results", "hits", "matches", "text", "content"]
                    let lhs = priority.firstIndex(of: $0) ?? priority.count
                    let rhs = priority.firstIndex(of: $1) ?? priority.count
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
                for key in keys { visit(fields[key]!, path: path + [.string(key)]) }
            default: append(value, path: path)
            }
        }
        visit((try? JSONValue.parse(Data(content.utf8))) ?? .string(content), path: [])
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if !terms.isEmpty {
            let scores: [Int] = sections.map { section in
                terms.filter { section.text.localizedCaseInsensitiveContains($0) }.count
            }
            let order = sections.indices.sorted { left, right in
                scores[left] == scores[right] ? left < right : scores[left] > scores[right]
            }
            sections = order.map { sections[$0] }
        }
        var pages: [[JSONValue]] = [[]]
        var bytes = 2
        for section in sections {
            let size = ((try? section.value.serialize(pretty: false))?.utf8.count ?? 0) + 1
            if bytes + size > budget, !pages[pages.count - 1].isEmpty {
                pages.append([]); bytes = 2
            }
            pages[pages.count - 1].append(section.value)
            bytes += size
        }
        return pages
    }
}
