import Foundation

// Blueprint: | `ChatMarkdownTable.swift` | `ChatMarkdownTableParser`: pure prose segmentation and alignment/cell parsing of transcript tables |

// Require both header and separator before a table so partial input cannot flicker into columns.

public struct ChatMarkdownTable: Equatable, Sendable, Codable {
    public enum Align: Equatable, Sendable, Codable { case leading, center, trailing }

    public var header: [String]
    public var aligns: [Align]
    public var rows: [[String]]

    public init(header: [String], aligns: [Align], rows: [[String]]) {
        self.header = header
        self.aligns = aligns
        self.rows = rows
    }

    public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    public func align(_ column: Int) -> Align {
        aligns.indices.contains(column) ? aligns[column] : .leading
    }

    public func cell(_ row: [String], _ column: Int) -> String {
        row.indices.contains(column) ? row[column] : ""
    }
}

public enum ChatProseSegment: Equatable, Sendable {
    case text(String)
    case table(ChatMarkdownTable)
}

public enum ChatMarkdownTableParser {
    private static let cache = ChatContentCache<[ChatProseSegment]>()

    public static func segments(_ text: String) -> [ChatProseSegment] {
        guard text.contains("|") else { return [.text(text)] }
        if let hit = cache.lookup(text) { return hit }

        let lines = text.components(separatedBy: "\n")
        var out: [ChatProseSegment] = []
        var pending: [String] = []
        var index = 0

        func flushText() {
            guard !pending.isEmpty else { return }
            let joined = pending.joined(separator: "\n")
            pending.removeAll()
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out.append(.text(joined))
        }

        while index < lines.count {
            let line = lines[index]
            if line.contains("|"), index + 1 < lines.count,
               let aligns = separatorAligns(lines[index + 1]) {
                let header = cells(line)
                if !header.isEmpty, aligns.count == header.count {
                    var body: [[String]] = []
                    var cursor = index + 2
                    while cursor < lines.count, lines[cursor].contains("|"),
                          separatorAligns(lines[cursor]) == nil {
                        body.append(cells(lines[cursor]))
                        cursor += 1
                    }
                    flushText()
                    out.append(.table(ChatMarkdownTable(
                        header: header, aligns: aligns, rows: body
                    )))
                    index = cursor
                    continue
                }
            }
            pending.append(line)
            index += 1
        }
        flushText()

        let result = out.isEmpty ? [.text(text)] : out
        cache.insertIfAbsent(result, for: text)
        return result
    }

    /// Keep escaped pipes as literal cell content.
    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Return nil unless the row proves valid column separators and alignment.
    private static func separatorAligns(_ line: String) -> [ChatMarkdownTable.Align]? {
        guard line.contains("-"), line.contains("|") else { return nil }
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var aligns: [ChatMarkdownTable.Align] = []
        for part in parts {
            var body = part
            let left = body.hasPrefix(":")
            let right = body.hasSuffix(":")
            if left { body.removeFirst() }
            if right, !body.isEmpty { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            aligns.append(left && right ? .center : (right ? .trailing : .leading))
        }
        return aligns
    }
}
