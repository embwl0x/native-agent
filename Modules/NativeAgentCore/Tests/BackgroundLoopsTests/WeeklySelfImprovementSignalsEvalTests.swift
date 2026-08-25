import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore

// MARK: - core.loops eval wave — the weekly brain's INPUTS and its code lane
//
// Closes si.weekly.signalGather and si.weekly.fileCodeFinding.
//
// si.weekly.signalGather — every read inside `gatherSignals` is `try?`-guarded.
// A renamed chat-message directory or a moved log path silently yields an empty
// section, and the weekly brain reasons over nothing while the pass reports a
// normal-looking success. `gatherSignals` is private, so these evals drive it
// through `tickOutcome()` and read the signals off the PROMPT the loop actually
// sends — the same bytes the model would see.
//
// si.weekly.fileCodeFinding — the U2b code lane. Every existing construction in
// WeeklySelfImprovementLoopTests.swift omits `fileCodeFinding`, so the code
// branch ran only in production. Here it is wired, counted, and made to throw.

/// LLM stub that CAPTURES the prompt (the existing StubLLMClient in
/// WeeklySelfImprovementLoopTests.swift only counts calls).
private final class CapturingLLMClient: LLMClient, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var _prompts: [String] = []
    init(response: String) { self.response = response }
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _prompts.count }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return response
    }
}

private final class ProposalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [SelfImprovementProposal] = []
    private var _shouldThrow = false
    func setThrowing(_ value: Bool) { lock.lock(); _shouldThrow = value; lock.unlock() }
    var items: [SelfImprovementProposal] { lock.lock(); defer { lock.unlock() }; return _items }
    func record(_ p: SelfImprovementProposal) throws {
        lock.lock()
        _items.append(p)
        let shouldThrow = _shouldThrow
        lock.unlock()
        if shouldThrow {
            throw NSError(domain: "ProposalRecorder", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "code lane write failed"])
        }
    }
}

private let oneRuntimeOneCode = """
{
  "summary": "One skill to retire, one bug to file.",
  "findings": [
    {"kind":"runtime","title":"Drop unused skill","evidence":"skill X never fired",
     "proposedChange":"disable skill X","apply":{"op":"disable_skill","target":"skill-x"}},
    {"kind":"code","title":"Fix flaky tool","evidence":"tool Y errored 12x",
     "proposedChange":"handle the nil case in tool Y"}
  ]
}
"""

private struct WeeklyFixture {
    let root: URL
    let now: Date

    static func make(_ tag: String) throws -> WeeklyFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("weeklySI-signals-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WeeklyFixture(root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func write(_ relativePath: String, _ body: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url, options: .atomic)
    }

