import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

private func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DreamCycleRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTrustPolicy(_ root: URL, enabled: Bool) {
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json: String
    if enabled {
        json = """
        {"trainingPolicy":{"dream_scheduler":true},"personalityPolicy":{"dream_cycle_enabled":true}}
        """
    } else {
        json = """
        {"trainingPolicy":{"dream_scheduler":false},"personalityPolicy":{"dream_cycle_enabled":true}}
        """
    }
    try! json.data(using: .utf8)!.write(to: dir.appendingPathComponent("policy.json"))
}

/// Seed a session JSONL with role/content rows (no createdAt — legacy shape).
/// File mtime is touched to `mtime` (default now) so the recency prefilter +
/// the createdAt-fallback-to-mtime path can be exercised.
private func seedSession(_ root: URL, id: String, lines: [(String, String)], mtime: Date = Date()) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(id).jsonl")
    var body = ""
    for (role, content) in lines {
        body += "{\"role\":\"\(role)\",\"content\":\(jsonEscape(content))}\n"
    }
    try! body.data(using: .utf8)!.write(to: url)
    try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

/// Seed a session JSONL with explicit per-row createdAt timestamps. File mtime
/// is set to the newest row so the cheap mtime prefilter agrees with the rows.
private func seedSessionTimed(_ root: URL, id: String, rows: [(role: String, content: String, at: Date)]) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(id).jsonl")
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var body = ""
    for r in rows {
        body += "{\"role\":\"\(r.role)\",\"content\":\(jsonEscape(r.content)),\"createdAt\":\"\(iso.string(from: r.at))\"}\n"
    }
    try! body.data(using: .utf8)!.write(to: url)
    let newest = rows.map(\.at).max() ?? Date()
    try! FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: url.path)
}

private func jsonEscape(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
    var str = String(data: data, encoding: .utf8)!
    str.removeFirst(); str.removeLast()
    return str
}

private func diaryNames(_ root: URL) -> [String] {
    let dir = root.appendingPathComponent("dream_diary")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    // Drop the hidden state file (.dream_state.json) — only count entries.
    return names.filter { $0.hasSuffix(".md") }
}

private let cannedDreamJSON = """
{"title":"Quiet Loop","summary":"A reflective beat from today — the conversation circled a familiar tension and resolved without a flourish.","mood":"contemplative","emerging_themes":["circular thinking","resolution"],"surprising_moments":["the user named the pattern themselves"]}
"""

/// Mock LLM that returns a fixed response and CAPTURES every prompt it's sent,
/// so tests can prove which messages fed the dream.
private final class CannedLLMClient: LLMClient, @unchecked Sendable {
    let response: String
    private let lock = NSLock()
    private var _calls: Int = 0
    private var _prompts: [String] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return _prompts.last }

    init(_ response: String) { self.response = response }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1; _prompts.append(prompt) }
        return response
    }
}

private final class ThrowingLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: Int = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        throw NSError(domain: "DreamCycleRunnerTests", code: -1005, userInfo: [
            NSLocalizedDescriptionKey: "transient network connection was lost"
        ])
    }
}

private enum InjectedContextReadError: Error {
    case failed
}

/// Mutable injectable clock so the high-water-mark tests can advance "now"
/// across calendar days between runs.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func set(_ d: Date) { lock.lock(); _now = d; lock.unlock() }
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(
        timeZone: TimeZone(identifier: "UTC")!,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ))!
}

@Test
func dreamCycle_disabled_returnsDisabled() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: false)
    seedSession(root, id: "s1", lines: [("user","hi"),("assistant","hello")])

    let runner = DreamCycleRunner(dataRoot: root, llm: CannedLLMClient(cannedDreamJSON))
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.disabled == true)
    #expect(report.entriesWritten == 0)
    let diary = root.appendingPathComponent("dream_diary")
    #expect(!FileManager.default.fileExists(atPath: diary.path))
}

@Test
func dreamCycle_writesPreviousCentralDateStem() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    let runTime = utcDate(2026, 6, 17, 8, 30) // 03:30 America/Chicago.
    seedSessionTimed(root, id: "central-night", rows: [
        (role: "user", content: "yesterday's material", at: runTime.addingTimeInterval(-600)),
        (role: "assistant", content: "dream over prior day", at: runTime.addingTimeInterval(-540)),
    ])

    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: CannedLLMClient(cannedDreamJSON),
        now: { runTime }
    )
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.entriesWritten == 1)
    #expect(diaryNames(root) == ["2026-06-16.md"])
    let body = try String(
        contentsOf: root.appendingPathComponent("dream_diary/2026-06-16.md"),
        encoding: .utf8
    )
    #expect(body.contains("# Dream — 2026-06-16"))
}

