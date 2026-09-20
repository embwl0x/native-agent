import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

// Ledger fence core.substrate.organism — rem.weeklyMarker
//
// STUCK STAMP. `data/harness/last_weekly_rem_run` is the cross-driver weekly
// idempotency marker for REM. The stamp lands BEFORE the LLM pass (so two
// drivers can't both run) and is restored on failure (so a failed pass doesn't
// suppress the retry). If that restore is ever missed, ONE failed run silences
// REM for a full week — with no error surface anywhere: the next run logs the
// benign "already ran within 6 days" line and returns a zero report. The file is
// not even registered as an instrument source, so nothing dates it either.
//
// The existing suite covers the corrupt-marker fail-closed path and the
// concurrent-driver path. Neither covers the RESTORE. These do.

private func markerTempRoots() -> (data: URL, persona: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-weekly-marker-\(UUID().uuidString)", isDirectory: true)
    let data = base.appendingPathComponent("data", isDirectory: true)
    let persona = base.appendingPathComponent("persona", isDirectory: true)
    try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
    return (data, persona)
}

private let markerTestNow: Date = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: "2026-05-31")!
}()

private func seedMarkerREMInputs(dataRoot: URL, personaRoot: URL) throws {
    let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (date, daysAgo) in [("2026-05-28", 3), ("2026-05-29", 2)] {
        let url = dir.appendingPathComponent("\(date).md")
        try "I kept returning to a lesson about steadiness.\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: markerTestNow.addingTimeInterval(TimeInterval(-daysAgo * 86_400))],
            ofItemAtPath: url.path
        )
    }
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
}

@Test
func weeklyREMIgnoresUnreadableEntriesOutsideTheDateWindow() async throws {
    let (dataRoot, personaRoot) = markerTempRoots()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedMarkerREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let oldEntry = dataRoot.appendingPathComponent("dream_diary/2026-05-01.md")
    try fm.createSymbolicLink(at: oldEntry, withDestinationURL: oldEntry)
    #expect(throws: (any Error).self) {
        _ = try String(contentsOf: oldEntry, encoding: .utf8)
    }
    let llm = MockLLMClient(scriptedResponses: ["[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { markerTestNow }
    )
    _ = try await consolidator.runWeeklyREM()
    #expect(llm.callCount == 1)
    #expect(fm.fileExists(atPath: markerURL(dataRoot).path))
}

private func markerURL(_ dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("last_weekly_rem_run")
}

@Test(arguments: ["diary", "diary-directory", "proposal", "proposal-io", "proposal-base"])
func weeklyREMUnreadContentPreservesBytesAndClaimAndRetries(failure: String) async throws {
    let (dataRoot, personaRoot) = markerTempRoots()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedMarkerREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let marker = markerURL(dataRoot)
    try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    let priorClaim = Data("2026-05-01T00:00:00Z prior-claim".utf8)
    try priorClaim.write(to: marker)
    let diary = dataRoot.appendingPathComponent("dream_diary")
    let growth = personaRoot.appendingPathComponent("GROWTH.md")
    let growthBytes = Data(String(repeating: "authored preamble without entry boundaries\n", count: 1000).utf8)
    try growthBytes.write(to: growth)
    let blocked: URL
    let original: Data
    let malformed = Data([0xff, 0xfe])
    if failure == "diary" {
        blocked = diary.appendingPathComponent("2026-05-28.md")
        original = try Data(contentsOf: blocked)
        try malformed.write(to: blocked)
    } else if failure == "diary-directory" {
        blocked = diary
        original = Data()
        try fm.moveItem(at: diary, to: dataRoot.appendingPathComponent("saved-diary"))
        try malformed.write(to: blocked)
    } else {
        // A young diary skips distillation and reaches the growth evidence read.
        try fm.removeItem(at: diary)
        blocked = dataRoot.appendingPathComponent(failure == "proposal-base" ? "rem_proposals_base.json" : "rem_proposals.jsonl")
        original = failure == "proposal-base" ? Data("{\"rows\":[]}".utf8) : Data()
        if failure == "proposal-io" {
            try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
            try malformed.write(to: blocked.appendingPathComponent("original"))
        } else {
            try malformed.write(to: blocked)
        }
    }
    let llm = MockLLMClient(scriptedResponses: ["[]", "[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true), clock: { markerTestNow }
    )
    await #expect(throws: (any Error).self) { _ = try await consolidator.runWeeklyREM() }
    let bytesURL = failure == "proposal-io" ? blocked.appendingPathComponent("original") : blocked
    #expect(try Data(contentsOf: bytesURL) == malformed)
    #expect(try Data(contentsOf: growth) == growthBytes)
    #expect(try Data(contentsOf: marker) == priorClaim)
    if failure == "diary-directory" {
        try fm.removeItem(at: blocked)
        try fm.moveItem(at: dataRoot.appendingPathComponent("saved-diary"), to: diary)
    } else {
        if failure == "proposal-io" { try fm.removeItem(at: blocked) }
        try original.write(to: blocked)
    }
    _ = try await consolidator.runWeeklyREM()
    #expect(try Data(contentsOf: marker) != priorClaim)
    #expect(try Data(contentsOf: growth) == growthBytes)
}

/// Throws on the FIRST call only, so one consolidator instance can fail and the
/// next can succeed against the same root.
private final class FailOnceLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let successPayload: String
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(successPayload: String = "[]") { self.successPayload = successPayload }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        let index: Int = lock.withLock { _calls += 1; return _calls }
        if index == 1 {
            throw NSError(domain: "REMWeeklyMarkerRollbackTests", code: -1005, userInfo: [
                NSLocalizedDescriptionKey: "the network connection was lost",
            ])
        }
        return successPayload
    }
}

