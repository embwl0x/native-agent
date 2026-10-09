import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace

/// Typed subset of Bot API 10.2 rich blocks that improves ordinary assistant
/// replies without exposing provider traces or requiring a second UI surface.
public indirect enum TelegramInputRichBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(text: String, size: Int)
    case preformatted(text: String, language: String?)
    case table([[TelegramInputRichTableCell]])
    case details(summary: String, blocks: [TelegramInputRichBlock])

    var jsonValue: JSONValue {
        switch self {
        case .paragraph(let text):
            return .object(["type": .string("paragraph"), "text": .string(text)])
        case .heading(let text, let size):
            return .object([
                "type": .string("heading"),
                "text": .string(text),
                "size": .int(Int64(min(6, max(1, size)))),
            ])
        case .preformatted(let text, let language):
            var value: [String: JSONValue] = [
                "type": .string("pre"),
                "text": .string(text),
            ]
            if let language, !language.isEmpty {
                value["language"] = .string(language)
            }
            return .object(value)
        case .table(let rows):
            return .object([
                "type": .string("table"),
                "cells": .array(rows.map { .array($0.map(\.jsonValue)) }),
                "is_bordered": .bool(true),
                "is_striped": .bool(true),
            ])
        case .details(let summary, let blocks):
            return .object([
                "type": .string("details"),
                "summary": .string(summary),
                "blocks": .array(blocks.map(\.jsonValue)),
            ])
        }
    }
}

public struct TelegramInputRichTableCell: Sendable, Equatable {
    public let text: String
    public let isHeader: Bool

    public init(text: String, isHeader: Bool) {
        self.text = text
        self.isHeader = isHeader
    }

    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [
            "text": .string(text),
            "align": .string("left"),
            "valign": .string("top"),
        ]
        if isHeader { value["is_header"] = .bool(true) }
        return .object(value)
    }
}

public struct TelegramInputRichMessage: Sendable, Equatable {
    public let blocks: [TelegramInputRichBlock]

    public init(blocks: [TelegramInputRichBlock]) {
        self.blocks = blocks
    }

    var jsonValue: JSONValue {
        .object(["blocks": .array(blocks.map(\.jsonValue))])
    }
}

/// Pure, bounded renderer. Its only input is the already-user-visible
/// assistant reply. It strips explicit reasoning containers defensively and
/// runs the same secret redactor used by turn traces before building blocks.
enum TelegramRichMessageRenderer {
    // Bot API rich limits: 32768 UTF-8 bytes, 500 nested blocks/rows,
    // 16 nesting levels and 20 table columns. Keep payload headroom.
    static let maximumUTF8Bytes = 30_000
    static let maximumBlocks = 256
    static let maximumBlockUnits = 480
    static let maximumTableColumns = 20

    /// Split at native block boundaries, retaining every visible text fragment.
    /// A draft uses the latest packet; final delivery persists all packets.
    static func render(_ raw: String) -> [TelegramInputRichMessage] {
        let safe = sanitize(raw)
        guard !safe.isEmpty else { return [] }
        let parsed = parseBlocks(Array(safe.split(separator: "\n", omittingEmptySubsequences: false)))
        let blocks = parsed.flatMap {
            split($0, maximumBytes: maximumUTF8Bytes, maximumUnits: maximumBlockUnits)
        }
        return packets(blocks, maximumBytes: maximumUTF8Bytes, maximumUnits: maximumBlockUnits)
            .map(TelegramInputRichMessage.init(blocks:))
    }