/// COMBINED MODEL: two sessions touched today produce ONE dream entry for the
/// day (filename has no session suffix), via a SINGLE LLM call — not one dream
/// per session.
@Test
func dreamCycle_writesOneCombinedEntryForTheDay() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "sessA", lines: [
        ("user","Today we wrestled with the dream cycle port."),
        ("assistant","Yeah — the persona-bypass rule is the load-bearing piece.")
    ])
    seedSession(root, id: "sessB", lines: [
        ("user","Quick aside about the missions UI."),
        ("assistant","Noted — the poll fix lands the terminal status.")
    ])

    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm)
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.disabled == false)
    #expect(report.sessionsProcessed == 2)   // both sessions fed the one dream
    #expect(report.entriesWritten == 1)      // ONE entry, not two
    #expect(report.errors.isEmpty)
    #expect(llm.calls == 1)                  // ONE LLM call, not per-session

    let names = diaryNames(root)
    #expect(names.count == 1)
    // Combined entry: <date>.md, no `_<sessionId>` suffix.
    #expect(!names[0].contains("_"))
    let body = try String(contentsOf: root.appendingPathComponent("dream_diary/\(names[0])"), encoding: .utf8)
    #expect(body.contains("Quiet Loop"))
    #expect(body.contains("woven from 2 conversations"))
}

/// Five recent sessions still collapse to ONE combined dream + ONE LLM call.
@Test
func dreamCycle_collapsesManySessionsIntoOneDream() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    for idx in 0..<5 {
        seedSession(root, id: "sess\(idx)", lines: [("user", "message \(idx)"), ("assistant", "reply \(idx)")])
    }

    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm)
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.sessionsProcessed == 5)
    #expect(report.entriesWritten == 1)
    #expect(llm.calls == 1)
    #expect(diaryNames(root).count == 1)
}

/// Same-day second run is a no-op (one dream per calendar day) and must NOT
/// re-invoke the LLM.
@Test
func dreamCycle_idempotent_secondRunSameDayWritesNothing() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "sessB", lines: [("user","one"),("assistant","two")])

    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm)

    let first = try await runner.runNightlyDreamCycle()
    #expect(first.entriesWritten == 1)
    #expect(llm.calls == 1)

    let second = try await runner.runNightlyDreamCycle()
    #expect(second.entriesWritten == 0)
    #expect(llm.calls == 1)
}

/// A session whose file is older than the recency window (no prior dream mark)
/// is skipped — nothing to dream.
@Test
func dreamCycle_skipsStaleSessions() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    let old = Date().addingTimeInterval(-3 * 24 * 60 * 60)
    seedSession(root, id: "stale", lines: [("user","old")], mtime: old)

    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm)
    let report = try await runner.runNightlyDreamCycle()
    #expect(report.sessionsProcessed == 0)
    #expect(report.entriesWritten == 0)
    #expect(llm.calls == 0)
}

