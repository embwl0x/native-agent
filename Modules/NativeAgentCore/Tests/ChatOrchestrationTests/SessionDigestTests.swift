import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - U3 wave-2 item 8: since-last-session digest
//
// Covers: digest assembly from a synthetic prior session, the ~500-token
// sentence-safe cap, per-session BYTE-STABILITY across turns (the U1
// prompt-cache invariant), fresh-session absence, source-error fail-open,
// and the adapter invariant systemPrompt == stable + "\n\n" + dynamic with
// the digest present.

// MARK: helpers

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sessiondigest-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// sessions.json with one PRIOR session (ended at `priorEnd`) and the
/// current session row.
private func writeSessionsFixture(
    root: URL,
    currentId: String,
    priorId: String = "prior-session",
    priorTitle: String = "Memory wave planning",
    priorEnd: String = "2026-06-09T20:00:00Z",
    priorPreview: String = "Shipped wave 1. Next up: the digest provider."
) throws {
    let json = """
    [
      {"id": "\(priorId)", "createdAt": "2026-06-09T18:00:00Z",
       "updatedAt": "\(priorEnd)", "title": "\(priorTitle)",
       "messageCount": 12, "lastMessagePreview": "\(priorPreview)"},
      {"id": "\(currentId)", "createdAt": "2026-06-10T09:00:00Z",
       "updatedAt": "2026-06-10T09:00:00Z", "title": "Current",
       "messageCount": 0, "lastMessagePreview": ""}
    ]
    """
    try write(json, to: root.appendingPathComponent("chat/sessions.json"))
}

private func writeWorklogFixture(root: URL, lines: [String]) throws -> URL {
    let path = root.appendingPathComponent("worklog/claude-worklog.jsonl")
    try write(lines.joined(separator: "\n") + "\n", to: path)
    return path
}

private func worklogRow(ts: String, kind: String = "build", summary: String) -> String {
    """
    {"ts": "\(ts)", "id": "\(UUID().uuidString)", "kind": "\(kind)", \
    "project": "NativeAgent", "summary": "\(summary)"}
    """
}

/// Fully-populated synthetic fixture: prior session + every digest source
/// carrying at least one post-anchor item. Returns the provider wired to the
/// fixture paths (worklog + agent inbox INSIDE the fixture root — hermetic).
private func makeFullFixture(root: URL, currentId: String) throws -> SessionDigestProvider {
    try writeSessionsFixture(root: root, currentId: currentId)
    // traces: 2 post-anchor llm.call rows + 1 tool.dispatch + 1 PRE-anchor row
    try write(
        """
        {"createdAt": "2026-06-09T10:00:00Z", "kind": "llm.call", "status": "ok"}
        {"createdAt": "2026-06-10T08:00:00Z", "kind": "llm.call", "status": "ok"}
        {"createdAt": "2026-06-10T08:01:00Z", "kind": "llm.call", "status": "ok"}
        {"createdAt": "2026-06-10T08:02:00Z", "kind": "tool.dispatch", "status": "ok"}
        """ + "\n",
        to: root.appendingPathComponent("traces/events.jsonl")
    )
    // Workshop executions: one completed after the anchor, one stale
    try write(
        """
        [
          {"id": "m1", "title": "Stale mission", "status": "done",
           "updatedAt": "2026-06-01T00:00:00.443113+00:00"},
          {"id": "m2", "title": "Trace ledger port", "status": "done",
           "completedAt": "2026-06-10T07:30:00.123456+00:00"}
        ]
        """,
        to: root.appendingPathComponent("workshop/legacy_executions.json")
    )
    // dream diary: one entry; mtime (now) is after the 2026-06-09 anchor
    try write(
        "# dream\nDIGEST-DREAM-BODY",
        to: root.appendingPathComponent("dream_diary/2026-06-10.md")
    )
    // agent inbox standup (mtime now > anchor)
    let inboxDir = root.appendingPathComponent("agent_inbox", isDirectory: true)
    try write(
        """
        # Claude — Session Log

        ## 2026-06-10 — fix/branch
        **Worked on:** DIGEST-STANDUP-MARKER wave 2 digest provider.
        **Status:** done
        """,
        to: inboxDir.appendingPathComponent("from_claude.md")
    )
    // worklog: 1 post-anchor row + 1 pre-anchor row
    let worklog = try writeWorklogFixture(root: root, lines: [
        worklogRow(ts: "2026-06-08T10:00:00.000Z", summary: "PRE-ANCHOR worklog row."),
        worklogRow(ts: "2026-06-10T08:05:00.000Z", summary: "DIGEST-WORKLOG-MARKER shipped U1 telemetry."),
    ])
    return SessionDigestProvider(
        dataRoot: root, agentInboxDir: inboxDir, worklogPath: worklog
    )
}

