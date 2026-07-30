import Foundation
import PersistenceCore

// MARK: - Turn Inspector W3 — testable grouping + replay-parse model
//
// Pure, UI-free types that turn a flat stream of `TurnTraceEvent`s (from the
// live `TurnTraceBus` OR a replayed per-day JSONL file) into the per-turn cards
// the Inspector tab renders. ALL grouping / ordering / summary logic lives here
// so it can be unit-tested without a SwiftUI view body (the brief's
// "extract the grouping logic into a testable type").
//
// The view layer (InspectorView.swift / TurnInspectorStore.swift) only OWNS the
// event buffer and calls `TurnInspectorGrouping.group(_:)` to render. Nothing
// here touches the bus, the hot path, or disk — `TurnTraceReplayReader` is the
// one IO type and it reads off the main actor by contract (callers hop a
// background task).

// MARK: - Event status

/// Rendered status for one row's status dot / chip color. Derived from the
/// event's payload (`status` / `phase` fields), never from raw content.
enum InspectorRowStatus: String, Equatable {
    case ok
    case failed
    case running
    case neutral

    /// Map onto the app's existing `NativeAgentTheme.statusColor` vocabulary
    /// ("ok" / "fail" / "warn" / else). Keeps the Inspector consistent with the
    /// rest of the app's status coloring without introducing new tokens.
    var themeStatus: String {
        switch self {
        case .ok: return "ok"
        case .failed: return "fail"
        case .running: return "warn"
        case .neutral: return "info"
        }
    }
}

// MARK: - InspectorEventRow

/// One event in a turn's timeline, flattened for display. Built purely from a
/// `TurnTraceEvent`; carries the redacted previews already present in the event
/// payload (NEVER re-derives or re-emits content).
struct InspectorEventRow: Identifiable, Equatable {
    let id: String
    /// The raw event kind, e.g. "tool.dispatch", "llm.call", "assembly.stage".
    let kind: String
    let ts: Date
    let status: InspectorRowStatus
    /// Compact one-line label (e.g. tool name, stage name, "12.3k tok").
    let title: String
    /// Duration in ms when the event carries one (tool end, etc.), else nil.
    let durationMs: Int?
    /// Whether this row can expand to show detail lines.
    let isExpandable: Bool
    /// Key/value detail lines shown when the row is expanded. Already redacted +
    /// bounded at emission; we only pretty-print them here.
    let detailLines: [DetailLine]

    struct DetailLine: Identifiable, Equatable {
        // Deterministic id (label) so SwiftUI row identity + expansion state is
        // STABLE across recompute. A turn never carries two detail lines with
        // the same label, so the label alone is unique within a row.
        var id: String { label }
        let label: String
        let value: String
    }

    /// Short chip text for the kind (drops the namespace prefix for density).
    var kindChip: String {
        if let dot = kind.firstIndex(of: ".") {
            return String(kind[kind.index(after: dot)...])
        }
        return kind
    }
}

// MARK: - InspectorTurnCard

/// One turn's worth of events, grouped + summarized. Newest turn renders on top
/// (see `TurnInspectorGrouping.group`); rows within are chronological.
struct InspectorTurnCard: Identifiable, Equatable {
    let id: String          // turnId
    let surface: String?
    let sessionId: String?
    /// Chronological rows (oldest → newest within the turn).
    let rows: [InspectorEventRow]
    /// Earliest event timestamp in the turn (drives newest-turn-on-top sort).
    let startedAt: Date
    /// Latest event timestamp in the turn.
    let lastAt: Date

    // Summary line fields.
    var eventCount: Int { rows.count }
    /// Total wall time across the turn's events, in milliseconds.
    var wallMs: Int { max(0, Int(lastAt.timeIntervalSince(startedAt) * 1000)) }
    /// Total LLM tokens (input + output) summed across llm.call events, when any.
    let llmTokens: Int?
    /// First TTFT (ms) observed on an llm.call event, when present.
    let ttftMs: Int?
}

// MARK: - TurnInspectorGrouping

/// Pure transform: a flat event list → per-turn cards, newest turn first.
enum TurnInspectorGrouping {

