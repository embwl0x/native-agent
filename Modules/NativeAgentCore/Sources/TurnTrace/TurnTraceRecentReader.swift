import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `TurnTraceRecentReader.swift` | Checked record windows, model-call evidence and measured coverage |

/// Reads turn evidence and standalone receipts from the one record.
public struct TurnTraceRecentReader: Sendable {
    public static let maxRows = 2_000

    public struct Snapshot: Sendable {
        public let events: [TurnTraceEvent]
        public let unreadable: Int
        /// The query reached its row bound; earlier evidence may remain outside this read.
        public let limitReached: Bool
        /// Timestamp of the first retained detail in record order; nil when absent or unreadable.
        public let firstRetainedAt: Date?
        public let lastSeq: Int64?
        /// The read covered its whole window readably. It says nothing about health; an empty window is covered, not settled.
        public var completeSequences: Bool { !limitReached && unreadable == 0 }

        public init(events: [TurnTraceEvent], unreadable: Int = 0, limitReached: Bool = false,
                    firstRetainedAt: Date? = nil, lastSeq: Int64? = nil) {
            self.events = events
            self.unreadable = unreadable
            self.limitReached = limitReached
            self.firstRetainedAt = firstRetainedAt
            self.lastSeq = lastSeq
        }
    }

    private let lane: TurnTracePersistLane
    private let rowLimit: Int

    public init(dataRootOverride: URL? = nil, rowLimit: Int = TurnTraceRecentReader.maxRows) {
        self.lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
        self.rowLimit = max(1, rowLimit)
    }

    /// A since window or a named turn reads its full retained evidence through `now`. Other reads take the newest bounded record window of
    /// `now`'s whole day (with history, of every retained day through it), as a day's evidence read before. Holding selects kinds or turn ids
    /// after coverage is checked; `kinds` narrows the query itself. Trace names a turn's subject in the record.
    public func read(now: Date = Date(), history: Bool = false, since: Date? = nil, holding marks: [String] = [],
                     trace: String? = nil, kinds: [String]? = nil) async throws -> Snapshot {
        if let trace, NativeAgentChatSessionID.normalizedPathComponent(trace) != trace {
            throw PersistenceCoreError.ioFailure("trace must name a turn id in the record.")
        }
        let limit: Int? = since == nil && trace == nil ? rowLimit : nil
        let calendar = TurnTracePersistLane.dayCalendar
        let from = since ?? (history || trace != nil ? nil : calendar.startOfDay(for: now))
        var through = now
        if limit != nil {
            guard let dayEnd = calendar.dateInterval(of: .day, for: now)?.end else {
                throw PersistenceCoreError.ioFailure("Could not resolve the record day containing \(now).")
            }
            through = dayEnd.addingTimeInterval(-0.001)
        }
        let read = try await lane.events(.init(subjects: trace.map { [$0] }, kinds: kinds, from: from, through: through, limit: limit,
                                               newestFirst: limit != nil))
        let first = try await lane.events(.init(through: now, limit: 1))
        let ordered = limit == nil ? read.events : Array(read.events.reversed())
        let events = ordered.filter { marks.isEmpty || marks.contains($0.kind) || marks.contains($0.turnId) }
        return Snapshot(events: events, unreadable: read.unreadable,
                        limitReached: limit.map { read.events.count + read.unreadable >= $0 } ?? false,
                        firstRetainedAt: first.events.first?.ts, lastSeq: read.lastSeq)
    }

