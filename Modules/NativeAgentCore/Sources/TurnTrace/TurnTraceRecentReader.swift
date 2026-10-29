import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTraceRecentReader.swift` | Checked recent/day-file reads, historical receipt reconciliation and usage queries; preserves unmatched history, outcomes and read coverage |

/// Reads the writer's day files using its calendar and root overrides.
public struct TurnTraceRecentReader: Sendable {
    public static let maxRows = 2_000
    public static let maxBytes = 8 * 1_024 * 1_024

    public struct Snapshot: Sendable {
        public let sourceURL: URL
        public let events: [TurnTraceEvent]
        public let sourceURLs: [URL]
        public let truncated: Bool
        public let oldestRetainedDay: Date?
        public let malformedRows: Int
        public let trailingPartialLine: Bool
        public var completeSequences: Bool { !truncated && malformedRows == 0 && !trailingPartialLine }

        public init(sourceURL: URL, events: [TurnTraceEvent], sourceURLs: [URL] = [], truncated: Bool = false, oldestRetainedDay: Date? = nil, malformedRows: Int = 0, trailingPartialLine: Bool = false) {
            self.sourceURL = sourceURL
            self.events = events
            self.sourceURLs = sourceURLs.isEmpty ? [sourceURL] : sourceURLs
            self.truncated = truncated
            self.oldestRetainedDay = oldestRetainedDay
            self.malformedRows = malformedRows
            self.trailingPartialLine = trailingPartialLine
        }
    }

    private let lane: TurnTracePersistLane
    private let rowLimit: Int

    /// `rowLimit` widens the tail for a reader that must find one session's
    /// latest turn: on a busy day 2,000 rows can end before it.
    public init(dataRootOverride: URL? = nil, rowLimit: Int = TurnTraceRecentReader.maxRows) {
        self.lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
        self.rowLimit = rowLimit
    }

    /// Unwindowed history shares a tail budget; since reads the complete retained window.
    /// With `holding`, framing is checked before selecting a kind or turn id.
    public func read(now: Date = Date(), history: Bool = false, since: Date? = nil, holding marks: [String] = [], trace: String? = nil, maximumReadBytes: Int = TurnTraceRecentReader.maxBytes) async throws -> Snapshot {
        let sourceURL = lane.path(for: now)
        let paths: [URL]
        var oldestRetainedDay: Date?
        if let trace {
            let filename = String(trace.dropFirst("turn_traces/".count))
            guard trace == "turn_traces/" + filename, filename.hasSuffix(".jsonl"),
                  let day = TurnTracePersistLane.day(from: String(filename.dropLast(6))),
                  filename == TurnTracePersistLane.dayString(from: day) + ".jsonl" else {
                throw PersistenceCoreError.ioFailure("trace must name turn_traces/<yyyy-MM-dd>.jsonl.")
            }
            paths = [sourceURL.deletingLastPathComponent().appendingPathComponent(filename)]
        } else if let since {
            let directory = sourceURL.deletingLastPathComponent()
            let entries = FileManager.default.fileExists(atPath: directory.path)
                ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
            let days = entries.compactMap { path -> (URL, Date)? in
                guard path.pathExtension == "jsonl",
                      let day = TurnTracePersistLane.day(from: path.deletingPathExtension().lastPathComponent), day <= now else { return nil }
                return (path, day)
            }
            oldestRetainedDay = days.map(\.1).min()
            paths = days.filter { $0.1 >= TurnTracePersistLane.dayCalendar.startOfDay(for: since) }
                .map(\.0).sorted { $0.lastPathComponent > $1.lastPathComponent }
        } else {
            paths = (0..<(history ? TurnTraceRetention.defaultKeepDays : 1)).compactMap {
                TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -$0, to: now).map { lane.path(for: $0) }
            }
        }
        var events: [TurnTraceEvent] = []
        var sources: [URL] = []
        var remainingRows = rowLimit
        var remainingBytes = maximumReadBytes
        var truncated = false
        var malformedRows = 0
        var trailingPartialLine = false
        for path in paths {
            guard trace != nil || since != nil || (remainingRows > 0 && remainingBytes > 0) else { truncated = true; break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                if trace != nil { truncated = true }
                continue
            }
            if isDirectory.boolValue {
                throw PersistenceCoreError.ioFailure("turn trace path is a directory: \(path.path)")
            }
            if since != nil || trace != nil {
                sources.append(path)
                let receipt = try await TurnTraceReplayReader.read(path)
                malformedRows += receipt.report.malformedLineCount
                trailingPartialLine = trailingPartialLine || receipt.report.trailingPartialLine
                if !receipt.report.isClean { truncated = true }
                for event in receipt.events {
                    guard marks.isEmpty || marks.contains(event.kind) || marks.contains(event.turnId) else { continue }
                    guard since.map({ event.ts >= $0 }) ?? true, event.ts <= now else { continue }
                    events.append(event)
                }
                continue
            }
            let receipt = try await TurnTraceReplayReader.tail(path, limit: remainingRows, maxBytes: remainingBytes)
            sources.append(path)
            malformedRows += receipt.report.malformedLineCount
            events += receipt.events
            remainingRows -= receipt.report.physicalLineCount
            remainingBytes -= receipt.bytesRead
            truncated = truncated || receipt.truncated || remainingRows <= 0
        }
        return Snapshot(sourceURL: sourceURL, events: events, sourceURLs: sources, truncated: truncated, oldestRetainedDay: oldestRetainedDay, malformedRows: malformedRows, trailingPartialLine: trailingPartialLine)
    }

    /// Turn evidence has one durable owner. Historical ledger rows are removed
    /// only when matched to a retained event, preserving any older outcome.
    public func traceEvidence(
        now: Date = Date(), since: Date? = nil,
        maximumReadBytes: Int = TurnTraceRecentReader.maxBytes
    ) async throws -> (rows: [JSONValue], report: JSONLReadReport, turns: Snapshot, sourceAbsent: Bool) {
        let turns = try await read(now: now, history: true, since: since,
                                   holding: since == nil ? [] : ["llm.call", "provider.noReply", "tool.dispatch", "memory.commit", "context.compact", "turn.plan", "turn.terminal", "work.identified"],
                                   maximumReadBytes: maximumReadBytes)
        let path = lane.resolvedDataRoot().appendingPathComponent("traces/events.jsonl")
        let ledger: (rows: [JSONValue], report: JSONLReadReport)
        if since != nil {
            ledger = try await SwiftNativePersistenceCore.readJSONLReporting(path)
        } else {
            let tail = try await SwiftNativePersistenceCore.tailJSONLReadReceipt(path, limit: rowLimit, maxBytes: maximumReadBytes)
            ledger = (tail.rows, JSONLReadReport(malformedLineCount: tail.malformedJSONRowCount))
        }
        func matchKey(kind: String, payload: [String: JSONValue], date: Date) throws -> Data? {
            let identity: [JSONValue]
            switch kind {
            case "tool.dispatch":
                guard case .object(let receipt)? = payload["receipt"],
                      case .string(let id)? = receipt["id"] else { return nil }
                identity = [.string(id)]
            case "turn.plan":
                guard case .string(let id)? = payload["runId"] else { return nil }
                identity = [.string(id)]
            case "llm.call", "provider.noReply":
                guard case .string(let turn)? = payload["turnId"], !turn.isEmpty, turn != "unknown" else { return nil }
                // Historical calls have no shared id; match their recorded second
                // and measurements, consuming each ledger row at most once.
                let fields = kind == "llm.call"
                    ? ["provider", "model", "surface", "purpose", "streaming", "durationMs", "ttftMs", "inputTokens", "outputTokens"]
                    : ["provider", "surface", "seconds", "events"]
                identity = [.string(turn), .int(Int64(date.timeIntervalSince1970.rounded(.down)))]
                    + fields.map { payload[$0] ?? .null }
            default: return nil
            }
            return try JSONValue.array([.string(kind)] + identity).serializedData(pretty: false)
        }
        var matches: [Data: [Int]] = [:]
        for (index, row) in ledger.rows.enumerated().reversed() {
            guard case .object(let object) = row, case .string(let kind)? = object["kind"],
                  case .object(let payload)? = object["payload"],
                  case .string(let raw)? = object["createdAt"], let date = TurnTraceEvent.parseISO8601(raw),
                  let key = try matchKey(kind: kind, payload: payload, date: date) else { continue }
            matches[key, default: []].append(index)
        }
        var matched: Set<Int> = []
        var rows: [JSONValue] = []
        for event in turns.events {
            guard !event.diagnostic.isEmpty || ["llm.call", "provider.noReply", "tool.dispatch", "turn.plan"].contains(event.kind),
                  case .object(var payload) = event.payload else { continue }
            if event.kind == "tool.dispatch", payload["phase"] != .string("end"), event.diagnostic.isEmpty { continue }
            payload["turnId"] = .string(event.turnId)
            if let key = try matchKey(kind: event.kind, payload: payload, date: event.ts),
               let index = matches[key]?.popLast(), case .object(let legacy) = ledger.rows[index] {
                matched.insert(index)
                if case .object(let older)? = legacy["payload"] { payload = older.merging(payload) { _, current in current } }
                if payload["status"] == nil { payload["status"] = legacy["status"] }
            }
            let title: String
            if let value = event.diagnostic["title"]?.stringValue { title = value }
            else if event.kind == "turn.plan", case .string(let goal)? = payload["goalType"],
               case .string(let mode)? = payload["contextMode"] { title = "\(goal) -> \(mode)" }
            else if case .string(let value)? = payload[event.kind == "tool.dispatch" ? "name" : event.kind == "llm.call" ? "model" : "provider"] { title = value }
            else { title = event.kind }
            let id: String
            if let value = event.diagnostic["id"]?.stringValue { id = value }
            else if event.kind == "tool.dispatch", case .object(let receipt)? = payload["receipt"],
               case .string(let receiptID)? = receipt["id"] { id = receiptID }
            else {
                id = SHA256.hash(data: try event.jsonRow.serializedData(pretty: false))
                    .map { String(format: "%02x", $0) }.joined()
            }
            rows.append(.object([
                "id": .string(id), "kind": .string(event.kind), "title": .string(title),
                "status": event.diagnostic["status"] ?? payload["status"] ?? .string(event.kind == "provider.noReply" ? "failed" : event.kind == "llm.call" ? "unknown" : "ok"),
                "createdAt": event.diagnostic["createdAt"] ?? .string(event.ts.formatted(TurnTraceEvent.fractionalISO8601)),
                "payload": .object(payload),
            ]))
        }
        rows += ledger.rows.enumerated().compactMap { matched.contains($0.offset) ? nil : $0.element }
        var report = ledger.report
        report.malformedLineCount += turns.malformedRows
        report.trailingPartialLine = report.trailingPartialLine || turns.trailingPartialLine
        var dated: [(row: JSONValue, date: Date, index: Int)] = []
        for (index, row) in rows.enumerated() {
            var date = Date.distantPast
            if case .object(let object) = row, case .string(let raw)? = object["createdAt"],
               let parsed = TurnTraceEvent.parseISO8601(raw) { date = parsed }
            dated.append((row, date, index))
        }
        dated.sort { $0.date == $1.date ? $0.index < $1.index : $0.date < $1.date }
        rows = dated.map(\.row)
        return (rows, report, turns,
                turns.sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
                    && !FileManager.default.fileExists(atPath: path.path))
    }

    public func modelCalls(now: Date = Date()) async throws -> JSONValue {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let evidence = try await traceEvidence(now: now, since: weekAgo)
        var calls: [(Date, String, String, Int64?)] = []
        var oldest: Date?
        for row in evidence.rows {
            guard case .object(let object) = row,
                  case .string(let rawDate)? = object["createdAt"],
                  let date = TurnTraceEvent.parseISO8601(rawDate) else {
                throw PersistenceCoreError.ioFailure("Model calls: a trace row has no readable createdAt; inspect the retained trace sources.")
            }
            oldest = min(oldest ?? date, date)
            guard object["kind"] == .string("llm.call"), date <= now,
                  date >= now.addingTimeInterval(-7 * 86_400) else { continue }
            guard case .object(let payload)? = object["payload"] else {
                throw PersistenceCoreError.ioFailure("Model calls: a call has no payload; inspect the retained trace sources.")
            }
            let purpose = if case .string(let value)? = payload["purpose"] { value } else { "other" }
            let turn = if case .string(let value)? = payload["turnId"], !value.isEmpty { value } else { "unknown" }
            let duration = try TraceMeasurement.value(payload["durationMs"], field: "durationMs")
            calls.append((date, purpose, turn, duration))
        }
        let week = evidence.turns
        let rounds = Self.rounds(week.events)
        let windows: [JSONValue] = try [("24h", 86_400.0), ("7d", 7 * 86_400.0)].map { label, seconds in
            let since = now.addingTimeInterval(-seconds)
            let finished = rounds.filter { $0.at >= since }.map(\.rounds)
            var turns: [String: [String: Int64]] = [:]
            var totals: [String: Int64] = [:]
            var durations: [String: Int64] = [:]
            var missingDuration: Int64 = 0
            for (date, purpose, turn, duration) in calls where date >= since {
                turns[turn, default: [:]][purpose, default: 0] += 1
                totals[purpose, default: 0] += 1
                if let duration { durations[purpose] = try TraceMeasurement.add(durations[purpose] ?? 0, duration, field: "durationMs") }
                else { missingDuration += 1 }
            }
            return .object([
                "window": .string(label), "since": .string(since.formatted(.iso8601)),
                "counts_by_purpose": .object(totals.mapValues(JSONValue.int)),
                "per_turn": .array(turns.sorted { $0.key < $1.key }.map {
                    .object(["turn_id": .string($0.key), "counts_by_purpose": .object($0.value.mapValues(JSONValue.int))])
                }),
                "top_five_by_total_ms": .array(durations.sorted {
                    $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
                }.prefix(5).map { .object(["purpose": .string($0.key), "total_ms": .int($0.value)]) }),
                "missing_duration_calls": .int(missingDuration),
                "predates_retained_rows": .bool(oldest.map { since < $0 } ?? true),
                "rounds_per_turn": .object(["turns": .int(Int64(finished.count)),
                    "p50": Self.percentile(finished, 0.5).map { .int(Int64($0)) } ?? .null,
                    "p90": Self.percentile(finished, 0.9).map { .int(Int64($0)) } ?? .null]),
            ])
        }
        // The week's five heaviest asks and the first six calls each made: her
        // own, refusals included; a call run inside another names its parent.
        let top = rounds.sorted { $0.rounds > $1.rounds }.prefix(5)
        let asks = week.events
        let heaviest: [JSONValue] = top.map { turn in
            var ask = "", made: [String] = []
            for event in asks where event.turnId == turn.turn {
                guard case .object(let payload) = event.payload else { continue }
                if event.kind == "work.identified", case .string(let title)? = payload["title"] { ask = String(title.prefix(80)) }
                guard event.kind == "tool.dispatch", payload["phase"] == .string("end"), payload["parentId"] == nil else { continue }
                made.append(Self.callLabel(payload) + (payload["status"] == .string("failed") ? "!" : ""))
            }
            return .object(["turn_id": .string(turn.turn), "at": .string(turn.at.formatted(.iso8601)),
                            "rounds": .int(Int64(turn.rounds)), "ask": .string(ask),
                            "first_six": .array(made.prefix(6).map(JSONValue.string))])
        }
        return .object([
            "status": .string(evidence.report.malformedLineCount == 0 && !evidence.report.trailingPartialLine && !week.truncated ? "ok" : "incomplete"),
            "title": .string("Model calls"), "until": .string(now.formatted(.iso8601)),
            "measurement": .string("Recorded llm.call rows in turn_traces and standalone calls in traces/events.jsonl, including recorded failures. Unbound calls use turn_id unknown; unlabelled older calls use purpose other. Windows may exceed retained rows. Missing durations are not estimated. rounds_per_turn is each finished turn's model rounds (its first call and one per tool round, from its turn.terminal row in the per-day turn traces), nearest-rank p50/p90; heaviest_asks are the week's five turns with the most rounds, ! marking a call that failed."),
            "malformed_rows": .int(Int64(evidence.report.malformedLineCount)),
            "trailing_partial_line": .bool(evidence.report.trailingPartialLine),
            "windows": .array(windows),
            "heaviest_asks": .array(heaviest),
            "turn_traces_incomplete": .bool(week.truncated),
        ])
    }

    /// Each finished turn's model rounds: its first call and one per tool
    /// round, as its terminal row counts them.
    public static func rounds(_ events: [TurnTraceEvent]) -> [(turn: String, at: Date, rounds: Int)] {
        events.compactMap { event in
            guard event.kind == "turn.terminal", case .object(let payload) = event.payload,
                  case .int(let rounds)? = payload["providerRoundCount"] else { return nil }
            return (event.turnId, event.ts, Int(rounds))
        }
    }

    /// Nearest-rank percentile; nil with nothing to rank.
    public static func percentile(_ values: [Int], _ p: Double) -> Int? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    /// An app call as heaviest_asks names it: its action, or what it read.
    static func callLabel(_ payload: [String: JSONValue]) -> String {
        if case .object(let receipt)? = payload["receipt"], case .string(let action)? = receipt["action"], action != "app" { return action }
        let args: [String: JSONValue] = if case .string(let raw)? = payload["args"],
            case .object(let args)? = try? JSONValue.parse(Data(raw.utf8)) { args } else { [:] }
        // A long script's args are clipped past parsing; its key names still say what it was.
        let keys: [JSONValue] = if case .array(let names)? = payload["argKeys"] { names } else { args.keys.map(JSONValue.string) }
        let blank: [JSONValue] = [.null, .string(""), .array([])]
        guard let key = ["actions", "script", "find", "page", "item"].first(where: {
            keys.contains(.string($0)) && !blank.contains(args[$0] ?? .bool(true))
        }) else { return "home" }
        switch args[key] {
        case .array(let list)?: return "\(key)[\(list.count)]"
        case .string(let text)? where ["page", "item"].contains(key): return key + " " + text
        default: return key
        }
    }

    public func usage(since: Date, now: Date = Date(), by: String = "model") async throws -> JSONValue {
        let evidence = try await traceEvidence(now: now, since: since)
        let snapshot = evidence.turns
        var oldestEvidence = snapshot.oldestRetainedDay
        let metrics = ["inputTokens", "cacheReadInputTokens", "outputTokens", "durationMs"]
        let zero = Dictionary(uniqueKeysWithValues: (["calls"] + metrics).map { ($0, Int64(0)) })
        var totals = zero
        var groups: [String: [String: Int64]] = [:]
        var missing: [String: [String: Int64]] = [:]
        var totalMissing: [String: Int64] = [:]
        for row in evidence.rows {
            guard case .object(let object) = row, object["kind"] == .string("llm.call") else { continue }
            guard case .string(let rawDate)? = object["createdAt"],
                  let date = TurnTraceEvent.parseISO8601(rawDate),
                  case .object(let payload)? = object["payload"] else {
                throw PersistenceCoreError.ioFailure("Damaged usage evidence: a model call has no readable date or payload.")
            }
            oldestEvidence = min(oldestEvidence ?? date, date)
            guard date >= since, date <= now else { continue }
            let key: String
            if by == "day" { key = TurnTracePersistLane.dayString(from: date) }
            else if case .string(let value)? = payload[by], !value.isEmpty { key = value }
            else { key = "unknown" }
            groups[key, default: zero]["calls", default: 0] += 1
            totals["calls", default: 0] += 1
            for metric in metrics {
                guard let value = try TraceMeasurement.value(payload[metric], field: metric) else {
                    missing[key, default: [:]][metric, default: 0] += 1
                    totalMissing[metric, default: 0] += 1
                    continue
                }
                let groupTotal = try TraceMeasurement.add(groups[key]?[metric] ?? 0, value, field: metric)
                groups[key, default: zero][metric] = groupTotal
                totals[metric] = try TraceMeasurement.add(totals[metric] ?? 0, value, field: metric)
            }
        }
        func counts(_ values: [String: Int64], missing: [String: Int64]) -> [String: JSONValue] {
            var row = values.mapValues(JSONValue.int)
            row["missing_fields"] = .object(missing.mapValues(JSONValue.int))
            return row
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let predatesRetention = oldestEvidence.map { since < $0 } ?? false
        let incomplete = !evidence.report.isClean || snapshot.truncated
        return .object([
            "status": .string(incomplete ? "incomplete" : "ok"), "by": .string(by),
            "since": .string(formatter.string(from: since)), "until": .string(formatter.string(from: now)),
            "covered_since": oldestEvidence.map { .string(formatter.string(from: max(since, $0))) } ?? .null,
            "oldest_retained_day": snapshot.oldestRetainedDay.map { .string(TurnTracePersistLane.dayString(from: $0)) } ?? .null,
            "predates_retention": .bool(predatesRetention),
            "coverage": .string(oldestEvidence == nil ? "No retained model-call evidence is available." : predatesRetention
                ? "The requested window predates retained evidence; earlier usage is unavailable."
                : "The requested window is within retained evidence. Retention and damaged rows can leave gaps."),
            "malformed_rows": .int(Int64(evidence.report.malformedLineCount)),
            "trailing_partial_line": .bool(evidence.report.trailingPartialLine),
            "turn_traces_incomplete": .bool(snapshot.truncated),
            "measurement": .string("Exact checked sums of reconciled llm.call values from daily turn traces and standalone traces/events.jsonl, without double-counting matched historical copies. missing_fields counts absent or null measurements; invalid domains or overflowing totals fail explicitly. Input and cached input are separate counters. Retention and read damage limit coverage."),
            "totals": .object(counts(totals, missing: totalMissing)),
            "groups": .array(groups.sorted { $0.key < $1.key }.map { key, values in
                var row = counts(values, missing: missing[key] ?? [:])
                row[by] = .string(key)
                return .object(row)
            }),
        ])
    }
}
