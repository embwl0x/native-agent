import Foundation
import PersistenceCore
// Blueprint: | `TurnTraceReadProjection.swift` | `TurnTraceRow`, `TurnTraceGrouping`, `TurnTraceReplayReader`, `TurnInspectorGrouping`; PersistenceCore framing and TurnTraceEvent decoding shared by replay, recent, Doctor, recovery and guarded append reads; reports read coverage before window/kind policies; decoded terminal matching is independent of strict recovery coverage validation |

/// Stable chronological evidence and metrics shared by the Inspector and phone summaries.
public struct TurnTraceGroup: Identifiable, Sendable {
    public let id: String
    public let surface: String?
    public let sessionId: String?
    public let events: [TurnTraceEvent]
    public let startedAt: Date
    public let lastAt: Date
    public var eventCount: Int { events.count }
    public var wallMs: Int { max(0, Int(lastAt.timeIntervalSince(startedAt) * 1000)) }
    public let llmTokens: Int?
    public let ttftMs: Int?
}

public enum TurnTraceGrouping {
    public static func group(_ events: [TurnTraceEvent]) -> [TurnTraceGroup] {
        guard !events.isEmpty else { return [] }
        // Carry the original arrival index so ties (same ts — persisted ts
        // collapses to whole seconds) preserve INPUT/FILE order rather than
        // relying on an unstable sort. Live arrival order == emission order;
        // replay file order == append order; both are the true story order.
        var byTurn: [String: [(index: Int, event: TurnTraceEvent)]] = [:]
        for (i, ev) in events.enumerated() { byTurn[ev.turnId, default: []].append((i, ev)) }

        var cards: [TurnTraceGroup] = []
        cards.reserveCapacity(byTurn.count)
        for (turnId, group) in byTurn {
            // Chronological by ts; ties broken by ORIGINAL ARRIVAL INDEX so the
            // order is stable + deterministic even when timestamps are equal.
            let sortedPairs = group.sorted {
                if $0.event.ts != $1.event.ts { return $0.event.ts < $1.event.ts }
                return $0.index < $1.index
            }
            let sorted = sortedPairs.map(\.event)
            // A group is only ever built from at least one event, but an empty
            // one must skip the turn rather than trap the inspector.
            guard let started = sorted.first?.ts, let last = sorted.last?.ts else { continue }
            // Surface/session: take the first non-nil we see (they're turn-wide).
            let surface = sorted.lazy.compactMap { $0.surface }.first
            let session = sorted.lazy.compactMap { $0.sessionId }.first
            let (tokens, ttft) = llmSummary(sorted)
            cards.append(TurnTraceGroup(
                id: turnId,
                surface: surface,
                sessionId: session,
                events: sorted,
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

    private static func intValue(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let n): return Int(n)
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }

}

public struct TurnTraceReplayReader {
    static let replayCache = TurnTraceReplayCache()

    /// Resolve the per-day file path under the live (or overridden) trace root.
    /// Uses `TurnTracePersistLane.path(for:)`'s resolver so live + replay read the same
    /// location.
    public static func fileURL(for date: Date, root: URL) -> URL {
        TurnTracePersistLane.fileURL(for: date, root: root)
    }
    public typealias ReadResult = (events: [TurnTraceEvent], report: JSONLReadReport)

    /// Missing files are empty; read failures throw and damaged framing stays in the report.
    public static func read(_ url: URL) async throws -> ReadResult {
        let key = url.resolvingSymlinksInPath().path
        let before = TurnTraceReplayCache.fileStamp(url)
        if let cached = replayCache.lookup(key: key, stamp: before) { return cached }
        let result: ReadResult = before == .absent ? ([], .clean) : try parse(Data(contentsOf: url))
        if let before, before.byteCount <= TurnTraceReplayCache.maximumCacheableBytes,
           before == TurnTraceReplayCache.fileStamp(url) {
            replayCache.store(key: key, stamp: before, result: result)
        }
        return result
    }

    static func parse(_ data: Data) -> ReadResult {
        let read = SwiftNativePersistenceCore.decodeJSONL(data) {
            TurnTraceEvent(persistedJSONRow: $0, physicalByteCount: $1)
        }
        return (read.rows, read.report)
    }

    /// Positive terminal evidence among decoded rows. Recovery callers must
    /// separately validate coverage before concluding a damaged feed is settled.
    static func containsTerminal(forTurn turnId: String, in events: [TurnTraceEvent], status: String? = nil) -> Bool {
        events.contains { event in
            guard event.turnId == turnId, TurnTraceEvent.isTerminalKind(event.kind) else { return false }
            guard let status else { return true }
            guard case .object(let payload) = event.payload else { return false }
            return payload["status"] == .string(status)
        }
    }

    static func decode(_ rows: [JSONValue], report: JSONLReadReport) -> ReadResult {
        let events = rows.compactMap(TurnTraceEvent.init(jsonRow:))
        var report = report
        report.malformedLineCount += rows.count - events.count
        return (events, report)
    }

    static func tail(_ url: URL, limit: Int, maxBytes: Int) async throws
        -> (events: [TurnTraceEvent], report: JSONLReadReport, bytesRead: Int, truncated: Bool) {
        let read = try await SwiftNativePersistenceCore().tailJSONLReadReceipt(url, limit: limit, maxBytes: maxBytes)
        let result = decode(read.rows, report: JSONLReadReport(
            malformedLineCount: read.malformedJSONRowCount, physicalLineCount: read.physicalRowsScanned))
        return (result.events, result.report, read.bytesRead, read.truncatedToByteWindow)
    }
}

/// Small process-wide cache for the two day files used by the recurring mobile
/// summary pass. Yesterday is immutable and today's file changes only when a
/// turn emits trace rows, so reparsing both every 30 seconds was pure idle CPU.
/// Stat-strength identity keeps the append-only file authoritative; files over
/// 2 MiB are deliberately not retained to bound decoded-event memory when the
/// user browses an unusually large historical day.
final class TurnTraceReplayCache: @unchecked Sendable {
    typealias Result = TurnTraceReplayReader.ReadResult

    enum FileStamp: Equatable {
        case absent
        case present(device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int)

        var byteCount: Int64 {
            if case .present(_, _, let size, _, _) = self { return size }
            return 0
        }
    }

    static let maximumCacheableBytes: Int64 = 2 * 1_024 * 1_024
    static let maximumEntries = 3

    private struct Entry {
        let stamp: FileStamp
        let result: Result
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    static func fileStamp(_ url: URL) -> FileStamp? {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return .present(
                device: info.st_dev,
                inode: info.st_ino,
                size: Int64(info.st_size),
                seconds: info.st_mtimespec.tv_sec,
                nanoseconds: info.st_mtimespec.tv_nsec
            )
        }
        return errno == ENOENT ? .absent : nil
    }

    func lookup(key: String, stamp: FileStamp?) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let stamp, let entry = entries[key], entry.stamp == stamp else { return nil }
        return entry.result
    }

    func store(key: String, stamp: FileStamp, result: Result) {
        lock.lock()
        defer { lock.unlock() }
        guard stamp.byteCount <= Self.maximumCacheableBytes else { return }
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maximumEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(stamp: stamp, result: result)
    }

}

/// One parsed turn-trace row, reduced to the envelope the Doctor rows need.
public struct TurnTraceRow: Sendable {
    public let kind: String
    public let ts: Date
    public let turnId: String
    public let sessionId: String?
    public let surface: String?
    public let payload: [String: JSONValue]
}

extension TurnTraceReplayReader {
    /// Validate the retained physical window before applying the Doctor's kind/time policy.
    public static func scan(
        _ path: URL, budget: Int, floor: Date, kinds: Set<String>, handle: (TurnTraceRow) -> Void
    ) async -> (truncated: Bool, malformedLines: Int, matchedRows: Int)? {
        guard let read = try? await tail(path, limit: Int.max, maxBytes: budget) else { return nil }
        var matchedRows = 0
        for event in read.events where kinds.contains(event.kind) && event.ts >= floor {
            matchedRows += 1
            let payload: [String: JSONValue] = if case .object(let fields) = event.payload { fields } else { [:] }
            handle(TurnTraceRow(kind: event.kind, ts: event.ts, turnId: event.turnId,
                sessionId: event.sessionId, surface: event.surface, payload: payload))
        }
        return (read.truncated, read.report.malformedLineCount, matchedRows)
    }
}


// Inspector row labels and styling; ordering and metrics belong to TurnTrace.

// MARK: - Event status

/// Rendered status for one row's status dot / chip color. Derived from the
/// event's payload (`status` / `phase` fields), never from raw content.
public enum InspectorRowStatus: String, Equatable, Sendable {
    case ok
    case failed
    case running
    case neutral

    /// Map onto the app's existing `NativeAgentTheme.statusColor` vocabulary
    /// ("ok" / "fail" / "warn" / else). Keeps the Inspector consistent with the
    /// rest of the app's status coloring without introducing new tokens.
    public var themeStatus: String {
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
public struct InspectorEventRow: Identifiable, Equatable, Sendable {
    public let id: String
    /// The raw event kind, e.g. "tool.dispatch", "llm.call", "assembly.stage".
    public let kind: String
    public let ts: Date
    public let status: InspectorRowStatus
    /// Compact one-line label (e.g. tool name, stage name, "12.3k tok").
    public let title: String
    /// Duration in ms when the event carries one (tool end, etc.), else nil.
    public let durationMs: Int?
    /// Whether this row can expand to show detail lines.
    public let isExpandable: Bool
    /// Key/value detail lines shown when the row is expanded. Already redacted +
    /// bounded at emission; we only pretty-print them here.
    public let detailLines: [DetailLine]

    public struct DetailLine: Identifiable, Equatable, Sendable {
        // Deterministic id (label) so SwiftUI row identity + expansion state is
        // STABLE across recompute. A turn never carries two detail lines with
        // the same label, so the label alone is unique within a row.
        public var id: String { label }
        public let label: String
        public let value: String
    }

    /// Short chip text for the kind (drops the namespace prefix for density).
    public var kindChip: String {
        if let dot = kind.firstIndex(of: ".") {
            return String(kind[kind.index(after: dot)...])
        }
        return kind
    }
}

// MARK: - InspectorTurnCard

/// One turn's worth of events, grouped + summarized. Newest turn renders on top
/// (see `TurnInspectorGrouping.group`); rows within are chronological.
public struct InspectorTurnCard: Identifiable, Equatable, Sendable {
    public let id: String          // turnId
    public let surface: String?
    public let sessionId: String?
    /// Chronological rows (oldest → newest within the turn).
    public let rows: [InspectorEventRow]
    /// Earliest event timestamp in the turn (drives newest-turn-on-top sort).
    public let startedAt: Date
    /// Latest event timestamp in the turn.
    public let lastAt: Date

    // Summary line fields.
    public let eventCount: Int
    /// Total wall time across the turn's events, in milliseconds.
    public let wallMs: Int
    /// Total LLM tokens (input + output) summed across llm.call events, when any.
    public let llmTokens: Int?
    /// First TTFT (ms) observed on an llm.call event, when present.
    public let ttftMs: Int?
}

// MARK: - TurnInspectorGrouping

/// Pure transform: a flat event list → per-turn cards, newest turn first.
public enum TurnInspectorGrouping {

    /// Group `events` by `turnId`, build a card per turn, and sort cards so the
    /// most recently STARTED turn is first (matches the live "newest on top"
    /// cascade and the replay view's reverse-chronological reading).
    ///
    /// Within a turn rows are sorted by `ts` ascending (chronological story).
    /// Events with turnId "unknown" are still grouped (under that id) so a
    /// direct-engine-caller turn is visible rather than silently dropped.
    public static func group(_ events: [TurnTraceEvent]) -> [InspectorTurnCard] {
        cards(TurnTraceGrouping.group(events))
    }

    public static func cards(_ groups: [TurnTraceGroup]) -> [InspectorTurnCard] {
        groups.map { group in
            InspectorTurnCard(
                id: group.id, surface: group.surface, sessionId: group.sessionId,
                rows: group.events.enumerated().map { offset, event in
                    makeRow(event, id: "\(group.id)#\(offset)")
                },
                startedAt: group.startedAt, lastAt: group.lastAt,
                eventCount: group.eventCount, wallMs: group.wallMs,
                llmTokens: group.llmTokens, ttftMs: group.ttftMs
            )
        }
    }

    // MARK: Row construction (per-kind shaping)

    /// Build a row for `ev`. `id` is supplied by the caller (deterministic:
    /// turnId + chronological position) so SwiftUI identity is stable across
    /// recompute. A default UUID id is provided for direct unit-test callers
    /// that don't care about identity stability.
    public static func makeRow(_ ev: TurnTraceEvent, id: String = UUID().uuidString) -> InspectorEventRow {
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
            add("purpose", "purpose")
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
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
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
