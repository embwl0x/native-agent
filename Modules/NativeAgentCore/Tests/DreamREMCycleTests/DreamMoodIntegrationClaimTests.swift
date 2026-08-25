import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

// Ledger fence core.substrate.organism — dream.moodIntegrationClaim
//
// `claimMoodIntegration` (DreamCycleRunner.swift) is an exclusive-create marker
// beside the diary entry: exactly one caller per calendar date gets to push the
// dream's felt tone into Agent's slow disposition layer. It returns `false` on
// ANY write error, so a genuine failure (permissions, full disk, a path that is
// not a regular file) is INDISTINGUISHABLE from "already claimed" — the nudge is
// silently skipped and the run still reports success.
//
// These evals pin the two properties that ARE contractual today:
//   1. at most ONE mood nudge per calendar date, including across a `force`
//      re-render of the same day's entry;
//   2. a claim that cannot be taken never blocks or corrupts the diary commit.
// The distinguishability of failure-vs-already-claimed needs a production seam
// (see the BUILD report) and is deliberately NOT asserted here — asserting the
// swallow would freeze the bug in place.

private let moodDreamJSON = """
{"title":"Quiet Loop","summary":"A reflective beat from today — the conversation circled a familiar tension and resolved without a flourish.","mood":"contemplative","emerging_themes":["circular thinking"],"surprising_moments":["the user named the pattern"]}
"""

private func moodTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DreamMoodClaimTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func enableDreams(_ root: URL) {
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = """
    {"trainingPolicy":{"dream_scheduler":true},"personalityPolicy":{"dream_cycle_enabled":true}}
    """
    try! json.data(using: .utf8)!.write(to: dir.appendingPathComponent("policy.json"))
}

private func seedMoodSession(_ root: URL, id: String, lines: [(String, String)]) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var body = ""
    for (role, content) in lines {
        let escaped = String(
            data: try! JSONSerialization.data(withJSONObject: [content]),
            encoding: .utf8
        )!.dropFirst().dropLast()
        body += "{\"role\":\"\(role)\",\"content\":\(escaped)}\n"
    }
    try! body.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(id).jsonl"))
}

private final class MoodRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _moods: [String] = []
    var moods: [String] { lock.lock(); defer { lock.unlock() }; return _moods }
    func record(_ mood: String) { lock.lock(); _moods.append(mood); lock.unlock() }
}

private final class FixedDreamLLM: LLMClient, @unchecked Sendable {
    private let payload: String
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(_ payload: String) { self.payload = payload }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return payload
    }
}

/// One night, one felt tone — however many times the entry re-renders. A `force`
/// run rewrites the same day's diary entry and MUST NOT push a second nudge into
/// her disposition layer.
@Test
func dreamMoodIntegratesAtMostOncePerCalendarDayEvenAcrossAForcedRerender() async throws {
    let root = moodTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedMoodSession(root, id: "sess-a", lines: [
        ("user", "We circled the same tension again today."),
        ("assistant", "We did — and it resolved without a flourish."),
    ])

    let recorder = MoodRecorder()
    let llm = FixedDreamLLM(moodDreamJSON)
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: llm,
        moodSink: { mood in recorder.record(mood) }
    )

    let first = try await runner.runNightlyDreamCycle()
    #expect(first.entriesWritten == 1)
    #expect(first.errors.isEmpty)
    #expect(recorder.moods.count == 1, "the first dream must move her exactly once")
    #expect(recorder.moods.first == "contemplative", "the sink receives the dream's own mood line")

    // Forced re-render of the SAME day.
    let second = try await runner.runNightlyDreamCycle(force: true)
    #expect(second.entriesWritten == 1, "force did re-render the entry")
    #expect(llm.calls == 2, "force genuinely re-ran the dream — otherwise this proves nothing")
    #expect(
        recorder.moods.count == 1,
        "a forced re-render pushed a SECOND mood nudge: \(recorder.moods)"
    )

    // The claim marker is a real artifact on disk, exactly one per date.
    let diaryDir = root.appendingPathComponent("dream_diary", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: diaryDir.path)) ?? []
    let claims = names.filter { $0.hasPrefix(".mood_integrated_") }
    #expect(claims.count == 1, "expected exactly one claim marker, found \(claims)")
    let dateKey = DreamREMSchedule.dreamEntryDateKey()
    #expect(claims.first == ".mood_integrated_\(dateKey)")
}

/// A claim that CANNOT be taken must never block the diary commit. The claim path
/// is pre-created as a DIRECTORY, so the exclusive-create write fails with an
/// error that is not "already exists" — the same class of failure a permissions
/// or full-disk error produces.
@Test
func anUnclaimableMoodMarkerNeverBlocksOrCorruptsTheDiaryCommit() async throws {
    let root = moodTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedMoodSession(root, id: "sess-b", lines: [
        ("user", "Another quiet evening of the same loop."),
        ("assistant", "Quiet, and it closed on its own."),
    ])

    // Block the claim path before the run.
    let diaryDir = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: diaryDir, withIntermediateDirectories: true)
    let dateKey = DreamREMSchedule.dreamEntryDateKey()
    let claimPath = diaryDir.appendingPathComponent(".mood_integrated_\(dateKey)")
    try FileManager.default.createDirectory(at: claimPath, withIntermediateDirectories: true)

    let recorder = MoodRecorder()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: FixedDreamLLM(moodDreamJSON),
        moodSink: { mood in recorder.record(mood) }
    )
    let report = try await runner.runNightlyDreamCycle()

    // The dream itself still commits — the felt-tone nudge is a tail effect, not
    // a precondition. A regression that made the claim failure abort the run
    // would lose the whole night's entry.
    #expect(report.entriesWritten == 1, "an unclaimable mood marker aborted the diary commit")
    #expect(report.errors.isEmpty)
    let entry = diaryDir.appendingPathComponent("\(dateKey).md")
    #expect(FileManager.default.fileExists(atPath: entry.path))
    let body = try String(contentsOf: entry, encoding: .utf8)
    #expect(body.contains("Quiet Loop"))

    // And her disposition layer is NOT moved on a claim it never won.
    #expect(
        recorder.moods.isEmpty,
        "the mood sink fired without owning the claim: \(recorder.moods)"
    )
}

/// The counterpart to the blocked case: with a clean root the sink DOES fire.
/// Without this, the assertion above could pass simply because the sink is never
/// wired on any path.
@Test
func moodSinkFiresOnAnUncontestedClaimSoTheBlockedCaseIsNotVacuous() async throws {
    let root = moodTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedMoodSession(root, id: "sess-c", lines: [
        ("user", "A plain day, nothing sharp."),
        ("assistant", "Plain, and that was fine."),
    ])
    let recorder = MoodRecorder()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: FixedDreamLLM(moodDreamJSON),
        moodSink: { mood in recorder.record(mood) }
    )
    let report = try await runner.runNightlyDreamCycle()
    #expect(report.entriesWritten == 1)
    #expect(recorder.moods == ["contemplative"])
}
