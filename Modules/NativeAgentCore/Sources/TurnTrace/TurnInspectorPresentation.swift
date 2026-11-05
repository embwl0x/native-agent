import Foundation
import PersistenceCore
// Blueprint: | `TurnInspectorPresentation.swift` | Shared Inspector rows and bounded redacted details |

/// Rendered status for one row's status dot / chip color. Derived from the event's payload (`status` / `phase` fields), never from raw content.
public enum InspectorRowStatus: String, Equatable, Sendable {
    case ok
    case failed
    case running
    case neutral

    public var themeStatus: String {
        switch self {
        case .ok: return "ok"
        case .failed: return "fail"
        case .running: return "warn"
        case .neutral: return "info"
        }
    }
}

/// Reuse redacted event previews; presentation must not derive or emit new content.
public struct InspectorEventRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let ts: Date
    public let status: InspectorRowStatus
    public let title: String
    public let durationMs: Int?
    public let isExpandable: Bool
    /// Only pretty-print details already bounded and redacted at emission.
    public let detailLines: [DetailLine]

    public struct DetailLine: Identifiable, Equatable, Sendable {
        // Unique labels preserve row identity and expansion state across recomputation.
        public var id: String { label }
        public let label: String
        public let value: String
    }

    public var kindChip: String {
        if let dot = kind.firstIndex(of: ".") {
            return String(kind[kind.index(after: dot)...])
        }
        return kind
    }
}

/// Group from shared evidence so newest-first cards retain chronological rows.
public struct InspectorTurnCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let surface: String?
    public let sessionId: String?
    public let rows: [InspectorEventRow]
    /// Earliest timestamp controls newest-started-turn order.
    public let startedAt: Date
    public let lastAt: Date

    public let eventCount: Int
    public let wallMs: Int
    public let llmTokens: Int?
    public let ttftMs: Int?
}

public enum TurnInspectorGrouping {

    public static func group(_ events: [TurnTraceEvent]) -> [InspectorTurnCard] {
        cards(TurnTraceGrouping.group(events))
    }

    public static func cards(_ groups: [TurnTraceGroup]) -> [InspectorTurnCard] {
        groups.map { group in
            InspectorTurnCard(
                id: group.id, surface: group.surface, sessionId: group.sessionId,
                rows: group.events.enumerated().map { offset, event in
                    makeRow(event, id: "\(group.id)#\(offset)", measurementError: offset == 0 ? group.measurementError : nil)
                },
                startedAt: group.startedAt, lastAt: group.lastAt,
                eventCount: group.eventCount, wallMs: group.wallMs,
                llmTokens: group.llmTokens, ttftMs: group.ttftMs
            )
        }
    }

    /// Caller-supplied turn/position ids preserve SwiftUI identity; omitted ids use a UUID.
    public static func makeRow(_ ev: TurnTraceEvent, id: String = UUID().uuidString, measurementError: String? = nil) -> InspectorEventRow {
        let p = (ev.payload.objectValue ?? [:])
        var measurementError = measurementError
        let title: String
        do { title = try rowTitle(kind: ev.kind, payload: p) }
        catch {
            title = "Token measurements unavailable"
            measurementError = error.localizedDescription
        }
        let status = measurementError == nil ? rowStatus(kind: ev.kind, payload: p) : .failed
        let duration = p["durationMs"]?.integerValue.flatMap(Int.init(exactly:))
        var details = detailLines(kind: ev.kind, payload: p)
        if let measurementError { details.append(.init(label: "Measurement error", value: measurementError)) }
        // Expand only projected details so plain events stay compact.
        let expandable = !details.isEmpty
        return InspectorEventRow(
            id: id,
            kind: ev.kind,
            ts: ev.ts,
            status: status,
            title: title,
            durationMs: duration,
            isExpandable: expandable,
            detailLines: details
        )
    }