/// A failed weekly REM pass must NOT leave its claim stamped. Otherwise the
/// weekly window stays closed for six days and every retry logs a benign skip.
@Test
func aFailedWeeklyREMPassRestoresTheMarkerSoTheRetryIsAdmitted() async throws {
    let (dataRoot, personaRoot) = markerTempRoots()
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedMarkerREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)

    let marker = markerURL(dataRoot)
    #expect(!FileManager.default.fileExists(atPath: marker.path), "fixture starts with no prior REM run")

    let llm = FailOnceLLM()
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { markerTestNow }
    )

    // (1) The failing pass surfaces as a throw — not a quiet zero report.
    await #expect(throws: (any Error).self) {
        _ = try await consolidator.runWeeklyREM()
    }
    #expect(llm.calls == 1, "the LLM pass genuinely ran and failed")

    // (2) The claim was rolled back to its pre-claim state (there was none).
    let stampedAfterFailure: String? = (try? Data(contentsOf: marker))
        .flatMap { String(data: $0, encoding: .utf8) }
    #expect(
        stampedAfterFailure == nil || stampedAfterFailure?.isEmpty == true,
        "a failed pass left the weekly claim stamped (\(stampedAfterFailure ?? "nil")) — REM is now silenced for six days"
    )

    // (3) THE TOOTH: the retry is admitted immediately, at the SAME clock time.
    //     If the rollback were dropped, this run would land on the "already ran
    //     within 6 days" skip and the LLM would never be called again.
    let second = try await consolidator.runWeeklyREM()
    #expect(
        llm.calls == 2,
        "the retry was suppressed by a stuck weekly marker — no LLM pass ran"
    )
    #expect(second.evidenceDatesMin == REMConstants._REM_MIN_EVIDENCE_DATES)
}

/// Positive control for the assertion above: after a run that SUCCEEDS, the
/// marker really is stamped and really does close the window. Without this, an
/// absent marker after failure could just mean the marker mechanism is dead.
@Test
func aSucceedingWeeklyREMPassStampsTheMarkerAndClosesTheWindow() async throws {
    let (dataRoot, personaRoot) = markerTempRoots()
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedMarkerREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)

    let llm = MockLLMClient(scriptedResponses: ["[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { markerTestNow }
    )

    _ = try await consolidator.runWeeklyREM()
    #expect(llm.callCount == 1)

    // The stamp exists and its FIRST whitespace token is a parseable ISO instant
    // at (or before) the run clock — that token is what the 6-day freshness
    // check reads. A malformed stamp makes every later run fail closed.
    let raw = try #require(
        (try? Data(contentsOf: markerURL(dataRoot))).flatMap { String(data: $0, encoding: .utf8) },
        "a successful pass did not stamp the weekly marker"
    )
    let firstToken = try #require(raw.split(separator: " ", maxSplits: 1).first).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let stampedAt = try #require(
        ISO8601DateFormatter().date(from: firstToken),
        "weekly marker's freshness token is not parseable: \(firstToken)"
    )
    #expect(abs(stampedAt.timeIntervalSince(markerTestNow)) < 60)
    // The claim carries a unique run id after the timestamp, so a rollback can
    // compare-and-restore exactly its own claim.
    #expect(raw.split(separator: " ").count >= 2, "weekly marker carries no unique claim token")

    // Window closed: an immediate second pass does no LLM work.
    _ = try await consolidator.runWeeklyREM()
    #expect(llm.callCount == 1, "the weekly marker did not close the window")
}