/// HIGH-WATER MARK: the second night dreams ONLY the messages that arrived
/// since the last dream — it must not re-read what the first dream already
/// covered. Proven by capturing the prompt: run-2 sees the new message and NOT
/// the two already-dreamed ones.
@Test
func dreamCycle_highWaterMark_dreamsOnlyNewMessages() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)

    let base = Date(timeIntervalSince1970: 1_750_000_000)        // fixed epoch
    let msg1At = base
    let msg2At = base.addingTimeInterval(60)
    let day1 = base.addingTimeInterval(3600)
    let msg3At = base.addingTimeInterval(86_400)                 // next day
    let day2 = base.addingTimeInterval(90_000)

    // Night 1: two messages exist.
    seedSessionTimed(root, id: "s", rows: [
        (role: "user", content: "ALREADY-DREAMED-ONE", at: msg1At),
        (role: "assistant", content: "ALREADY-DREAMED-TWO", at: msg2At),
    ])

    let clock = Clock(day1)
    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, now: { clock.now })

    let r1 = try await runner.runNightlyDreamCycle()
    #expect(r1.entriesWritten == 1)
    #expect(llm.calls == 1)

    // Night 2: a NEW message arrives in the same session.
    seedSessionTimed(root, id: "s", rows: [
        (role: "user", content: "ALREADY-DREAMED-ONE", at: msg1At),
        (role: "assistant", content: "ALREADY-DREAMED-TWO", at: msg2At),
        (role: "user", content: "BRAND-NEW-MESSAGE", at: msg3At),
    ])
    clock.set(day2)

    let r2 = try await runner.runNightlyDreamCycle()
    #expect(r2.entriesWritten == 1)
    #expect(llm.calls == 2)
    let prompt = llm.lastPrompt ?? ""
    #expect(prompt.contains("BRAND-NEW-MESSAGE"))          // the new material
    #expect(!prompt.contains("ALREADY-DREAMED-ONE"))       // not re-read
    #expect(!prompt.contains("ALREADY-DREAMED-TWO"))
    // Two distinct daily entries on disk.
    #expect(diaryNames(root).count == 2)
}

/// HIGH-WATER MARK: a later day with NO new messages since the last dream is a
/// clean no-op — no empty entry, no extra LLM call.
@Test
func dreamCycle_highWaterMark_noNewMessagesIsNoOp() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)

    let base = Date(timeIntervalSince1970: 1_750_000_000)
    let day1 = base.addingTimeInterval(3600)
    let day2 = base.addingTimeInterval(90_000)

    seedSessionTimed(root, id: "s", rows: [
        (role: "user", content: "hello", at: base),
        (role: "assistant", content: "hi", at: base.addingTimeInterval(30)),
    ])

    let clock = Clock(day1)
    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, now: { clock.now })

    _ = try await runner.runNightlyDreamCycle()
    #expect(llm.calls == 1)
    #expect(diaryNames(root).count == 1)

    // Next day, nothing new arrived.
    clock.set(day2)
    let r2 = try await runner.runNightlyDreamCycle()
    #expect(r2.entriesWritten == 0)
    #expect(r2.sessionsProcessed == 0)
    #expect(llm.calls == 1)                // not called again
    #expect(diaryNames(root).count == 1)   // no empty second-day entry
}

@Test
func dreamCycle_llmFailureDoesNotAdvanceMarkOrWriteEmptyEntry() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)

    let runTime = utcDate(2026, 6, 17, 8, 30)
    seedSessionTimed(root, id: "s", rows: [
        (role: "user", content: "material that still needs a dream", at: runTime.addingTimeInterval(-600)),
        (role: "assistant", content: "do not consume this on failure", at: runTime.addingTimeInterval(-540)),
    ])

    let failingLLM = ThrowingLLMClient()
    let failingRunner = DreamCycleRunner(dataRoot: root, llm: failingLLM, now: { runTime })
    let failed = try await failingRunner.runNightlyDreamCycle()

    #expect(failed.entriesWritten == 0)
    #expect(failed.sessionsProcessed == 1)
    #expect(failed.errors.contains { $0.contains("llm error") })
    #expect(failingLLM.calls == 1)
    #expect(diaryNames(root).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("dream_diary/.dream_state.json").path
    ))

    let goodLLM = CannedLLMClient(cannedDreamJSON)
    let retryRunner = DreamCycleRunner(dataRoot: root, llm: goodLLM, now: { runTime.addingTimeInterval(15 * 60) })
    let retry = try await retryRunner.runNightlyDreamCycle()

    #expect(retry.entriesWritten == 1)
    #expect(goodLLM.calls == 1)
    let prompt = goodLLM.lastPrompt ?? ""
    #expect(prompt.contains("material that still needs a dream"))
    #expect(diaryNames(root).count == 1)
}

