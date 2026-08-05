import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import ProviderRouting

/// LLM stub returning a fixed diagnosis, thread-safe call counter.
private final class DiagLLM: LLMClient, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var _calls = 0
    init(response: String = "Likely root cause: storage check failing.") { self.response = response }
    var calls: Int { lock.withLock { _calls } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return response
    }
}

/// LLM that always throws — proves a failed diagnostic pass does not consume
/// the cooldown.
private final class ThrowingLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw NSError(domain: "test", code: 1)
    }
}

/// Collects the injected fileProposal (title, evidence) calls.
private final class ProposalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [(title: String, evidence: String)] = []
    func add(_ t: String, _ e: String) { lock.lock(); _items.append((t, e)); lock.unlock() }
    var items: [(title: String, evidence: String)] { lock.lock(); defer { lock.unlock() }; return _items }
}

/// Counts resolved-proposal closeout callbacks.
private final class CloseoutCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    func add() { lock.lock(); _calls += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
}

/// Mutable clock holder for cooldown-window tests.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

private func tempDir(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("selfHeal_\(tag)_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Write doctor/latest.json with the given check statuses.
private func writeDoctor(_ dir: URL, statuses: [String]) {
    let checks = statuses.enumerated().map { i, s in
        "{\"id\":\"check\(i)\",\"title\":\"Check \(i)\",\"status\":\"\(s)\"}"
    }.joined(separator: ",")
    let body = "{\"checks\":[\(checks)],\"runAt\":\"2026-06-11T00:00:00Z\"}"
    let doctorDir = dir.appendingPathComponent("doctor", isDirectory: true)
    try? FileManager.default.createDirectory(at: doctorDir, withIntermediateDirectories: true)
    try? body.data(using: .utf8)!.write(to: doctorDir.appendingPathComponent("latest.json"))
}

/// Write errors.jsonl with `count` rows stamped at `now` (within the window).
private func writeErrors(_ dir: URL, count: Int, now: Date, extraLine: String? = nil) {
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let ts = SelfHealingHook.isoString(now)
    var rows = (0..<count).map { "{\"ts\":\"\(ts)\",\"msg\":\"error \($0)\"}" }
    if let extraLine { rows.append(extraLine) }
    try? rows.joined(separator: "\n").data(using: .utf8)!
        .write(to: logsDir.appendingPathComponent("errors.jsonl"))
}

private func makeHook(
    dir: URL,
    clock: ClockBox,
    llm: any LLMClient,
    collector: ProposalCollector,
    closeDoctorFailureProposals: @escaping @Sendable () async -> Void = {}
) -> SelfHealingHook {
    SelfHealingHook(
        llm: llm,
        router: SwiftNativeProviderRouting(),
        dataRoot: dir,
        clock: { clock.now },
        fileProposal: { collector.add($0, $1) },
        closeDoctorFailureProposals: closeDoctorFailureProposals)
}

@Test func selfHeal_loopId_and_surface() {
    let loop = SelfHealingHook(llm: DiagLLM(), dataRoot: hermeticDataRoot(), fileProposal: { _, _ in })
    #expect(loop.loopId == "self_healing")
    #expect(SelfHealingHook.surface == "diagnostics")
    #expect(loop.interval == 30 * 60)
}

@Test func selfHeal_doctor_transition_fires_once_not_every_tick() async {
    let dir = tempDir("transition"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)

    // Tick 1: doctor healthy → establishes the prior baseline, no fire
    // (a first observation asserts no transition).
    writeDoctor(dir, statuses: ["ok", "ok"])
    await hook.tick()
    #expect(collector.items.isEmpty)

    // Tick 2: doctor now failing → healthy→fail transition fires.
    writeDoctor(dir, statuses: ["ok", "fail"])
    await hook.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.title.contains("Doctor failure") == true)

    // Tick 3: still failing → NOT a new transition (prior already fail), and
    // cooldown holds anyway. No second proposal.
    await hook.tick()
    #expect(collector.items.count == 1)
}

@Test func selfHeal_unchanged_doctor_state_does_not_rewrite_stamp() async throws {
    let dir = tempDir("stabledoctor"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    let stamp = dir.appendingPathComponent("evolution", isDirectory: true)
        .appendingPathComponent("self_heal", isDirectory: true)
        .appendingPathComponent("doctor_state.json")

    writeDoctor(dir, statuses: ["ok"])
    await hook.tick()
    let first = try String(contentsOf: stamp, encoding: .utf8)

    clock.advance(600)
    await hook.tick()
    let second = try String(contentsOf: stamp, encoding: .utf8)

    #expect(first == second)
    #expect(collector.items.isEmpty)
}

@Test func selfHeal_no_transition_when_first_observation_is_fail() async {
    let dir = tempDir("firstfail"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    // First-ever observation is already failing — no prior healthy state to
    // transition FROM, so nothing fires (honest: we never saw it go bad).
    writeDoctor(dir, statuses: ["fail"])
    await hook.tick()
    #expect(collector.items.isEmpty)
}

@Test func selfHeal_healthyDoctorRunsResolvedProposalCloseoutOnly() async {
    let dir = tempDir("healthycloseout"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let closeout = CloseoutCollector()
    let llm = DiagLLM()
    let hook = makeHook(
        dir: dir,
        clock: clock,
        llm: llm,
        collector: collector,
        closeDoctorFailureProposals: { closeout.add() }
    )

    writeDoctor(dir, statuses: ["ok"])
    await hook.tick()

    #expect(closeout.calls == 1)
    #expect(collector.items.isEmpty)
    #expect(llm.calls == 0)
    let cooldownStamp = dir.appendingPathComponent("evolution", isDirectory: true)
        .appendingPathComponent("self_heal", isDirectory: true)
        .appendingPathComponent("last_proposal.json")
    #expect(!FileManager.default.fileExists(atPath: cooldownStamp.path))
}

@Test func selfHeal_burst_threshold_edge() async {
    // Below threshold → no fire.
    let dirLow = tempDir("burstlow"); defer { try? FileManager.default.removeItem(at: dirLow) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let lowCollector = ProposalCollector()
    let lowHook = makeHook(dir: dirLow, clock: clock, llm: DiagLLM(), collector: lowCollector)
    writeDoctor(dirLow, statuses: ["ok"])   // healthy: isolate the burst detector
    writeErrors(dirLow, count: SelfHealingHook.errorBurstThreshold - 1, now: clock.now)
    await lowHook.tick()
    #expect(lowCollector.items.isEmpty)

    // Exactly at threshold → fires.
    let dirHi = tempDir("bursthi"); defer { try? FileManager.default.removeItem(at: dirHi) }
    let hiCollector = ProposalCollector()
    let hiHook = makeHook(dir: dirHi, clock: clock, llm: DiagLLM(), collector: hiCollector)
    writeDoctor(dirHi, statuses: ["ok"])
    writeErrors(dirHi, count: SelfHealingHook.errorBurstThreshold, now: clock.now)
    await hiHook.tick()
    #expect(hiCollector.items.count == 1)
    #expect(hiCollector.items.first?.title.contains("error burst") == true)
}

@Test func selfHeal_old_errors_outside_window_do_not_count() async {
    let dir = tempDir("burstold"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    // Stamp the errors well BEFORE the window — they must not count.
    let old = clock.now.addingTimeInterval(-(SelfHealingHook.errorBurstWindow + 600))
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold + 5, now: old)
    await hook.tick()
    #expect(collector.items.isEmpty)
}

@Test func selfHeal_cooldown_suppresses_repeat_then_reengages() async {
    let dir = tempDir("cooldown"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])

    // Burst → first proposal.
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold, now: clock.now)
    await hook.tick()
    #expect(collector.items.count == 1)

    // Re-burst within the cooldown window → suppressed.
    clock.advance(SelfHealingHook.cooldownSeconds / 2)
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold, now: clock.now)
    await hook.tick()
    #expect(collector.items.count == 1)

    // Past the cooldown → re-engages.
    clock.advance(SelfHealingHook.cooldownSeconds)
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold, now: clock.now)
    await hook.tick()
    #expect(collector.items.count == 2)
}

@Test func selfHeal_cooldown_exposes_one_exact_future_deadline() async {
    let dir = tempDir("deadline"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold, now: clock.now)

    await hook.tick()

    let expected = clock.now.addingTimeInterval(SelfHealingHook.cooldownSeconds)
    #expect(hook.nextMeaningfulDeadline(after: clock.now) == expected)
    #expect(hook.nextMeaningfulDeadline(after: expected) == nil)
}

@Test func selfHeal_failed_diagnosis_does_not_consume_cooldown() async {
    let dir = tempDir("llmfail"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    // Tick 1: throwing LLM → no proposal, cooldown NOT stamped.
    let failHook = makeHook(dir: dir, clock: clock, llm: ThrowingLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold, now: clock.now)
    guard case .failed(let failure) = await failHook.tickOutcome() else {
        Issue.record("expected typed self-healing diagnosis failure")
        return
    }
    #expect(failure.contains("diagnosis"))
    #expect(collector.items.isEmpty)

    // Tick 2 immediately after (a working LLM, same data root) → fires,
    // proving the failed pass left no cooldown stamp behind.
    let okHook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    await okHook.tick()
    #expect(collector.items.count == 1)
}

@Test func selfHeal_store_write_failure_consumes_no_cooldown_or_transition() async {
    let dir = tempDir("storefail"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()

    // Tick 1: healthy baseline.
    let throwingStore = SelfHealingHook(
        llm: DiagLLM(),
        router: SwiftNativeProviderRouting(),
        dataRoot: dir,
        clock: { clock.now },
        fileProposal: { _, _ in throw NSError(domain: "store", code: 7) })
    writeDoctor(dir, statuses: ["ok"])
    await throwingStore.tick()

    // Tick 2: healthy→fail transition, but the proposal store write THROWS →
    // nothing filed, cooldown NOT stamped, transition NOT consumed.
    writeDoctor(dir, statuses: ["fail"])
    await throwingStore.tick()
    #expect(collector.items.isEmpty)

    // Tick 3: working store, same data root → the surviving transition fires
    // immediately (no cooldown was burned by the failed write).
    let okHook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    await okHook.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.title.contains("Doctor failure") == true)
}

@Test func selfHeal_failed_diagnosis_does_not_consume_doctor_transition() async {
    let dir = tempDir("llmfailtransition"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()

    // Baseline healthy, then fail with a throwing LLM → transition observed
    // but the diagnostic pass dies; the healthy→fail edge must survive.
    let failHook = makeHook(dir: dir, clock: clock, llm: ThrowingLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    await failHook.tick()
    writeDoctor(dir, statuses: ["fail"])
    await failHook.tick()
    #expect(collector.items.isEmpty)

    // Working LLM next tick: the un-consumed transition fires.
    let okHook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    await okHook.tick()
    #expect(collector.items.count == 1)
}

@Test func selfHeal_stale_row_interleaved_in_tail_does_not_hide_newer_rows() async {
    // Adversarial ordering: current rows, ONE stale dated row, then more
    // current rows appended after it. An early break at the stale row would
    // miss the rows behind it and false-negative a real burst.
    let dir = tempDir("interleaved"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let nowTS = SelfHealingHook.isoString(clock.now)
    let staleTS = SelfHealingHook.isoString(
        clock.now.addingTimeInterval(-(SelfHealingHook.errorBurstWindow + 600)))
    var rows = (0..<(SelfHealingHook.errorBurstThreshold - 1)).map {
        "{\"ts\":\"\(nowTS)\",\"msg\":\"current early \($0)\"}"
    }
    rows.append("{\"ts\":\"\(staleTS)\",\"msg\":\"stale straggler\"}")
    rows.append("{\"ts\":\"\(nowTS)\",\"msg\":\"current late\"}")   // tips it to threshold
    try? rows.joined(separator: "\n").data(using: .utf8)!
        .write(to: logsDir.appendingPathComponent("errors.jsonl"))
    await hook.tick()
    #expect(collector.items.count == 1)   // the burst MUST fire
}

@Test func selfHeal_undated_rows_never_count_toward_burst() async {
    let dir = tempDir("undated"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    // A pile of timestamp-less rows (corrupt/legacy log) — counting these as
    // "current" would make a stale log a PERMANENT false burst trigger.
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let rows = (0..<(SelfHealingHook.errorBurstThreshold + 10)).map { "{\"msg\":\"legacy row \($0)\"}" }
    try? rows.joined(separator: "\n").data(using: .utf8)!
        .write(to: logsDir.appendingPathComponent("errors.jsonl"))
    await hook.tick()
    #expect(collector.items.isEmpty)
}

@Test func selfHeal_evidence_redacts_secrets_and_carries_diagnosis() async {
    let dir = tempDir("redact"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(
        dir: dir, clock: clock,
        llm: DiagLLM(response: "Root cause: token refresh loop."),
        collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    // One error row embeds a secret-looking token; it must be redacted in the
    // evidence that lands in the proposal.
    let secret = "{\"ts\":\"\(SelfHealingHook.isoString(clock.now))\",\"msg\":\"auth failed token=sk-ABCDEFGH12345678\"}"
    writeErrors(dir, count: SelfHealingHook.errorBurstThreshold - 1, now: clock.now, extraLine: secret)
    await hook.tick()

    #expect(collector.items.count == 1)
    let evidence = collector.items.first?.evidence ?? ""
    #expect(evidence.contains("Root cause: token refresh loop."))   // diagnosis present
    #expect(evidence.contains("[REDACTED]"))                        // secret scrubbed
    #expect(!evidence.contains("sk-ABCDEFGH12345678"))              // raw secret gone
}

@Test func selfHeal_no_signals_no_fire() async {
    let dir = tempDir("quiet"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let llm = DiagLLM()
    let hook = makeHook(dir: dir, clock: clock, llm: llm, collector: collector)
    // No doctor file, no errors file → nothing to act on, no crash, no LLM call.
    await hook.tick()
    #expect(collector.items.isEmpty)
    #expect(llm.calls == 0)
}

@Test func selfHeal_redactSecrets_patterns() {
    let cases = [
        "Authorization: Bearer abcdef1234567890",
        "api_key=\"verysecretvalue123\"",
        "ghp_" + "0123456789ABCDEFabcdef",
        "key sk-ant-" + "0123456789abcdef",
    ]
    for c in cases {
        let out = SelfHealingHook.redactSecrets(c)
        #expect(out.contains("[REDACTED]"), "expected redaction in: \(c) → \(out)")
    }
}