// MARK: engine harness (mirrors SessionHistoryTests)

private final class StubRoutingD: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high")]
    }
}

private struct FixedRecallStubD: MemoryRecalling {
    let hits: [MemoryRecallHit]
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] { hits }
}

private func makeDigestEngine(
    personaRoot: URL,
    remPinsDataRoot: URL? = nil,
    recallHits: [MemoryRecallHit] = []
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: SwiftNativePersonaEngine(root: personaRoot),
        memory: recallHits.isEmpty ? nil : FixedRecallStubD(hits: recallHits),
        router: StubRoutingD(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: remPinsDataRoot,
        memoryPromoter: nil
    )
}

// MARK: - provider unit tests

@Test
func sessionDigest_renders_from_synthetic_prior_session() async throws {
    let root = try makeTempRoot("render")
    let provider = try makeFullFixture(root: root, currentId: "current-1")

    let digest = await provider.digest(forSessionId: "current-1")
    let d = try #require(digest)

    #expect(d.hasPrefix(SessionDigestProvider.headerLine))
    #expect(d.contains("Previous session \"Memory wave planning\""))
    #expect(d.contains("(12 messages)"))
    #expect(d.contains("ended 2026-06-09 20:00 UTC"))
    #expect(d.contains("Last reply: Shipped wave 1."))
    #expect(d.contains("DIGEST-WORKLOG-MARKER"))
    #expect(!d.contains("PRE-ANCHOR"))                      // anchor filter
    #expect(d.contains("Workshop: 1 task(s) updated"))
    #expect(d.contains("Trace ledger port"))
    #expect(!d.contains("Stale mission"))                   // anchor filter
    #expect(d.contains("Standup from claude"))
    #expect(d.contains("DIGEST-STANDUP-MARKER"))
    #expect(d.contains("Dream diary: 1 new entry (latest: 2026-06-10.md)"))
    #expect(d.contains("Traces: 3 events (llm.call ×2, tool.dispatch ×1)"))
}

