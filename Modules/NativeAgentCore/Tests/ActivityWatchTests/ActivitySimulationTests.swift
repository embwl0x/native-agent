import Foundation
import Testing
@testable import ActivityWatch

private let base: Double = 1_700_000_000

private func scriptJSON(_ body: String) throws -> ActivityScript {
    try ActivityScript.parse(data: Data(body.utf8))
}

// MARK: - Parsing

@Test("SCRIPT: every event type in the emitted schema actually parses")
func schemaEventsAllParse() throws {
    // The schema is documentation the CLI prints; if it drifts from the parser
    // it becomes a lie that costs someone an afternoon. Parse the exact example
    // events the schema advertises.
    let schema = ActivityScript.schemaJSON()
    let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
    let events = try #require(object?["events"] as? [[String: Any]])
    #expect(events.count == 11, "the schema advertises \(events.count) event kinds")

    let payload: [String: Any] = [
        "version": 1,
        "policy": ["captureEnabled": true, "captureTitles": true],
        "events": events,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let script = try ActivityScript.parse(data: data)
    #expect(script.events.count == 11)

    // And every case of the input vocabulary is represented.
    var kinds = Set<String>()
    for event in script.events {
        switch event {
        case .activate: kinds.insert("activate")
        case .focusEvent: kinds.insert("focusEvent")
        case .titleChange: kinds.insert("titleChange")
        case .idle: kinds.insert("idle")
        case .lock: kinds.insert("lock")
        case .unlock: kinds.insert("unlock")
        case .sleep: kinds.insert("sleep")
        case .wake: kinds.insert("wake")
        case .terminate: kinds.insert("terminate")
        case .crash: kinds.insert("crash")
        case .heartbeat: kinds.insert("heartbeat")
        }
    }
    #expect(kinds.count == 11)
}

@Test("SCRIPT: a script with no policy captures NOTHING")
func scriptWithoutPolicyCapturesNothing() async throws {
    let store = try engineTestStore()
    let script = try scriptJSON("""
    {"version": 1, "events": [
      {"type": "activate", "bundleId": "com.apple.Terminal", "appName": "Terminal", "at": \(base)},
      {"type": "focusEvent", "at": \(base + 10)},
      {"type": "terminate", "at": \(base + 20)}
    ]}
    """)
    #expect(!script.policy.captureEnabled)
    let spans = try await ActivitySimulator.replay(script, into: store)
    #expect(spans.isEmpty)
}

@Test("SCRIPT: a bad event is rejected with the index, not silently skipped")
func badEventIsRejected() {
    #expect(throws: ActivityScript.ParseError.self) {
        _ = try scriptJSON("""
        {"version": 1, "events": [{"type": "teleport", "at": 1}]}
        """)
    }
    #expect(throws: ActivityScript.ParseError.self) {
        _ = try scriptJSON("""
        {"version": 1, "events": [{"type": "activate", "at": 1}]}
        """)
    }
    #expect(throws: ActivityScript.ParseError.self) {
        _ = try scriptJSON("""
        {"version": 7, "events": []}
        """)
    }
}

// MARK: - Replay

