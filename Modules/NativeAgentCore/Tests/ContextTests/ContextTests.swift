import Testing
import Foundation
@testable import Context
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Helpers

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_717_000_000) }

// Hermetic data root for `SwiftNativeContextClient` (U5 W-F test hermeticity).
// The client's `dataRoot:` parameter defaults to
// `PersistenceCore.defaultDataRoot()` — the LIVE app data root under
// `swift test`. The lookup-branch tests below only need an isolated (and
// possibly empty) root; pinning each to a fresh temp dir keeps reads/writes
// off the user's live data. Mirrors the ResearchTests makeHermeticClient
// pattern (commit 988802bb).
private func hermeticContextRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ContextTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func obj(_ v: JSONValue) -> [String: JSONValue]? {
    if case .object(let o) = v { return o } else { return nil }
}

private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s } else { return nil }
}

private func arr(_ v: JSONValue?) -> [JSONValue]? {
    if case .array(let a)? = v { return a } else { return nil }
}

// MARK: - Feature-surface lookup (the portable branch)

@Test func featureSurfaceLookupEmptyQueryReturnsAll19() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: ["type": .string("lookup_feature_surface")])
    #expect(result != nil)
    guard let r = result else { return }
    #expect(r.status == "ready")
    #expect(r.type == "lookup_feature_surface")
    #expect(r.query == "")
    // No query → all 19 static feature-surface records (no [:30] truncation).
    #expect(r.features.count == featureSurfaceRecordsCount)
    #expect(r.features.count == 19)
}

@Test func featureSurfaceLookupFiltersByNameSubstring() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: [
        "type": .string("lookup_feature_surface"),
        "query": .string("Command Center"),
    ])
    guard let r = result, let first = obj(r.features.first ?? .null) else {
        Issue.record("expected at least one match for 'Command Center'")
        return
    }
    #expect(r.query == "Command Center")
    // Exactly the Command Center record matches by name.
    #expect(r.features.count == 1)
    #expect(str(first["id"]) == "feature:command_center")
}

@Test func featureSurfaceLookupFiltersByDescriptionSubstringCaseInsensitive() async {
    // "memory" appears in the description of feature:memory_system (and maybe
    // others); the match is case-insensitive on name OR description.
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: [
        "type": .string("lookup_feature_surface"),
        "query": .string("MEMORY"),
    ])
    guard let r = result else {
        Issue.record("nil result for description match")
        return
    }
    #expect(!r.features.isEmpty)
    let ids = r.features.compactMap { obj($0).flatMap { str($0["id"]) } }
    #expect(ids.contains("feature:memory_system"))
}

@Test func featureSurfaceLookupNoMatchYieldsEmptyFeatures() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: [
        "type": .string("lookup_feature_surface"),
        "query": .string("zzz-no-such-feature-xyz"),
    ])
    guard let r = result else {
        Issue.record("nil result for no-match query")
        return
    }
    #expect(r.features.isEmpty)
    #expect(r.status == "ready")
}

@Test func featureSurfaceLookupAcceptsTypeAliases() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    for alias in ["lookup_feature_surface", "feature_surface", "features"] {
        let result = await client.lookup(body: ["type": .string(alias)])
        #expect(result != nil, "alias \(alias) should be served natively")
        #expect(result?.type == alias)
    }
}

@Test func queryFallsBackToMessageKey() async {
    // Python: query = str(body.get("query") or body.get("message") or "")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: [
        "type": .string("features"),
        "message": .string("Command Center"),
    ])
    #expect(result?.query == "Command Center")
    #expect(result?.features.count == 1)
}

@Test func emptyStringQueryIsTreatedAsNoQuery() async {
    // Python "" is falsy → all records, no filter.
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: [
        "type": .string("features"),
        "query": .string(""),
    ])
    #expect(result?.features.count == 19)
}

// MARK: - Envelope shape (byte-equal key order/set)

@Test func envelopeKeySetMatchesPython() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: ["type": .string("features")])
    guard let r = result, case .object(let env) = r.toJSON() else {
        Issue.record("expected object envelope")
        return
    }
    // {"status", "type", "query", "features", "createdAt"}
    #expect(Set(env.keys) == ["status", "type", "query", "features", "createdAt"])
    #expect(str(env["status"]) == "ready")
    #expect(str(env["createdAt"]) != nil)
    #expect(arr(env["features"]) != nil)
}