@Test
func sessionDigest_caps_at_500_tokens_sentence_safe() async throws {
    let root = try makeTempRoot("cap")
    // Sentence-dense overflow fixture so a sentence boundary always exists
    // near any cap the final truncation lands on.
    let sentence = "This finding was verified end to end. "
    let longText = String(repeating: sentence, count: 12) // ~470 chars
    try writeSessionsFixture(
        root: root, currentId: "current-cap",
        priorTitle: String(repeating: "Long title segment. ", count: 8),
        priorPreview: longText
    )
    let worklog = try writeWorklogFixture(root: root, lines: (0..<6).map { i in
        worklogRow(ts: "2026-06-10T0\(i):05:00.000Z", summary: longText)
    })
    let inboxDir = root.appendingPathComponent("agent_inbox", isDirectory: true)
    try write(
        "## 2026-06-10 — branch\n**Worked on:** \(longText)",
        to: inboxDir.appendingPathComponent("from_claude.md")
    )
    try write(
        "## 2026-06-10 — branch\n**Worked on:** \(longText)",
        to: inboxDir.appendingPathComponent("from_codex.md")
    )
    let provider = SessionDigestProvider(
        dataRoot: root, agentInboxDir: inboxDir, worklogPath: worklog
    )

    // Production path: hard cap (~500 tokens at 4 chars/token) always holds.
    let digest = try #require(await provider.digest(forSessionId: "current-cap"))
    #expect(digest.count <= SessionDigestProvider.digestCharCap)

    // Truncation mechanism: per-line clips keep the natural size under the
    // production cap, so exercise the FINAL sentence-safe truncation through
    // the internal cap seam — the uncapped render here is ~1.5-1.8k chars,
    // well past a 400-char cap.
    let capped = try #require(provider.buildDigest(currentSessionId: "current-cap", cap: 400))
    let uncapped = try #require(provider.buildDigest(currentSessionId: "current-cap", cap: .max))
    #expect(uncapped.count > 400)       // the fixture genuinely overflows
    #expect(capped.count <= 400)
    // Sentence-safe: the clipped digest ends on a sentence terminator,
    // never mid-word (fixture content is sentence-dense).
    let last = try #require(capped.trimmingCharacters(in: .whitespacesAndNewlines).last)
    #expect([".", "!", "?", "…"].contains(String(last)))
    // And the capped render is a prefix of the uncapped one (truncation,
    // never rewriting).
    #expect(uncapped.hasPrefix(capped))
}

@Test
func sessionDigest_fresh_session_no_prior_returns_nil() async throws {
    let root = try makeTempRoot("fresh")
    // sessions.json carries ONLY the current session — first session ever.
    let json = """
    [{"id": "only-session", "createdAt": "2026-06-10T09:00:00Z",
      "updatedAt": "2026-06-10T09:05:00Z", "title": "First ever"}]
    """
    try write(json, to: root.appendingPathComponent("chat/sessions.json"))
    let provider = SessionDigestProvider(
        dataRoot: root,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: root.appendingPathComponent("worklog/none.jsonl")
    )
    #expect(await provider.digest(forSessionId: "only-session") == nil)
    // Missing sessions.json entirely → also nil.
    let emptyRoot = try makeTempRoot("fresh-empty")
    let provider2 = SessionDigestProvider(
        dataRoot: emptyRoot,
        agentInboxDir: emptyRoot.appendingPathComponent("agent_inbox"),
        worklogPath: emptyRoot.appendingPathComponent("worklog/none.jsonl")
    )
    #expect(await provider2.digest(forSessionId: "any") == nil)
}

@Test
func sessionDigest_source_errors_fail_open() async throws {
    // Corrupt sessions.json → no digest, no throw.
    let root = try makeTempRoot("corrupt-sessions")
    try write("{{{{ not json at all", to: root.appendingPathComponent("chat/sessions.json"))
    let provider = SessionDigestProvider(
        dataRoot: root,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: root.appendingPathComponent("worklog/none.jsonl")
    )
    #expect(await provider.digest(forSessionId: "s") == nil)

    // Valid prior session + corrupt secondary sources → digest still
    // renders; the broken sources just drop out.
    let root2 = try makeTempRoot("corrupt-secondaries")
    try writeSessionsFixture(root: root2, currentId: "cur")
    try write("not jsonl \u{0} garbage", to: root2.appendingPathComponent("traces/events.jsonl"))
    try write("[{\"broken\": ", to: root2.appendingPathComponent("workshop/legacy_executions.json"))
    let worklog = root2.appendingPathComponent("worklog/claude-worklog.jsonl")
    try write("also not json\n", to: worklog)
    let provider2 = SessionDigestProvider(
        dataRoot: root2,
        agentInboxDir: root2.appendingPathComponent("agent_inbox"),
        worklogPath: worklog
    )
    let digest = try #require(await provider2.digest(forSessionId: "cur"))
    #expect(digest.hasPrefix(SessionDigestProvider.headerLine))
    #expect(digest.contains("Previous session"))
    #expect(!digest.contains("Traces:"))
    #expect(!digest.contains("Missions:"))
}