@Test
func dreamCycle_memoryContextFailureDoesNotConsumeTheDay() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "memory-read", lines: [
        ("user", "material that must remain retryable"),
        ("assistant", "the memory context should be present before reflection"),
    ])

    let failedLLM = CannedLLMClient(cannedDreamJSON)
    let moodSpy = MoodSinkSpy()
    let failed = try await DreamCycleRunner(
        dataRoot: root,
        llm: failedLLM,
        memoryDeltaProvider: { throw InjectedContextReadError.failed },
        moodSink: moodSpy.sink
    ).runNightlyDreamCycle()

    #expect(failed.entriesWritten == 0)
    #expect(failed.errors.contains { $0.contains("memory context read failed") })
    #expect(failedLLM.calls == 0)
    #expect(diaryNames(root).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("dream_diary/.dream_state.json").path
    ))
    #expect(moodSpy.moods.isEmpty)

    let retryLLM = CannedLLMClient(cannedDreamJSON)
    let retry = try await DreamCycleRunner(
        dataRoot: root,
        llm: retryLLM,
        memoryDeltaProvider: { ["a recovered memory delta"] },
        moodSink: moodSpy.sink
    ).runNightlyDreamCycle()

    #expect(retry.entriesWritten == 1)
    #expect(retry.errors.isEmpty)
    #expect(retryLLM.calls == 1)
    #expect(moodSpy.moods == ["contemplative"])
}

@Test
func dreamCycle_feltContextFailureDoesNotConsumeTheDay() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "felt-read", lines: [
        ("user", "material whose felt context must not be fabricated"),
        ("assistant", "leave it available for a truthful retry"),
    ])

    let failedLLM = CannedLLMClient(cannedDreamJSON)
    let moodSpy = MoodSinkSpy()
    let failed = try await DreamCycleRunner(
        dataRoot: root,
        llm: failedLLM,
        feltSummaryProvider: { throw InjectedContextReadError.failed },
        moodSink: moodSpy.sink
    ).runNightlyDreamCycle()

    #expect(failed.entriesWritten == 0)
    #expect(failed.errors.contains { $0.contains("felt context read failed") })
    #expect(failedLLM.calls == 0)
    #expect(diaryNames(root).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("dream_diary/.dream_state.json").path
    ))
    #expect(moodSpy.moods.isEmpty)

    let retryLLM = CannedLLMClient(cannedDreamJSON)
    let retry = try await DreamCycleRunner(
        dataRoot: root,
        llm: retryLLM,
        feltSummaryProvider: { "steady after a demanding day" },
        moodSink: moodSpy.sink
    ).runNightlyDreamCycle()

    #expect(retry.entriesWritten == 1)
    #expect(retry.errors.isEmpty)
    #expect(retryLLM.calls == 1)
    #expect(moodSpy.moods == ["contemplative"])
}

@Test
func dreamCycle_invalidPayloadsDoNotCommitOrSignalCompletion() async throws {
    let invalidPayloads: [(label: String, body: String)] = [
        ("blank response", "   \n"),
        ("empty object", "{}"),
        ("blank title", #"{"title":"  ","summary":"S","mood":"calm","emerging_themes":[],"surprising_moments":[]}"#),
        ("blank summary", #"{"title":"T","summary":"\n ","mood":"calm","emerging_themes":[],"surprising_moments":[]}"#),
        ("wrong mood type", #"{"title":"T","summary":"S","mood":4,"emerging_themes":[],"surprising_moments":[]}"#),
        ("wrong themes type", #"{"title":"T","summary":"S","mood":"calm","emerging_themes":"theme","surprising_moments":[]}"#),
        ("non-string surprise", #"{"title":"T","summary":"S","mood":"calm","emerging_themes":[],"surprising_moments":[1]}"#),
    ]

    for invalid in invalidPayloads {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeTrustPolicy(root, enabled: true)
        seedSession(root, id: "invalid-payload", lines: [
            ("user", "do not consume this input"),
            ("assistant", "the payload must validate first"),
        ])

        let llm = CannedLLMClient(invalid.body)
        let moodSpy = MoodSinkSpy()
        let report = try await DreamCycleRunner(
            dataRoot: root,
            llm: llm,
            moodSink: moodSpy.sink
        ).runNightlyDreamCycle()

        #expect(report.entriesWritten == 0, "\(invalid.label) must not report a committed entry")
        #expect(!report.errors.isEmpty, "\(invalid.label) must report failure")
        #expect(llm.calls == 1)
        #expect(diaryNames(root).isEmpty, "\(invalid.label) must not write a diary")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("dream_diary/.dream_state.json").path
        ), "\(invalid.label) must not advance the high-water mark")
        #expect(moodSpy.moods.isEmpty, "\(invalid.label) must not signal mood completion")
    }
}

@Test
func dreamCycle_highWaterWriteFailureRollsBackAndRemainsRetryable() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "mark-failure", lines: [
        ("user", "keep this available until both files commit"),
        ("assistant", "the mark must be durable too"),
    ])

    let diaryDir = root.appendingPathComponent("dream_diary", isDirectory: true)
    let markPath = diaryDir.appendingPathComponent(".dream_state.json")
    try FileManager.default.createDirectory(at: markPath, withIntermediateDirectories: true)

    let llm = CannedLLMClient(cannedDreamJSON)
    let moodSpy = MoodSinkSpy()
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, moodSink: moodSpy.sink)
    let failed = try await runner.runNightlyDreamCycle()

    #expect(failed.entriesWritten == 0)
    #expect(failed.errors.contains { $0.contains("high-water mark write error") })
    #expect(diaryNames(root).isEmpty, "a new diary must be removed when its mark fails")
    #expect(moodSpy.moods.isEmpty)

    try FileManager.default.removeItem(at: markPath)
    let retry = try await runner.runNightlyDreamCycle()

    #expect(retry.entriesWritten == 1)
    #expect(retry.errors.isEmpty)
    #expect(diaryNames(root).count == 1)
    #expect(FileManager.default.fileExists(atPath: markPath.path))
    #expect(moodSpy.moods == ["contemplative"])
}

