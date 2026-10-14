import SwiftUI
import ToolRegistry
import Foundation
import ChatOrchestration
import ChatSessionWork
import NativeAgentShared
import PersistenceCore

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

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
        target = Self.boundedLine(Self.target(input), limit: 180)
        outcome = ChatToolOutcome.displayOutcome(result: result, ok: meta?.ok, hasResult: meta?.resultSummary != nil)
        summary = Self.boundedLine(ChatToolOutcome.displaySummary(outcome: outcome, input: input, result: result), limit: 240)
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

    static func target(_ input: JSONValue?) -> String {
        guard case .object(let fields)? = input else { return "" }
        var values = ["path", "file", "file_path", "target", "task", "task_id", "parent", "title", "query", "id"]
            .compactMap { fields[$0]?.stringValue }
        if case .array(let children)? = fields["children"] {
            values += children.compactMap { child in
                guard case .object(let fields) = child else { return nil }
                return fields["title"]?.stringValue
            }
        }
        return values.joined(separator: " · ")
    }

    static func boundedLine(_ text: String, limit: Int) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .truncated(to: limit, suffix: "…")
    }

    /// ui-simplify 2026-09-02: an absent duration used to render the words
    /// "unknown duration" beside every streamed tool call — a confession the
    /// reader could do nothing with. A missing duration now says nothing at
    /// all; the pill's outcome glyph still distinguishes pending from done.
    static func durationText(_ durationMs: Int?) -> String {
        guard let durationMs else { return "" }
        return "\(durationMs)ms"
    }

    /// Fluid glass A2: a call's arguments or result as "key: value" lines a
    /// person can read — top-level fields in key order, each value one short
    /// line, nested values counted rather than dumped. Raw JSON stays behind
    /// the row's "Raw" toggle. Not an object (or not JSON): no lines.
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
                shown = boundedLine(text, limit: 120)
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
        // The inputs are already capped at 1,002 rows. One compact matrix
        // retains the existing alignment and tie-breaking within that bound.
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

// PATCH-2026-05-08: wave2-chat-ux — ToolPillView for role=tool messages.
// Fluid glass A2: one tool call as the transcript's one activity row
// (`ChatActivityRow`). Opened, it reads as a person would say it — the short
// summary, then the call's arguments and result as "key: value" lines — and
// the raw JSON sits behind a secondary "Raw" toggle.
struct ToolPillView: View {
    var message: ChatMessage
    /// The settled fold's own sentence for this call ("Wrote a file"); nil
    /// shows the tool's title and target.
    var headline: String? = nil
    @State private var expanded = false
    @State private var showsRaw = false

    private var meta: ChatMessageMetadata? { message.metadata }
    @State private var presentation: ToolPillPresentation?
    private var resultSummary: String { meta?.resultSummary ?? "" }
    var body: some View {
        Group {
            if let presentation, presentation.revision.metadata == meta {
                pill(presentation)
            }
        }
        .task(id: ToolPillPresentation.Revision(metadata: meta, expanded: expanded)) {
            if let presentation, presentation.revision.metadata == meta,
               presentation.revision.expanded || !expanded { return }
            let revision = ToolPillPresentation.Revision(metadata: meta, expanded: expanded)
            let prepared = await Task.detached(priority: .userInitiated) { ToolPillPresentation(revision) }.value
            if !Task.isCancelled { presentation = prepared }
        }
    }

    private func pill(_ presentation: ToolPillPresentation) -> some View {
        let target = presentation.target
        let title = presentation.title
        let summary = presentation.summary
        let outcome = presentation.outcome
        let durationText = presentation.durationText
        let line = headline ?? (target.isEmpty ? title : "\(title) · \(target)")
        return ChatActivityRow(
            title: line,
            trailing: durationText,
            isExpanded: $expanded,
            accessibilityLabel: [line, summary, outcome.rawValue, durationText]
                .filter { !$0.isEmpty }.joined(separator: ". ")
        ) {
            if headline == nil {
                Image(systemName: outcome.icon)
                    .accessibilityHidden(true)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                if let remedy = presentation.remedy {
                    Text("Next step: " + remedy)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let fields = presentation.fields
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(field.key + ":").foregroundStyle(NativeAgentShell.tertiary)
                        Text(field.value).lineLimit(2)
                    }
                }
                // Inline diff for write_file
                if let lines = presentation.diffLines {
                    ToolDiffView(diffLines: lines)
                }
                Button(showsRaw ? "Hide raw" : "Raw") { showsRaw.toggle() }
                    .buttonStyle(.plain)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .padding(.top, 2)
                if showsRaw {
                    // Fix 4: cap display strings so large payloads don't
                    // materialise fully in the view.
                    VStack(alignment: .leading, spacing: 4) {
                        if let json = meta?.inputJSON {
                            Text(json.truncated(to: 8000, suffix: "\n…[truncated]"))
                        }
                        if !resultSummary.isEmpty {
                            Text(resultSummary.truncated(to: 8000, suffix: "\n…[truncated]"))
                        }
                    }
                    .font(.system(size: ShellType.captionSize, design: .monospaced))
                }
            }
        }
    }
}

extension ChatToolOutcome.DisplayOutcome {
    var icon: String {
        switch self {
        case .pending: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .refused: "hand.raised"
        case .partial: "circle.lefthalf.filled"
        case .connectionFailed: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        case .needsYou: "person.crop.circle.badge.questionmark"
        }
    }
}

// PATCH-2026-05-08: wave2-chat-ux — unified diff viewer for write_file expanded view
struct ToolDiffView: View {
    let diffLines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Diff")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        toolDiffLine(line)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func toolDiffLine(_ line: String) -> some View {
        if line.hasPrefix("+") {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.07))
        } else if line.hasPrefix("-") {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07))
        } else {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