// MARK: - engine integration: injection point + cache invariant

@Test
func buildTurnContextWithHistory_injects_digest_at_head_of_dynamic_segment() async throws {
    let root = try makeTempRoot("inject")
    let provider = try makeFullFixture(root: root, currentId: "s-digest")
    // REM pins so we can prove digest lands AFTER pins inside stable.
    try write(
        """
        {"SOUL.md": [{"id": "pin-1", "text": "PIN-MARKER-BEFORE-DIGEST", "createdAt": "2026-06-01T00:00:00Z"}]}
        """,
        to: root.appendingPathComponent("rem_pins.json")
    )
    let personaDir = try makeTempRoot("persona-inject")
    try write("PERSONA-MARKER-STABLE", to: personaDir.appendingPathComponent("SOUL.md"))
    let engine = makeDigestEngine(
        personaRoot: personaDir,
        remPinsDataRoot: root,
        recallHits: [MemoryRecallHit(score: 0.9, preview: "RECALL-MARKER-DYNAMIC")]
    )
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-digest",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )

    let seg = try #require(ctx.systemSegments)
    let digest = try #require(await provider.digest(forSessionId: "s-digest"))

    // Digest sits at the very HEAD of the DYNAMIC segment (2026-07-24 cache
    // fix) — it describes the PREVIOUS session, so it is per-session content
    // and must sit on the churning side of the stable-end cache breakpoint.
    #expect(seg.dynamic.hasPrefix(digest))
    // ...and NEVER in the stable segment, which the breakpoint covers.
    #expect(!seg.stable.contains(SessionDigestProvider.headerLine))
    // Stable is persona + REM pins ONLY, in that order.
    let persona = try #require(seg.stable.range(of: "PERSONA-MARKER-STABLE"))
    let pin = try #require(seg.stable.range(of: "PIN-MARKER-BEFORE-DIGEST"))
    #expect(persona.lowerBound < pin.lowerBound)
    // MODEL-VISIBLE ORDER IS UNCHANGED: in `combined` the digest still lands
    // after persona+pins and before the recall mass — only the breakpoint
    // boundary moved, not a single byte the model reads.
    let combined = try #require(ctx.systemPrompt)
    let cPin = try #require(combined.range(of: "PIN-MARKER-BEFORE-DIGEST"))
    let cHeader = try #require(combined.range(of: SessionDigestProvider.headerLine))
    let cRecall = try #require(combined.range(of: "RECALL-MARKER-DYNAMIC"))
    #expect(cPin.lowerBound < cHeader.lowerBound)
    #expect(cHeader.lowerBound < cRecall.lowerBound)
    #expect(seg.dynamic.contains("RECALL-MARKER-DYNAMIC"))
    // Adapter invariant with digest present: byte-exact reassembly.
    #expect(ctx.systemPrompt == seg.stable + "\n\n" + seg.dynamic)
    #expect(seg.reassembles(into: ctx.systemPrompt ?? ""))
}

