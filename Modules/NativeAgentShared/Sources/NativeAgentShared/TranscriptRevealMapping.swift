import Foundation

// Blueprint: | `TranscriptRevealMapping.swift` | Parser-position glyph cuts shared by Mac and phone transcript renderers |

public enum TranscriptRevealMapping: Equatable, Sendable, Codable {
    case mapped([TranscriptRevealCut])
    case failed(reason: String)

    @available(macOS 15, iOS 18, *)
    public init(_ block: TranscriptBlock, rendered: String) {
        do { self = .mapped(try Self.cuts(block, rendered: rendered)) }
        catch { self = .failed(reason: error.localizedDescription) }
    }

    /// Parser positions address source bytes, including entities and escapes whose glyphs are not literal source characters.
    @available(macOS 15, iOS 18, *)
    private static func cuts(_ block: TranscriptBlock, rendered: String) throws -> [TranscriptRevealCut] {
        guard block.id.hasPrefix(block.messageID + "#") else { return [] }
        let source = block.source
        func atomic() -> [TranscriptRevealCut] {
            [TranscriptRevealCut(utf8End: rendered.utf8.count, utf16End: rendered.utf16.count, markdownEnd: source.utf8.count)]
        }
        var input = MappedSource(source: source)
        var prefix = ""
        var literal = false
        switch block.kind {
        case .reply:
            input.append(source[...])
        case .heading:
            let indent: Substring = source.drop(while: { $0 == " " || $0 == "\t" })
            let marks: Substring = indent.drop(while: { $0 == "#" })
            let trimmed: Substring = marks.drop(while: { $0.isWhitespace })
            if let last = trimmed.lastIndex(where: { !$0.isWhitespace }) { input.append(trimmed[...last]) }
        case .quote:
            var previous: String.Index?
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                if let previous { input.append(source[previous..<line.startIndex]) }
                let marked = line.drop { $0 == " " || $0 == "\t" }.dropFirst()
                input.append(marked.first == " " ? marked.dropFirst() : marked)
                previous = line.endIndex
            }
        case .listItem(let marker, _, _):
            let marked = source.drop { $0 == " " }.drop { !$0.isWhitespace }.dropFirst()
            input.append(marked)
            prefix = "\t" + marker + "\t"
        case .code:
            guard let newline = source.firstIndex(of: "\n"), source.hasSuffix("\n```") else {
                throw mappingFailure()
            }
            let from = source.index(after: newline)
            let to = source.index(source.endIndex, offsetBy: -4)
            guard from <= to else { throw mappingFailure() }
            input.append(source[from..<to])
            literal = true
        case .attachment, .user:
            return atomic()
        default:
            return []
        }
        if input.text.isEmpty { return atomic() }
        var cuts: [TranscriptRevealCut] = []
        var glyphs = ""
        var utf8 = 0
        var utf16 = 0
        func append(_ text: String, end: Int) throws {
            guard let markdownEnd = input.ends[end] else { throw mappingFailure() }
            glyphs += text
            utf8 += text.utf8.count
            utf16 += text.utf16.count
            cuts.append(TranscriptRevealCut(utf8End: utf8, utf16End: utf16, markdownEnd: markdownEnd))
        }
        if !prefix.isEmpty { try append(prefix, end: 0) }
        func appendLiteral(_ range: Range<String.Index>) throws {
            var at = range.lowerBound
            while at < range.upperBound {
                let end = input.text.index(after: at)
                try append(oneParagraph(String(input.text[at..<end])),
                           end: input.text.utf8.distance(from: input.text.utf8.startIndex, to: end))
                at = end
            }
        }
        if literal || TranscriptDocument.isPlain(input.text) {
            try appendLiteral(input.text.startIndex..<input.text.endIndex)
        } else {
            switch ChatRichContentParser.inline(input.text, sourcePositions: true) {
            case .failed(_, let reason):
                throw CocoaError(.formatting,
                    userInfo: [NSLocalizedDescriptionKey: "The transcript reveal mapping parse failed: " + reason])
            case .parsed(let styled):
                for run in styled.runs {
                    guard let position = run.markdownSourcePosition, let range = Range(position, in: input.text) else {
                        throw mappingFailure()
                    }
                    let text = oneParagraph(String(styled[run.range].characters))
                    if text == oneParagraph(String(input.text[range])) {
                        try appendLiteral(range)
                    } else {
                        // A transformed parser run is one reveal unit; none of its source is copied before all its glyphs show.
                        try append(text, end: input.text.utf8.distance(from: input.text.utf8.startIndex, to: range.upperBound))
                    }
                }
            }
        }
        guard glyphs == rendered else { throw mappingFailure() }
        return cuts
    }

    /// Every platform renders the same source line separators into one TextKit paragraph.
    public static func oneParagraph(_ text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == "\u{2029}" || $0 == "\u{85}" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\u{2028}")
            .replacingOccurrences(of: "\r", with: "\u{2028}")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
            .replacingOccurrences(of: "\u{2029}", with: "\u{2028}")
            .replacingOccurrences(of: "\u{85}", with: "\u{2028}")
    }

    private static func mappingFailure() -> CocoaError {
        CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "The transcript renderer could not map its glyphs to Markdown source."])
    }

    private struct MappedSource {
        let source: String
        var text = ""
        var ends: [Int: Int] = [:]

        mutating func append(_ slice: Substring) {
            var at = slice.startIndex
            if text.isEmpty { ends[0] = source.utf8.distance(from: source.utf8.startIndex, to: at) }
            while at < slice.endIndex {
                let end = slice.index(after: at)
                text.append(contentsOf: slice[at..<end])
                ends[text.utf8.count] = source.utf8.distance(from: source.utf8.startIndex, to: end)
                at = end
            }
        }
    }
}
