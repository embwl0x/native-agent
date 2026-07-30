import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore

/// LLM stub that returns a fixed response and counts calls (thread-safe so it
/// satisfies `@Sendable` capture in the loop).
private final class StubLLMClient: LLMClient, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var _callCount = 0
    init(response: String) { self.response = response }
    var callCount: Int { lock.withLock { _callCount } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _callCount += 1 }
        return response
    }
}

/// Thread-safe collector for the injected `stageProposal` closure.
private final class StageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [SelfImprovementProposal] = []
    func add(_ p: SelfImprovementProposal) { lock.lock(); _items.append(p); lock.unlock() }
    var items: [SelfImprovementProposal] { lock.lock(); defer { lock.unlock() }; return _items }
}

private func tempDir(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("weeklySI_\(tag)_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Four findings: one runtime WITH a valid apply op (stageable), one code
/// (report-only), one "runtime" with NO apply op (must be dropped — the
/// no-dead-button guarantee), and one bogus kind (dropped).
private let scriptedFindings = """
{
  "summary": "Quiet week; one underused skill and one flaky tool.",
  "findings": [
    {"kind": "runtime", "title": "Drop unused skill", "evidence": "skill X never fired", "proposedChange": "disable skill X", "apply": {"op": "disable_skill", "target": "skill-x"}},
    {"kind": "code", "title": "Fix flaky tool", "evidence": "tool Y errored 12x", "proposedChange": "handle the nil case in tool Y"},
    {"kind": "runtime", "title": "Runtime with no op", "evidence": "e", "proposedChange": "c"},
    {"kind": "bogus", "title": "ignore me", "evidence": "", "proposedChange": ""}
  ]
}
"""

@Test func weeklySI_loopId_and_interval() {
    let loop = WeeklySelfImprovementLoop(
        llm: StubLLMClient(response: ""), isEnabled: { true }, stageProposal: { _ in }
    )
    #expect(loop.loopId == "self_improvement_sweep")
    #expect(loop.interval == 7 * 24 * 60 * 60)
}

@Test func weeklySI_disabled_does_nothing() async {
    let dir = tempDir("disabled")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = StubLLMClient(response: scriptedFindings)
    let collector = StageCollector()
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { false },
        stageProposal: { collector.add($0) }
    )
    await loop.tick()
    #expect(llm.callCount == 0)                 // never asked the LLM
    #expect(collector.items.isEmpty)            // nothing staged
    let digestDir = dir.appendingPathComponent("self_improvement/digests")
    #expect((try? FileManager.default.contentsOfDirectory(atPath: digestDir.path))?.isEmpty ?? true)
}

@Test func weeklySI_markerFailureIsTypedAndNeverSpendsLLM() async throws {
    let dir = tempDir("marker_failure")
    defer { try? FileManager.default.removeItem(at: dir) }
    // Block creation of `<root>/self_improvement/last_weekly_run` by placing a
    // regular file where the directory must live.
    try Data("blocked".utf8).write(
        to: dir.appendingPathComponent("self_improvement"),
        options: .atomic
    )
    let llm = StubLLMClient(response: scriptedFindings)
    let loop = WeeklySelfImprovementLoop(
        llm: llm,
        dataRoot: dir,
        isEnabled: { true },
        stageProposal: { _ in }
    )

    let outcome = await loop.tickOutcome()

    guard case .failed(let error) = outcome else {
        Issue.record("expected typed marker failure, got \(outcome)")
        return
    }
    #expect(!error.isEmpty)
    #expect(llm.callCount == 0)
}

@Test func weeklySI_enabled_ingests_analyzes_stages_runtime_only_and_writes_digest() async {
    let dir = tempDir("run")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = StubLLMClient(response: scriptedFindings)
    let collector = StageCollector()
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true },
        stageProposal: { collector.add($0) }
    )
    await loop.tick()

    #expect(llm.callCount == 1)
    // Only the ONE runtime finding is staged; the code finding and the
    // bogus-kind finding are not.
    // Only the runtime finding WITH a valid apply op stages; the code finding,
    // the op-less "runtime" finding, and the bogus-kind finding are all dropped.
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.kind == .runtime)
    #expect(collector.items.first?.title == "Drop unused skill")
    #expect(collector.items.first?.applyOp == "disable_skill")
    #expect(collector.items.first?.applyTarget == "skill-x")
    // Digest written, and it mentions both the runtime and code findings.
    let digestDir = dir.appendingPathComponent("self_improvement/digests")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: digestDir.path)) ?? []
    #expect(files.count == 1)
    if let name = files.first,
       let body = try? String(contentsOf: digestDir.appendingPathComponent(name), encoding: .utf8) {
        #expect(body.contains("Drop unused skill"))
        #expect(body.contains("Fix flaky tool"))
    } else {
        Issue.record("no digest written")
    }
}

