import Foundation
import Testing
@testable import NativeAgentApp
import PersistenceCore

private actor InspectorLiveConsumerGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var subscriptionID: UUID?

    func wait(subscriptionID: UUID) async {
        self.subscriptionID = subscriptionID
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func currentSubscriptionID() -> UUID? { subscriptionID }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

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

    @Test func replay_parse_still_bounds_hand_edited_payloads() throws {
        let oversized = String(repeating: "x", count: TurnTraceEvent.maxPayloadStringChars + 500)
        let row = try JSONValue.object([
            "turnId": .string("manual-row"),
            "ts": .string("2026-08-29T10:00:00.000Z"),
            "kind": .string("tool.dispatch"),
            "payload": .object(["detail": .string(oversized)]),
        ]).serialize(pretty: false)

        let parsed = TurnTraceReplayReader.parse(row)

        let event = try #require(parsed.events.first)
        guard case .object(let payload) = event.payload,
              case .string(let detail)? = payload["detail"] else {
            Issue.record("bounded replay payload was not preserved as an object")
            return
        }
        #expect(detail.count < oversized.count)
        #expect(detail.contains("chars]"))
    }

    @Test func replay_read_absent_file_is_empty_not_error() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).jsonl")
        let parsed = TurnTraceReplayReader.read(url)
        #expect(parsed.events.isEmpty)
        #expect(parsed.skipped == 0)
    }

    @Test func replay_read_reuses_unchanged_file_and_invalidates_on_append() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-trace-cache-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = url.resolvingSymlinksInPath().path
        TurnTraceReplayReader.replayCache.forget(key: key)

        let firstLine = try event(turn: "A", kind: "llm.call", tsOffset: 0)
            .jsonRow.serialize(pretty: false) + "\n"
        try Data(firstLine.utf8).write(to: url)
        let before = TurnTraceReplayReader.replayCache._testStats(key: key)
        let cold = TurnTraceReplayReader.read(url)
        let warm = TurnTraceReplayReader.read(url)
        let cached = TurnTraceReplayReader.replayCache._testStats(key: key)

        #expect(cold.events == warm.events)
        #expect(cached.misses - before.misses == 1)
        #expect(cached.hits - before.hits == 1)

        let secondLine = try event(turn: "B", kind: "memory.commit", tsOffset: 1)
            .jsonRow.serialize(pretty: false) + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondLine.utf8))
        try handle.close()

        let changed = TurnTraceReplayReader.read(url)
        let invalidated = TurnTraceReplayReader.replayCache._testStats(key: key)
        #expect(changed.events.count == 2)
        #expect(invalidated.misses - cached.misses == 1)
        TurnTraceReplayReader.replayCache.forget(key: key)
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

    // app.chat / ui.inspector.liveDropCount
    @Test @MainActor func liveInspectorSurfacesItsOwnBusBackpressureCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-live-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let gate = InspectorLiveConsumerGate()
        let store = TurnInspectorStore(
            liveBus: bus,
            liveSubscriptionCapacity: 1,
            beforeLiveConsumption: { id in await gate.wait(subscriptionID: id) }
        )
        store.start()

        let subscriptionDeadline = Date().addingTimeInterval(2)
        while await bus.subscriberCount == 0, Date() < subscriptionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await bus.subscriberCount == 1)

        let gateDeadline = Date().addingTimeInterval(2)
        var subscriptionID = await gate.currentSubscriptionID()
        while subscriptionID == nil, Date() < gateDeadline {
            try await Task.sleep(for: .milliseconds(5))
            subscriptionID = await gate.currentSubscriptionID()
        }
        #expect(subscriptionID != nil)

        // The store has subscribed but its consumer is deliberately held.
        // These real bus emissions overflow the production capacity-one sink;
        // no artificial count is injected into the UI store.
        for index in 0..<8 {
            TurnTraceBus.fire(
                event(turn: "drop-turn", kind: "tool.dispatch", tsOffset: Double(index)),
                on: bus
            )
        }

        let overflowDeadline = Date().addingTimeInterval(2)
        if let subscriptionID {
            while await bus.dropCount(subscriptionID) == 0, Date() < overflowDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await bus.dropCount(subscriptionID) > 0)
        }
        await gate.release()

        let dropDeadline = Date().addingTimeInterval(2)
        while store.liveDropCount == 0, Date() < dropDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.liveDropCount > 0)
        #expect(TurnInspectorLiveDropPresentation.label(for: store.liveDropCount)
            == "\(store.liveDropCount) dropped")
        #expect(TurnInspectorLiveDropPresentation.label(for: 0) == nil)
        #expect(TurnInspectorLiveDropPresentation.label(for: -1) == nil)

        store.stop()
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