@Test("REPLAY: a full day timeline produces exactly the expected spans")
func replayProducesExpectedSpans() async throws {
    let store = try engineTestStore()
    let script = try scriptJSON("""
    {
      "version": 1,
      "tzOffsetMin": 0,
      "policy": {"captureEnabled": true, "captureTitles": true, "excludedBundleIDs": ["com.1password.1password"]},
      "events": [
        {"type": "activate",    "bundleId": "com.apple.Terminal", "appName": "Terminal", "at": \(base)},
        {"type": "focusEvent",  "at": \(base + 30)},
        {"type": "titleChange", "raw": "build.log — Terminal", "at": \(base + 60)},
        {"type": "heartbeat",   "at": \(base + 120)},
        {"type": "activate",    "bundleId": "com.1password.1password", "appName": "1Password", "at": \(base + 180)},
        {"type": "focusEvent",  "at": \(base + 200)},
        {"type": "activate",    "bundleId": "com.apple.Safari", "appName": "Safari", "at": \(base + 240)},
        {"type": "lock",        "at": \(base + 300)},
        {"type": "activate",    "bundleId": "com.apple.Mail", "appName": "Mail", "at": \(base + 400)},
        {"type": "unlock",      "at": \(base + 500)},
        {"type": "activate",    "bundleId": "com.apple.Mail", "appName": "Mail", "at": \(base + 510)},
        {"type": "idle",        "at": \(base + 900)}
      ]
    }
    """)

    let spans = try await ActivitySimulator.replay(script, into: store)

    // REBASELINED 2026-08-14 (live-run defect): the script's FIRST title no
    // longer splits Terminal into a titleless row plus a successor — it is
    // stamped onto the open row in place. What used to be spans 1+2 is now one
    // span. Anything else here is unchanged.
    //
    // 1. Terminal (build.log, stamped in place) → closed by the switch to the
    //    EXCLUDED app
    // 2. Safari → closed by the lock, at the lock boundary
    // 3. Mail (after unlock + re-activate) → closed by idle
    // The 1Password activation and the mid-lock Mail activation write NOTHING.
    #expect(spans.count == 3)

    #expect(spans[0].bundleId == "com.apple.Terminal")
    #expect(spans[0].titleRedacted == "build.log — Terminal")
    #expect(spans[0].startedAt == base, "the initial title must not move the start")
    #expect(spans[0].endedAt == base + 180)
    #expect(spans[0].closeReason == .appChange)
    #expect(spans[0].eventCount == 2, "the focus event and the retitle, not the heartbeat")
    #expect(spans[0].lastSeenAt == base + 120, "the heartbeat still moved last_seen_at")

    #expect(spans[1].bundleId == "com.apple.Safari")
    #expect(spans[1].endedAt == base + 300)
    #expect(spans[1].closeReason == .lock)

    #expect(spans[2].bundleId == "com.apple.Mail")
    #expect(spans[2].startedAt == base + 510, "no span exists for the locked stretch")
    #expect(spans[2].endedAt == base + 900)
    #expect(spans[2].closeReason == .idle)

    // The defect this rebaseline exists for: no row may be zero-length.
    for span in spans {
        #expect((span.endedAt ?? span.lastSeenAt) > span.startedAt, "zero-length row")
    }

    #expect(spans.allSatisfy { $0.bundleId != "com.1password.1password" })
    // Every open has exactly one close.
    #expect(spans.allSatisfy { $0.endedAt != nil && $0.closeReason != nil })
    // Deterministic ids, so a replay can be diffed.
    #expect(spans.map(\.id) == ["sim-0", "sim-1", "sim-2"])
}

@Test("REPLAY: a crash leaves an open row that the NEXT replay reconciles")
func replayCrashThenReconcile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivitySimCrash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let crashScript = try scriptJSON("""
    {"version": 1, "policy": {"captureEnabled": true}, "events": [
      {"type": "activate", "bundleId": "com.apple.Xcode", "appName": "Xcode", "at": \(base)},
      {"type": "focusEvent", "at": \(base + 45)},
      {"type": "crash", "at": \(base + 90)}
    ]}
    """)

    let firstRun = try await ActivitySimulator.replay(
        crashScript, into: try ActivitySpanStore(dataRoot: root)
    )
    #expect(firstRun.count == 1)
    #expect(firstRun[0].endedAt == nil, "a crash must NOT synthesise a close")
    #expect(firstRun[0].lastSeenAt == base + 45)

    // Next process start, same data root.
    let restartScript = try scriptJSON("""
    {"version": 1, "policy": {"captureEnabled": true}, "events": []}
    """)
    let secondRun = try await ActivitySimulator.replay(
        restartScript, into: try ActivitySpanStore(dataRoot: root)
    )
    #expect(secondRun.count == 1)
    #expect(secondRun[0].endedAt == base + 45, "closed at last_seen_at, not at 'now'")
    #expect(secondRun[0].closeReason == .abandoned)
}

@Test("REPLAY: deterministic — the same script twice gives the same spans")
func replayIsDeterministic() async throws {
    let body = """
    {"version": 1, "policy": {"captureEnabled": true, "captureTitles": true}, "events": [
      {"type": "activate", "bundleId": "a", "appName": "A", "at": \(base)},
      {"type": "titleChange", "raw": "one", "at": \(base + 10)},
      {"type": "titleChange", "raw": "two", "at": \(base + 20)},
      {"type": "terminate", "at": \(base + 30)}
    ]}
    """
    let first = try await ActivitySimulator.replay(try scriptJSON(body), into: try engineTestStore())
    let second = try await ActivitySimulator.replay(try scriptJSON(body), into: try engineTestStore())
    #expect(first == second)
    #expect(ActivitySimulator.spansJSON(first) == ActivitySimulator.spansJSON(second))
}

@Test("REPLAY: the JSON output never contains a raw secret title")
func replayJSONCarriesNoRawSecret() async throws {
    let secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
    let script = try scriptJSON("""
    {"version": 1, "policy": {"captureEnabled": true, "captureTitles": true}, "events": [
      {"type": "activate", "bundleId": "a", "appName": "A", "at": \(base)},
      {"type": "titleChange", "raw": "\(secret)", "at": \(base + 10)},
      {"type": "terminate", "at": \(base + 20)}
    ]}
    """)
    let spans = try await ActivitySimulator.replay(script, into: try engineTestStore())
    let json = ActivitySimulator.spansJSON(spans)
    #expect(!json.contains(secret))
    #expect(!json.contains("sk-ant"))
    #expect(json.contains("[redacted]"))
}