    func loop(
        llm: any LLMClient,
        stage: @escaping @Sendable (SelfImprovementProposal) async throws -> Void = { _ in },
        code: (@Sendable (SelfImprovementProposal) async throws -> Void)? = nil
    ) -> WeeklySelfImprovementLoop {
        WeeklySelfImprovementLoop(
            llm: llm,
            dataRoot: root,
            clock: { now },
            isEnabled: { true },
            stageProposal: stage,
            fileCodeFinding: code
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("core.loops · weekly self-improvement signals")
struct WeeklySelfImprovementSignalsEvalTests {

    /// PRESENCE, per section. With all four sources seeded at the live paths,
    /// none of the four sections may degrade to "(none)" / be missing. A path
    /// or key rename fails here instead of quietly shipping an empty prompt.
    @Test func everySeededSignalSectionReachesThePrompt() async throws {
        let f = try WeeklyFixture.make("present")
        defer { f.cleanup() }

        try f.write("chat/messages/session-1.jsonl", """
        {"role":"user","content":"CHAT-MARKER-recent-ask","createdAt":"\(f.iso(daysAgo: 1))"}
        {"role":"assistant","content":"sure","createdAt":"\(f.iso(daysAgo: 1))"}
        {"role":"user","content":"CHAT-MARKER-stale-ask","createdAt":"\(f.iso(daysAgo: 30))"}
        """)
        try f.write("logs/errors.jsonl", """
        {"createdAt":"\(f.iso(daysAgo: 2))","message":"ERR-MARKER-recent"}
        """)
        try f.write("doctor/latest.json", #"{"status":"DOCTOR-MARKER"}"#)
        try f.write("skills/registry.json", #"{"skills":["SKILL-MARKER"]}"#)

        let llm = CapturingLLMClient(response: oneRuntimeOneCode)
        let outcome = await f.loop(llm: llm).tickOutcome()
        #expect(outcome == .completed(result: "weekly proposals staged"))

        let prompt = try #require(llm.prompts.first)

        // 1. chat
        #expect(prompt.contains("## Chat activity (last 7 days)"))
        #expect(prompt.contains("CHAT-MARKER-recent-ask"),
                "a recent user message must reach the brain — this is where corrections live")
        #expect(prompt.contains("across 1 session(s)"))
        #expect(!prompt.contains("Messages: 0 "), "a populated chat dir must not report zero")
        #expect(!prompt.contains("CHAT-MARKER-stale-ask"),
                "the 7-day window is real: a 30-day-old message must be excluded")

        // 2. errors
        #expect(prompt.contains("## Error log (last 7 days)"))
        #expect(prompt.contains("ERR-MARKER-recent"))

        // 3. doctor
        #expect(prompt.contains("## Doctor health (latest)"))
        #expect(prompt.contains("DOCTOR-MARKER"))

        // 4. skills
        #expect(prompt.contains("## Skill registry"))
        #expect(prompt.contains("SKILL-MARKER"))
    }

    /// TEETH FOR THE ABOVE. The same loop against a data root where each source
    /// sits one rename away from where the reader looks: the pass still reports
    /// success, still writes a digest, and the brain sees nothing. This is the
    /// silent-zero mode named in the ledger, asserted rather than described —
    /// and it is what makes the presence test above non-vacuous.
    @Test func renamedSourcePathsDegradeSilentlyToAnEmptyPrompt() async throws {
        let f = try WeeklyFixture.make("renamed")
        defer { f.cleanup() }

        // chat/session_messages/ instead of chat/messages/
        try f.write("chat/session_messages/session-1.jsonl", """
        {"role":"user","content":"CHAT-MARKER-recent-ask","createdAt":"\(f.iso(daysAgo: 1))"}
        """)
        // logs/error.jsonl (singular) instead of logs/errors.jsonl
        try f.write("logs/error.jsonl", #"{"createdAt":"2026-08-20T00:00:00Z","message":"ERR-MARKER"}"#)
        // doctor/last.json instead of doctor/latest.json
        try f.write("doctor/last.json", #"{"status":"DOCTOR-MARKER"}"#)
        // skills/skills.json instead of skills/registry.json
        try f.write("skills/skills.json", #"{"skills":["SKILL-MARKER"]}"#)

        let llm = CapturingLLMClient(response: oneRuntimeOneCode)
        let outcome = await f.loop(llm: llm).tickOutcome()

        #expect(outcome == .completed(result: "weekly proposals staged"),
                "the pass reports SUCCESS on an empty brain — the silent mode")
        let prompt = try #require(llm.prompts.first)
        #expect(prompt.contains("Messages: 0 across 0 session(s)"))
        #expect(!prompt.contains("CHAT-MARKER-recent-ask"))
        #expect(prompt.contains("## Error log (last 7 days)\n(none)"))
        #expect(!prompt.contains("ERR-MARKER"))
        #expect(!prompt.contains("## Doctor health (latest)"),
                "the doctor section is omitted entirely, not marked absent")
        #expect(!prompt.contains("## Skill registry"))
    }

    /// si.weekly.fileCodeFinding — when the lane is wired, EVERY code-class
    /// finding reaches it exactly once AND still appears in the digest (the
    /// lane is additive, not a replacement). Runtime findings never leak into
    /// the code lane.
    @Test func codeFindingsReachTheWiredLaneExactlyOnce_andStillAppearInTheDigest() async throws {
        let f = try WeeklyFixture.make("codelane")
        defer { f.cleanup() }
        let llm = CapturingLLMClient(response: oneRuntimeOneCode)
        let staged = ProposalRecorder()
        let filed = ProposalRecorder()

        let outcome = await f.loop(
            llm: llm,
            stage: { try staged.record($0) },
            code: { try filed.record($0) }
        ).tickOutcome()

        #expect(outcome == .completed(result: "weekly proposals staged"))
        #expect(filed.items.count == 1, "the one code finding is filed exactly once")
        #expect(filed.items.first?.kind == .code)
        #expect(filed.items.first?.title == "Fix flaky tool")
        #expect(staged.items.count == 1)
        #expect(staged.items.first?.kind == .runtime,
                "runtime and code findings must not cross lanes")

        let digestDir = f.root.appendingPathComponent("self_improvement/digests")
        let names = try FileManager.default.contentsOfDirectory(atPath: digestDir.path)
        let name = try #require(names.first)
        let body = try String(contentsOf: digestDir.appendingPathComponent(name), encoding: .utf8)
        #expect(body.contains("Fix flaky tool"),
                "filing a code finding must not remove it from the digest")
        #expect(body.contains("Drop unused skill"))
    }

    /// UNWIRED LANE (the assembly's nil default, and the honest default on a
    /// non-repo install): the code finding dies in the digest with no signal —
    /// and the pass still reports success. Pinned so the pre-U2b behavior is a
    /// deliberate fallback rather than something that can regress unnoticed.
    @Test func unwiredCodeLaneSilentlyDropsTheFinding() async throws {
        let f = try WeeklyFixture.make("nolane")
        defer { f.cleanup() }
        let llm = CapturingLLMClient(response: oneRuntimeOneCode)
        let staged = ProposalRecorder()

        let outcome = await f.loop(llm: llm, stage: { try staged.record($0) }, code: nil).tickOutcome()

        #expect(outcome == .completed(result: "weekly proposals staged"))
        #expect(staged.items.count == 1)
        let digestDir = f.root.appendingPathComponent("self_improvement/digests")
        let names = try FileManager.default.contentsOfDirectory(atPath: digestDir.path)
        let body = try String(
            contentsOf: digestDir.appendingPathComponent(try #require(names.first)),
            encoding: .utf8)
        #expect(body.contains("Fix flaky tool"),
                "digest-only is the whole remaining trace when the lane is nil")
    }

    /// A THROWING code lane must be OBSERVABLE: `.failed`, no digest, and the
    /// weekly marker rolled back so the next tick re-runs the pass instead of
    /// burning the week. (Same contract the 2026-07-23 A4.5 fix gave
    /// stageProposal; nothing asserted it for the code lane.)
    @Test func throwingCodeLaneFailsTheTickAndRollsBackTheWeeklyMarker() async throws {
        let f = try WeeklyFixture.make("throwing")
        defer { f.cleanup() }
        let llm = CapturingLLMClient(response: oneRuntimeOneCode)
        let filed = ProposalRecorder()
        filed.setThrowing(true)

        let failed = await f.loop(llm: llm, code: { try filed.record($0) }).tickOutcome()
        guard case .failed(let error) = failed else {
            Issue.record("a throwing code lane must surface as .failed, got \(failed)")
            return
        }
        #expect(error.contains("code lane write failed"))

        let digestDir = f.root.appendingPathComponent("self_improvement/digests")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: digestDir.path)) ?? []
        #expect(names.isEmpty, "a failed pass must not leave a digest claiming it ran")

        // Marker rollback: the very next tick re-runs the whole pass rather
        // than skipping as "weekly pass already committed".
        filed.setThrowing(false)
        let retry = await f.loop(llm: llm, code: { try filed.record($0) }).tickOutcome()
        #expect(retry == .completed(result: "weekly proposals staged"))
        #expect(llm.callCount == 2, "the rolled-back marker must let the retry spend a fresh pass")
        #expect(filed.items.count == 2)
    }
}