    private static func split(
        _ block: TelegramInputRichBlock,
        maximumBytes: Int,
        maximumUnits: Int
    ) -> [TelegramInputRichBlock] {
        switch block {
        case .paragraph(let text):
            return textChunks(text, maximumBytes: maximumBytes).map(TelegramInputRichBlock.paragraph)
        case .heading(let text, let size):
            return textChunks(text, maximumBytes: maximumBytes).map { .heading(text: $0, size: size) }
        case .preformatted(let text, let language):
            return textChunks(text, maximumBytes: maximumBytes).map { .preformatted(text: $0, language: language) }
        case .table(let rows):
            let columnCount = rows.map(\.count).max() ?? 0
            var result: [TelegramInputRichBlock] = []
            let columnsPerBlock = min(maximumTableColumns, max(1, maximumBytes / 4))
            for column in stride(from: 0, to: columnCount, by: columnsPerBlock) {
                var current: [[TelegramInputRichTableCell]] = []
                var currentBytes = 0
                for row in rows {
                    let cells = Array(row.dropFirst(column).prefix(columnsPerBlock))
                    guard !cells.isEmpty else { continue }
                    let fragments = cells.map {
                        textChunks($0.text, maximumBytes: maximumBytes / columnsPerBlock)
                    }
                    // Continue oversized cell text in the same column; no text
                    // is dropped to make a wide or long table fit a packet.
                    for part in 0..<max(1, fragments.map(\.count).max() ?? 0) {
                        let continued = cells.enumerated().map { index, cell in
                            TelegramInputRichTableCell(
                                text: part < fragments[index].count ? fragments[index][part] : "",
                                isHeader: cell.isHeader
                            )
                        }
                        let rowBytes = continued.reduce(0) { $0 + $1.text.utf8.count }
                        if !current.isEmpty,
                           currentBytes + rowBytes > maximumBytes || current.count + 2 > maximumUnits {
                            result.append(.table(current))
                            current = []
                            currentBytes = 0
                        }
                        current.append(continued)
                        currentBytes += rowBytes
                    }
                }
                if !current.isEmpty { result.append(.table(current)) }
            }
            return result
        case .details(let summary, let children):
            // A deeply nested summary can consume its parent's remaining text
            // budget. Preserve its text and children as native sibling blocks.
            guard maximumBytes >= 8, maximumUnits >= 2 else {
                return split(.paragraph(summary), maximumBytes: maximumBytes, maximumUnits: maximumUnits)
                    + children.flatMap { split($0, maximumBytes: maximumBytes, maximumUnits: maximumUnits) }
            }
            let summaries = textChunks(summary, maximumBytes: maximumBytes / 2)
            guard let lastSummary = summaries.last else { return [] }
            var result = summaries.dropLast().map(TelegramInputRichBlock.paragraph)
            let childBytes = maximumBytes - lastSummary.utf8.count
            let childUnits = maximumUnits - 1
            let blocks = children.flatMap { split($0, maximumBytes: childBytes, maximumUnits: childUnits) }
            let groups = packets(blocks, maximumBytes: childBytes, maximumUnits: childUnits)
            if groups.isEmpty { result.append(.details(summary: lastSummary, blocks: [])) }
            for group in groups { result.append(.details(summary: lastSummary, blocks: group)) }
            return result
        }
    }

    private static func packets(
        _ blocks: [TelegramInputRichBlock],
        maximumBytes: Int,
        maximumUnits: Int
    ) -> [[TelegramInputRichBlock]] {
        var result: [[TelegramInputRichBlock]] = []
        var current: [TelegramInputRichBlock] = []
        var bytes = 0
        var units = 0
        for block in blocks {
            let size = dimensions(block)
            if !current.isEmpty,
               bytes + size.bytes > maximumBytes || units + size.units > maximumUnits || current.count >= maximumBlocks {
                result.append(current)
                current = []
                bytes = 0
                units = 0
            }
            current.append(block)
            bytes += size.bytes
            units += size.units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func dimensions(_ block: TelegramInputRichBlock) -> (bytes: Int, units: Int) {
        switch block {
        case .paragraph(let text), .heading(let text, _), .preformatted(let text, _):
            return (text.utf8.count, 1)
        case .table(let rows):
            return (rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.utf8.count } }, 1 + rows.count)
        case .details(let summary, let children):
            return children.reduce((bytes: summary.utf8.count, units: 1)) { total, child in
                let size = dimensions(child)
                return (total.bytes + size.bytes, total.units + size.units)
            }
        }
    }