@Test
func dreamCycle_forcedRewriteRestoresPriorDiaryWhenHighWaterWriteFails() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    let runTime = utcDate(2026, 6, 17, 8, 30)
    seedSessionTimed(root, id: "forced-mark-failure", rows: [
        (role: "user", content: "new material", at: runTime.addingTimeInterval(-600)),
        (role: "assistant", content: "preserve the prior entry on failure", at: runTime.addingTimeInterval(-540)),
    ])

    let diaryDir = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: diaryDir, withIntermediateDirectories: true)
    let diaryPath = diaryDir.appendingPathComponent("2026-06-16.md")
    let priorDiary = "# Dream — 2026-06-16\n\n**Prior committed entry**\n"
    try Data(priorDiary.utf8).write(to: diaryPath)
    try FileManager.default.createDirectory(
        at: diaryDir.appendingPathComponent(".dream_state.json"),
        withIntermediateDirectories: true
    )

    let moodSpy = MoodSinkSpy()
    let report = try await DreamCycleRunner(
        dataRoot: root,
        llm: CannedLLMClient(cannedDreamJSON),
        moodSink: moodSpy.sink,
        now: { runTime }
    ).runNightlyDreamCycle(force: true)

    #expect(report.entriesWritten == 0)
    #expect(report.errors.contains { $0.contains("high-water mark write error") })
    #expect(try String(contentsOf: diaryPath, encoding: .utf8) == priorDiary)
    #expect(moodSpy.moods.isEmpty)
}

// MARK: - Felt dreams: the felt-tone section (prompt assembly)

/// A felt-summary provider returning a summary → the dream prompt carries the
/// felt section (header invites TONE coloring) with the summary text. Proven by
/// capturing the prompt the LLM was sent.
@Test
func dreamCycle_feltSummary_presentInPrompt() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user","hi"),("assistant","hello")])

    let llm = CannedLLMClient(cannedDreamJSON)
    let feltText = "the day has a good feel — from 2 felt moments.\n- warm — planning the weekend with User"
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: llm,
        feltSummaryProvider: { feltText }
    )
    let report = try await runner.runNightlyDreamCycle()
    #expect(report.entriesWritten == 1)

    let prompt = llm.lastPrompt ?? ""
    #expect(prompt.contains("HOW THE DAY FELT"), "felt section header missing: \(prompt)")
    #expect(prompt.contains("let it color the dream's tone"),
            "header must invite TONE coloring, never scripting: \(prompt)")
    #expect(prompt.contains("the day has a good feel"), "felt summary text missing: \(prompt)")
    #expect(prompt.contains("planning the weekend with User"))
}