/// REGRESSION GUARD (2026-07-24): the stable segment must be byte-identical
/// across two DIFFERENT sessions. Anthropic's prompt cache is an exact-prefix
/// match scoped to the ORGANIZATION, not to a session, so anything
/// per-session inside the stable block makes the stable-end cache_control
/// breakpoint a guaranteed miss on every fresh session — which is exactly
/// what the digest did while it lived at the tail of `stable` (measured:
/// cacheRead=0 on back-to-back identical bridge turns).
@Test
func stable_segment_is_byte_identical_across_different_sessions() async throws {
    let root = try makeTempRoot("cross-session")
    let provider = try makeFullFixture(root: root, currentId: "s-one")
    let personaDir = try makeTempRoot("persona-cross")
    try write("PERSONA-BYTES", to: personaDir.appendingPathComponent("SOUL.md"))
    let reader = SessionHistoryReader(dataRoot: root)

    let engine = makeDigestEngine(personaRoot: personaDir)
    let a = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-one",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let b = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: "s-two",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let segA = try #require(a.systemSegments)
    let segB = try #require(b.systemSegments)

    // The cacheable prefix is the SAME BYTES for two unrelated sessions.
    #expect(segA.stable == segB.stable)
    // And it carries none of the per-session digest.
    #expect(!segA.stable.contains(SessionDigestProvider.headerLine))
    #expect(!segB.stable.contains(SessionDigestProvider.headerLine))
    // Invariant still holds on both.
    #expect(segA.reassembles(into: a.systemPrompt ?? ""))
    #expect(segB.reassembles(into: b.systemPrompt ?? ""))
}

