import EngineRuntime
import SwiftUI
import ToolRegistry
import Foundation
import ChatToolParsing
import ChatSessionWork
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ChatToolPillView.swift` | `ToolPillPresentation` (a tool row's title, target, outcome and duration) and `ToolDiffPresentation` |

struct ToolPillPresentation: Sendable {
    struct Revision: Equatable, Sendable {
        let metadata: ChatMessageMetadata?
        let expanded: Bool
    }

    let revision: Revision
    let title: String
    let target: String
    let summary: String
    let outcome: ChatToolOutcome.DisplayOutcome
    let durationText: String
    let fields: [(key: String, value: String)]
    let remedy: String?
    let diffLines: [String]?

    init(_ revision: Revision) {
        self.revision = revision
        let meta = revision.metadata
        let call = ToolNameAliases.shown(meta?.toolName ?? "tool", inputJSON: meta?.inputJSON)
        let input = call.inputJSON.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        let result = meta?.resultSummary.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        title = Self.title(call.name)
        target = TranscriptRowFace.boundedLine(TranscriptRowFace.toolTarget(input), limit: 180)
        outcome = ChatToolOutcome.projection(kind: meta?.kind, ok: meta?.ok,
            result: result, hasResult: meta?.resultSummary != nil, resultStatus: meta?.resultStatus,
            interactionState: meta?.interactionState).outcome
        summary = TranscriptRowFace.boundedLine(ChatToolOutcome.displaySummary(outcome: outcome, input: input, result: result), limit: 240)
        durationText = Self.durationText(meta?.durationMs)
        fields = revision.expanded ? Self.fieldLines(input) + Self.fieldLines(result) : []
        remedy = revision.expanded ? result.flatMap(ChatToolOutcome.remedy) : nil
        if revision.expanded, call.name == "write_file", let before = meta?.beforeContent, let after = meta?.afterContent {
            diffLines = ToolDiffPresentation.lines(before: before, after: after)
        } else { diffLines = nil }
    }
    static func title(_ name: String) -> String {
        ToolActivityPresentation.title(name)
    }

    /// Missing duration stays blank; only outcome evidence distinguishes pending from done.
    static func durationText(_ durationMs: Int?) -> String {
        guard let durationMs else { return "" }
        return "\(durationMs)ms"
    }

    /// Bound field summaries while keeping raw JSON separately reachable.
    static func fieldLines(_ value: JSONValue?, limit: Int = 8) -> [(key: String, value: String)] {
        guard case .object(let fields)? = value else { return [] }
        let lines = fields.keys.sorted().lazy.compactMap { key -> (key: String, value: String)? in
            let shown: String
            switch fields[key]! {
            case .null: return nil
            case .bool(let flag): shown = flag ? "yes" : "no"
            case .int(let number): shown = String(number)
            case .double(let number): shown = String(number)
            case .string(let text):
                guard !text.isEmpty else { return nil }
                shown = TranscriptRowFace.boundedLine(text, limit: 120)
            case .array(let items): shown = items.count == 1 ? "1 item" : "\(items.count) items"
            case .object(let nested): shown = nested.count == 1 ? "1 field" : "\(nested.count) fields"
            }
            return (key.replacingOccurrences(of: "_", with: " "), shown)
        }
        return Array(lines.prefix(limit))
    }
}

enum ToolDiffPresentation {
    static func lines(before: String, after: String, limit: Int = 60) -> [String] {
        let beforeLines = before.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        let afterLines = after.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        let rows = alignedRows(before: beforeLines, after: afterLines)
        let displayed = Array(rows.prefix(limit))
        guard rows.count > displayed.count else { return displayed }
        return displayed + ["... (\(rows.count - displayed.count) more lines)"]
    }

    private static func alignedRows(before: [String], after: [String]) -> [String] {
        let m = before.count
        let n = after.count
        // The 1,002-row input cap bounds the alignment matrix without changing tie-breaking.
        var lengths = Array(repeating: UInt16(0), count: (m + 1) * (n + 1))
        if m > 0, n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    lengths[i * (n + 1) + j] = before[i] == after[j]
                        ? lengths[(i + 1) * (n + 1) + j + 1] + 1
                        : max(lengths[(i + 1) * (n + 1) + j], lengths[i * (n + 1) + j + 1])
                }
            }
        }
        var rows: [String] = []
        var i = 0
        var j = 0
        while i < m, j < n {
            if before[i] == after[j] {
                rows.append(" \(before[i])")
                i += 1
                j += 1
            } else if lengths[(i + 1) * (n + 1) + j] >= lengths[i * (n + 1) + j + 1] {
                rows.append("-\(before[i])")
                i += 1
            } else {
                rows.append("+\(after[j])")
                j += 1
            }
        }
        while i < m { rows.append("-\(before[i])"); i += 1 }
        while j < n { rows.append("+\(after[j])"); j += 1 }
        return rows
    }
}
