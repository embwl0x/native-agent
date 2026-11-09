import Foundation

// Blueprint: | `TranscriptMarkdown.swift` | A message's markdown as document pieces (paragraphs, lists, headings, quotes, code, tables), stamped as blocks |

extension TranscriptDocument {
    /// Ids "<messageID>#<n>" in order; the first block takes `lead`, a list item after a list item leads as one, the rest as paragraphs.
    public static func stamp(_ pieces: [TranscriptPiece], messageID: String, role: String, lead: TranscriptBlock.Lead) -> [TranscriptBlock] {
        var out: [TranscriptBlock] = []
        out.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            let blockLead: TranscriptBlock.Lead = index == 0 ? lead
                : (piece.isListItem && pieces[index - 1].isListItem ? .listItem : .paragraph)
            out.append(TranscriptBlock(id: "\(messageID)#\(index)", messageID: messageID, role: role, kind: piece.kind,
                                       source: piece.source, lead: blockLead, foldGroup: nil))
        }
        return out
    }

    // MARK: Markdown

    /// Lines of one paragraph: "#"-"######" and a space make a heading, consecutive ">" lines one quote, the rest a reply paragraph.
    public static func linePieces(_ text: String, ink: TranscriptBlock.Ink) -> [TranscriptPiece] {
        var out: [TranscriptPiece] = []
        var plain: [Substring] = []
        var quote: [Substring] = []
        func flushPlain() {
            let body = plain.joined(separator: "\n")
            plain.removeAll()
            guard body.contains(where: { !$0.isWhitespace }) else { return }
            out.append(TranscriptPiece(kind: .reply(runs: inline(body), ink: ink), source: body))
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let body = quote.map { line -> Substring in
                let marked = line.drop { $0 == " " || $0 == "\t" }.dropFirst()
                return marked.first == " " ? marked.dropFirst() : marked
            }.joined(separator: "\n")
            out.append(TranscriptPiece(kind: .quote(runs: inline(body)), source: quote.joined(separator: "\n")))
            quote.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let heading = headingText(trimmed) {
                flushPlain()
                flushQuote()
                out.append(TranscriptPiece(kind: .heading(runs: inline(heading)), source: String(line)))
            } else if trimmed.first == ">" {
                flushPlain()
                quote.append(line)
            } else {
                flushQuote()
                plain.append(line)
            }
        }
        flushPlain()
        flushQuote()
        return out
    }

    public static func headingText(_ trimmed: Substring) -> String? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The person's bubble is one paragraph: the reply reading of their words, joined by blank lines (list rows by line breaks), with
    /// markers, quote marks and code kept as text so nothing leaves the bubble.
    public static func flattened(_ pieces: [TranscriptPiece]) -> [TranscriptRun] {
        var out: [TranscriptRun] = []
        for (index, piece) in pieces.enumerated() {
            let body: [TranscriptRun]
            switch piece.kind {
            case .reply(let runs, _): body = runs
            case .heading(let runs): body = runs.map { run in var bold = run; bold.bold = true; return bold }
            case .quote(let runs): body = [TranscriptRun(text: "> ")] + runs
            case .listItem(let marker, let depth, let runs): body = [TranscriptRun(text: String(repeating: " ", count: depth) + marker + " ")] + runs
            case .code(_, let text): body = [TranscriptRun(text: text, code: true)]
            default: body = [TranscriptRun(text: lineBreaks(piece.source))]
            }
            if index > 0 {
                let separator = piece.isListItem && pieces[index - 1].isListItem ? "\u{2028}" : "\u{2028}\u{2028}"
                append(TranscriptRun(text: separator), to: &out)
            }
            for run in body { append(run, to: &out) }
        }
        return out
    }

    /// Inline Markdown preserves whitespace and only http, https and mailto links; parse failures remain visible.
    public static func inline(_ text: String) -> [TranscriptRun] {
        guard !text.isEmpty else { return [] }
        if isPlain(text) { return [TranscriptRun(text: text)] }
        let outcome = ChatRichContentParser.inline(text)
        guard case .parsed(let styled) = outcome else { return [TranscriptRun(text: lineBreaks(String(outcome.presentation.characters)))] }
        var out: [TranscriptRun] = []
        for run in styled.runs {
            let intent = run.inlinePresentationIntent ?? []
            append(TranscriptRun(text: lineBreaks(String(styled[run.range].characters)), bold: intent.contains(.stronglyEmphasized),
                                 italic: intent.contains(.emphasized), code: intent.contains(.code),
                                 strike: intent.contains(.strikethrough), link: run.link), to: &out)
        }
        return out
    }

    /// Bytes that can start inline markdown (emphasis, code, links, autolinks, entities, escapes, strikethrough) or that the parser
    /// rewrites (line endings, tabs, NUL).
    private static let markdownBytes: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in Array("*_`[]<>\\&~:@!\n\r\t".utf8) + [0] { table[Int(byte)] = true }
        return table
    }()

    public static func isPlain(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last, !first.isWhitespace, !last.isWhitespace else { return false }
        return !text.utf8.contains { markdownBytes[Int($0)] } && !text.contains("www.")
    }

    /// Adjacent runs with the same styling join, so equal text always gives equal runs; empty runs drop.
    public static func append(_ run: TranscriptRun, to runs: inout [TranscriptRun]) {
        guard !run.text.isEmpty else { return }
        if let last = runs.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code, last.strike == run.strike,
           last.link == run.link {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    /// A block is one paragraph, so its line breaks are U+2028.
    public static func lineBreaks(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == 10 || $0 == 13 }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\u{2028}")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
            .replacingOccurrences(of: "\r", with: "\u{2028}")
    }

    public static func tableSource(_ table: ChatMarkdownTable) -> String {
        let rule = table.header.indices.map { column -> String in
            switch table.align(column) {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        return ([table.header, rule] + table.rows).map { cells in
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }.joined(separator: "\n")
    }
}

@available(macOS 15, iOS 18, *)
extension TranscriptDocument {
    /// Parse readable reply blocks; only the live edge closes unfinished Markdown.
    public static func replyPieces(_ text: String, ink: TranscriptBlock.Ink, edge: Bool) -> [TranscriptPiece] {
        let content = ChatRichContentParser.blocks(text)
        var out: [TranscriptPiece] = []
        for (blockIndex, block) in content.enumerated() {
            switch block {
            case .code(let language, let code):
                out.append(TranscriptPiece(kind: .code(language: language ?? "", text: lineBreaks(code)),
                                           source: "```" + (language ?? "") + "\n" + code + "\n```"))
            case .prose(let prose):
                let segments = ChatMarkdownTableParser.segments(prose)
                for (segmentIndex, segment) in segments.enumerated() {
                    switch segment {
                    case .table(let table):
                        out.append(TranscriptPiece(kind: .attachment(.table(table)), source: tableSource(table)))
                    case .text(let segmentText):
                        let atEdge = edge && blockIndex == content.count - 1 && segmentIndex == segments.count - 1
                        out += prosePieces(segmentText, ink: ink, edge: atEdge)
                    }
                }
            }
        }
        return out
    }

    /// Blank lines separate paragraphs; list markers preserve item order and indentation.
    public static func prosePieces(_ text: String, ink: TranscriptBlock.Ink, edge: Bool) -> [TranscriptPiece] {
        let paragraphs = StreamingParagraphText.paragraphs(Substring(text))
        var out: [TranscriptPiece] = []
        for (index, raw) in paragraphs.enumerated() {
            var paragraph = raw.trimmingCharacters(in: .newlines)
            if edge, index == paragraphs.count - 1 { paragraph = StreamingParagraphText.closingEdge(Substring(paragraph)) }
            guard paragraph.contains(where: { !$0.isWhitespace }) else { continue }
            let rows = ChatRichContentParser.listRows(paragraph)
            guard rows.contains(where: { $0.marker != nil }) else {
                out += linePieces(paragraph, ink: ink)
                continue
            }
            for row in rows where row.marker != nil || !row.text.isEmpty {
                guard let marker = row.marker else {
                    out += linePieces(row.text, ink: ink)
                    continue
                }
                let source = String(repeating: " ", count: row.indent) + (marker == "•" ? "-" : marker) + " " + row.text
                out.append(TranscriptPiece(kind: .listItem(marker: marker, depth: row.indent, runs: inline(row.text)), source: source))
            }
        }
        return out
    }
}

/// One paragraph of a message before it has its id and lead.
public struct TranscriptPiece: Equatable, Sendable {
    public var kind: TranscriptBlock.Kind
    public var source: String

    public init(kind: TranscriptBlock.Kind, source: String) {
        self.kind = kind
        self.source = source
    }

    public var isListItem: Bool {
        if case .listItem = kind { return true }
        return false
    }
}
