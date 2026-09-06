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

/// Write doctor/latest.json with explicit check ids, so a test can name the
/// Doctor-only diagnostic rows the hook must ignore.
private func writeDoctorRows(_ dir: URL, rows: [(id: String, status: String)]) {
    let checks = rows.map { row in
        "{\"id\":\"\(row.id)\",\"title\":\"\(row.id)\",\"status\":\"\(row.status)\"}"
    }.joined(separator: ",")
    let body = "{\"checks\":[\(checks)],\"runAt\":\"2026-09-02T00:00:00Z\"}"
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

// MARK: - FIX 3: the watched feeds are the LIVE ones, and a dead one says so

/// Write `rows` to `relative` under `dir`, optionally back-dating the file's
/// modification time (that is what makes a feed "silent").
private func writeFeed(
    _ dir: URL, relative: String, rows: [String], modified: Date? = nil
) {
    let url = relative.split(separator: "/").reduce(dir) {
        $0.appendingPathComponent(String($1))
    }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? rows.joined(separator: "\n").data(using: .utf8)!.write(to: url)
    if let modified {
        try? FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
    }
}

@Test func selfHeal_burst_in_the_live_telegram_feed_fires() async {
    // The firehose the detector was NOT watching: `telegram/errors.jsonl` takes
    // a row on every failed poll while `logs/errors.jsonl` has had no writer
    // since the Python daemon was retired.
    let dir = tempDir("telegramBurst"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    let ts = SelfHealingHook.isoString(clock.now)
    writeFeed(dir, relative: "telegram/errors.jsonl",
              rows: (0..<SelfHealingHook.errorBurstThreshold).map {
                  "{\"at\":\"\(ts)\",\"context\":\"poll\",\"error\":\"unavailable \($0)\"}"
              })

    await hook.tick()

    #expect(collector.items.count == 1)
    #expect(collector.items.first?.evidence.contains("[telegram]") == true)
}

@Test func selfHeal_burst_counts_across_every_watched_feed() async {
    // Neither feed alone crosses the threshold; together they do. A per-file
    // detector would have missed a machine failing on two surfaces at once.
    let dir = tempDir("splitBurst"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    let ts = SelfHealingHook.isoString(clock.now)
    let half = SelfHealingHook.errorBurstThreshold / 2
    writeFeed(dir, relative: "slack/errors.jsonl",
              rows: (0..<half).map { "{\"at\":\"\(ts)\",\"error\":\"socket \($0)\"}" })
    writeFeed(dir, relative: "logs/background_loop_failures.jsonl",
              rows: (0..<(SelfHealingHook.errorBurstThreshold - half)).map {
                  "{\"createdAt\":\"\(ts)\",\"loopId\":\"telegram_poll\",\"error\":\"502 \($0)\"}"
              })

    await hook.tick()

    #expect(collector.items.count == 1)
    let evidence = collector.items.first?.evidence ?? ""
    #expect(evidence.contains("[slack]"))
    #expect(evidence.contains("[loops]"))
}

@Test func selfHeal_deadFeed_is_no_signal_never_clean() async {
    // A feed full of rows that nobody has WRITTEN in three months. Its rows are
    // not current, and its emptiness-of-recent-rows is not health.
    let dir = tempDir("deadFeed"); defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let ts = SelfHealingHook.isoString(now)
    writeFeed(dir, relative: "logs/errors.jsonl",
              rows: (0..<(SelfHealingHook.errorBurstThreshold + 5)).map {
                  "{\"ts\":\"\(ts)\",\"msg\":\"stale row \($0)\"}"
              },
              modified: now.addingTimeInterval(-90 * 24 * 60 * 60))

    let statuses = SelfHealingHook.scanErrorFeeds(dataRoot: dir, now: now)
    guard let legacy = statuses.first(where: { $0.feed.label == "legacy" }) else {
        Issue.record("legacy feed missing from the watch list")
        return
    }
    #expect(legacy.silent)
    #expect(legacy.recentCount == 0)   // a dead file's rows are never "current"
    #expect(legacy.summary(now: now).contains("no signal"))
    #expect(!legacy.summary(now: now).contains("0 row(s)"))
    // Every other feed is absent → also no signal, never "clean".
    #expect(statuses.allSatisfy { $0.silent })
    #expect(statuses.first(where: { $0.feed.label == "telegram" })?
        .summary(now: now).contains("never written") == true)

    // And it does not manufacture a burst.
    let clock = ClockBox(now)
    let collector = ProposalCollector()
    let llm = DiagLLM()
    let hook = makeHook(dir: dir, clock: clock, llm: llm, collector: collector)
    writeDoctor(dir, statuses: ["ok"])
    await hook.tick()
    #expect(collector.items.isEmpty)
    #expect(llm.calls == 0)
}

@Test func selfHeal_liveButQuietFeed_reports_a_row_count_not_no_signal() async {
    let dir = tempDir("quietLive"); defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Written just now, but with only old rows in it: a working feed with
    // nothing recent to say. That IS evidence of health.
    let old = SelfHealingHook.isoString(now.addingTimeInterval(-3 * 60 * 60))
    writeFeed(dir, relative: "telegram/errors.jsonl",
              rows: ["{\"at\":\"\(old)\",\"error\":\"an hour-old blip\"}"])

    let statuses = SelfHealingHook.scanErrorFeeds(dataRoot: dir, now: now)
    let telegram = statuses.first { $0.feed.label == "telegram" }
    #expect(telegram?.silent == false)
    #expect(telegram?.recentCount == 0)
    #expect(telegram?.summary(now: now) == "0 row(s)")
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


// MARK: - Doctor-only rows never drive an unattended decision
//
// 2026-09-02 live incident: two new Doctor rows (`prompt_prefix_health`,
// `subconscious_vitals`) grade a measurement window and went red on pre-fix
// history. The heartbeat pushed an alert about them; this hook would have
// filed an evolution proposal about them. Filing a proposal is an unattended
// decision, so the same exclusion applies here — the rows stay fully visible
// in the Doctor UI and are invisible to every robot.

@Test func selfHeal_doctorOnlyFailingRow_neverFlipsTheVerdict() async {
    let dir = tempDir("doctoronly"); defer { try? FileManager.default.removeItem(at: dir) }
    let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
    let collector = ProposalCollector()
    let hook = makeHook(dir: dir, clock: clock, llm: DiagLLM(), collector: collector)

    // Baseline: everything green.
    writeDoctorRows(dir, rows: [("storage", "ok"), ("memory_store", "ok")])
    await hook.tick()
    #expect(collector.items.isEmpty)

    // Both Doctor-only rows go red. This is the exact snapshot that woke User.
    writeDoctorRows(dir, rows: [
        ("storage", "ok"),
        ("memory_store", "ok"),
        ("prompt_prefix_health", "fail"),
        ("subconscious_vitals", "fail"),
    ])
    await hook.tick()
    // No transition, because neither row is one this hook may judge.
    #expect(collector.items.isEmpty)
    #expect(hook.loadDoctorSnapshot()?.healthy == true)

    // A REAL check failing still fires — the filter narrows what is judged,
    // it does not switch the detector off.
    writeDoctorRows(dir, rows: [
        ("storage", "fail"),
        ("prompt_prefix_health", "fail"),
    ])
    await hook.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.title.contains("Doctor failure") == true)
}

@Test func selfHeal_snapshotOfOnlyDoctorOnlyRows_isUnavailableNotHealthy() {
    let dir = tempDir("allexcluded"); defer { try? FileManager.default.removeItem(at: dir) }
    let hook = makeHook(dir: dir, clock: ClockBox(Date(timeIntervalSince1970: 1_700_000_000)),
                        llm: DiagLLM(), collector: ProposalCollector())
    writeDoctorRows(dir, rows: [
        ("prompt_prefix_health", "fail"),
        ("subconscious_vitals", "warn"),
    ])
    // Nothing judgeable was observed. That is UNKNOWN, never a clean bill of
    // health — the same rule the malformed-snapshot branch follows.
    #expect(hook.loadDoctorSnapshot() == nil)
}
