import SwiftUI
import Foundation

enum ToolPillPresentation {
    enum Outcome: Equatable {
        case pending
        case succeeded
        case failed

        var icon: String {
            switch self {
            case .pending: "clock"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .pending: .secondary
            case .succeeded: .green
            case .failed: .red
            }
        }
    }

    static func outcome(ok: Bool?) -> Outcome {
        guard let ok else { return .pending }
        return ok ? .succeeded : .failed
    }

    /// ui-simplify 2026-09-02: an absent duration used to render the words
    /// "unknown duration" beside every streamed tool call — a confession the
    /// reader could do nothing with. A missing duration now says nothing at
    /// all; the pill's outcome glyph still distinguishes pending from done.
    static func durationText(_ durationMs: Int?) -> String {
        guard let durationMs else { return "" }
        return "\(durationMs)ms"
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
        var lengths = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0, n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    lengths[i][j] = before[i] == after[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
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
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
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

// PATCH-2026-05-08: wave2-chat-ux — ToolPillView for role=tool messages
struct ToolPillView: View {
    var message: ChatMessage
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meta: ChatMessageMetadata? { message.metadata }
    private var toolName: String { meta?.toolName ?? "tool" }
    private var outcome: ToolPillPresentation.Outcome {
        ToolPillPresentation.outcome(ok: meta?.ok)
    }
    private var durationText: String { ToolPillPresentation.durationText(meta?.durationMs) }
    private var resultSummary: String { meta?.resultSummary ?? "" }

    private var icon: String {
        switch toolName {
        case "read_file", "list_dir": return "doc.text.magnifyingglass"
        case "write_file": return "square.and.pencil"
        case "bash": return "terminal"
        case "grep": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    private var inputOneLiner: String {
        guard let json = meta?.inputJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let parts = obj.map { k, v in "\(k)=\(v)" }.joined(separator: " ")
        return parts.truncated(to: 80, keeping: 77)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed pill
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .easeOut(duration: 0.15), reduceMotion: reduceMotion
                )) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(toolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !inputOneLiner.isEmpty {
                        Text(inputOneLiner)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // Duration badge — omitted entirely when unknown.
                    if !durationText.isEmpty {
                        Text(durationText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // A missing outcome is pending/unknown, never implicit success.
                    Image(systemName: outcome.icon)
                        .font(.caption2)
                        .foregroundStyle(outcome.color)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: 560, alignment: .leading)

            // Expanded detail card
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let json = meta?.inputJSON {
                        // Fix 4: cap display strings so large payloads don't materialise fully in the view
                        let displayJSON = json.truncated(to: 8000, suffix: "\n…[truncated]")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    if !resultSummary.isEmpty {
                        let displayResult = resultSummary.truncated(to: 8000, suffix: "\n…[truncated]")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Result")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayResult)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    // Inline diff for write_file
                    if toolName == "write_file", let before = meta?.beforeContent, let after = meta?.afterContent {
                        ToolDiffView(before: before, after: after)
                    }
                }
                .padding(10)
                .frame(maxWidth: 560, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 24) // indent tool pills from left margin
    }
}

// PATCH-2026-05-08: wave2-chat-ux — unified diff viewer for write_file expanded view
struct ToolDiffView: View {
    var before: String
    var after: String

    private var diffLines: [String] {
        ToolDiffPresentation.lines(before: before, after: after)
    }

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
