import SwiftUI

// Third pass (the conversation itself), item 2. A Markdown table used to land
// in the transcript as pipes and dashes: the rich-content model knows prose and
// fenced code only, and the prose path falls through to inline text. The
// comparison a question deserves therefore had to be read as source.
//
// PURE PROJECTION, like `ChatRichContentParser`: segmenting is a total function
// of the prose string — no clock, no state, no side effects — and it is cached
// per distinct string, so a settled bubble parses once.
//
// STREAMING NEVER GETS HERE. The in-flight bubble renders raw text; a half
// arrived table therefore stays readable as text and only becomes a table once
// its header AND separator row exist (which is also the rule below, so a
// re-render mid-stream would not flicker a one-column table into view).

struct ChatMarkdownTable: Equatable {
    enum Align: Equatable { case leading, center, trailing }

    var header: [String]
    var aligns: [Align]
    var rows: [[String]]

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    func align(_ column: Int) -> Align {
        column < aligns.count ? aligns[column] : .leading
    }

    func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }
}

enum ChatProseSegment: Equatable {
    case text(String)
    case table(ChatMarkdownTable)
}

enum ChatMarkdownTableParser {
    private static let cache = ChatContentCache<[ChatProseSegment]>()

    /// Split prose into plain text and table segments.
    static func segments(_ text: String) -> [ChatProseSegment] {
        // Fast path: no pipe, no table. Costs one substring scan and allocates
        // nothing beyond the wrapper — the overwhelmingly common bubble.
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
                // A separator that does not describe the header is not a table.
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

    /// Cells of one row: outer pipes dropped, `\|` kept as a literal pipe.
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

    /// `|---|:--:|---:|` → per-column alignment; nil when the line is not a
    /// separator row at all.
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

/// A rendered Markdown table: aligned columns, wrapping cells, inline Markdown
/// (links included, through the same sanitized cache as prose).
///
/// `Grid` sizes columns from their content, so a narrow column stays narrow and
/// a prose-heavy one wraps instead of forcing a horizontal scroller inside the
/// transcript's own scroll view.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable

    var body: some View {
        let columns = Array(0..<table.columnCount)
        Grid(alignment: .topLeading, horizontalSpacing: NativeAgentSpacing.sm, verticalSpacing: 0) {
            GridRow {
                ForEach(columns, id: \.self) { column in
                    cellText(table.cell(table.header, column), column: column)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.vertical, NativeAgentSpacing.xs)
                }
            }
            Divider().opacity(0.4).gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        cellText(table.cell(table.rows[row], column), column: column)
                            .padding(.vertical, NativeAgentSpacing.xs)
                    }
                }
                if row < table.rows.count - 1 {
                    Divider().opacity(0.15).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, NativeAgentSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cellText(_ text: String, column: Int) -> some View {
        let aligned: Alignment = switch table.align(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        Group {
            if let attributed = ChatMarkdownCache.attributed(text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .multilineTextAlignment(table.align(column) == .trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: aligned)
        .gridColumnAlignment(table.align(column) == .trailing ? .trailing : .leading)
    }
}
