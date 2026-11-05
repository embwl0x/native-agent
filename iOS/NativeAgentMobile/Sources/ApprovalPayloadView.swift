import SwiftUI
import CoreFoundation
import NativeAgentShared
import UserNotifications
// Blueprint: | `ApprovalPayloadView.swift` | An approval's words (title, kind, reason) and readable payload fields with the exact Mac-sent details |

typealias PendingApproval = ApprovalRequest

enum ApprovalText {
    @MainActor static var agentDecision: String { "Studio canon is \(iCloudSyncEngine.shared.agentDisplayName)'s to decide." }

    static func kind(_ action: String) -> String {
        let id = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let head = id.split(separator: ".").first.map(String.init) ?? id
        switch head {
        case "self_improvement", "improvement": return "Self-improvement"
        case "skill": return "New skill"
        case "memory", "rem": return "Memory"
        case "autonomy": return "Autonomy"
        default: return id.isEmpty ? "Before I go ahead" : ToolActivityPresentation.title(id)
        }
    }

    static func title(_ approval: PendingApproval) -> String {
        approval.title.isEmpty ? ToolActivityPresentation.title(approval.action)
            : ToolActivityPresentation.approvalText(approval.title, tool: approval.action)
    }

    static func reason(_ approval: PendingApproval) -> String? {
        approval.reason.map { readable(ToolActivityPresentation.approvalText($0, tool: approval.action)) }
    }

    static func readable(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = text.firstMatch(of: /^\[[A-Za-z0-9_.\-]+\]\s*/) { text.removeSubrange(tag.range) }
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let marks = line.firstMatch(of: /^#{1,6}\s*/) {
                line.removeSubrange(marks.range)
                if !line.contains(" "), line.contains(where: { "-_.".contains($0) }) { continue }
            }
            line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Payload preview

/// Show readable outgoing fields before approval so consent is informed; retain exact raw details and never synthesize missing payloads.
struct PayloadPreview: View {
    let approval: PendingApproval
    var maxLines = 6
    @State private var showsDetails = false
    @State private var lines: [Line]?

    static let missingLine = "Full details appear once your Mac sends them."

    var payload: String? {
        guard let preview = approval.payloadPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else { return nil }
        return preview
    }

    var body: some View {
        Group {
        if let payload {
            VStack(alignment: .leading, spacing: 6) {
                if let lines {
                    ForEach(Array(lines.prefix(maxLines).enumerated()), id: \.offset) { _, line in
                        (Text(line.label + ": ").foregroundStyle(AlivePalette.secondary)
                            + Text(line.value).foregroundStyle(AlivePalette.text))
                            .font(.subheadline)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(ApprovalText.readable(payload).components(separatedBy: "\n\n").first ?? payload)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let hidden = max(0, (lines?.count ?? 0) - maxLines)
                Button(hidden > 0 ? "Details \u{00b7} \(hidden) more" : "Details") { showsDetails = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHint("Shows everything your Mac sent for this request")
            }
            .sheet(isPresented: $showsDetails) {
                ApprovalDetailsSheet(title: ApprovalText.title(approval),
                                     payload: payload) { showsDetails = false }
            }
        } else {
            Text(Self.missingLine)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
        .onChange(of: payload, initial: true) { _, payload in
            lines = payload.flatMap(Self.readableLines)
        }
    }

    struct Line: Equatable {
        let label: String
        let value: String
    }

    /// Non-object payloads need the Mac's preview; connector input takes precedence for readable objects.
    static func readableLines(_ payload: String) -> [Line]? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var body = object
        for key in ["input", "arguments", "args", "params", "parameters"] {
            if let inner = object[key] as? [String: Any], !inner.isEmpty { body = inner; break }
        }
        var lines: [Line] = []
        for key in readingOrder(body.keys) where !isID(key) {
            if let nested = body[key] as? [String: Any] {
                for inner in readingOrder(nested.keys) where !isID(inner) {
                    if let value = words(nested[inner]) { lines.append(Line(label: label(inner), value: value)) }
                }
            } else if let value = words(body[key]) {
                lines.append(Line(label: label(key), value: value))
            }
        }
        return lines
    }

    /// Put who and where before content to match how the user reads an envelope.
    private static func readingOrder<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        let lead = ["to", "recipient", "recipients", "channel", "chat", "calendar", "list", "account",
                    "cc", "bcc", "subject", "title", "name", "when", "date", "start", "start_date",
                    "startdate", "end", "end_date", "enddate", "message", "text", "body", "content", "notes"]
        func rank(_ key: String) -> Int {
            let flat = key.lowercased().replacingOccurrences(of: "-", with: "_")
            return lead.firstIndex(of: flat) ?? lead.firstIndex(of: flat.replacingOccurrences(of: "_", with: "")) ?? lead.count
        }
        return keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    private static func isID(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "id" || lower.hasSuffix("_id") || lower.hasSuffix("-id") || lower.hasSuffix("uuid")
            || (key.hasSuffix("Id") || key.hasSuffix("ID")) && key.count > 2
    }

    private static func label(_ key: String) -> String {
        var spaced = ""
        for (index, char) in key.enumerated() {
            if index > 0, char.isUppercase, let last = spaced.last, last.isLowercase { spaced.append(" ") }
            spaced.append(char)
        }
        let words = AliveWords.humanized(spaced.lowercased())
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Keep nested structures in Details so the card stays readable.
    private static func words(_ value: Any?) -> String? {
        let text: String
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            text = UserDisplayFormatters.parseISOTimestamp(trimmed) != nil ? AliveWords.readable(trimmed) : trimmed
        case let number as NSNumber:
            text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
        case let list as [Any]:
            let items = list.compactMap { $0 is [String: Any] || $0 is [Any] ? nil : words($0) }
            guard !items.isEmpty else { return nil }
            text = items.count > 4 ? items.prefix(4).joined(separator: ", ") + ", +\(items.count - 4) more"
                : items.joined(separator: ", ")
        default:
            return nil
        }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "\u{2026}" : flat
    }
}

/// Details preserve exactly what the Mac sent.
private struct ApprovalDetailsSheet: View {
    let title: String
    let payload: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            AlivePage(title: title, line: "What your Mac sent for this request.", style: .pushed) {
                Section {
                    Text(payload)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AlivePalette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar { Button("Done", action: onDone) }
        }
    }
}