    private static func rowStatus(kind: String, payload p: [String: JSONValue]) -> InspectorRowStatus {
        if kind == "tool.dispatch", let verdict = p["receipt"]?.objectValue?["resultClass"]?.stringValue {
            return p["phase"] == .string("begin") ? .running
                : ["succeeded": .ok, "failed": .failed, "refused": .failed, "timeout": .failed][verdict] ?? .neutral
        }
        switch p["status"]?.stringValue?.lowercased() {
        case "ok", "success", "succeeded": return .ok
        case "failed", "error", "denied": return .failed
        case "running", "begin", "in_progress": return .running
        default: break
        }
        switch p["phase"]?.stringValue?.lowercased() {
        case "begin", "start": return .running
        case "end", "done": return .ok
        default: return .neutral
        }
    }

    private static func rowTitle(kind: String, payload p: [String: JSONValue]) throws -> String {
        switch kind {
        case "tool.dispatch":
            let name = p["name"]?.stringValue ?? p["tool"]?.stringValue ?? "tool"
            let phase = p["phase"]?.stringValue
            return phase.map { "\(name) (\($0))" } ?? name
        case "file.touch":
            let tool = p["tool"]?.stringValue ?? "file"
            let mode = p["mode"]?.stringValue.map { " · \($0)" } ?? ""
            let count = p["pathCount"]?.integerValue.flatMap(Int.init(exactly:)).map { " · \($0) path\($0 == 1 ? "" : "s")" } ?? ""
            return tool + mode + count
        case "llm.call":
            let tokens = try TraceMeasurement.tokens(p)
            let input = tokens.input.map { String($0) } ?? "unavailable"
            let output = tokens.output.map { String($0) } ?? "unavailable"
            return "\(input) in · \(output) out"
        case "assembly.stage":
            let total = p["systemTotalChars"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
            let recalled = p["recalledCount"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
            return "system \(total) chars · \(recalled) recalled"
        case "context.snapshot":
            let total = p["systemTotalChars"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
            let cognitive = p["containsCognitiveSubstrate"]?.boolValue == true
                ? " · cognitive"
                : ""
            return "system \(total) chars\(cognitive)"
        case "stream.tick":
            // A tick without a call is movement that is no call: a thought or held text.
            guard let call = p["call"]?.stringValue, let bytes = p["bytes"]?.integerValue else { return "moving" }
            return "writing \(call) · \(bytes) bytes"
        case "thinking.delta":
            return p["text"]?.stringValue.map { String($0.prefix(80)) } ?? "thinking"
        case "memory.commit":
            return p["id"]?.stringValue.map { "commit \($0)" } ?? "memory.commit"
        case "context.stage":
            return p["stage"]?.stringValue ?? kind
        default:
            return kind
        }
    }

    private static func detailLines(kind: String, payload p: [String: JSONValue]) -> [InspectorEventRow.DetailLine] {
        var out: [InspectorEventRow.DetailLine] = []
        func add(_ label: String, _ key: String) {
            if let v = displayValue(p[key]) {
                out.append(.init(label: label, value: v))
            }
        }
        func addChunked(_ label: String, _ key: String) {
            guard let value = chunkedString(p[key]), !value.isEmpty else { return }
            out.append(.init(label: label, value: value))
        }
        switch kind {
        case "tool.dispatch":
            add("name", "name")
            add("status", "status")
            add("args", "args")
            add("result", "result")
            add("error", "error")
        case "file.touch":
            add("tool", "tool")
            add("mode", "mode")
            if case .array(let arr)? = p["paths"] {
                for (i, v) in arr.enumerated() {
                    if case .string(let s) = v {
                        out.append(.init(label: "path[\(i)]", value: s))
                    }
                }
            }
        case "assembly.stage":
            add("stableChars", "stableChars")
            add("dynamicChars", "dynamicChars")
            add("historyChars", "historyChars")
            add("currentChars", "currentChars")
            add("systemTotalChars", "systemTotalChars")
            add("recalledCount", "recalledCount")
        case "context.snapshot":
            add("model", "model")
            add("runId", "runId")
            add("systemChars", "systemTotalChars")
            add("stableChars", "stableChars")
            add("dynamicChars", "dynamicChars")
            add("userChars", "userMessageChars")
            add("toolSchemas", "toolSchemaCount")
            add("recalled", "recalledCount")
            addChunked("stable", "stablePreview")
            addChunked("dynamic", "dynamicPreview")
            addChunked("system", "systemPreview")
            addChunked("cognitive", "cognitivePreview")
            addChunked("user", "userPreview")
            if let tools = p["toolNames"]?.arrayValue?.compactMap(\.stringValue), !tools.isEmpty {
                out.append(.init(label: "tools", value: tools.joined(separator: ", ")))
            }
            if let recalled = recalledDisplay(p["recalled"]), !recalled.isEmpty {
                out.append(.init(label: "memories", value: recalled))
            }
        case "context.stage":
            add("stage", "stage")
            add("elapsedMs", "elapsedMs")
            add("counts", "counts")
            add("labels", "labels")
            if p["stage"]?.stringValue == "memory.promotion",
               case .object(let counts)? = p["counts"],
               let predicted = counts["surpriseWouldDefer"]?.integerValue.flatMap(Int.init(exactly:)),
               let changed = counts["surpriseChangedOnPrediction"]?.integerValue.flatMap(Int.init(exactly:)),
               let incomplete = counts["surpriseIncompletePredictions"]?.integerValue.flatMap(Int.init(exactly:)) {
                var flags: [String: JSONValue] = [:]
                if case .object(let found)? = p["flags"] { flags = found }
                var labels: [String: JSONValue] = [:]
                if case .object(let found)? = p["labels"] { labels = found }
                let deferred = flags["surpriseDeferred"]?.boolValue == true
                let lower = labels["surpriseLowerBound"]?.stringValue ?? "0"
                let bar = labels["surpriseCostBar"]?.stringValue ?? "1"
                out.append(.init(label: "memory deferral",
                    value: (deferred ? "Deferred: this turn stays owed and is judged in a batch later. "
                        : "Judged now. ")
                        + """
                            Predicted no-op on \(predicted) turns; changed something on \(changed); not yet labelled \(incomplete). Lower bound \(lower) \
                            against cost bar \(bar).
                            """))
                if flags["surpriseLedgerReadable"]?.boolValue != true {
                    out.append(.init(label: "deferral evidence", value: "Ledger unavailable or incomplete; no prediction can stand on it."))
                }
            }
        case "llm.call":
            add("model", "model")
            add("purpose", "purpose")
            // Keys match LLMCallTraceRecorder's bus payload exactly.
            add("cacheRead", "cacheReadInputTokens")
            add("cacheCreation", "cacheCreationInputTokens")
            add("ttftMs", "ttftMs")
        case "thinking.delta":
            add("text", "text")
            add("redacted", "redacted")
        default:
            break
        }
        return out
    }

    private static func chunkedString(_ v: JSONValue?) -> String? {
        guard let chunks = v?.arrayValue?.compactMap(\.stringValue) else { return nil }
        return chunks.joined()
    }

    private static func recalledDisplay(_ v: JSONValue?) -> String? {
        guard case .array(let rows)? = v else { return nil }
        let rendered = rows.enumerated().compactMap { index, value -> String? in
            guard case .object(let obj) = value else { return nil }
            let id = obj["id"]?.stringValue.map { "\($0): " } ?? "#\(index + 1): "
            let preview = chunkedString(obj["preview"]) ?? displayValue(obj["preview"]) ?? ""
            guard !preview.isEmpty else { return nil }
            return id + preview
        }
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n\n")
    }

    private static func displayValue(_ v: JSONValue?) -> String? {
        if let text = v?.scalarText { return text }
        switch v {
        case .array, .object:
            // Values are already bounded at emission; serialize compactly.
            return (try? v?.serialize(pretty: false)) ?? nil
        default:
            return nil
        }
    }
}