@Test func featureRecordJSONKeySetMatchesPython() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    let result = await client.lookup(body: ["type": .string("features")])
    guard let r = result, let rec = obj(r.features.first ?? .null) else {
        Issue.record("expected a record")
        return
    }
    let expected: Set<String> = [
        "id", "sourceId", "name", "kind", "status", "description",
        "triggers", "permissions", "riskClass", "autoload", "useCount",
        "lastUsedAt", "updatedAt", "endpoints",
    ]
    #expect(Set(rec.keys) == expected)
    // lastUsedAt is always null in the static literal.
    #expect(rec["lastUsedAt"] == .null)
    #expect(rec["autoload"] == .bool(false))
    #expect(rec["useCount"] == .int(0))
}

// MARK: - Non-portable types defer to HTTP (nil)

@Test func nonPortableTypesReturnNil() async {
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: hermeticContextRoot())
    // lookup_capability is the DEFAULT type when none supplied → must defer.
    #expect(await client.lookup(body: [:]) == nil)
    for t in [
        "lookup_capability", "capability", "capabilities",
        "lookup_memory_policy", "memory_policy", "memory",
        "lookup_full_operating_map", "full_operating_map", "operating_map",
        "totally_unknown_type",
    ] {
        let r = await client.lookup(body: ["type": .string(t)])
        #expect(r == nil, "type \(t) must defer to HTTP (nil)")
    }
}

// MARK: - Factory

@Test func factoryReturnsSwiftNative() async {
    let client = makeContextClient()
    #expect(client is SwiftNativeContextClient)
}

@Test func factoryWritesFeedbackOnlyUnderInjectedDataRoot() async throws {
    let root = makeTempDataRoot()
    let client = makeContextClient(dataRoot: root)
    let result = await client.recordContextFeedback(body: ["reason": .string("hermetic factory")])

    #expect(result != nil)
    #expect(FileManager.default.fileExists(atPath: root
        .appendingPathComponent("context", isDirectory: true)
        .appendingPathComponent("feedback", isDirectory: true)
        .appendingPathComponent("events.jsonl").path))
}

// MARK: - GET /v1/context/latest (wave 36 W02)

