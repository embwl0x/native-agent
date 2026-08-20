import Foundation
import NativeAgentCore
import PersistenceCore

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
        var value: [String: JSONValue] = ["text": .string(text)]
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
    static let maximumUTF8Bytes = 30_000
    static let maximumBlocks = 256
    static let maximumBlockUnits = 480
    static let maximumTableColumns = 12
    static let maximumTableRows = 40

    static func render(_ raw: String) -> TelegramInputRichMessage? {
        let safe = sanitize(raw)
        guard !safe.isEmpty, safe.utf8.count <= maximumUTF8Bytes else { return nil }
        let parsed = parseBlocks(Array(safe.split(separator: "\n", omittingEmptySubsequences: false)))
        var remainingUnits = maximumBlockUnits
        let blocks = bounded(parsed, remainingUnits: &remainingUnits)
        guard !blocks.isEmpty else { return nil }
        return TelegramInputRichMessage(blocks: blocks)
    }

    /// Telegram counts nested blocks and table rows toward its 500-block
    /// ceiling. Reserve headroom for future server-side accounting changes.
    private static func bounded(
        _ blocks: [TelegramInputRichBlock],
        remainingUnits: inout Int
    ) -> [TelegramInputRichBlock] {
        var result: [TelegramInputRichBlock] = []
        for block in blocks.prefix(maximumBlocks) where remainingUnits > 0 {
            switch block {
            case .table(let rows):
                guard remainingUnits >= 2 else { return result }
                let keptRows = Array(rows.prefix(min(rows.count, remainingUnits - 1)))
                guard !keptRows.isEmpty else { continue }
                result.append(.table(keptRows))
                remainingUnits -= 1 + keptRows.count
            case .details(let summary, let children):
                remainingUnits -= 1
                let boundedChildren = bounded(children, remainingUnits: &remainingUnits)
                guard !boundedChildren.isEmpty else { continue }
                result.append(.details(summary: summary, blocks: boundedChildren))
            default:
                result.append(block)
                remainingUnits -= 1
            }
        }
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

    private static func parseBlocks(_ source: [Substring]) -> [TelegramInputRichBlock] {
        let lines = source.map(String.init)
        var blocks: [TelegramInputRichBlock] = []
        var index = 0
        while index < lines.count, blocks.count < maximumBlocks {
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
                    text: truncateUTF8(body.joined(separator: "\n"), limit: 12_000),
                    language: language.isEmpty ? nil : String(language.prefix(32))
                ))
                continue
            }

            if let heading = heading(from: line) {
                blocks.append(.heading(text: heading.text, size: heading.size))
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "<details>",
               index + 1 < lines.count,
               let summary = detailsSummary(from: lines[index + 1]) {
                index += 2
                var nested: [Substring] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != "</details>" {
                    nested.append(Substring(lines[index]))
                    index += 1
                }
                if index < lines.count { index += 1 }
                let childBlocks = Array(parseBlocks(nested).prefix(48))
                if !childBlocks.isEmpty {
                    blocks.append(.details(
                        summary: truncateUTF8(summary, limit: 512),
                        blocks: childBlocks
                    ))
                }
                continue
            }

            if index + 1 < lines.count,
               isTableRow(line),
               isTableSeparator(lines[index + 1]) {
                let header = tableCells(line)
                index += 2
                var rows = [header.map { TelegramInputRichTableCell(text: $0, isHeader: true) }]
                while index < lines.count,
                      isTableRow(lines[index]),
                      rows.count < maximumTableRows {
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
            let text = truncateUTF8(paragraph.joined(separator: "\n"), limit: 8_000)
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
        return (hashes.count, truncateUTF8(text, limit: 1_024))
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
            .prefix(maximumTableColumns)
            .map {
                truncateUTF8(
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines),
                    limit: 1_024
                )
            }
    }

    private static func truncateUTF8(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var output = ""
        var count = 0
        for character in value {
            let bytes = String(character).utf8.count
            if count + bytes + 3 > limit { break }
            output.append(character)
            count += bytes
        }
        return output + "..."
    }
}