@Test func weeklySI_is_idempotent_within_the_week() async {
    let dir = tempDir("idem")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = StubLLMClient(response: scriptedFindings)
    let collector = StageCollector()
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true },
        stageProposal: { collector.add($0) }
    )
    await loop.tick()       // first run: stages + writes marker
    await loop.tick()       // same week: must skip

    #expect(llm.callCount == 1)          // LLM not called a second time
    #expect(collector.items.count == 1)  // no duplicate proposal
}

@Test func weeklySI_manualRequestBypassesCadenceWithoutDeletingCanonicalMarker() async throws {
    let dir = tempDir("manual")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = StubLLMClient(response: scriptedFindings)
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true }, stageProposal: { _ in }
    )

    #expect(await loop.tickOutcome() == .completed(result: "weekly proposals staged"))
    let marker = dir.appendingPathComponent("self_improvement/last_weekly_run")
    let firstStamp = try Data(contentsOf: marker)

    let token = try await WeeklySelfImprovementLoop.requestManualRun(dataRoot: dir)
    #expect(await loop.tickOutcome() == .completed(result: "weekly proposals staged"))
    try await WeeklySelfImprovementLoop.clearManualRunRequest(dataRoot: dir, token: token)

    #expect(llm.callCount == 2)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(!(try Data(contentsOf: marker)).isEmpty)
    #expect(!firstStamp.isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("self_improvement/manual_run_requested").path
        )
    )
}

@Test func weeklySI_oldCallerCannotClearANewerManualRequest() async throws {
    let dir = tempDir("manual_token")
    defer { try? FileManager.default.removeItem(at: dir) }
    let oldToken = try await WeeklySelfImprovementLoop.requestManualRun(dataRoot: dir)
    let newToken = try await WeeklySelfImprovementLoop.requestManualRun(dataRoot: dir)

    try await WeeklySelfImprovementLoop.clearManualRunRequest(dataRoot: dir, token: oldToken)
    let request = dir.appendingPathComponent("self_improvement/manual_run_requested")
    #expect(try String(contentsOf: request, encoding: .utf8) == newToken)

    try await WeeklySelfImprovementLoop.clearManualRunRequest(dataRoot: dir, token: newToken)
    #expect(!FileManager.default.fileExists(atPath: request.path))
}

// MEASURE leg (north-star, 2026-06-15): the injected mission-outcome trend must
// reach the self-improvement LLM prompt so the improvement brain reasons over
// real job outcomes, not just chat/error/doctor proxies.

/// LLM stub that records the prompt it was handed.
private final class PromptCapturingLLM: LLMClient, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var _callCount = 0
    private var _prompt: String?
    init(response: String) { self.response = response }
    var callCount: Int { lock.withLock { _callCount } }
    var capturedPrompt: String? { lock.withLock { _prompt } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _callCount += 1; _prompt = prompt }
        return response
    }
}

@Test func weeklySI_foldsWorkshopOutcomeSignalIntoPrompt() async {
    let dir = tempDir("outcomes")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = PromptCapturingLLM(response: scriptedFindings)
    let marker = "MARKER_OUTCOME_TREND_XYZ_completion_rate_UP"
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true },
        stageProposal: { _ in },
        workshopOutcomes: { marker }
    )
    await loop.tick()
    #expect(llm.callCount == 1)
    #expect(llm.capturedPrompt?.contains(marker) == true)
}

@Test func weeklySI_emptyWorkshopOutcomeSignalIsOmitted() async {
    let dir = tempDir("outcomes_empty")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = PromptCapturingLLM(response: scriptedFindings)
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true },
        stageProposal: { _ in },
        workshopOutcomes: { "" }   // no history → no signal
    )
    await loop.tick()
    #expect(llm.callCount == 1)
    // No Workshop execution-outcomes header when the provider returns empty.
    #expect(llm.capturedPrompt?.contains("Mission outcomes") == false)
}

// MEASURE attribution: the weekly digest persists the Workshop execution-outcome snapshot
// AT THIS PASS (point-in-time record tying proposals to the number then).
@Test func weeklySI_digestPersistsWorkshopOutcomeSnapshot() async {
    let dir = tempDir("digest_outcomes")
    defer { try? FileManager.default.removeItem(at: dir) }
    let llm = StubLLMClient(response: scriptedFindings)
    let marker = "MEASURE_SNAPSHOT_MARKER_XYZ"
    let loop = WeeklySelfImprovementLoop(
        llm: llm, dataRoot: dir, isEnabled: { true },
        stageProposal: { _ in },
        workshopOutcomes: { marker }
    )
    await loop.tick()
    let digestDir = dir.appendingPathComponent("self_improvement/digests")
    let mds = ((try? FileManager.default.contentsOfDirectory(at: digestDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "md" }
    #expect(mds.count == 1)
    let content = (try? String(contentsOf: mds[0], encoding: .utf8)) ?? ""
    #expect(content.contains(marker))   // snapshot folded into the durable digest
}
