import Foundation
import Testing
@testable import NativeAgentApp
import PersistenceCore

// MARK: - Turn Inspector W3 — grouping + replay-parse hermetic tests
//
// Covers the testable model logic the Inspector tab depends on:
//   1. grouping events by turnId into cards, newest-started turn on top
//   2. rows within a turn ordered chronologically
//   3. per-turn summary (event count, llm tokens, ttft, wall time)
//   4. row shaping (status / title / duration / expandable detail)
//   5. replay JSONL parse: round-trip, bad-row skip, empty/absent.

@Suite("Turn Inspector W3 model")
struct TurnInspectorModelTests {

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

    // MARK: 1 + 2. grouping + ordering

    @Test func groups_by_turn_newest_started_on_top() {
        // Turn A started at +0, turn B started at +100. B must render first.
        let events = [
            event(turn: "A", kind: "assembly.stage", tsOffset: 0),
            event(turn: "A", kind: "llm.call", tsOffset: 5),
            event(turn: "B", kind: "assembly.stage", tsOffset: 100),
            event(turn: "B", kind: "llm.call", tsOffset: 105),
        ]
        let cards = TurnInspectorGrouping.group(events)
        #expect(cards.count == 2)
        #expect(cards[0].id == "B", "newest-started turn must be first")
        #expect(cards[1].id == "A")
    }

    @Test func rows_within_turn_are_chronological() {
        // Feed out of order; rows must come back sorted ascending by ts.
        let events = [
            event(turn: "A", kind: "llm.call", tsOffset: 30),
            event(turn: "A", kind: "assembly.stage", tsOffset: 10),
            event(turn: "A", kind: "tool.dispatch", tsOffset: 20),
        ]
        let card = TurnInspectorGrouping.group(events)[0]
        #expect(card.rows.map(\.kind) == ["assembly.stage", "tool.dispatch", "llm.call"])
    }

    @Test func empty_events_produce_no_cards() {
        #expect(TurnInspectorGrouping.group([]).isEmpty)
    }

    @Test func unknown_turnId_is_still_grouped_not_dropped() {
        let events = [event(turn: "unknown", kind: "llm.call", tsOffset: 0)]
        let cards = TurnInspectorGrouping.group(events)
        #expect(cards.count == 1)
        #expect(cards[0].id == "unknown", "direct-engine 'unknown' turns must remain visible")
    }

    // MARK: 3. per-turn summary

    @Test func summary_sums_llm_tokens_and_picks_first_ttft() {
        let events = [
            event(turn: "A", kind: "assembly.stage", tsOffset: 0),
            event(turn: "A", kind: "llm.call", tsOffset: 2, payload: .object([
                "inputTokens": .int(100), "outputTokens": .int(20), "ttftMs": .int(350),
            ])),
            event(turn: "A", kind: "llm.call", tsOffset: 4, payload: .object([
                "inputTokens": .int(50), "outputTokens": .int(10), "ttftMs": .int(900),
            ])),
        ]
        let card = TurnInspectorGrouping.group(events)[0]
        #expect(card.eventCount == 3)
        #expect(card.llmTokens == 180, "100+20+50+10 across both llm.call events")
        #expect(card.ttftMs == 350, "first observed ttft")
        #expect(card.surface == "chat")
        #expect(card.sessionId == "sess-1")
    }

    @Test func summary_wall_time_is_span_in_ms() {
        let events = [
            event(turn: "A", kind: "assembly.stage", tsOffset: 0),
            event(turn: "A", kind: "stream.tick", tsOffset: 1.5),
        ]
        let card = TurnInspectorGrouping.group(events)[0]
        #expect(card.wallMs == 1500)
    }

    @Test func summary_no_llm_call_reports_nil_tokens() {
        let events = [event(turn: "A", kind: "stream.tick", tsOffset: 0)]
        let card = TurnInspectorGrouping.group(events)[0]
        #expect(card.llmTokens == nil)
        #expect(card.ttftMs == nil)
    }