    /// Recorded receipts and turn evidence share one query; no second feed or inferred measurement is merged into it.
    /// `kinds` narrows the query to the kinds a caller reads; nil reads every kind, standalone receipts included.
    public func traceEvidence(now: Date = Date(), since: Date? = nil, kinds: [String]? = nil) async throws -> (rows: [JSONValue], turns: Snapshot) {
        let turns = try await read(now: now, history: true, since: since, kinds: kinds)
        var rows: [JSONValue] = []
        for event in turns.events {
            guard !event.diagnostic.isEmpty || ["llm.call", "provider.noReply", "tool.dispatch"].contains(event.kind) else { continue }
            guard case .object(var payload) = event.payload else {
                throw PersistenceCoreError.ioFailure("The \(event.kind) detail has no object payload.")
            }
            if event.kind == "tool.dispatch", payload["phase"] != .string("end"), event.diagnostic.isEmpty { continue }
            payload["turnId"] = .string(event.turnId)
            let title: String
            if let value = event.diagnostic["title"]?.stringValue { title = value }
            else if case .string(let value)? = payload[event.kind == "tool.dispatch" ? "name" : event.kind == "llm.call" ? "model"
                : "provider"] { title = value }
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
                "status": event.diagnostic["status"] ?? payload["status"] ?? .string(event.kind == "provider.noReply" ? "failed" : event.kind == "llm.call"
                    ? "unknown" : "ok"),
                "createdAt": event.diagnostic["createdAt"] ?? .string(event.ts.formatted(TurnTraceEvent.fractionalISO8601)),
                "payload": .object(payload),
            ]))
        }
        var dated: [(row: JSONValue, date: Date, index: Int)] = []
        for (index, row) in rows.enumerated() {
            guard case .object(let object) = row, case .string(let raw)? = object["createdAt"],
                  let date = TurnTraceEvent.parseISO8601(raw) else {
                throw PersistenceCoreError.ioFailure("A recorded receipt has no readable createdAt.")
            }
            dated.append((row, date, index))
        }
        dated.sort { $0.date == $1.date ? $0.index < $1.index : $0.date < $1.date }
        return (dated.map(\.row), turns)
    }

    public func modelCalls(now: Date = Date()) async throws -> JSONValue {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let evidence = try await traceEvidence(now: now, since: weekAgo)
        var calls: [(Date, String, String, Int64?)] = []
        for row in evidence.rows {
            guard case .object(let object) = row,
                  case .string(let rawDate)? = object["createdAt"],
                  let date = TurnTraceEvent.parseISO8601(rawDate) else {
                throw PersistenceCoreError.ioFailure("Model calls: a trace row has no readable createdAt; inspect the retained trace sources.")
            }
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
                "before_first_retained_detail": week.firstRetainedAt.map { .bool(since < $0) } ?? .null,
                "rounds_per_turn": .object(["turns": .int(Int64(finished.count)),
                    "p50": Self.percentile(finished, 0.5).map { .int(Int64($0)) } ?? .null,
                    "p90": Self.percentile(finished, 0.9).map { .int(Int64($0)) } ?? .null]),
            ])
        }
        // Include refusals in heaviest asks and retain parent identity for nested calls.
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
            "status": .string(week.unreadable > 0 || week.limitReached ? "incomplete" : calls.isEmpty ? "unmeasured" : "ok"),
            "title": .string("Model calls"), "until": .string(now.formatted(.iso8601)),
            "measurement": .string("""
                Recorded llm.call details, including standalone calls and recorded failures. Unbound calls use turn_id unknown; calls without a purpose use \
                purpose other. Windows may exceed retained evidence. Missing durations are not estimated. rounds_per_turn is each finished turn's model \
                rounds (its first call and one per round of calls, from its turn.terminal detail), \
                nearest-rank p50/p90; heaviest_asks are the week's five turns with the most rounds, ! marking a call that failed.
                """),
            "unreadable_details": .int(Int64(evidence.turns.unreadable)),
            "windows": .array(windows),
            "heaviest_asks": .array(heaviest),
            "limit_reached": .bool(week.limitReached),
        ])
    }

    /// Read model-round counts from the terminal owner: first call plus one per tool round.
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

    /// Identify heaviest asks by the actual app action or read target.
    static func callLabel(_ payload: [String: JSONValue]) -> String {
        if case .object(let receipt)? = payload["receipt"], case .string(let action)? = receipt["action"], action != "app" { return action }
        let decoded: [String: JSONValue]? = if case .string(let raw)? = payload["args"],
            case .object(let args)? = try? JSONValue.parse(Data(raw.utf8)) { args } else { nil }
        let args = decoded ?? [:]
        // A long script's args are clipped past parsing; its key names still say what it was.
        let keys: [JSONValue] = if case .array(let names)? = payload["argKeys"] { names } else { args.keys.map(JSONValue.string) }
        let blank: [JSONValue] = [.null, .string(""), .array([])]
        guard let key = ["actions", "script", "find", "page", "item"].first(where: {
            keys.contains(.string($0)) && !blank.contains(args[$0] ?? .bool(true))
        }) else { return decoded?.isEmpty == true ? "home" : "unknown (arguments unavailable)" }
        switch args[key] {
        case .array(let list)?: return "\(key)[\(list.count)]"
        case .string(let text)? where ["page", "item"].contains(key): return key + " " + text
        default: return key
        }
    }

    public func usage(since: Date, now: Date = Date(), by: String = "model") async throws -> JSONValue {
        let evidence = try await traceEvidence(now: now, since: since)
        let snapshot = evidence.turns
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
        let incomplete = snapshot.unreadable > 0 || snapshot.limitReached
        return .object([
            "status": .string(incomplete ? "incomplete" : totals["calls"] == 0 ? "unmeasured" : "ok"), "by": .string(by),
            "since": .string(formatter.string(from: since)), "until": .string(formatter.string(from: now)),
            "first_retained_detail_at": snapshot.firstRetainedAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "coverage": .string("Recorded values only. Gaps and forgotten details cannot be estimated; record order does not prove a time boundary."),
            "unreadable_details": .int(Int64(evidence.turns.unreadable)),
            "limit_reached": .bool(snapshot.limitReached),
            "measurement": .string("""
                Exact checked sums of recorded llm.call details, including standalone calls. missing_fields counts absent or null measurements; invalid \
                domains or overflowing totals fail explicitly. Input and cached input are separate counters. Retention and read damage limit coverage.
                """),
            "totals": .object(counts(totals, missing: totalMissing)),
            "groups": .array(groups.sorted { $0.key < $1.key }.map { key, values in
                var row = counts(values, missing: missing[key] ?? [:])
                row[by] = .string(key)
                return .object(row)
            }),
        ])
    }
}