/// A felt-summary provider returning nil → the felt section is ABSENT entirely
/// (silence stays silence — the header is NOT emitted empty). String-level assert.
@Test
func dreamCycle_feltSummaryNil_sectionAbsent() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user","hi"),("assistant","hello")])

    let llm = CannedLLMClient(cannedDreamJSON)
    // Default provider (nil) AND an explicit nil provider both omit the section.
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: llm,
        feltSummaryProvider: { nil }
    )
    let report = try await runner.runNightlyDreamCycle()
    #expect(report.entriesWritten == 1)

    let prompt = llm.lastPrompt ?? ""
    #expect(!prompt.contains("HOW THE DAY FELT"), "felt section must be omitted on nil: \(prompt)")
    #expect(!prompt.contains("color the dream's tone"), "felt header must not appear on nil: \(prompt)")
    // The rest of the prompt is unchanged — World/Self halves still present.
    #expect(prompt.contains("WORLD HALF"))
    #expect(prompt.contains("SELF HALF"))
}

/// An empty / whitespace-only felt summary is treated as silence too — no header.
@Test
func dreamCycle_feltSummaryEmpty_sectionAbsent() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user","hi"),("assistant","hello")])

    let llm = CannedLLMClient(cannedDreamJSON)
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: llm,
        feltSummaryProvider: { "   \n  " }
    )
    _ = try await runner.runNightlyDreamCycle()
    let prompt = llm.lastPrompt ?? ""
    #expect(!prompt.contains("HOW THE DAY FELT"), "whitespace-only felt summary must omit the section: \(prompt)")
}

// MARK: - Cancellation before the diary write (W3b Finding 1)

/// LLM that returns a valid dream body BUT cancels the enclosing dream task the
/// instant before it returns — so by the time the runner reaches the pre-write
/// `Task.checkCancellation()` guard, the task is already cancelled. Proves a
/// timed-out/abandoned dream body commits NO diary artifact.
private final class CancelBeforeReturnLLM: LLMClient, @unchecked Sendable {
    let response: String
    private let holder: DreamTaskHolder
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    init(_ response: String, holder: DreamTaskHolder) {
        self.response = response
        self.holder = holder
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        holder.cancel()  // cancel the dream task BEFORE the runner reaches its guard
        return response
    }
}

/// Thread-safe box the test uses to hand the running dream task back to the LLM
/// mock so it can cancel it mid-flight.
private final class DreamTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DreamReport, Error>?
    func set(_ t: Task<DreamReport, Error>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

@Test
func dreamCycle_cancelledBeforeWrite_commitsNoDiaryArtifact() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    let runTime = utcDate(2026, 6, 17, 8, 30)  // 03:30 America/Chicago
    // Recent material so the runner reaches the LLM call (not the empty-input
    // short-circuit) and thus the pre-write cancellation guard.
    seedSessionTimed(root, id: "central-night", rows: [
        (role: "user", content: "material that should NOT be dreamed after cancel", at: runTime.addingTimeInterval(-600)),
        (role: "assistant", content: "and neither should this", at: runTime.addingTimeInterval(-540)),
    ])

    let holder = DreamTaskHolder()
    let llm = CancelBeforeReturnLLM(cannedDreamJSON, holder: holder)
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, now: { runTime })

    // Entering the actor is a suspension point, so this synchronous `set` lands
    // before the actor body ever reaches `complete()` — the mock cancels a
    // populated handle.
    let task = Task { try await runner.runNightlyDreamCycle(force: true) }
    holder.set(task)

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    // The LLM DID run (we cancelled AFTER the response was in hand) — proof the
    // guard, not an early cancellation-throw in the LLM call, is what stopped the
    // write.
    #expect(llm.calls == 1)
    // No diary file, and the high-water mark never advanced.
    #expect(diaryNames(root).isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("dream_diary/.dream_state.json").path
    ))
}

// MARK: - Mood sink (U2a, 2026-07-09) — the dream's felt tone flows back out

/// Thread-safe capture of every mood line the runner hands its sink.
private final class MoodSinkSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _moods: [String] = []
    var moods: [String] { lock.withLock { _moods } }
    /// Record from a SYNC method — `lock()`/`unlock()` are unavailable inside the
    /// async sink closure; `withLock` is the async-safe scoped form.
    private func record(_ mood: String) { lock.withLock { _moods.append(mood) } }
    var sink: DreamMoodSink { { [self] mood in record(mood) } }
}

