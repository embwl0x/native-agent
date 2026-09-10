import SwiftUI
import Foundation
import PersistenceCore

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

enum ToolPillPresentation {
    enum Outcome: String, Equatable {
        case pending = "Running"
        case succeeded = "Completed"
        case refused = "Refused"
        case partial = "Partial"
        case connectionFailed = "Connection failed"
        case unknown = "Outcome unknown"
        case failed = "Failed"

        var icon: String {
            switch self {
            case .pending: "clock"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .refused: "hand.raised"
            case .partial: "circle.lefthalf.filled"
            case .connectionFailed: "exclamationmark.triangle"
            case .unknown: "questionmark.circle"
            }
        }

        var color: Color {
            .secondary
        }
    }

    /// Pure projection of the dispatch envelope, never of the transport success bit.
    /// The catch boundary projects AutonomyGateError and MCPSubprocessError to
    /// these exact wire forms; do not search arbitrary result prose for errors.
    static func outcome(toolName: String = "", result: String? = nil, ok: Bool? = nil) -> Outcome {
        guard let result else { return ok == nil ? .pending : .unknown }
        guard let value = try? JSONValue.parse(Data(result.utf8)) else { return .unknown }
        guard case .object(let fields) = value else {
            // read_file returns the file text directly; unknown tools have no
            // registered scalar completion contract.
            if toolName == "read_file", case .string = value { return .succeeded }
            return .unknown
        }
        let status = fields["status"]?.stringValue?.lowercased()
        let error = fields["error"]?.stringValue
        if status == "partial" || fields["partial"] == .bool(true) { return .partial }
        if ["refused", "denied", "rejected"].contains(status ?? "") { return .refused }
        if status == "failed", let error, error.hasPrefix("tool denied: "), fields["reason"] == .string(error) {
            return .refused
        }
        if status == "failed", error == "streamClosed", fields["reason"] == .string("streamClosed") {
            return .connectionFailed
        }
        if fields["streamClosed"] == .bool(true) { return .connectionFailed }
        if fields["isError"] == .bool(true) || fields["ok"] == .bool(false)
            || fields["success"] == .bool(false)
            || ["failed", "failure", "error"].contains(status ?? "") { return .failed }
        if let errorValue = fields["error"], errorValue != .null { return .failed }
        if status == "running" { return .pending }
        if fields["dryRun"] == .bool(true) || fields["dry_run"] == .bool(true) { return .unknown }
        if ["complete", "completed", "delivered", "done", "ok", "passed", "succeeded", "success"].contains(status ?? "") {
            return .succeeded
        }
        return .unknown
    }

    static func title(_ name: String) -> String {
        ["read": "Read a document", "apply_patch": "Edit files", "read_file": "Read a file",
         "codex_message": "Send a coding request", "restart_app": "Restart the app",
         "write_file": "Write a file", "git": "Work with version history", "install_app": "Install the app",
         "shell": "Run a command", "list_dir": "List files", "image_generate": "Create an image",
         "tool_load": "Enable a tool", "bash": "Run a command", "claude_message": "Send a helper request",
         "studio_journal": "Write a working note", "tool_catalog": "Find available tools",
         "omp_message": "Send a helper request", "tool_unload": "Release a tool",
         "invoke_codex": "Ask a coding helper", "read_skill": "Read a skill",
         "desk_breakdown": "Break down a task", "mcp__notes__search": "Search notes"][name] ?? name
    }

    static func target(_ input: String?) -> String {
        guard let input, let value = try? JSONValue.parse(Data(input.utf8)), case .object(let fields) = value else { return "" }
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

    static func summary(outcome: Outcome, input: String?, result: String?) -> String {
        let value = result.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        let fields: [String: JSONValue] = { if case .object(let fields) = value { return fields }; return [:] }()
        let reason = fields["reason"]?.stringValue ?? fields["error"]?.stringValue
        switch outcome {
        case .pending: return "No result yet"
        case .unknown: return "Response received · completion not confirmed"
        case .connectionFailed: return "Connection lost · completion unknown"
        case .refused:
            if reason == "tool denied: fileAccess=read_only blocks write_file" {
                return "Reading only is allowed; file not written."
            }
            return reason ?? "The request was refused."
        case .partial:
            var count = "Partially completed"
            if case .array(let created)? = fields["created"], let input,
               let args = try? JSONValue.parse(Data(input.utf8)), case .object(let args) = args,
               case .array(let children)? = args["children"] {
                count = "\(created.count) of \(children.count) tasks created"
            }
            // Desk breakdown reports "creating child N 'Title': <error>"; say what
            // did not happen and why. The raw reason stays verbatim in Details.
            var why = reason
            if let reason, reason.hasPrefix("creating child "),
               let open = reason.firstIndex(of: "'"),
               let close = reason[reason.index(after: open)...].firstIndex(of: "'") {
                let title = reason[reason.index(after: open)..<close]
                let rest = reason[close...].dropFirst()
                let error = rest.hasPrefix(": ") ? rest.dropFirst(2) : rest
                why = "\(title) not created: \(error)"
            }
            return count + (why.map { " · \($0)" } ?? "")
        case .failed: return reason ?? "The request failed."
        case .succeeded:
            if case .string(let text) = value { return text }
            return fields["summary"]?.stringValue ?? fields["message"]?.stringValue ?? "Completed"
        }
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
    @Environment(\.dynamicTypeSize) private var typeSize

    init(message: ChatMessage, initiallyExpanded: Bool = false) {
        self.message = message
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var meta: ChatMessageMetadata? { message.metadata }
    private var toolName: String { meta?.toolName ?? "tool" }
    private var outcome: ToolPillPresentation.Outcome {
        ToolPillPresentation.outcome(toolName: toolName, result: meta?.resultSummary, ok: meta?.ok)
    }
    private var durationText: String { ToolPillPresentation.durationText(meta?.durationMs) }
    private var resultSummary: String { meta?.resultSummary ?? "" }
    private var title: String { ToolPillPresentation.title(toolName) }
    private var target: String {
        ToolPillPresentation.boundedLine(ToolPillPresentation.target(meta?.inputJSON), limit: 180)
    }
    private var summary: String {
        ToolPillPresentation.boundedLine(
            ToolPillPresentation.summary(outcome: outcome, input: meta?.inputJSON, result: meta?.resultSummary), limit: 240)
    }
    private var textSize: CGFloat { typeSize.isAccessibilitySize ? 19 : 13 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title).fontWeight(.semibold).fixedSize()
                            Spacer(minLength: 0)
                            controls
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                            controls
                        }
                    }
                    if !target.isEmpty {
                        Text(target)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: textSize))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .shellKeyboardTarget(.receipt)
            .onKeyPress(.return) { toggleDetails(); return .handled }
            .onKeyPress(.space) { toggleDetails(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, target, summary, outcome.rawValue, durationText, "Details"].filter { !$0.isEmpty }.joined(separator: ". "))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            // Expanded detail card
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tool: \(toolName)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 24) // indent tool pills from left margin
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Label(outcome.rawValue, systemImage: outcome.icon)
                .foregroundStyle(outcome.color)
                .fixedSize(horizontal: false, vertical: true)
            if !durationText.isEmpty {
                Text(durationText).foregroundStyle(.secondary)
            }
            Label("Details", systemImage: expanded ? "chevron.down" : "chevron.right")
        }
    }

    private func toggleDetails() {
        withAnimation(NativeAgentMotion.respecting(.easeOut(duration: 0.15), reduceMotion: reduceMotion)) {
            expanded.toggle()
        }
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