    private static func textChunks(_ text: String, maximumBytes: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count > maximumBytes else { return [text] }
        var result: [String] = []
        var chunk = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if bytes + size > maximumBytes, !chunk.isEmpty {
                result.append(chunk)
                chunk = ""
                bytes = 0
            }
            chunk.unicodeScalars.append(scalar)
            bytes += size
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    static func sanitize(_ raw: String) -> String {
        var value = raw
        for pattern in [
            #"(?is)<think(?:ing)?\b[^>]*>.*?</think(?:ing)?>"#,
            #"(?is)<analysis\b[^>]*>.*?</analysis>"#,
            #"(?im)^\s*(?:hidden[_ ]reasoning|internal[_ ]trace|raw[_ ]provider[_ ]payload|tool[_ ]arguments?)\s*:.*$"#,
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: ""
            )
        }
        value = TelegramPollLoop._tgRedactToken(TurnTraceRedactor.redactText(value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let tokenRegex = try? NSRegularExpression(
            pattern: #"\b[0-9]{6,12}:[A-Za-z0-9_-]{12,}\b"#
        ) {
            value = tokenRegex.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: "[REDACTED_TELEGRAM_TOKEN]"
            )
        }
        return value
    }

    /// 2026-09-22: rich blocks and ordinary sends carry plain text (no
    /// parse_mode, no entities), so markdown showed raw. Outside code fences:
    /// drop `**bold**` and `*italic*` markers, turn `[text](url)` into
    /// "text (url)", and drop the backticks around inline code (its contents
    /// stay untouched). Bullets ("* ") and math (2*3*4) are left alone.
    static func stripBoldMarkers(_ text: String) -> String {
        guard text.contains("*") || text.contains("`") || text.contains("]("),
              let bold = try? NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#),
              // Opens at start/after space or an opening bracket/quote; closes before
              // space, punctuation or end. A / or . beside a star never counts (globs).
              let italic = try? NSRegularExpression(
                  pattern: #"(?<![^\s(\[{"'“‘])\*(?=[^\s*/.])(.+?)(?<=[^\s*/.])\*(?![^\s,;:!?)\]}"'”’])"#
              ),
              let link = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
        else { return text }
        var inFence = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            if line.hasPrefix("```") { inFence.toggle(); return line }
            guard !inFence else { return line }
            let parts = line.split(separator: "`", omittingEmptySubsequences: false)
            let cleaned = parts
                .enumerated()
                .map { index, part -> String in
                    var part = String(part)
                    guard index.isMultiple(of: 2) else { return part }
                    for (regex, template) in [(bold, "$1"), (italic, "$1"), (link, "$1 ($2)")] {
                        part = regex.stringByReplacingMatches(
                            in: part,
                            range: NSRange(part.startIndex..., in: part),
                            withTemplate: template
                        )
                    }
                    return part
                }
            // Paired backticks (odd part count) are inline code: drop them.
            return cleaned.joined(separator: parts.count.isMultiple(of: 2) ? "`" : "")
        }.joined(separator: "\n")
    }

    private static func parseBlocks(_ source: [Substring], depth: Int = 0) -> [TelegramInputRichBlock] {
        let lines = source.map(String.init)
        var blocks: [TelegramInputRichBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                var body: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.preformatted(
                    text: body.joined(separator: "\n"),
                    language: language.isEmpty ? nil : language
                ))
                continue
            }

            if let heading = heading(from: line) {
                blocks.append(.heading(text: heading.text, size: heading.size))
                index += 1
                continue
            }

            if depth < 14, line.trimmingCharacters(in: .whitespacesAndNewlines) == "<details>",
               index + 1 < lines.count,
               let summary = detailsSummary(from: lines[index + 1]) {
                index += 2
                var nested: [Substring] = []
                var nesting = 1
                while index < lines.count {
                    let marker = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if marker == "<details>" { nesting += 1 }
                    if marker == "</details>" { nesting -= 1 }
                    if nesting == 0 { break }
                    nested.append(Substring(lines[index]))
                    index += 1
                }
                if index < lines.count { index += 1 }
                let childBlocks = parseBlocks(nested, depth: depth + 1)
                blocks.append(.details(summary: summary, blocks: childBlocks))
                continue
            }

            if index + 1 < lines.count,
               isTableRow(line),
               isTableSeparator(lines[index + 1]) {
                let header = tableCells(line)
                index += 2
                var rows = [header.map { TelegramInputRichTableCell(text: $0, isHeader: true) }]
                while index < lines.count,
                      isTableRow(lines[index]) {
                    rows.append(tableCells(lines[index]).map {
                        TelegramInputRichTableCell(text: $0, isHeader: false)
                    })
                    index += 1
                }
                if !header.isEmpty { blocks.append(.table(rows)) }
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !lines[index].hasPrefix("```"),
                  heading(from: lines[index]) == nil,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != "<details>",
                  !(index + 1 < lines.count && isTableRow(lines[index]) && isTableSeparator(lines[index + 1])) {
                paragraph.append(lines[index])
                index += 1
            }
            let text = paragraph.joined(separator: "\n")
            if !text.isEmpty { blocks.append(.paragraph(text)) }
        }
        return blocks
    }

    private static func heading(from line: String) -> (size: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    private static func detailsSummary(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<summary>"), trimmed.hasSuffix("</summary>") else {
            return nil
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "<summary>".count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -"</summary>".count)
        let value = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && tableCells(line).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
