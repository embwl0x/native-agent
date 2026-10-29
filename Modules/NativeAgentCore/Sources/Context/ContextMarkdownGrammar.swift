import CryptoKit
import Foundation
import NativeAgentCore
import PersonaEngine
// Blueprint: | `ContextMarkdownGrammar.swift` | `ContextMarkdownCompiler` grammar: UTF-8 block ranges, Markdown boundaries and generated USER fact bullets |

// MARK: - Markdown structure

extension ContextMarkdownCompiler {
    enum BlockShape: String, Sendable {
        case paragraph
        case list
        case fence
    }

    private struct SourceLine: Sendable {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    struct ParsedBlock: Sendable {
        let shape: BlockShape
        let headingPath: [String]
        let range: ContextSourceRange
        let body: String
        /// True for a single generated USER.md bullet; drives content-keyed identity.
        var isGeneratedUserFact: Bool = false
    }

    func parse(
        _ data: Data,
        atomizingGeneratedUserFacts: Bool = false
    ) throws -> [ParsedBlock] {
        let bytes = [UInt8](data)
        let lines = Self.lines(in: bytes)
        let generatedBody = atomizingGeneratedUserFacts
            ? Self.generatedUserBodyByteRange(bytes: bytes, lines: lines)
            : nil
        var headings: [String?] = Array(repeating: nil, count: 6)
        var blocks: [ParsedBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let lineBytes = Array(bytes[line.start..<line.contentEnd])
            if Self.isBlank(lineBytes) {
                index += 1
                continue
            }
            if let heading = Self.atxHeading(lineBytes) {
                headings[heading.level - 1] = heading.title
                if heading.level < headings.count {
                    for deeper in heading.level..<headings.count { headings[deeper] = nil }
                }
                index += 1
                continue
            }

            let startIndex = index
            let shape: BlockShape
            if let fence = Self.fenceOpening(lineBytes) {
                shape = .fence
                index += 1
                while index < lines.count {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    index += 1
                    if Self.isFenceClosing(candidate, opening: fence) { break }
                }
            } else if Self.isListStart(lineBytes) {
                shape = .list
                // Generated lists end at the region boundary, before the closing marker.
                let generatedLimit = generatedBody
                    .flatMap { $0.contains(lines[index].start) ? $0.upperBound : nil }
                    ?? Int.max
                index += 1
                while index < lines.count, lines[index].start < generatedLimit {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    if Self.isBlank(candidate)
                        || Self.atxHeading(candidate) != nil
                        || Self.fenceOpening(candidate) != nil {
                        break
                    }
                    index += 1
                }
            } else {
                shape = .paragraph
                index += 1
                while index < lines.count {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    if Self.isBlank(candidate)
                        || Self.atxHeading(candidate) != nil
                        || Self.fenceOpening(candidate) != nil
                        || Self.isListStart(candidate) {
                        break
                    }
                    index += 1
                }
            }

            // Split generated USER.md facts per bullet; all other content keeps whole-block atoms.
            let isGeneratedFact = shape == .list
                && generatedBody?.contains(lines[startIndex].start) == true
            let itemSpans = isGeneratedFact
                ? Self.topLevelListItemSpans(
                    bytes: bytes,
                    lines: lines,
                    from: startIndex,
                    to: index
                )
                : [(first: startIndex, last: index - 1)]

            for span in itemSpans {
                let first = lines[span.first]
                let last = lines[span.last]
                let bodyData = Data(bytes[first.start..<last.contentEnd])
                guard let body = String(data: bodyData, encoding: .utf8) else {
                    throw ContextMarkdownCompilerError.malformedUTF8
                }
                // Autogen markers delimit content and never become atoms.
                if Self.isAutogenMarkerBlock(body) { continue }
                guard bodyData.count <= ContextMarkdownCompilerLimits.maxAtomUTF8Bytes else {
                    throw ContextMarkdownCompilerError.atomTooLarge(
                        index: blocks.count,
                        actualBytes: bodyData.count,
                        maximumBytes: ContextMarkdownCompilerLimits.maxAtomUTF8Bytes
                    )
                }
                blocks.append(ParsedBlock(
                    shape: shape,
                    headingPath: headings.compactMap { $0 },
                    range: ContextSourceRange(utf8Start: first.start, utf8End: last.contentEnd),
                    body: body,
                    isGeneratedUserFact: isGeneratedFact
                ))
            }
        }
        return blocks
    }