/// Build a throwaway data root with the daemon's directory layout under a tmp
/// dir. Returns the root URL; caller is responsible for nothing (tmp dirs are
/// reaped by the OS / test sandbox).
private func makeTempDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctxtest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeFile(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// Seed a chat session in sessions.json and (optionally) a messages JSONL file
/// plus a receipt JSON. Mirrors the daemon's on-disk layout exactly.
private func seedSession(
    root: URL,
    sessionId: String,
    sessionFields: String,
    messagesJSONL: String? = nil
) {
    writeFile("[{\"id\":\"\(sessionId)\"\(sessionFields)}]",
              to: root.appendingPathComponent("chat/sessions.json"))
    if let messagesJSONL {
        writeFile(messagesJSONL,
                  to: root.appendingPathComponent("chat/messages/\(sessionId).jsonl"))
    }
}

private func seedReceipt(root: URL, runId: String, json: String) {
    writeFile(json, to: root.appendingPathComponent("context/\(runId).json"))
}

@Test func latestReturnsReceiptForMostRecentMessageWithRunId() async {
    let root = makeTempDataRoot()
    let sid = "mobile_app_session"
    // Two messages; newest carries runId=run2. Walk is newest-first so run2 wins.
    seedSession(
        root: root, sessionId: sid, sessionFields: ",\"title\":\"x\"",
        messagesJSONL: """
        {"id":"a","runId":"run1","content":"hi"}
        {"id":"b","runId":"run2","content":"there"}
        """)
    seedReceipt(root: root, runId: "run1", json: "{\"runId\":\"run1\",\"mode\":\"minimal\"}")
    seedReceipt(root: root, runId: "run2", json: "{\"runId\":\"run2\",\"mode\":\"capability\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    guard let r = result, case .object(let o) = r else {
        Issue.record("expected receipt object")
        return
    }
    #expect(str(o["runId"]) == "run2")
    #expect(str(o["mode"]) == "capability")
    #expect(o["startupContext"] == nil)  // NOT the startup-fallback branch
}

@Test func latestSkipsMessagesWithoutRunIdAndMissingReceiptFiles() async {
    let root = makeTempDataRoot()
    let sid = "sess_skip"
    // Newest (run_missing) has a runId but NO receipt file → skip to run_ok.
    seedSession(
        root: root, sessionId: sid, sessionFields: "",
        messagesJSONL: """
        {"id":"a","runId":"run_ok","content":"hi"}
        {"id":"b","content":"no runid here"}
        {"id":"c","runId":"run_missing","content":"newest"}
        """)
    seedReceipt(root: root, runId: "run_ok", json: "{\"runId\":\"run_ok\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    guard case .object(let o)? = await client.latestContextReceipt(sessionId: sid) else {
        Issue.record("expected run_ok receipt")
        return
    }
    #expect(str(o["runId"]) == "run_ok")
}

@Test func latestFallsBackToStartupRunIdReceiptWithFlag() async {
    let root = makeTempDataRoot()
    let sid = "sess_startup"
    // Has messages but NONE carry a usable receipt → fall to startupContextRunId.
    seedSession(
        root: root, sessionId: sid,
        sessionFields: ",\"startupContextRunId\":\"startrun\"",
        messagesJSONL: "{\"id\":\"a\",\"content\":\"no runid\"}")
    seedReceipt(root: root, runId: "startrun", json: "{\"runId\":\"startrun\",\"mode\":\"minimal\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    guard case .object(let o)? = await client.latestContextReceipt(sessionId: sid) else {
        Issue.record("expected startup receipt")
        return
    }
    #expect(str(o["runId"]) == "startrun")
    #expect(o["startupContext"] == .bool(true))  // receipt["startupContext"] = True
}

@Test func latestMergesInlineStartupContextWithFlag() async {
    let root = makeTempDataRoot()
    let sid = "sess_inline"
    // No messages with receipts, no startupContextRunId, but inline startupContext.
    seedSession(
        root: root, sessionId: sid,
        sessionFields: ",\"startupContext\":{\"mode\":\"minimal\",\"foo\":1}",
        messagesJSONL: "{\"id\":\"a\",\"content\":\"no runid\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    guard case .object(let o)? = await client.latestContextReceipt(sessionId: sid) else {
        Issue.record("expected merged inline startup context")
        return
    }
    // {"startupContext": True, **startup_context}
    #expect(o["startupContext"] == .bool(true))
    #expect(str(o["mode"]) == "minimal")
    #expect(o["foo"] == .int(1))
}

@Test func latestDefersForEmptySessionNeedingHydration() async {
    let root = makeTempDataRoot()
    let sid = "sess_empty"
    // Known session, ZERO messages, no startupContextRunId, no inline startup.
    // Python would GENERATE via ensure_session_startup_context (routing engine).
    // Swift MUST defer (nil) — must not fabricate a divergent receipt.
    seedSession(root: root, sessionId: sid, sessionFields: "")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    #expect(result == nil)  // → HTTP-delegate to the daemon
}

@Test func latestReturnsEmptyObjectForUnknownSession() async {
    let root = makeTempDataRoot()
    // Empty sessions.json; session_id not found.
    writeFile("[]", to: root.appendingPathComponent("chat/sessions.json"))
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: "ghost")
    #expect(result == .object([:]))  // Python `return {}`
}

@Test func latestStaleStartupRunIdEmptySessionReturnsEmptyObjectNotDefer() async {
    // gpt-5.5 review finding #1: a KNOWN EMPTY session whose startupContextRunId
    // is set but whose receipt file is MISSING does NOT trigger the routing
    // engine — ensure_session_startup_context no-ops (the id is already set), so
    // Python deterministically returns {}. Swift must return .object([:]), NOT
    // nil (deferring would be an unnecessary round-trip and, more importantly,
    // signals "Python would hydrate" which is false here).
    let root = makeTempDataRoot()
    let sid = "sess_stale_startup"
    seedSession(
        root: root, sessionId: sid,
        sessionFields: ",\"startupContextRunId\":\"missing_run\"")  // no messages, no receipt file
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    #expect(result == .object([:]))  // NOT nil
}