    /// Group `events` by `turnId`, build a card per turn, and sort cards so the
    /// most recently STARTED turn is first (matches the live "newest on top"
    /// cascade and the replay view's reverse-chronological reading).
    ///
    /// Within a turn rows are sorted by `ts` ascending (chronological story).
    /// Events with turnId "unknown" are still grouped (under that id) so a
    /// direct-engine-caller turn is visible rather than silently dropped.
    static func group(_ events: [TurnTraceEvent]) -> [InspectorTurnCard] {
        guard !events.isEmpty else { return [] }
        // Carry the original arrival index so ties (same ts — persisted ts
        // collapses to whole seconds) preserve INPUT/FILE order rather than
        // relying on an unstable sort. Live arrival order == emission order;
        // replay file order == append order; both are the true story order.
        var byTurn: [String: [(index: Int, event: TurnTraceEvent)]] = [:]
        for (i, ev) in events.enumerated() { byTurn[ev.turnId, default: []].append((i, ev)) }

        var cards: [InspectorTurnCard] = []
        cards.reserveCapacity(byTurn.count)
        for (turnId, group) in byTurn {
            // Chronological by ts; ties broken by ORIGINAL ARRIVAL INDEX so the
            // order is stable + deterministic even when timestamps are equal.
            let sortedPairs = group.sorted {
                if $0.event.ts != $1.event.ts { return $0.event.ts < $1.event.ts }
                return $0.index < $1.index
            }
            let sorted = sortedPairs.map(\.event)
            // Deterministic per-row id: turnId + chronological position. Stable
            // across recompute so SwiftUI keeps row identity + expansion state.
            let rows = sorted.enumerated().map { offset, ev in
                makeRow(ev, id: "\(turnId)#\(offset)")
            }
            let started = sorted.first!.ts
            let last = sorted.last!.ts
            // Surface/session: take the first non-nil we see (they're turn-wide).
            let surface = sorted.lazy.compactMap { $0.surface }.first
            let session = sorted.lazy.compactMap { $0.sessionId }.first
            let (tokens, ttft) = llmSummary(sorted)
            cards.append(InspectorTurnCard(
                id: turnId,
                surface: surface,
                sessionId: session,
                rows: rows,
                startedAt: started,
                lastAt: last,
                llmTokens: tokens,
                ttftMs: ttft
            ))
        }
        // Newest STARTED turn on top. Tie-break by turnId for determinism.
        return cards.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id > $1.id
        }
    }

    /// Sum input+output tokens across llm.call events and pick the first TTFT.
    private static func llmSummary(_ events: [TurnTraceEvent]) -> (tokens: Int?, ttftMs: Int?) {
        var tokenTotal = 0
        var sawTokens = false
        var ttft: Int? = nil
        for ev in events where ev.kind == "llm.call" {
            guard case .object(let p) = ev.payload else { continue }
            // Keys match LLMCallTelemetry's bus payload exactly (camelCase). No
            // snake_case fallback — that would risk double-counting if both ever
            // appeared, and the emitter only ever writes camelCase.
            if let n = intValue(p["inputTokens"]) { tokenTotal += n; sawTokens = true }
            if let n = intValue(p["outputTokens"]) { tokenTotal += n; sawTokens = true }
            if ttft == nil {
                ttft = intValue(p["ttftMs"])
            }
        }
        return (sawTokens ? tokenTotal : nil, ttft)
    }

    // MARK: Row construction (per-kind shaping)

    /// Build a row for `ev`. `id` is supplied by the caller (deterministic:
    /// turnId + chronological position) so SwiftUI identity is stable across
    /// recompute. A default UUID id is provided for direct unit-test callers
    /// that don't care about identity stability.
    static func makeRow(_ ev: TurnTraceEvent, id: String = UUID().uuidString) -> InspectorEventRow {
        let p = objectPayload(ev.payload)
        let status = rowStatus(kind: ev.kind, payload: p)
        let duration = intValue(p["durationMs"])
        let title = rowTitle(kind: ev.kind, payload: p)
        let details = detailLines(kind: ev.kind, payload: p)
        // Only tool.dispatch + file.touch + assembly.stage carry useful detail
        // worth an expander; everything else stays a one-liner.
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
        if case .string(let s)? = p["status"] {
            switch s.lowercased() {
            case "ok", "success", "succeeded": return .ok
            case "failed", "error", "denied": return .failed
            case "running", "begin", "in_progress": return .running
            default: break
            }
        }
        if case .string(let phase)? = p["phase"] {
            switch phase.lowercased() {
            case "begin", "start": return .running
            case "end", "done": return .ok
            default: break
            }
        }
        return .neutral
    }

    private static func rowTitle(kind: String, payload p: [String: JSONValue]) -> String {
        switch kind {
        case "tool.dispatch":
            let name = stringValue(p["name"]) ?? stringValue(p["tool"]) ?? "tool"
            let phase = stringValue(p["phase"])
            return phase.map { "\(name) (\($0))" } ?? name
        case "file.touch":
            let tool = stringValue(p["tool"]) ?? "file"
            let mode = stringValue(p["mode"]).map { " · \($0)" } ?? ""
            let count = intValue(p["pathCount"]).map { " · \($0) path\($0 == 1 ? "" : "s")" } ?? ""
            return tool + mode + count
        case "llm.call":
            if let tokens = intValue(p["inputTokens"]) ?? intValue(p["input_tokens"]) {
                let out = intValue(p["outputTokens"]) ?? intValue(p["output_tokens"]) ?? 0
                return "\(tokens) in · \(out) out"
            }
            return stringValue(p["model"]) ?? "llm.call"
        case "assembly.stage":
            let total = intValue(p["systemTotalChars"]) ?? 0
            let recalled = intValue(p["recalledCount"]) ?? 0
            return "system \(total) chars · \(recalled) recalled"
        case "context.snapshot":
            let total = intValue(p["systemTotalChars"]) ?? 0
            let cognitive = boolValue(p["containsCognitiveSubstrate"]) == true
                ? " · cognitive"
                : ""
            return "system \(total) chars\(cognitive)"
        case "stream.tick":
            let chars = intValue(p["chars"]) ?? 0
            let chunks = intValue(p["chunks"]) ?? 0
            return "\(chars) chars · \(chunks) chunks"
        case "thinking.delta":
            return stringValue(p["text"]).map { String($0.prefix(80)) } ?? "thinking"
        case "memory.commit":
            return stringValue(p["id"]).map { "commit \($0)" } ?? "memory.commit"
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
            // paths is an array — render each.
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
            if let tools = stringArray(p["toolNames"]), !tools.isEmpty {
                out.append(.init(label: "tools", value: tools.joined(separator: ", ")))
            }
            if let recalled = recalledDisplay(p["recalled"]), !recalled.isEmpty {
                out.append(.init(label: "memories", value: recalled))
            }
        case "llm.call":
            add("model", "model")
            // Keys match LLMCallTelemetry's bus payload exactly.
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

    // MARK: Small JSONValue accessors

    private static func objectPayload(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = value { return o }
        return [:]
    }

    private static func stringValue(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    private static func intValue(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let n): return Int(n)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    private static func boolValue(_ v: JSONValue?) -> Bool? {
        if case .bool(let b)? = v { return b }
        return nil
    }

    private static func stringArray(_ v: JSONValue?) -> [String]? {
        guard case .array(let arr)? = v else { return nil }
        return arr.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
    }

    private static func chunkedString(_ v: JSONValue?) -> String? {
        guard let chunks = stringArray(v) else { return nil }
        return chunks.joined()
    }

    private static func recalledDisplay(_ v: JSONValue?) -> String? {
        guard case .array(let rows)? = v else { return nil }
        let rendered = rows.enumerated().compactMap { index, value -> String? in
            guard case .object(let obj) = value else { return nil }
            let id = stringValue(obj["id"]).map { "\($0): " } ?? "#\(index + 1): "
            let preview = chunkedString(obj["preview"]) ?? displayValue(obj["preview"]) ?? ""
            guard !preview.isEmpty else { return nil }
            return id + preview
        }
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n\n")
    }

    /// Render any leaf payload value as a short display string for a detail line.
    private static func displayValue(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .array, .object:
            // Serialize compactly; already bounded at emission.
            return (try? v?.serialize(pretty: false)) ?? nil
        case .null, .none:
            return nil
        }
    }
}

// MARK: - TurnTraceReplayReader

/// Reads a persisted per-day turn-trace JSONL file and decodes it into events.
/// PARSE-RESILIENT: a malformed line is SKIPPED (never throws past the bad row,
/// never crashes the UI). The 20k-line cap is enforced at write time, so the
/// file is already bounded; the reader additionally guards against an
/// unexpectedly huge file by reading the whole thing once (acceptable: capped).
struct TurnTraceReplayReader {

    /// Resolve the per-day file path under the live (or overridden) trace root.
    /// Mirrors `TurnTracePersistLane.path(for:)` so live + replay read the same
    /// location.
    static func fileURL(for date: Date, root: URL) -> URL {
        root
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("\(dayString(date)).jsonl")
    }

    /// Decode every well-formed JSONL row in `url` into events. Returns an empty
    /// array if the file is absent (no turns recorded that day) — not an error.
    /// Bad rows are counted in `skipped` for diagnostics.
    static func read(_ url: URL) -> (events: [TurnTraceEvent], skipped: Int) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ([], 0)
        }
        return parse(text)
    }

    /// Pure parse of newline-delimited JSON rows. Extracted so it is unit
    /// testable against an in-memory fixture (no file IO).
    static func parse(_ text: String) -> (events: [TurnTraceEvent], skipped: Int) {
        var events: [TurnTraceEvent] = []
        var skipped = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let value = try? JSONValue.parse(Data(line.utf8)),
                  let event = TurnTraceEvent(jsonRow: value) else {
                skipped += 1
                continue
            }
            events.append(event)
        }
        return (events, skipped)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