    /// Bytes between exactly one well-formed marker pair, allowing a manual preamble.
    /// This cuts atoms; `ContextPreparation.generatedUserFacts` owns projection suppression.
    private static func generatedUserBodyByteRange(
        bytes: [UInt8],
        lines: [SourceLine]
    ) -> Range<Int>? {
        let start = Array(UserMDAutogenMarkers.bodyStart.utf8)
        let end = Array(UserMDAutogenMarkers.bodyEnd.utf8)
        var startOffset: Int?
        var endOffset: Int?
        for line in lines {
            let content = Array(bytes[line.start..<line.contentEnd])
            let trimmed = trimmingASCIIWhitespace(content)
            if trimmed == start {
                guard startOffset == nil else { return nil }
                startOffset = line.end
            } else if trimmed == end {
                guard endOffset == nil else { return nil }
                endOffset = line.start
            }
        }
        guard let startOffset, let endOffset, startOffset <= endOffset else { return nil }
        return startOffset..<endOffset
    }

    private static func trimmingASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var lower = 0
        var upper = bytes.count
        while lower < upper, bytes[lower] == 0x20 || bytes[lower] == 0x09 { lower += 1 }
        while upper > lower, bytes[upper - 1] == 0x20 || bytes[upper - 1] == 0x09 { upper -= 1 }
        return Array(bytes[lower..<upper])
    }

    /// Column-zero list items in `[from, to)`; continuations and any leading span stay attached.
    private static func topLevelListItemSpans(
        bytes: [UInt8],
        lines: [SourceLine],
        from: Int,
        to: Int
    ) -> [(first: Int, last: Int)] {
        var spans: [(first: Int, last: Int)] = []
        for lineIndex in from..<to {
            let content = Array(bytes[lines[lineIndex].start..<lines[lineIndex].contentEnd])
            let startsItem = lineIndex == from
                || (content.first.map { $0 != 0x20 && $0 != 0x09 } ?? false) && isListStart(content)
            if startsItem {
                spans.append((lineIndex, lineIndex))
            } else if !spans.isEmpty {
                spans[spans.count - 1].last = lineIndex
            }
        }
        return spans.isEmpty ? [(from, to - 1)] : spans
    }

    private static func lines(in bytes: [UInt8]) -> [SourceLine] {
        var result: [SourceLine] = []
        var start = 0
        while start < bytes.count {
            var cursor = start
            while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D {
                cursor += 1
            }
            let contentEnd = cursor
            if cursor < bytes.count {
                if bytes[cursor] == 0x0D, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x0A {
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            result.append(SourceLine(start: start, contentEnd: contentEnd, end: cursor))
            start = cursor
        }
        return result
    }

    private static func isBlank(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func atxHeading(_ bytes: [UInt8]) -> (level: Int, title: String)? {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        let markerStart = cursor
        while cursor < bytes.count, bytes[cursor] == 0x23 { cursor += 1 }
        let level = cursor - markerStart
        guard (1...6).contains(level) else { return nil }
        guard cursor == bytes.count || bytes[cursor] == 0x20 || bytes[cursor] == 0x09 else {
            return nil
        }
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
        var end = bytes.count
        while end > cursor, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        var hashStart = end
        while hashStart > cursor, bytes[hashStart - 1] == 0x23 { hashStart -= 1 }
        if hashStart < end,
           hashStart == cursor || bytes[hashStart - 1] == 0x20 || bytes[hashStart - 1] == 0x09 {
            end = hashStart
            while end > cursor, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        }
        let title = String(decoding: bytes[cursor..<end], as: UTF8.self)
        return (level, title)
    }

    static func fenceOpening(_ bytes: [UInt8]) -> (marker: UInt8, count: Int)? {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == 0x60 || bytes[cursor] == 0x7E else {
            return nil
        }
        let marker = bytes[cursor]
        let start = cursor
        while cursor < bytes.count, bytes[cursor] == marker { cursor += 1 }
        let count = cursor - start
        return count >= 3 ? (marker, count) : nil
    }

    private static func isFenceClosing(
        _ bytes: [UInt8],
        opening: (marker: UInt8, count: Int)
    ) -> Bool {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        let start = cursor
        while cursor < bytes.count, bytes[cursor] == opening.marker { cursor += 1 }
        guard cursor - start >= opening.count else { return false }
        return bytes[cursor...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    static func isListStart(_ bytes: [UInt8]) -> Bool {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        guard cursor < bytes.count else { return false }
        if bytes[cursor] == 0x2D || bytes[cursor] == 0x2A || bytes[cursor] == 0x2B {
            cursor += 1
            return cursor < bytes.count && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09)
        }
        let digitStart = cursor
        while cursor < bytes.count,
              cursor - digitStart < 9,
              (0x30...0x39).contains(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > digitStart,
              cursor < bytes.count,
              bytes[cursor] == 0x2E || bytes[cursor] == 0x29 else {
            return false
        }
        cursor += 1
        return cursor < bytes.count && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09)
    }
}
