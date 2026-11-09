import Foundation

// Blueprint: | `TranscriptLiveMarkdown.swift` | Incremental complete markdown blocks, one reparsed open tail and source-to-glyph reveal cuts |

@available(macOS 15, iOS 18, *)
struct TranscriptLiveMarkdown {
    private var rowID = ""
    private var source = ""
    private var scanned = 0
    private var committed = 0
    private var fence: Int?
    private var complete: [TranscriptPiece] = []

    mutating func pieces(rowID: String, text: String) -> [TranscriptPiece] {
        if self.rowID != rowID || !text.hasPrefix(source) {
            self = Self()
            self.rowID = rowID
        }
        source = text
        let utf8 = text.utf8
        var cursor = utf8.index(utf8.startIndex, offsetBy: scanned)
        while let newline = utf8[cursor...].firstIndex(of: 10) {
            let end = utf8.index(after: newline)
            let line = String(text[cursor..<newline]).trimmingCharacters(in: .whitespaces)
            let ticks = line.prefix { $0 == "`" }.count
            let heading = fence == nil && TranscriptDocument.headingText(Substring(line)) != nil
            let listItem = fence == nil && ChatRichContentParser.listRows(line).first?.marker != nil
            let opensFence = fence == nil && ticks >= 3 && !line.dropFirst(ticks).contains("`")
            if heading || listItem || opensFence { commit(through: utf8.distance(from: utf8.startIndex, to: cursor)) }
            var closes = false
            if let opened = fence {
                if ticks >= opened, line.dropFirst(ticks).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    closes = true
                }
            } else if opensFence {
                fence = ticks
            }
            scanned = utf8.distance(from: utf8.startIndex, to: end)
            if fence == nil, line.isEmpty || closes || heading { commit(through: scanned) }
            cursor = end
        }
        let start = utf8.index(utf8.startIndex, offsetBy: committed)
        return complete + TranscriptDocument.replyPieces(String(text[start...]), ink: .primary, edge: true)
    }

    private mutating func commit(through end: Int) {
        guard end > committed else { return }
        let utf8 = source.utf8
        let from = utf8.index(utf8.startIndex, offsetBy: committed)
        let to = utf8.index(utf8.startIndex, offsetBy: end)
        complete += TranscriptDocument.replyPieces(String(source[from..<to]), ink: .primary, edge: false)
        committed = end
    }

    /// The renderer owns each local source map; the line only seats its glyphs in reveal order.
    static func line(_ paragraphs: [TranscriptRenderedParagraph], rowID: String, text: String, streaming: Bool) -> TranscriptLiveLine {
        var result: [String: [TranscriptRevealCut]] = [:]
        var glyphs = ""
        for paragraph in paragraphs where paragraph.block.id.hasPrefix(paragraph.block.messageID + "#") {
            // Failed mappings stay whole on the face and retain their cause in the press's issue.
            guard case .mapped(let cuts) = paragraph.mapping else { continue }
            if !glyphs.isEmpty { glyphs += "\n\n" }
            let offset = glyphs.utf8.count
            result[paragraph.block.id] = cuts.map { cut in
                TranscriptRevealCut(utf8End: offset + cut.utf8End, utf16End: cut.utf16End, markdownEnd: cut.markdownEnd)
            }
            glyphs += String(paragraph.body.characters)
        }
        return TranscriptLiveLine(rowID: rowID, text: text, glyphs: glyphs, streaming: streaming, cuts: result)
    }
}