@Test func latestRunIdTruthyNonStringCoerces() async {
    // gpt-5.5 review finding #2: Python `str(message.get("runId") or "")`
    // coerces a truthy non-string. A message carrying runId as an int 7 must
    // resolve to receipt file "7.json".
    let root = makeTempDataRoot()
    let sid = "sess_intrun"
    seedSession(
        root: root, sessionId: sid, sessionFields: "",
        messagesJSONL: "{\"id\":\"a\",\"runId\":7,\"content\":\"hi\"}")
    seedReceipt(root: root, runId: "7", json: "{\"runId\":7,\"mode\":\"minimal\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    guard case .object(let o)? = await client.latestContextReceipt(sessionId: sid) else {
        Issue.record("expected receipt resolved via coerced int runId")
        return
    }
    #expect(str(o["mode"]) == "minimal")
}

@Test func latestReturnsEmptyObjectForNonEmptySessionWithNoReceipts() async {
    let root = makeTempDataRoot()
    let sid = "sess_nonempty_noreceipt"
    // Session has a message (non-empty) but no runId/startup → Python `return {}`.
    seedSession(
        root: root, sessionId: sid, sessionFields: "",
        messagesJSONL: "{\"id\":\"a\",\"content\":\"plain\"}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    #expect(result == .object([:]))  // not the hydration branch (session is non-empty)
}

// MARK: - WAVE 37 W01 §6.159 gap #1: malformed receipt → Python `{}`, not a miss

@Test func latestMalformedReceiptFileReturnsEmptyObjectNotMiss() async {
    // gap #1: Python `read_json(path, {})` returns its DEFAULT `{}` for a file
    // that EXISTS but holds unparseable JSON → `isinstance({}, dict)` is True →
    // Python returns `{}` and STOPS the walk. The prior Swift impl (default
    // `.null`) treated a malformed file as a miss and kept searching — diverging.
    let root = makeTempDataRoot()
    let sid = "sess_malformed"
    // Newest message's runId points at a receipt file full of GARBAGE; an OLDER
    // message has a perfectly valid receipt. Python returns the malformed file's
    // `{}` (newest-first walk halts at the first existing file). If Swift wrongly
    // skipped the malformed file it would return the older valid receipt instead.
    seedSession(
        root: root, sessionId: sid, sessionFields: "",
        messagesJSONL: """
        {"id":"a","runId":"valid_run","content":"older"}
        {"id":"b","runId":"garbage_run","content":"newest"}
        """)
    seedReceipt(root: root, runId: "valid_run", json: "{\"runId\":\"valid_run\",\"mode\":\"capability\"}")
    seedReceipt(root: root, runId: "garbage_run", json: "{not valid json at all ]]}")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    // Python: malformed newest → read_json returns {} → returns {} (NOT the older
    // valid_run receipt, NOT nil).
    #expect(result == .object([:]))
}

@Test func latestNonObjectReceiptFileStillSkipsToNext() async {
    // Companion to gap #1: a file that PARSES but to a NON-object (a bare array)
    // is `isinstance(receipt, dict) == False` in Python → the walk CONTINUES.
    // This is the opposite of the malformed case and must NOT halt. Confirms the
    // existence-gate + object-guard combination preserves the array→skip path.
    let root = makeTempDataRoot()
    let sid = "sess_arrayreceipt"
    seedSession(
        root: root, sessionId: sid, sessionFields: "",
        messagesJSONL: """
        {"id":"a","runId":"valid_run","content":"older"}
        {"id":"b","runId":"array_run","content":"newest"}
        """)
    seedReceipt(root: root, runId: "valid_run", json: "{\"runId\":\"valid_run\",\"mode\":\"minimal\"}")
    seedReceipt(root: root, runId: "array_run", json: "[1, 2, 3]")  // valid JSON, not a dict
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    guard case .object(let o)? = await client.latestContextReceipt(sessionId: sid) else {
        Issue.record("expected to skip the array receipt and return valid_run")
        return
    }
    #expect(str(o["runId"]) == "valid_run")  // walked PAST the non-dict receipt
    #expect(str(o["mode"]) == "minimal")
}

@Test func latestMalformedStartupReceiptReturnsStartupContextTrue() async {
    // gap #1 on the STARTUP path: Python `read_json(startup_path, {})` on a
    // malformed-but-existing startup receipt returns `{}` → dict → sets
    // receipt["startupContext"] = True → returns {"startupContext": True}.
    let root = makeTempDataRoot()
    let sid = "sess_malformed_startup"
    // No message-carried receipts; startupContextRunId points at a garbage file.
    seedSession(
        root: root, sessionId: sid,
        sessionFields: ",\"startupContextRunId\":\"garbage_startup\"",
        messagesJSONL: "{\"id\":\"a\",\"content\":\"no runid\"}")
    seedReceipt(root: root, runId: "garbage_startup", json: "}{ broken")
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.latestContextReceipt(sessionId: sid)
    // Python: {} (from malformed read_json default) + startupContext=True.
    #expect(result == .object(["startupContext": .bool(true)]))
}

// MARK: - WAVE 37 W01 §6.159 gap #2: now_iso() microsecond + timezone parity

@Test func isoTimestampWholeSecondOmitsFraction() {
    // Python timespec='auto' OMITS the fractional part when microsecond == 0.
    // 1_717_000_000.0 → "2024-05-29T16:26:40+00:00" (verified vs datetime).
    let s = ContextLookupResult.isoTimestamp(Date(timeIntervalSince1970: 1_717_000_000))
    #expect(s == "2024-05-29T16:26:40+00:00")
}

@Test func isoTimestampMicrosecondsAreSixDigitsTruncated() {
    // Python prints all SIX microsecond digits and TRUNCATES (floors) the
    // epoch→datetime conversion. 1_717_000_000.840204 →
    // "2024-05-29T16:26:40.840204+00:00" (verified vs datetime.fromtimestamp).
    let s = ContextLookupResult.isoTimestamp(Date(timeIntervalSince1970: 1_717_000_000.840204))
    // Allow a 1µs tolerance for double-representation of the fractional input,
    // but assert the SHAPE is six-digit microsecond + "+00:00" (never millis).
    #expect(s.hasPrefix("2024-05-29T16:26:40."))
    #expect(s.hasSuffix("+00:00"))
    // "16:26:40." + 6 digits + "+00:00" → fractional field is exactly 6 chars.
    let frac = s.dropFirst("2024-05-29T16:26:40.".count).dropLast("+00:00".count)
    #expect(frac.count == 6, "expected six microsecond digits, got '\(frac)'")
    let allDigits = frac.allSatisfy { $0.isNumber }
    #expect(allDigits)
}

@Test func isoTimestampHalfSecondMatchesPython() {
    // 1_717_000_000.5 → Python "2024-05-29T16:26:40.500000+00:00".
    let s = ContextLookupResult.isoTimestamp(Date(timeIntervalSince1970: 1_717_000_000.5))
    #expect(s == "2024-05-29T16:26:40.500000+00:00")
}

// MARK: - POST /v1/context/feedback (wave 36 W02)

@Test func feedbackAppendsEventAndReturnsRecordedEnvelope() async {
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(
        now: fixedNow, dataRoot: root, makeEventID: { "fixed-event-id" })
    // Production Mac payload: {message_id, rating, persona} — none map to
    // message/preferredMode/reason → message="", preferredMode="",
    // reason="user correction" (default), hint=null.
    let result = await client.recordContextFeedback(body: [
        "message_id": .string("m1"),
        "rating": .string("up"),
        "persona": .string("agent"),
    ])
    guard let r = result, case .object(let env) = r else {
        Issue.record("expected recorded envelope")
        return
    }
    #expect(str(env["status"]) == "recorded")
    #expect(env["hint"] == .null)
    #expect(str(env["createdAt"]) != nil)
    guard case .object(let event)? = env["event"] else {
        Issue.record("expected event object")
        return
    }
    #expect(str(event["id"]) == "fixed-event-id")
    #expect(str(event["message"]) == "")
    #expect(str(event["preferredMode"]) == "")
    #expect(str(event["reason"]) == "user correction")
    // Verify the JSONL line actually landed on disk with sorted keys and the
    // serializer shape pinned during the Swift-native migration.
    // WAVE 37 W01 (§6.159 gap #2): `createdAt` preserves the retired timestamp
    // semantics.
    // fixedNow == 1_717_000_000.0 is an EXACT integer second → microsecond == 0,
    // so the timestamp omits the fractional part: "2024-05-29T16:26:40+00:00"
    // (NOT ".000+00:00", which the old ISO8601DateFormatter-based impl wrongly
    // produced).
    let eventsPath = root.appendingPathComponent("context/feedback/events.jsonl")
    let onDisk = (try? String(contentsOf: eventsPath, encoding: .utf8)) ?? ""
    let expectedLine = """
    {"createdAt": "2024-05-29T16:26:40+00:00", "id": "fixed-event-id", "message": "", "preferredMode": "", "reason": "user correction"}
    """
    #expect(onDisk == expectedLine + "\n")
}

@Test func feedbackHonorsReasonAndQueryFallbacks() async {
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(
        now: fixedNow, dataRoot: root, makeEventID: { "e2" })
    // message falls back from query; reason falls back from feedback.
    // preferredMode is NOT a recognized mode → still native (no defer).
    let result = await client.recordContextFeedback(body: [
        "query": .string("how are you"),
        "feedback": .string("too terse"),
        "mode": .string("not_a_real_mode"),
    ])
    guard case .object(let env)? = result, case .object(let event)? = env["event"] else {
        Issue.record("expected envelope+event")
        return
    }
    #expect(str(event["message"]) == "how are you")
    #expect(str(event["reason"]) == "too terse")
    #expect(str(event["preferredMode"]) == "not_a_real_mode")
    #expect(env["hint"] == .null)
}

@Test func feedbackDefersWhenHintEligible() async {
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    // message non-empty AND preferredMode is a recognized context-mode key →
    // learn_context_hint would fire (NON-NATIVE) → defer to HTTP.
    for mode in ["minimal", "capability", "memory", "ops", "workflow",
                 "research", "personality", "full"] {
        let result = await client.recordContextFeedback(body: [
            "message": .string("route this as capability"),
            "preferredMode": .string(mode),
        ])
        #expect(result == nil, "mode \(mode) is hint-eligible → must defer to HTTP")
    }
    // Confirm NOTHING was appended to disk on the defer path.
    let eventsPath = root.appendingPathComponent("context/feedback/events.jsonl")
    #expect(!FileManager.default.fileExists(atPath: eventsPath.path))
}

@Test func feedbackTruthyNonStringMessageMakesHintEligibleDefer() async {
    // gpt-5.5 review finding #2: Python `str(body.get("message") or ...)`
    // coerces a truthy non-string. message=1 is truthy → with a recognized
    // preferredMode the payload is hint-eligible → MUST defer (nil), not append.
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    let result = await client.recordContextFeedback(body: [
        "message": .int(1),
        "preferredMode": .string("capability"),
    ])
    #expect(result == nil, "truthy non-string message + recognized mode → defer")
    let eventsPath = root.appendingPathComponent("context/feedback/events.jsonl")
    #expect(!FileManager.default.fileExists(atPath: eventsPath.path))
}

@Test func feedbackTruthyNonStringReasonCoerces() async {
    // Python `str(body.get("reason") or body.get("feedback") or "user correction")`
    // coerces a truthy non-string reason. reason=42 → "42".
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(
        now: fixedNow, dataRoot: root, makeEventID: { "e_reason" })
    let result = await client.recordContextFeedback(body: ["reason": .int(42)])
    guard case .object(let env)? = result, case .object(let event)? = env["event"] else {
        Issue.record("expected envelope+event")
        return
    }
    #expect(str(event["reason"]) == "42")
}

@Test func feedbackDoesNotDeferWhenModePresentButMessageEmpty() async {
    let root = makeTempDataRoot()
    let client = SwiftNativeContextClient(
        now: fixedNow, dataRoot: root, makeEventID: { "e3" })
    // preferredMode recognized BUT message empty → Python `if message and ...`
    // is False → hint stays None → native append.
    let result = await client.recordContextFeedback(body: [
        "preferredMode": .string("capability"),
    ])
    guard case .object(let env)? = result else {
        Issue.record("expected native recorded envelope (message empty)")
        return
    }
    #expect(str(env["status"]) == "recorded")
    #expect(env["hint"] == .null)
}

// MARK: - POST /v1/context/preview (PERMANENT HTTP)

@Test func previewAlwaysDefersToHTTP() async {
    let root = makeTempDataRoot()
    let swift = SwiftNativeContextClient(now: fixedNow, dataRoot: root)
    #expect(await swift.contextPreview(body: ["message": .string("hi")]) == nil)
    #expect(await swift.contextPreview(body: [:]) == nil)
}