    // MARK: 4. row shaping

    @Test func tool_dispatch_row_is_expandable_with_redacted_previews() {
        let ev = event(turn: "A", kind: "tool.dispatch", tsOffset: 0, payload: .object([
            "name": .string("read_file"),
            "phase": .string("end"),
            "status": .string("ok"),
            "durationMs": .int(42),
            "args": .string("{\"path\":\"/x\"}"),
            "result": .string("[REDACTED_PREVIEW]"),
        ]))
        let row = TurnInspectorGrouping.makeRow(ev)
        #expect(row.status == .ok)
        #expect(row.durationMs == 42)
        #expect(row.isExpandable)
        #expect(row.title.contains("read_file"))
        let labels = row.detailLines.map(\.label)
        #expect(labels.contains("args"))
        #expect(labels.contains("result"))
    }

    @Test func failed_status_maps_to_failed() {
        let ev = event(turn: "A", kind: "tool.dispatch", tsOffset: 0, payload: .object([
            "name": .string("write_file"), "status": .string("failed"),
        ]))
        #expect(TurnInspectorGrouping.makeRow(ev).status == .failed)
    }

    @Test func file_touch_renders_paths_as_detail_lines() {
        let ev = event(turn: "A", kind: "file.touch", tsOffset: 0, payload: .object([
            "tool": .string("read_file"),
            "mode": .string("read"),
            "pathCount": .int(2),
            "paths": .array([.string("/a.swift"), .string("/b.swift")]),
        ]))
        let row = TurnInspectorGrouping.makeRow(ev)
        #expect(row.isExpandable)
        let pathValues = row.detailLines.filter { $0.label.hasPrefix("path[") }.map(\.value)
        #expect(pathValues == ["/a.swift", "/b.swift"])
    }

    @Test func stream_tick_is_not_expandable() {
        let ev = event(turn: "A", kind: "stream.tick", tsOffset: 0, payload: .object([
            "chars": .int(120), "chunks": .int(8),
        ]))
        let row = TurnInspectorGrouping.makeRow(ev)
        #expect(!row.isExpandable, "stream.tick is a one-liner")
        #expect(row.title.contains("120"))
    }

    @Test func context_snapshot_row_is_expandable_with_context_sections() {
        let ev = event(turn: "A", kind: "context.snapshot", tsOffset: 0, payload: .object([
            "model": .string("claude-opus-4-8"),
            "runId": .string("run-1"),
            "systemTotalChars": .int(3456),
            "stableChars": .int(2000),
            "dynamicChars": .int(1456),
            "userMessageChars": .int(42),
            "toolSchemaCount": .int(2),
            "recalledCount": .int(1),
            "containsCognitiveSubstrate": .bool(true),
            "stablePreview": .array([.string("persona packet")]),
            "dynamicPreview": .array([.string("runtime facts")]),
            "cognitivePreview": .array([.string("[CognitiveSubstrate]\nprovisional state")]),
            "userPreview": .array([.string("hello")]),
            "toolNames": .array([.string("time_now"), .string("read_file")]),
            "recalled": .array([.object([
                "id": .string("mem-1"),
                "preview": .array([.string("remembered context")]),
            ])]),
        ]))
        let row = TurnInspectorGrouping.makeRow(ev)
        #expect(row.isExpandable)
        #expect(row.title == "system 3456 chars · cognitive")
        let details = Dictionary(uniqueKeysWithValues: row.detailLines.map { ($0.label, $0.value) })
        #expect(details["model"] == "claude-opus-4-8")
        #expect(details["stable"] == "persona packet")
        #expect(details["dynamic"] == "runtime facts")
        #expect(details["cognitive"]?.contains("[CognitiveSubstrate]") == true)
        #expect(details["user"] == "hello")
        #expect(details["tools"] == "time_now, read_file")
        #expect(details["memories"]?.contains("mem-1: remembered context") == true)
    }

