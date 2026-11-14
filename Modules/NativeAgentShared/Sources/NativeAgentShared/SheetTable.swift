import Foundation
// Blueprint: | `SheetTable.swift` | A table kept as a CSV or TSV file, read and written by the standard quoting rules |

/// A table kept as a CSV or TSV file: rows of fields. A field quoted with `"` may hold the delimiter, line breaks and doubled quotes; a line
/// break (LF, CRLF or CR) ends a row, and a final one adds no empty row. Each field keeps its text exactly as the file wrote it and each row
/// its own line break, so writing the table back changes only the fields that were set and the rows and columns that were added.
public struct SheetTable: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var value: String
        /// The field as the file wrote it, quotes included.
        public var raw: String
    }
    public struct Row: Sendable, Equatable {
        public var fields: [Field]
        /// The line break that ends the row as written; empty for a last row the file does not end with one.
        public var end: String
    }

    public var rows: [Row]
    public let delimiter: Unicode.Scalar
    /// The file's own line break (its first one; LF for a file with none), which ends a row that is added.
    public let lineEnd: String

    private static let delimiters: [String: Unicode.Scalar] = ["csv": ",", "tsv": "\t"]

    /// The field delimiter of a file type, or nil when the type is not a table file.
    public static func delimiter(type: String) -> Unicode.Scalar? { delimiters[type.lowercased()] }

    public init(_ text: String, delimiter: Unicode.Scalar) {
        var rows: [Row] = [], fields: [Field] = [], firstEnd: String?
        var value = String.UnicodeScalarView(), raw = String.UnicodeScalarView()
        // Inside a quoted field; a quote just read inside one (a second quote is a literal one, anything else closes the field's quotes);
        // a CR just read (an LF right after it belongs to the same line break).
        var quoted = false, quoteRead = false, pendingCR = false
        func endField() {
            fields.append(Field(value: String(value), raw: String(raw)))
            value = .init()
            raw = .init()
        }
        func endRow(_ end: String) {
            endField()
            rows.append(Row(fields: fields, end: end))
            fields = []
            if firstEnd == nil, !end.isEmpty { firstEnd = end }
        }
        for scalar in text.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" {
                    endRow("\r\n")
                    continue
                }
                endRow("\r")
            }
            if quoted {
                if !quoteRead {
                    raw.append(scalar)
                    if scalar == "\"" { quoteRead = true } else { value.append(scalar) }
                    continue
                }
                quoteRead = false
                if scalar == "\"" {
                    raw.append(scalar)
                    value.append(scalar)
                    continue
                }
                quoted = false
            }
            switch scalar {
            case "\"" where raw.isEmpty:
                quoted = true
                raw.append(scalar)
            case delimiter: endField()
            case "\n": endRow("\n")
            case "\r": pendingCR = true
            default:
                value.append(scalar)
                raw.append(scalar)
            }
        }
        if pendingCR { endRow("\r") } else if quoted || !raw.isEmpty || !fields.isEmpty { endRow("") }
        self.rows = rows
        self.delimiter = delimiter
        self.lineEnd = firstEnd ?? "\n"
    }

    /// The table as the file's text: every field and line break as written, except what was set or added.
    public var text: String {
        let separator = String(Character(delimiter))
        return rows.map { row in row.fields.map(\.raw).joined(separator: separator) + row.end }.joined()
    }

    public var width: Int { rows.map(\.fields.count).max() ?? 0 }

    /// One cell's new words, quoted only if they need it; a short row grows with empty fields to reach the cell.
    public mutating func set(row: Int, column: Int, to value: String) {
        guard rows.indices.contains(row), column >= 0 else { return }
        if rows[row].fields.count <= column {
            rows[row].fields += Array(repeating: Field(value: "", raw: ""), count: column + 1 - rows[row].fields.count)
        }
        // A row's only field, emptied, would leave nothing on its line, and a last line of nothing is no row: it is written as "".
        let needsQuotes = value.unicodeScalars.contains { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || value.isEmpty && rows[row].fields.count == 1
        rows[row].fields[column] = Field(value: value, raw: needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value)
    }

    /// An empty row as wide as the table, after a line break that the last row gains if the file did not end with one.
    public mutating func addRow() {
        if let last = rows.indices.last, rows[last].end.isEmpty { rows[last].end = lineEnd }
        rows.append(Row(fields: Array(repeating: Field(value: "", raw: ""), count: max(1, width)), end: lineEnd))
    }

    /// An empty column at the right: every row grows to the table's width plus one.
    public mutating func addColumn() {
        guard !rows.isEmpty else { return addRow() }
        let wide = width + 1
        for index in rows.indices {
            rows[index].fields += Array(repeating: Field(value: "", raw: ""), count: wide - rows[index].fields.count)
        }
    }
}
