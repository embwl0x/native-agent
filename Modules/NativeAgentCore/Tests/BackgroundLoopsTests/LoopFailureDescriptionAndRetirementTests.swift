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

@Test func identicalConsecutiveFailuresCoalesceButRecoveryStartsANewIncident() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailureIncidentCoalescing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipts = root.appendingPathComponent("failures.jsonl")
    let sched = SwiftNativeLoopScheduler(failureReceiptsPath: receipts)

    await sched.recordFailure(loopId: "L", error: "boom")
    await sched.recordFailure(loopId: "L", error: "boom")
    await sched.recordResult(loopId: "L", result: "completed")
    await sched.recordFailure(loopId: "L", error: "boom")

    let rows = await sched._testFailureReceiptRows()
    #expect(rows.count == 2)

    guard case .object(let first) = rows[0],
          case .int(let occurrences)? = first["occurrences"] else {
        Issue.record("expected coalesced receipt row")
        return
    }
    #expect(occurrences == 2)
    #expect(first["firstAt"] != nil)
    #expect(first["lastAt"] != nil)
}

// MARK: - FIX-13, append-only receipts for a flapping loop

@Test func flappingLoopReceiptsStayAppendOnlyAndReadTheSameCoalescedRow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlappingReceiptIO-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipts = root.appendingPathComponent("failures.jsonl")

    // A feed with history already in it — the case that used to cost a full
    // read + two full rewrites PER receipt, under the lock, while the loop was
    // flapping fastest.
    let seeded = (0..<500).map { i in
        "{\"id\":\"seed-\(i)\",\"kind\":\"background_loop.failure\",\"loopId\":\"other\","
            + "\"status\":\"failed\",\"error\":\"old\",\"createdAt\":\"2026-01-01T00:00:00Z\","
            + "\"firstAt\":\"2026-01-01T00:00:00Z\",\"lastAt\":\"2026-01-01T00:00:00Z\","
            + "\"occurrences\":1}"
    }.joined(separator: "\n") + "\n"
    try Data(seeded.utf8).write(to: receipts)

    let sched = SwiftNativeLoopScheduler(failureReceiptsPath: receipts)
    let flaps = 50
    for _ in 0..<flaps {
        await sched.recordFailure(loopId: "flapper", error: "boom")
    }

    // Same coalesced read result readers have always seen: ONE row for the
    // incident, carrying the full occurrence count.
    let rows = await sched._testFailureReceiptRows()
    #expect(rows.count == seeded.split(separator: "\n").count + 1)
    guard case .object(let last) = rows.last,
          case .string("flapper")? = last["loopId"],
          case .int(let occurrences)? = last["occurrences"] else {
        Issue.record("expected one coalesced flapper row, got \(String(describing: rows.last))")
        return
    }
    #expect(occurrences == flaps)
    #expect(last["firstAt"] != nil)
    #expect(last["lastAt"] != nil)

    // Bounded I/O: the 500 seeded rows were never rewritten. Byte-identical
    // prefix proves the appends touched only the tail; a stable inode proves no
    // whole-file atomic replacement happened on ANY of the 50 receipts (the old
    // path minted a new inode per receipt via temp-write + rename).
    let text = try String(contentsOf: receipts, encoding: .utf8)
    #expect(text.hasPrefix(seeded))
    let inode = (try FileManager.default.attributesOfItem(atPath: receipts.path)[.systemFileNumber]) as? Int

    await sched.recordFailure(loopId: "flapper", error: "boom")
    let inodeAfter = (try FileManager.default.attributesOfItem(atPath: receipts.path)[.systemFileNumber]) as? Int
    #expect(inode != nil)
    #expect(inode == inodeAfter)
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

@Test func retiredIdsAreExactlyTheDeRegisteredSet() {
    // mission_executor is a LIVE wire id (de-mission rename fence) and must
    // never appear here; if this set grows, the assembly comment for the
    // newly retired loop is the place that justifies it.
    //
    // `rem_cycle` joined 2026-08-31: the duplicate weekly REM lane, retired in
    // favour of the `nativeagent-weekly-rem` TriggerScheduler job.
    // `memory_consolidation` and `self_improvement_sweep` are NOT here — both
    // are live weekly lanes with no other owner.
    #expect(SwiftNativeLoopScheduler.retiredLoopIds
            == ["golden_eval", "stale_artifact_sweep", "rem_cycle"])
    #expect(!SwiftNativeLoopScheduler.retiredLoopIds.contains("memory_consolidation"))
    #expect(!SwiftNativeLoopScheduler.retiredLoopIds.contains("self_improvement_sweep"))
}
