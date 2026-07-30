import Foundation
import Testing
@testable import NativeAgentApp
import PersistenceCore

// MARK: - Turn Inspector W4 — summary computation + size-budget hermetic tests
//
// Covers the W4 acceptance criteria:
//   1. grouping → summary mapping is correct (counts, tokens, ttft, wall, kinds)
//   2. malformed rows are skipped when reading a day file (never crash)
//   3. the size cap enforces truncation with the `truncated` marker
//   4. deterministic ordering: newest-started turn first
//   5. source reads the SAME root the live lane writes to (env/override seam),
//      computed from an explicit directory — never the live data/turn_traces.

@Suite("Turn Inspector W4 summary")
struct TurnSummaryComputerTests {

    private func event(
        turn: String,
        kind: String,
        tsOffset: TimeInterval,
        surface: String? = "chat",
        session: String? = "sess-1",
        payload: JSONValue = .object([:])
    ) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: Date(timeIntervalSince1970: 1_700_000_000 + tsOffset),
            kind: kind,
            sessionId: session,
            surface: surface,
            payload: payload
        )
    }

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnsummary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 1. grouping → summary mapping

    @Test func maps_grouped_card_to_summary_fields() {
        let llmPayload = JSONValue.object([
            "inputTokens": .int(120),
            "outputTokens": .int(40),
            "ttftMs": .int(310),
        ])
        let events = [
            event(turn: "A", kind: "assembly.stage", tsOffset: 0),
            event(turn: "A", kind: "tool.dispatch", tsOffset: 2),
            event(turn: "A", kind: "tool.dispatch", tsOffset: 3),
            event(turn: "A", kind: "llm.call", tsOffset: 5, payload: llmPayload),
        ]
        let file = TurnSummaryComputer.compute(from: events)
        #expect(file.summaries.count == 1)
        let s = file.summaries[0]
        #expect(s.id == "A")
        #expect(s.surface == "chat")
        #expect(s.sessionId == "sess-1")
        #expect(s.eventCount == 4)
        #expect(s.wallMs == 5000)
        #expect(s.llmTokens == 160)
        #expect(s.ttftMs == 310)
        #expect(s.kinds["tool.dispatch"] == 2)
        #expect(s.kinds["assembly.stage"] == 1)
        #expect(s.kinds["llm.call"] == 1)
        #expect(file.truncated == false)
        #expect(file.totalTurnsSeen == 1)
    }

    @Test func summary_carries_no_content_only_counts() {
        // A payload with content-shaped fields must NOT leak into the summary —
        // the summary type structurally cannot hold args/result/text, so we
        // assert the projection only surfaces kind counts + numeric metrics.
        let toolPayload = JSONValue.object([
            "name": .string("read_file"),
            "args": .string("/secret/path"),
            "result": .string("file body that must never sync"),
            "status": .string("ok"),
        ])
        let events = [event(turn: "A", kind: "tool.dispatch", tsOffset: 0, payload: toolPayload)]
        let file = TurnSummaryComputer.compute(from: events)
        let encoder = TurnSummaryComputer.makeEncoder()
        let json = String(data: (try? encoder.encode(file)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!json.contains("/secret/path"))
        #expect(!json.contains("file body that must never sync"))
        #expect(json.contains("tool.dispatch"))
    }

    // MARK: 4. deterministic ordering (newest-started first)

    @Test func summaries_newest_started_first() {
        let events = [
            event(turn: "A", kind: "llm.call", tsOffset: 0),
            event(turn: "B", kind: "llm.call", tsOffset: 100),
            event(turn: "C", kind: "llm.call", tsOffset: 50),
        ]
        let file = TurnSummaryComputer.compute(from: events)
        #expect(file.summaries.map(\.id) == ["B", "C", "A"])
    }

    // MARK: 3. size cap + truncation marker

    @Test func count_cap_truncates_oldest_and_marks() {
        // Build maxTurns + 5 turns; each turn started at a distinct, increasing
        // ts so newest-first keeps the highest-offset turns.
        let extra = 5
        let n = TurnSummaryComputer.maxTurns + extra
        var events: [TurnTraceEvent] = []
        for i in 0..<n {
            events.append(event(turn: "t\(i)", kind: "llm.call", tsOffset: TimeInterval(i)))
        }
        let file = TurnSummaryComputer.compute(from: events)
        #expect(file.summaries.count == TurnSummaryComputer.maxTurns)
        #expect(file.truncated == true)
        #expect(file.totalTurnsSeen == n)
        // Newest-first: the kept set must be the highest-offset turns. The oldest
        // (t0..t4) are dropped; t(n-1) is first.
        #expect(file.summaries.first?.id == "t\(n - 1)")
        #expect(!file.summaries.contains { $0.id == "t0" })
    }

    @Test func byte_cap_truncates_until_under_budget() {
        var events: [TurnTraceEvent] = []
        for i in 0..<TurnSummaryComputer.maxTurns {
            events.append(event(
                turn: "turn-\(UUID().uuidString)",
                kind: "tool.dispatch",
                tsOffset: TimeInterval(i),
                payload: .object(["status": .string("ok")])
            ))
        }
        let file = TurnSummaryComputer.compute(from: events)
        let data = (try? TurnSummaryComputer.makeEncoder().encode(file)) ?? Data()
        #expect(data.count <= TurnSummaryComputer.maxBytes,
                "serialized summary file must stay under the byte budget")
    }

    @Test func byte_cap_exercises_truncation_with_injected_budget() throws {
        // Force the byte path deterministically: a budget small enough that only
        // a handful of summaries fit. Newest-first prefix must survive, oldest
        // dropped, marker set, and the final file ALWAYS under budget.
        var events: [TurnTraceEvent] = []
        for i in 0..<20 {
            events.append(event(turn: "t\(i)", kind: "llm.call", tsOffset: TimeInterval(i)))
        }
        let budget = 600
        let file = TurnSummaryComputer.compute(from: events, maxBytes: budget)
        #expect(file.truncated == true)
        #expect(file.summaries.count < 20)
        #expect(file.summaries.first?.id == "t19", "newest turn must survive byte truncation")
        let data = try TurnSummaryComputer.makeEncoder().encode(file)
        #expect(data.count <= budget)
    }

    @Test func single_oversized_record_drops_to_empty_never_over_budget() throws {
        // BLOCKER regression (gpt-5.5 W4 r1): one record alone exceeding the
        // budget must yield an EMPTY truncated file, never an over-budget write.
        let events = [event(turn: "only", kind: "llm.call", tsOffset: 0)]
        let budget = 40 // smaller than any single-record file
        let file = TurnSummaryComputer.compute(from: events, maxBytes: budget)
        #expect(file.summaries.isEmpty)
        #expect(file.truncated == true)
        #expect(file.totalTurnsSeen == 1)
    }

    @Test func unknown_or_malicious_kind_never_serialized() throws {
        // BLOCKER regression (gpt-5.5 W4 r1): `kind` is freeform at the bus
        // layer; a content-bearing kind must NOT become a JSON key in the
        // snapshot — it buckets to "other".
        let evil = "user said: my password is hunter2 /Users/example/secret.txt"
        let events = [
            event(turn: "A", kind: evil, tsOffset: 0),
            event(turn: "A", kind: "llm.call", tsOffset: 1),
        ]
        let file = TurnSummaryComputer.compute(from: events)
        let json = String(data: try TurnSummaryComputer.makeEncoder().encode(file), encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
        #expect(!json.contains("secret.txt"))
        #expect(file.summaries[0].kinds[TurnSummaryComputer.otherKindBucket] == 1)
        #expect(file.summaries[0].kinds["llm.call"] == 1)
        #expect(file.summaries[0].eventCount == 2)
    }

    @Test func oversized_identity_fields_are_capped() throws {
        let longSurface = String(repeating: "x", count: 5_000)
        let events = [event(turn: "A", kind: "llm.call", tsOffset: 0, surface: longSurface)]
        let file = TurnSummaryComputer.compute(from: events)
        let s = try #require(file.summaries.first)
        #expect((s.surface?.count ?? 0) <= TurnSummaryComputer.maxIdentityFieldLength)
    }

    // MARK: 2. malformed rows skipped (day-file read)

    @Test func reads_day_file_and_skips_malformed_rows() {
        let root = tmpRoot()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = TurnTraceReplayReader.fileURL(for: now, root: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Two good rows for one turn + one malformed line + one blank line.
        let good1 = event(turn: "A", kind: "assembly.stage", tsOffset: 0)
        let good2 = event(turn: "A", kind: "llm.call", tsOffset: 1,
                          payload: .object(["inputTokens": .int(10), "outputTokens": .int(5)]))
        func row(_ e: TurnTraceEvent) -> String {
            (try? e.jsonRow.serialize(pretty: false)) ?? ""
        }
        let text = [row(good1), "{not valid json", "", row(good2)].joined(separator: "\n")
        try? text.data(using: .utf8)?.write(to: url)

        let events = TurnSummarySource.loadEvents(root: root, now: now, includeYesterday: false)
        #expect(events.count == 2, "malformed + blank lines skipped, 2 good rows kept")
        let file = TurnSummaryComputer.compute(from: events)
        #expect(file.summaries.count == 1)
        #expect(file.summaries[0].eventCount == 2)
        #expect(file.summaries[0].llmTokens == 15)
    }

    @Test func absent_day_file_yields_empty() {
        let root = tmpRoot()
        let events = TurnSummarySource.loadEvents(root: root, includeYesterday: false)
        #expect(events.isEmpty)
        let file = TurnSummaryComputer.compute(from: events)
        #expect(file.summaries.isEmpty)
        #expect(file.truncated == false)
        #expect(file.totalTurnsSeen == 0)
    }

    // MARK: schema stability (JSON field names iOS decodes)

    @Test func encoded_schema_field_names_are_stable() throws {
        let events = [event(
            turn: "A", kind: "llm.call", tsOffset: 0,
            payload: .object(["inputTokens": .int(1), "outputTokens": .int(2), "ttftMs": .int(9)])
        )]
        let file = TurnSummaryComputer.compute(from: events)
        let data = try TurnSummaryComputer.makeEncoder().encode(file)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["truncated"] != nil)
        #expect(obj["totalTurnsSeen"] != nil)
        // NO generatedAt: an always-changing stamp would defeat the snapshot
        // writer's digest skip and force a write + KVS signal every 30s pass.
        #expect(obj["generatedAt"] == nil)
        let arr = try #require(obj["summaries"] as? [[String: Any]])
        let s = try #require(arr.first)
        for key in ["id", "surface", "sessionId", "startedAt", "lastAt",
                    "eventCount", "wallMs", "llmTokens", "ttftMs", "kinds"] {
            #expect(s[key] != nil, "summary JSON must carry stable key \(key)")
        }
    }
}
