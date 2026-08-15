// L4-13 + L4-15 (upgrade campaign 2026-08, disjoint sweep).
//
// L4-13: a failure receipt whose `error` field is blank says nothing — the
// row exists, the evidence doesn't. Two layers: `describeLoopError` gives
// loops an always-non-empty error string (type name + NSError domain/code
// when `localizedDescription` is empty), and `appendFailureReceipt` backstops
// any empty string that reaches it anyway.
//
// L4-15: `golden_eval` and `stale_artifact_sweep` were deliberately
// de-registered (assembly comments carry the why), but their durable stamps
// lived on in background_loop_state.json forever because entries deliberately
// outlive `unregister`. The tombstone drops them at load, so the next flush
// writes a file without them.

import Foundation
import Testing
@testable import BackgroundLoops
import PersistenceCore

// MARK: - L4-13, the describer

private struct EmptyDescriptionError: Error, LocalizedError {
    var errorDescription: String? { "" }
}

private struct SpokenError: Error, LocalizedError {
    var errorDescription: String? { "the disk was full" }
}

@Test func describeLoopError_prefersANonEmptyLocalizedDescription() {
    #expect(SwiftNativeLoopScheduler.describeLoopError(SpokenError()) == "the disk was full")
}

@Test func describeLoopError_emptyDescriptionFallsBackToTypeAndCode() {
    let described = SwiftNativeLoopScheduler.describeLoopError(EmptyDescriptionError())
    #expect(!described.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(described.contains("EmptyDescriptionError"))
    // The NSError bridge's domain + code ride along so the receipt stays
    // greppable even for an anonymous error type.
    #expect(described.contains("code"))
}

// MARK: - L4-13, the receipt backstop

private struct EmptyErrorLoop: LoopRunner {
    let loopId = "empty_error_loop"
    let interval: TimeInterval = 3_600
    func tickOutcome() async -> LoopTickOutcome {
        .failed(error: "   ")
    }
}

@Test func failureReceiptWithEmptyErrorStringStillCarriesEvidence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EmptyErrReceipt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipts = root.appendingPathComponent("failures.jsonl")
    let sched = SwiftNativeLoopScheduler(failureReceiptsPath: receipts)
    await sched.register(EmptyErrorLoop())

    await sched._testRunOneTick(loopId: "empty_error_loop")

    let text = try String(contentsOf: receipts, encoding: .utf8)
    #expect(text.contains("background_loop.failure"))
    #expect(text.contains("unspecified failure (empty error description)"))
    // The receipt must never carry a blank error field.
    #expect(!text.contains(#""error":"""#))
}

// MARK: - L4-15, the retirement tombstone

@Test func retiredLoopStampsAreDroppedOnLoadAndAbsentFromTheNextFlush() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RetiredLoopState-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("background_loop_state.json")

    // A prior process left stamps for one live loop and both retired ones.
    let iso = ISO8601DateFormatter()
    let priorRun = iso.string(from: Date(timeIntervalSince1970: 1_786_000_000))
    let seeded = """
    {"version":"1","loops":{"weekly":"\(priorRun)","golden_eval":"\(priorRun)","stale_artifact_sweep":"\(priorRun)"}}
    """
    try seeded.write(to: statePath, atomically: true, encoding: .utf8)

    // Registering forces the load, and a first-ever loop id forces a durable
    // flush of the whole (now-pruned) map.
    let sched = SwiftNativeLoopScheduler(loopStatePath: statePath)
    await sched.register(EmptyErrorLoop())
    // Bounded wait for the rewrite to include the retired-key drop.
    let deadline = Date().addingTimeInterval(5)
    var loops: [String: Any] = [:]
    while Date() < deadline {
        if let data = try? Data(contentsOf: statePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let l = obj["loops"] as? [String: Any],
           l["empty_error_loop"] != nil {
            loops = l
            break
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    // The live stamp survived; the retired pair is gone from the rewrite.
    #expect(loops["weekly"] as? String == priorRun)
    #expect(loops["golden_eval"] == nil)
    #expect(loops["stale_artifact_sweep"] == nil)
}

@Test func retiredIdsAreExactlyTheDeRegisteredPair() {
    // mission_executor is a LIVE wire id (de-mission rename fence) and must
    // never appear here; if this set grows, the assembly comment for the
    // newly retired loop is the place that justifies it.
    #expect(SwiftNativeLoopScheduler.retiredLoopIds == ["golden_eval", "stale_artifact_sweep"])
}
