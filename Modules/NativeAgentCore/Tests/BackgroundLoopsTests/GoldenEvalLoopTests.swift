import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore

// MEASURE v2 (north-star, 2026-06-15): the golden-eval loop must be OFF by
// default (no token spend unasked), submit at most once per week (marker
// dedup), and retry if a tick submitted nothing.

private final class SubmitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _submitted = 0
    func record(_ n: Int) { lock.lock(); _calls += 1; _submitted += n; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var submitted: Int { lock.lock(); defer { lock.unlock() }; return _submitted }
}

private func goldenTempDir(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("goldenEval_\(tag)_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func goldenEval_loopId_and_interval() {
    let loop = GoldenEvalLoop(dataRoot: hermeticDataRoot(), isEnabled: { false }, submitGoldenJobs: { _ in 0 })
    #expect(loop.loopId == "golden_eval")
    #expect(loop.interval == 7 * 24 * 60 * 60)
}

@Test func goldenEval_disabled_doesNothing() async {
    let dir = goldenTempDir("disabled")
    defer { try? FileManager.default.removeItem(at: dir) }
    let counter = SubmitCounter()
    let loop = GoldenEvalLoop(
        dataRoot: dir, isEnabled: { false },
        submitGoldenJobs: { _ in counter.record(2); return 2 }
    )
    await loop.tick()
    #expect(counter.calls == 0)   // OFF by default → never submits
}

@Test func goldenEval_markerFailureIsTypedAndNeverSubmits() async throws {
    let dir = goldenTempDir("marker_failure")
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("blocked".utf8).write(
        to: dir.appendingPathComponent("golden_eval"),
        options: .atomic
    )
    let counter = SubmitCounter()
    let loop = GoldenEvalLoop(
        dataRoot: dir,
        isEnabled: { true },
        submitGoldenJobs: { _ in counter.record(1); return 1 }
    )

    let outcome = await loop.tickOutcome()

    guard case .failed(let error) = outcome else {
        Issue.record("expected typed marker failure, got \(outcome)")
        return
    }
    #expect(error.contains("marker"))
    #expect(counter.calls == 0)
}

@Test func goldenEval_enabled_submitsOncePerWeek() async {
    let dir = goldenTempDir("once")
    defer { try? FileManager.default.removeItem(at: dir) }
    let counter = SubmitCounter()
    let loop = GoldenEvalLoop(
        dataRoot: dir, isEnabled: { true },
        submitGoldenJobs: { _ in counter.record(2); return 2 }
    )
    await loop.tick()   // first: submits + stamps the weekly marker
    await loop.tick()   // same week: marker dedup → skipped
    #expect(counter.calls == 1)
    #expect(counter.submitted == 2)
}

private final class ReceivedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date?
    func set(_ d: Date) { lock.lock(); _value = d; lock.unlock() }
    var value: Date? { lock.lock(); defer { lock.unlock() }; return _value }
}

@Test func goldenEval_passesLoopClockToSubmitter() async {
    let dir = goldenTempDir("clock")
    defer { try? FileManager.default.removeItem(at: dir) }
    // The submitter MUST receive the loop's `now` (so each execution's createdAt
    // keys to the same ISO-week bucket the marker used) — NOT a fresh Date()
    // (gpt-5.5 re-review HIGH: shared timestamp source).
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let received = ReceivedDate()
    let loop = GoldenEvalLoop(
        dataRoot: dir, clock: { fixed }, isEnabled: { true },
        submitGoldenJobs: { now in received.set(now); return 1 }
    )
    await loop.tick()
    #expect(received.value == fixed)
}

@Test func goldenEval_zeroSubmitted_retriesNextTick() async {
    let dir = goldenTempDir("retry")
    defer { try? FileManager.default.removeItem(at: dir) }
    let counter = SubmitCounter()
    // Submission infra "down" — returns 0 each time. The marker must be
    // restored so the next tick retries (no week burned on a failed submit).
    let loop = GoldenEvalLoop(
        dataRoot: dir, isEnabled: { true },
        submitGoldenJobs: { _ in counter.record(0); return 0 }
    )
    let first = await loop.tickOutcome()
    let second = await loop.tickOutcome()
    #expect(first == .failed(error: "golden submission produced no jobs"))
    #expect(second == .failed(error: "golden submission produced no jobs"))
    #expect(counter.calls == 2)   // retried because nothing was submitted
}
