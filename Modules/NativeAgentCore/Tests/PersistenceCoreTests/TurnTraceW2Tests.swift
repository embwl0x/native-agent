import Testing
import Foundation
@testable import PersistenceCore

// Turn Inspector W2 — cross-module primitive tests (TurnTraceW2.swift):
// the secret redactor used by the thinking lane, and the per-surface
// thinking-lane gate.
@Suite("TurnTrace W2 primitives")
struct TurnTraceW2Tests {
    @Test("shared turn-trace lane auto-isolates XCTest fallback")
    func automaticXCTestRootNeverUsesProductionFallback() throws {
        let temp = URL(fileURLWithPath: "/tmp/nativeagent-trace-test-root", isDirectory: true)
        let root = try #require(TurnTracePersistLane.automaticTestRoot(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            processName: "NativeAgentCorePackageTests",
            temporaryDirectory: temp
        ))
        #expect(root.path.hasPrefix(temp.path))
        #expect(root.lastPathComponent.hasPrefix("NativeAgent-TurnTraceTests-"))
        #expect(TurnTracePersistLane.automaticTestRoot(
            environment: [:],
            processName: "swiftpm-testing-helper",
            temporaryDirectory: temp
        ) != nil)
        #expect(TurnTracePersistLane.automaticTestRoot(
            environment: [:],
            processName: "NativeAgent",
            temporaryDirectory: temp
        ) == nil)
        #expect(TurnTracePersistLane.testSafeInstanceOverride(
            defaultDataRoot(),
            automaticTestRoot: root
        ) == nil)
        let custom = temp.appendingPathComponent("explicit-custom", isDirectory: true)
        #expect(TurnTracePersistLane.testSafeInstanceOverride(
            custom,
            automaticTestRoot: root
        ) == custom)
    }

    // MARK: TurnTraceRedactor

    @Test func redactor_scrubs_known_secret_shapes() {
        // Each secret must be SCRUBBED (the raw secret gone, a REDACTED marker
        // present). The exact KIND label can vary when two patterns overlap
        // (e.g. an sk-ant key also matches the broader sk- OpenAI shape, which
        // is checked first) — the contract is "the secret never survives", not
        // a specific label.
        let cases: [(String, String)] = [
            ("token sk-ant-" + "0123456789ABCDEFGHIJ here", "sk-ant-" + "0123456789ABCDEFGHIJ"),
            ("key sk-proj-" + "ABCDEFGHIJ0123456789 done", "sk-proj-" + "ABCDEFGHIJ0123456789"),
            ("ghp_" + "0123456789abcdefghijABCDEF tail", "ghp_" + "0123456789abcdefghijABCDEF"),
            ("Authorization: Bearer abcDEF0123456789ghiJKL", "abcDEF0123456789ghiJKL"),
            ("API_KEY=supersecretvalue123", "supersecretvalue123"),
        ]
        for (raw, secret) in cases {
            let out = TurnTraceRedactor.redactText(raw)
            #expect(!out.contains(secret), "secret must be scrubbed from \(raw) → \(out)")
            #expect(out.contains("REDACTED_"), "a REDACTED marker must be present in \(out)")
        }
    }

    @Test func redactor_leaves_plain_text_untouched() {
        let plain = "I am reading the file at Modules/Foo/Bar.swift and thinking about the loop."
        #expect(TurnTraceRedactor.redactText(plain) == plain)
    }

    @Test func redactor_recurses_through_json_values() {
        let secret = "API_KEY=supersecretvalue123"
        let value: JSONValue = .object([
            "nested": .array([.string(secret), .int(4)]),
        ])
        guard case .object(let object) = TurnTraceRedactor.redactValue(value),
              case .array(let nested)? = object["nested"],
              case .string(let redacted)? = nested.first else {
            Issue.record("redactor changed the JSON shape")
            return
        }
        #expect(!redacted.contains("supersecretvalue123"))
        #expect(redacted.contains("[REDACTED_NAMED_SECRET]"))
        #expect(nested.dropFirst().first == .int(4))
    }

    // MARK: InspectorThinkingLane gate

    @Test func thinking_gate_defaults_false_unbound() {
        #expect(InspectorThinkingLane.summarizedThinking == false)
    }

    @Test func thinking_gate_off_for_non_chat_surface_even_when_setting_on() {
        let d = UserDefaults(suiteName: "w2-thinking-\(UUID().uuidString)")!
        d.set(true, forKey: InspectorThinkingLane.defaultsKey)
        // Setting is ON but the surface is not the eligible Mac chat surface.
        #expect(InspectorThinkingLane.isEnabledForSurface("telegram", defaults: d) == false)
        #expect(InspectorThinkingLane.isEnabledForSurface("ios", defaults: d) == false)
        // Eligible surface + setting on → enabled.
        #expect(InspectorThinkingLane.isEnabledForSurface("chat", defaults: d) == true)
    }

    @Test func thinking_gate_off_when_setting_unset() {
        let d = UserDefaults(suiteName: "w2-thinking-\(UUID().uuidString)")!
        // Key never set → default false → gate off even on the eligible surface.
        #expect(InspectorThinkingLane.isEnabledForSurface("chat", defaults: d) == false)
    }

    @Test func thinking_gate_taskLocal_binds_and_unbinds() {
        let inside = InspectorThinkingLane.$summarizedThinking.withValue(true) {
            InspectorThinkingLane.summarizedThinking
        }
        #expect(inside == true)
        #expect(InspectorThinkingLane.summarizedThinking == false)
    }

    // MARK: - W3 persist-lane override seam (W2 residual fix)
    //
    // The shared-bus tests pollute the live turn_traces feed unless the persist
    // lane can be redirected. The PRIORITY ORDER (env → instance → static →
    // default) is tested against the PURE `resolveRoot` helper so we never
    // mutate the process-wide static — which would race the parallel W1 tests
    // that append to / read back from the live lane. The global seam itself is
    // tested via its install-once semantics (never set to nil in-process).

    private func tmpURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-override-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func resolveRoot_env_outranks_everything() {
        let env = tmpURL("env"); let stat = tmpURL("stat")
        let inst = tmpURL("inst"); let def = tmpURL("def")
        let r = TurnTracePersistLane.resolveRoot(
            env: env, staticOverride: stat, instanceOverride: inst, defaultRoot: def)
        #expect(r == env)
    }

    @Test func resolveRoot_instance_outranks_static_and_default() {
        // A directly-constructed hermetic lane with an explicit instance
        // override must keep ITS root even if the process static is set — so a
        // global test seam can't clobber an instance-injected test lane.
        let stat = tmpURL("stat"); let inst = tmpURL("inst"); let def = tmpURL("def")
        let r = TurnTracePersistLane.resolveRoot(
            env: nil, staticOverride: stat, instanceOverride: inst, defaultRoot: def)
        #expect(r == inst)
    }

    @Test func resolveRoot_static_redirects_when_no_instance_override() {
        // The `.shared` lane's shape: no instance override → the process static
        // redirects it (this is the W2 shared-bus test seam).
        let stat = tmpURL("stat"); let def = tmpURL("def")
        let r = TurnTracePersistLane.resolveRoot(
            env: nil, staticOverride: stat, instanceOverride: nil, defaultRoot: def)
        #expect(r == stat)
    }

    @Test func resolveRoot_falls_through_to_default() {
        let def = tmpURL("def")
        let r = TurnTracePersistLane.resolveRoot(
            env: nil, staticOverride: nil, instanceOverride: nil, defaultRoot: def)
        #expect(r == def)
    }

    // Global seam: INSTALL-ONCE semantics (gpt-5.5 W3 review — the old
    // round-trip test set the global to nil mid-process, which can leak a
    // parallel suite's in-flight fire-and-forget emission into the LIVE feed).
    // This test never clears the override: it proves the first install wins,
    // a second candidate is rejected, and the effective root is never nil
    // afterwards. Safe under full-process parallelism — every candidate is a
    // non-live tmp root, and install-once is exactly the production contract
    // the shared-bus suites rely on.
    @Test func install_once_first_writer_wins_never_resets() {
        let a = tmpURL("install-a")
        let b = tmpURL("install-b")
        let effectiveA = TurnTracePersistLane.installTestRootOverrideIfUnset(a)
        // Another suite may have installed first — either way the effective
        // root is non-nil and stable from here on.
        let effectiveB = TurnTracePersistLane.installTestRootOverrideIfUnset(b)
        #expect(effectiveB == effectiveA, "second install must not change the root")
        #expect(effectiveB != b || effectiveA == b, "b can only win if it was first")
        #expect(TurnTracePersistLane.rootOverride == effectiveA)
        #expect(TurnTracePersistLane.rootOverride != nil)
    }

    // MARK: - W3 replay decode round-trip
    //
    // The replay lane reconstructs events from persisted JSONL. `jsonRow` and
    // `init?(jsonRow:)` must round-trip, and a malformed row must decode to nil
    // (skipped, never a crash).

    @Test func event_round_trips_through_jsonRow_decode() throws {
        let original = TurnTraceEvent(
            turnId: "turn-rt", kind: "tool.dispatch",
            sessionId: "sess-1", surface: "chat",
            payload: .object([
                "phase": .string("end"),
                "name": .string("read_file"),
                "status": .string("ok"),
                "durationMs": .int(42),
            ])
        )
        let row = original.jsonRow
        let decoded = try #require(TurnTraceEvent(jsonRow: row))
        #expect(decoded.turnId == original.turnId)
        #expect(decoded.kind == original.kind)
        #expect(decoded.sessionId == original.sessionId)
        #expect(decoded.surface == original.surface)
        #expect(decoded.payload == original.payload)
        // ts round-trips to second resolution (ISO8601 default has no fractional
        // seconds) — compare at whole-second granularity.
        #expect(abs(decoded.ts.timeIntervalSince(original.ts)) < 1.0)
    }

    @Test func oversizedPayloadIsExplicitlyBoundedAndKeepsLifecycleIdentity() throws {
        let event = TurnTraceEvent(
            turnId: "turn-large",
            kind: "tool.dispatch",
            payload: .object([
                "phase": .string("end"),
                "name": .string("list_dir"),
                "status": .string("ok"),
                "rows": .array((0..<2_000).map {
                    .object([
                        "index": .int(Int64($0)),
                        "value": .string("row-\($0)-" + String(repeating: "x", count: 40)),
                    ])
                }),
            ])
        )
        let payloadData = try event.payload.serializedData(pretty: false)
        #expect(payloadData.count <= TurnTraceEvent.maxPayloadBytes)
        guard case .object(let payload) = event.payload else {
            Issue.record("bounded payload was not an object")
            return
        }
        #expect(payload["_truncated"] == .bool(true))
        #expect(payload["phase"] == .string("end"))
        #expect(payload["name"] == .string("list_dir"))
        #expect(payload["status"] == .string("ok"))
        if case .string(let digest)? = payload["_sha256"] {
            #expect(digest.count == 64)
        } else {
            Issue.record("bounded payload digest missing")
        }
    }

    // Replay-order regression (observed live 2026-06-12): persistence is
    // fire-and-forget so FILE order is not emission order; whole-second ts made
    // same-second events tie and replay shuffled begin/end. Sub-second ts must
    // survive the round-trip so the chronological sort is honest.
    @Test func ts_round_trips_with_sub_second_precision() throws {
        let base = Date(timeIntervalSince1970: 1_760_000_000.0)
        let begin = TurnTraceEvent(turnId: "t", ts: base, kind: "tool.dispatch")
        let end = TurnTraceEvent(turnId: "t", ts: base.addingTimeInterval(0.120), kind: "tool.dispatch")
        let decodedBegin = try #require(TurnTraceEvent(jsonRow: begin.jsonRow))
        let decodedEnd = try #require(TurnTraceEvent(jsonRow: end.jsonRow))
        #expect(decodedBegin.ts < decodedEnd.ts, "120ms apart must stay ordered after round-trip")
        #expect(abs(decodedBegin.ts.timeIntervalSince(base)) < 0.005)
    }

    @Test func decode_accepts_legacy_plain_seconds_ts() {
        // Rows persisted before the fractional-seconds fix must still decode.
        let legacy = TurnTraceEvent(jsonRow: .object([
            "turnId": .string("t"), "kind": .string("k"),
            "ts": .string("2026-06-12T09:51:29Z"),
        ]))
        #expect(legacy != nil)
    }

    @Test func decode_rejects_malformed_rows() {
        // Missing turnId.
        #expect(TurnTraceEvent(jsonRow: .object(["kind": .string("x"), "ts": .string("2026-06-12T00:00:00Z")])) == nil)
        // Missing kind.
        #expect(TurnTraceEvent(jsonRow: .object(["turnId": .string("t"), "ts": .string("2026-06-12T00:00:00Z")])) == nil)
        // Missing ts.
        #expect(TurnTraceEvent(jsonRow: .object(["turnId": .string("t"), "kind": .string("x")])) == nil)
        // Unparseable ts.
        #expect(TurnTraceEvent(jsonRow: .object([
            "turnId": .string("t"), "kind": .string("x"), "ts": .string("not-a-date"),
        ])) == nil)
        // Not an object at all.
        #expect(TurnTraceEvent(jsonRow: .array([])) == nil)
        // Optional sessionId/surface absent → still decodes.
        let ok = TurnTraceEvent(jsonRow: .object([
            "turnId": .string("t"), "kind": .string("k"), "ts": .string("2026-06-12T00:00:00Z"),
        ]))
        #expect(ok != nil)
        #expect(ok?.sessionId == nil)
        #expect(ok?.surface == nil)
    }
}