    @Test func kindChip_drops_namespace_prefix() {
        let ev = event(turn: "A", kind: "tool.dispatch", tsOffset: 0)
        #expect(TurnInspectorGrouping.makeRow(ev).kindChip == "dispatch")
    }

    // MARK: 5. replay parse

    @Test func replay_parse_round_trips_well_formed_rows() throws {
        let e1 = event(turn: "A", kind: "llm.call", tsOffset: 0)
        let e2 = event(turn: "A", kind: "stream.tick", tsOffset: 1)
        let jsonl = [e1, e2]
            .map { (try? $0.jsonRow.serialize(pretty: false)) ?? "" }
            .joined(separator: "\n")
        let parsed = TurnTraceReplayReader.parse(jsonl)
        #expect(parsed.skipped == 0)
        #expect(parsed.events.count == 2)
        #expect(Set(parsed.events.map(\.kind)) == ["llm.call", "stream.tick"])
    }

    @Test func replay_parse_skips_bad_rows_never_crashes() {
        let good = (try? event(turn: "A", kind: "llm.call", tsOffset: 0)
            .jsonRow.serialize(pretty: false)) ?? ""
        let jsonl = [
            good,
            "{ this is not json",                       // malformed JSON
            #"{"turnId":"B"}"#,                          // missing kind + ts
            "",                                          // blank line
            #"{"turnId":"C","kind":"x","ts":"nope"}"#,   // unparseable ts
        ].joined(separator: "\n")
        let parsed = TurnTraceReplayReader.parse(jsonl)
        #expect(parsed.events.count == 1, "only the one good row survives")
        #expect(parsed.skipped == 3, "three malformed rows skipped (blank line not counted)")
    }

    @Test func replay_read_absent_file_is_empty_not_error() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).jsonl")
        let parsed = TurnTraceReplayReader.read(url)
        #expect(parsed.events.isEmpty)
        #expect(parsed.skipped == 0)
    }

    // MARK: 6. store lifecycle — no leaked subscriptions

    // Rapid start/stop cycles (incl. stop racing an in-flight subscribe) must
    // not leak bus sinks. We can't assert an exact count (the process-global bus
    // is shared with other parallel suites), so we assert the count RETURNS to
    // its baseline after the store settles — i.e. this store leaves no sink
    // behind.
    @Test func store_start_stop_does_not_leak_subscriptions() async throws {
        let baseline = await TurnTraceBus.shared.subscriberCount
        let store = await TurnInspectorStore()
        // Tight start/stop loop: each stop() bumps the generation; an in-flight
        // subscribe must bail + unsubscribe via its defer.
        for _ in 0..<8 {
            await store.start()
            await store.stop()
        }
        // One final clean start then stop.
        await store.start()
        await store.stop()
        // Positive step (the detached defer-unsubscribes SHOULD drain) polls
        // with a generous deadline — a fixed 400ms beat routinely loses to
        // scheduler noise under full-suite parallelism.
        let drainDeadline = Date().addingTimeInterval(10)
        while await TurnTraceBus.shared.subscriberCount > baseline, Date() < drainDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = await TurnTraceBus.shared.subscriberCount
        #expect(after <= baseline, "no sink leaked after start/stop cycling (baseline \(baseline), after \(after))")
    }

    @Test func replay_read_from_temp_file_round_trips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = TurnTraceReplayReader.fileURL(for: date, root: dir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ev = event(turn: "A", kind: "memory.commit", tsOffset: 0)
        let line = try ev.jsonRow.serialize(pretty: false) + "\n"
        try line.write(to: url, atomically: true, encoding: .utf8)

        let parsed = TurnTraceReplayReader.read(url)
        #expect(parsed.events.count == 1)
        #expect(parsed.events.first?.kind == "memory.commit")
        #expect(parsed.events.first?.turnId == "A")
    }
}