@Test
func buildTurnContextWithHistory_digest_byte_identical_across_turns_even_when_sources_move() async throws {
    let root = try makeTempRoot("byte-stable")
    let provider = try makeFullFixture(root: root, currentId: "s-stable")
    let personaDir = try makeTempRoot("persona-stable")
    try write("PERSONA-BYTES", to: personaDir.appendingPathComponent("SOUL.md"))
    let reader = SessionHistoryReader(dataRoot: root)

    // Turn 1 (no on-disk history yet — digest must already be injected).
    let engine1 = makeDigestEngine(personaRoot: personaDir)
    let turn1 = try await engine1.buildTurnContextWithHistory(
        surface: "chat", userMessage: "first", sessionId: "s-stable",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let seg1 = try #require(turn1.systemSegments)
    // Digest is present on turn 1, in the DYNAMIC segment (2026-07-24).
    #expect(seg1.dynamic.contains(SessionDigestProvider.headerLine))
    #expect(!seg1.stable.contains(SessionDigestProvider.headerLine))

    // Sources MOVE between turns: new worklog row + new trace event. The
    // cached digest must not change (per-session byte stability — the U1
    // stable-prefix cache contract).
    let worklogHandle = try FileHandle(forWritingTo: provider.worklogPath)
    try worklogHandle.seekToEnd()
    try worklogHandle.write(contentsOf: Data(
        (worklogRow(ts: "2026-06-10T11:00:00.000Z", summary: "LATE-ARRIVING worklog row.") + "\n").utf8
    ))
    try worklogHandle.close()
    let tracesPath = root.appendingPathComponent("traces/events.jsonl")
    let tracesHandle = try FileHandle(forWritingTo: tracesPath)
    try tracesHandle.seekToEnd()
    try tracesHandle.write(contentsOf: Data(
        "{\"createdAt\": \"2026-06-10T11:01:00Z\", \"kind\": \"llm.call\", \"status\": \"ok\"}\n".utf8
    ))
    try tracesHandle.close()

    // Turn 2: history now exists (write the turn-1 exchange), and a FRESH
    // engine instance proves the cache is process-global, not actor state.
    try write(
        """
        {"role": "user", "content": "first", "createdAt": "2026-06-10T10:00:00Z"}
        {"role": "assistant", "content": "reply", "createdAt": "2026-06-10T10:00:01Z"}
        """ + "\n",
        to: root.appendingPathComponent("chat/messages/s-stable.jsonl")
    )
    let engine2 = makeDigestEngine(personaRoot: personaDir)
    let turn2 = try await engine2.buildTurnContextWithHistory(
        surface: "chat", userMessage: "second", sessionId: "s-stable",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let seg2 = try #require(turn2.systemSegments)

    // THE cache invariant: stable bytes identical across turns, so the
    // provider prompt-cache prefix keeps hitting.
    #expect(seg1.stable == seg2.stable)
    #expect(!seg2.stable.contains("LATE-ARRIVING"))
    // Dynamic moved (history appeared) — that is the churn lane.
    #expect(seg2.dynamic.contains("Conversation history:"))
    // Invariant still holds on both turns. (Turn 1 has NO recall and NO
    // history, so its dynamic segment is the digest alone — `combined` is
    // asserted via the canonical accessor, which is exactly what the
    // adapters verify against.)
    #expect(turn1.systemPrompt == seg1.combined)
    #expect(seg1.reassembles(into: turn1.systemPrompt ?? ""))
    #expect(turn2.systemPrompt == seg2.stable + "\n\n" + seg2.dynamic)
    #expect(seg2.reassembles(into: turn2.systemPrompt ?? ""))

    // A DIFFERENT session in the same store computes its own digest (and may
    // see the late rows) — the cache is per-session, not global.
    let other = await provider.digest(forSessionId: "s-other")
    let stable = await provider.digest(forSessionId: "s-stable")
    #expect(other != stable || other == nil)
}

@Test
func buildTurnContextWithHistory_no_prior_session_leaves_prompt_unchanged() async throws {
    let root = try makeTempRoot("no-digest")
    // Only the current session exists → no digest anywhere in the prompt.
    let json = """
    [{"id": "s-new", "createdAt": "2026-06-10T09:00:00Z",
      "updatedAt": "2026-06-10T09:00:00Z", "title": "New"}]
    """
    try write(json, to: root.appendingPathComponent("chat/sessions.json"))
    let personaDir = try makeTempRoot("persona-nodigest")
    try write("PERSONA-NODIGEST", to: personaDir.appendingPathComponent("SOUL.md"))
    let provider = SessionDigestProvider(
        dataRoot: root,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: root.appendingPathComponent("worklog/none.jsonl")
    )
    let engine = makeDigestEngine(personaRoot: personaDir)
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hello", sessionId: "s-new",
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let seg = try #require(ctx.systemSegments)
    #expect(!seg.stable.contains(SessionDigestProvider.headerLine))
    #expect(!(ctx.systemPrompt ?? "").contains(SessionDigestProvider.headerLine))
    #expect(ctx.systemPrompt == seg.combined)
}

// MARK: - fix-round (gpt-5.5 review, 2026-06-10): durability + races

/// Thread-safe build counter for the single-flight assertion.
private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Test
func sessionDigest_concurrent_first_turns_yield_identical_bytes_from_one_build() async throws {
    // Provider level: 8 concurrent FIRST calls for the same session all
    // resolve to byte-identical digests.
    let root = try makeTempRoot("concurrent")
    let provider = try makeFullFixture(root: root, currentId: "current-conc")
    let results = await withTaskGroup(of: String?.self) { group in
        for _ in 0..<8 {
            group.addTask { await provider.digest(forSessionId: "current-conc") }
        }
        var out: [String?] = []
        for await r in group { out.append(r) }
        return out
    }
    let first = try #require(results.first ?? nil)
    #expect(results.count == 8)
    #expect(results.allSatisfy { $0 == first })

    // Cache level: the single-flight mechanism itself — concurrent misses
    // on ONE key run the build closure exactly once, even when the build
    // is slow enough that every caller arrives while it is in flight.
    let counter = BuildCounter()
    let key = "single-flight-\(UUID().uuidString)"
    let values = await withTaskGroup(of: String.self) { group in
        for _ in 0..<8 {
            group.addTask {
                await SessionDigestCache.shared.value(forKey: key) {
                    counter.increment()
                    Thread.sleep(forTimeInterval: 0.05)
                    return "BUILT-ONCE"
                }
            }
        }
        var out: [String] = []
        for await v in group { out.append(v) }
        return out
    }
    #expect(values.allSatisfy { $0 == "BUILT-ONCE" })
    #expect(counter.count == 1)
}

@Test
func sessionDigest_eviction_recovers_identical_bytes_from_disk() async throws {
    let root = try makeTempRoot("evict")
    let provider = try makeFullFixture(root: root, currentId: "current-evict")
    let first = try #require(await provider.digest(forSessionId: "current-evict"))

    // The first build persisted the exact bytes to the session-state file.
    let diskPath = root.appendingPathComponent(
        "chat/session_state/current-evict/digest.txt")
    #expect(FileManager.default.fileExists(atPath: diskPath.path))
    #expect(try String(contentsOf: diskPath, encoding: .utf8) == first)

    // Sources move AND the in-memory cache is dropped (simulated eviction —
    // the 256-session LRU evicting an active session, or an app restart).
    let handle = try FileHandle(forWritingTo: provider.worklogPath)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(
        (worklogRow(ts: "2026-06-10T12:00:00.000Z", summary: "POST-EVICTION row.") + "\n").utf8
    ))
    try handle.close()
    await SessionDigestCache.shared.removeAll()

    // Re-resolution reads the disk copy — identical bytes, never a rebuild
    // from the moved sources.
    let second = try #require(await provider.digest(forSessionId: "current-evict"))
    #expect(second == first)
    #expect(!second.contains("POST-EVICTION"))
}

@Test
func sessionDigest_interleaved_session_is_not_selected_as_prior() async throws {
    // Three sessions: the current one (created 09:00), a GENUINELY prior one
    // (last active the evening before), and an INTERLEAVED one — created
    // before the current session but still active after it started (second
    // window / parallel surface). The interleaved session is the
    // most-recently-updated other session, so an id!=current rule alone
    // would wrongly headline it as "previous session ended".
    let root = try makeTempRoot("interleave")
    let json = """
    [
      {"id": "genuine-prior", "createdAt": "2026-06-09T18:00:00Z",
       "updatedAt": "2026-06-09T20:00:00Z", "title": "Genuine prior",
       "messageCount": 4, "lastMessagePreview": "prior tail"},
      {"id": "current-int", "createdAt": "2026-06-10T09:00:00Z",
       "updatedAt": "2026-06-10T09:00:00Z", "title": "Current"},
      {"id": "interleaved", "createdAt": "2026-06-10T08:00:00Z",
       "updatedAt": "2026-06-10T10:00:00Z", "title": "Interleaved other window",
       "messageCount": 9, "lastMessagePreview": "interleaved tail"}
    ]
    """
    try write(json, to: root.appendingPathComponent("chat/sessions.json"))
    let provider = SessionDigestProvider(
        dataRoot: root,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: root.appendingPathComponent("worklog/none.jsonl")
    )

    // Selection: anchored on current.createdAt — the interleaved session
    // (updatedAt 10:00 > anchor 09:00) is skipped; the genuinely-prior one
    // is selected.
    let prior = try #require(provider.latestPriorSession(excluding: "current-int"))
    #expect(prior.id == "genuine-prior")

    // And the rendered digest headlines the right session.
    let digest = try #require(await provider.digest(forSessionId: "current-int"))
    #expect(digest.contains("Genuine prior"))
    #expect(digest.contains("ended 2026-06-09 20:00 UTC"))
    #expect(!digest.contains("Interleaved other window"))
    #expect(!digest.contains("interleaved tail"))

    // A session with NO persisted row (brand-new, index not yet written)
    // anchors at digest-build time: every session that was last active
    // before "now" qualifies, so the most recent one wins.
    let unknown = provider.latestPriorSession(excluding: "never-written")
    #expect(unknown?.id == "interleaved")
}

// M16 (2026-07-09): `sessionDigest_build_is_fast_enough` was deleted. It was a
// pure wall-clock assertion (`elapsedMs < 250`) on a shared, parallel test
// machine: it could only ever fail for reasons unrelated to the digest builder,
// and it could never catch a real regression that stayed under the budget on the
// developer's box. See the hang-proofing convention: pin the caps the code
// enforces, never a tight elapsed bound.
//
// M12 follow-up (2026-07-09): there IS a structural invariant to pin, and it is
// the one that made the wall-clock test pass in the first place — `worklogLines`
// reads the LAST `worklogTailBytes` (128 KiB) of the worklog, never the whole
// file. That bound is what keeps the build sub-linear in a log that grows without
// limit, and it is observable without a clock: an entry parked beyond the tail
// window cannot reach the digest no matter how recent its timestamp is.

/// Structural guard (replaces the deleted wall-clock perf test): the digest
/// builder's cost is bounded by a fixed tail read, not by worklog size.
///
/// The fixture writes a worklog whose FIRST line carries the NEWEST timestamp
/// of any row. If the builder read the whole file, that row would sort first and
/// headline the "Activity since then" list. It must not appear — it sits before
/// the 128 KiB tail window, so the builder never reads its bytes. The
/// "+N more entries since." count corroborates it: N counts only the rows
/// actually parsed, which must be strictly fewer than the rows on disk.
@Test
func sessionDigest_readsBoundedWorklogTail_notTheWholeFile() async throws {
    let root = try makeTempRoot("worklog-tail-bound")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSessionsFixture(root: root, currentId: "current-bounded")

    // `worklogTailBytes` is 128 KiB and private. Overshoot it decisively so the
    // test does not depend on the exact figure — only on the fact that SOME
    // fixed bound exists and the head of the file falls outside it.
    let filler = String(repeating: "x", count: 180)
    let fillerRowCount = 600
    var lines: [String] = [
        // Newest timestamp in the file, parked at byte 0.
        worklogRow(ts: "2026-06-10T23:59:00.000Z", summary: "HEAD-SENTINEL-BEYOND-TAIL")
    ]
    for _ in 0..<fillerRowCount {
        lines.append(worklogRow(ts: "2026-06-10T08:00:00.000Z", summary: "filler \(filler)"))
    }
    // The three genuinely-newest rows INSIDE the tail window.
    lines.append(worklogRow(ts: "2026-06-10T09:00:00.000Z", summary: "TAIL-MARKER-1"))
    lines.append(worklogRow(ts: "2026-06-10T09:01:00.000Z", summary: "TAIL-MARKER-2"))
    lines.append(worklogRow(ts: "2026-06-10T09:02:00.000Z", summary: "TAIL-MARKER-3"))
    let totalRowsOnDisk = lines.count

    let worklog = try writeWorklogFixture(root: root, lines: lines)
    let onDiskBytes = try #require(
        (try? FileManager.default.attributesOfItem(atPath: worklog.path))?[.size] as? NSNumber
    ).intValue
    // The fixture must actually exceed the bound, or the test proves nothing.
    #expect(onDiskBytes > 128 * 1024)

    let provider = SessionDigestProvider(
        dataRoot: root,
        agentInboxDir: root.appendingPathComponent("agent_inbox"),
        worklogPath: worklog
    )
    let digest = try #require(provider.buildDigest(currentSessionId: "current-bounded"))

    // The three newest rows inside the window are the three that surface.
    #expect(digest.contains("TAIL-MARKER-3"))
    #expect(digest.contains("TAIL-MARKER-2"))
    #expect(digest.contains("TAIL-MARKER-1"))

    // The bound, stated directly: the newest row on disk never got read.
    #expect(!digest.contains("HEAD-SENTINEL-BEYOND-TAIL"))

    // And the count line reports fewer entries than the file holds — the
    // builder parsed a window, not the log.
    let countLine = try #require(
        digest.split(separator: "\n").first { $0.contains("more entries since.") },
        "expected a '+N more entries since.' line for a worklog this large"
    )
    let reported = try #require(
        countLine.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
    )
    #expect(reported > 0)
    #expect(reported < totalRowsOnDisk - 3)
}