/// A dream that COMMITS an entry hands its mood line to the sink exactly once —
/// the same string the diary renders as `_Mood: …_`.
@Test
func dreamCycle_firesMoodSinkOnceAfterWritingTheEntry() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let spy = MoodSinkSpy()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: CannedLLMClient(cannedDreamJSON),
        moodSink: spy.sink
    )
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.entriesWritten == 1)
    #expect(spy.moods == ["contemplative"], "the sink gets the dream's own mood line: \(spy.moods)")

    let name = try #require(diaryNames(root).first)
    let body = try String(contentsOf: root.appendingPathComponent("dream_diary/\(name)"), encoding: .utf8)
    #expect(body.contains("_Mood: contemplative_"), "sink string must match what the diary renders")
}

/// One night, ONE felt tone (gpt-5.5 review HIGH, 2026-07-09): a `force` re-run
/// rewrites the same date's diary entry but must NOT nudge her disposition a
/// second time — the exclusive-create claim beside the diary entry gates the
/// sink at-most-once per calendar day, however many times the dream re-renders.
@Test
func dreamCycle_forcedRerunDoesNotFireTheMoodSinkTwice() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let spy = MoodSinkSpy()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: CannedLLMClient(cannedDreamJSON),
        moodSink: spy.sink
    )
    let first = try await runner.runNightlyDreamCycle()
    #expect(first.entriesWritten == 1)
    let second = try await runner.runNightlyDreamCycle(force: true)
    #expect(second.entriesWritten == 1, "force rewrites the entry")
    #expect(spy.moods == ["contemplative"],
            "the rewrite must not double-nudge the slow layer: \(spy.moods)")
}

/// A dream that never commits an entry must never move her: a policy-disabled run,
/// a run with nothing new to dream about, and an LLM failure all leave the sink cold.
@Test
func dreamCycle_moodSinkStaysSilentWhenNoEntryIsWritten() async throws {
    // (a) disabled by trust policy
    let disabledRoot = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: disabledRoot) }
    writeTrustPolicy(disabledRoot, enabled: false)
    seedSession(disabledRoot, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])
    let disabledSpy = MoodSinkSpy()
    _ = try await DreamCycleRunner(
        dataRoot: disabledRoot, llm: CannedLLMClient(cannedDreamJSON), moodSink: disabledSpy.sink
    ).runNightlyDreamCycle()
    #expect(disabledSpy.moods.isEmpty, "a disabled dream must not touch her disposition")

    // (b) nothing new since the last dream → no entry, no nudge
    let emptyRoot = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: emptyRoot) }
    writeTrustPolicy(emptyRoot, enabled: true)
    let emptySpy = MoodSinkSpy()
    let emptyReport = try await DreamCycleRunner(
        dataRoot: emptyRoot, llm: CannedLLMClient(cannedDreamJSON), moodSink: emptySpy.sink
    ).runNightlyDreamCycle()
    #expect(emptyReport.entriesWritten == 0)
    #expect(emptySpy.moods.isEmpty, "a dreamless night must not touch her disposition")

    // (c) the LLM failed → no entry, no nudge
    let failRoot = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: failRoot) }
    writeTrustPolicy(failRoot, enabled: true)
    seedSession(failRoot, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])
    let failSpy = MoodSinkSpy()
    let failReport = try await DreamCycleRunner(
        dataRoot: failRoot, llm: ThrowingLLMClient(), moodSink: failSpy.sink
    ).runNightlyDreamCycle()
    #expect(failReport.entriesWritten == 0)
    #expect(!failReport.errors.isEmpty)
    #expect(failSpy.moods.isEmpty, "a failed dream must not touch her disposition")
}

/// Mood is required completion data. A blank mood must fail the typed payload
/// boundary before the diary/high-water commit and leave the sink cold.
@Test
func dreamCycle_rejectsAnEmptyMoodField() async throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    writeTrustPolicy(root, enabled: true)
    seedSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let noMood = #"{"title":"T","summary":"S","mood":"   ","emerging_themes":[],"surprising_moments":[]}"#
    let spy = MoodSinkSpy()
    let report = try await DreamCycleRunner(
        dataRoot: root, llm: CannedLLMClient(noMood), moodSink: spy.sink
    ).runNightlyDreamCycle()

    #expect(report.entriesWritten == 0)
    #expect(report.errors.contains("invalid dream payload"))
    #expect(diaryNames(root).isEmpty)
    #expect(spy.moods.isEmpty, "an invalid dream must not move her")
}
