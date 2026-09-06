import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// NORTHSTAR clause 4 (sweep item 39, 2026-09-01): the organism's sleep pressure
// may fire the dream through the SAME runner the 03:30 America/Chicago job uses.
// These prove the two lanes share one dream — the pressure-fired entry is the
// entry the scheduled tick would have written, so the tick finds it and skips
// honestly instead of dreaming twice — and that the receipt names the lane.

private func makePressureRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DreamPressureTriggerTests-\(UUID().uuidString)", isDirectory: true)
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

private func seedPressureSession(_ root: URL, id: String, rows: [(role: String, content: String, at: Date)]) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(id).jsonl")
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var body = ""
    for row in rows {
        let escaped = String(
            data: try! JSONSerialization.data(withJSONObject: [row.content]),
            encoding: .utf8
        )!.dropFirst().dropLast()
        body += "{\"role\":\"\(row.role)\",\"content\":\(escaped),\"createdAt\":\"\(iso.string(from: row.at))\"}\n"
    }
    try! body.data(using: .utf8)!.write(to: url)
    try! FileManager.default.setAttributes(
        [.modificationDate: rows.map(\.at).max() ?? Date()],
        ofItemAtPath: url.path
    )
}

private func pressureDiaryNames(_ root: URL) -> [String] {
    let dir = root.appendingPathComponent("dream_diary")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".md") }.sorted()
}

private func dreamStateSidecar(_ root: URL) -> [String: JSONValue] {
    let path = root.appendingPathComponent("dream_diary", isDirectory: true)
        .appendingPathComponent(".dream_state.json")
    guard let data = try? Data(contentsOf: path),
          let parsed = try? JSONValue.parse(data),
          case .object(let object) = parsed else { return [:] }
    return object
}

private func sidecarString(_ object: [String: JSONValue], _ key: String) -> String? {
    if case .string(let value)? = object[key] { return value }
    return nil
}

private let pressureDreamJSON = """
{"title":"The Unfinished Ledger","summary":"A day of unresolved predictions kept circling until the circling itself became the shape worth keeping.","mood":"restless","emerging_themes":["unresolved prediction"],"surprising_moments":["the residue was the point"]}
"""

private final class CountingLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return pressureDreamJSON
    }
}

private final class PressureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ date: Date) { _now = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func set(_ date: Date) { lock.lock(); _now = date; lock.unlock() }
}

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        timeZone: TimeZone(identifier: "UTC")!,
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

@Test
func pressureFiredDreamWritesTheDayItIsDreamingAboutAndNamesItsTrigger() async throws {
    let root = makePressureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedPressureSession(root, id: "s1", rows: [
        (role: "user", content: "the deploy failed again", at: utc(2026, 9, 1, 2, 0)),
        (role: "assistant", content: "same signature as yesterday", at: utc(2026, 9, 1, 2, 1)),
    ])

    // 22:00 America/Chicago on Aug 31 — mid-life, hours before the 03:30 job.
    let clock = PressureClock(utc(2026, 9, 1, 3, 0))
    let llm = CountingLLM()
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, now: { clock.now })

    let report = try await runner.runNightlyDreamCycle(trigger: .pressure)

    #expect(report.entriesWritten == 1)
    #expect(report.errors.isEmpty)
    #expect(report.trigger == .pressure)
    #expect(report.skipReason == nil)
    #expect(llm.calls == 1)
    // The current Central day — exactly the entry the NEXT 03:30 job would write.
    #expect(pressureDiaryNames(root) == ["2026-08-31.md"])

    // Receipt lives in the runner's sidecar, never in the diary body (clause 6).
    let sidecar = dreamStateSidecar(root)
    #expect(sidecarString(sidecar, "lastDreamTrigger") == "pressure")
    #expect(sidecarString(sidecar, "lastDreamedAt") != nil)
    let body = try String(
        contentsOf: root.appendingPathComponent("dream_diary/2026-08-31.md"),
        encoding: .utf8
    )
    #expect(!body.lowercased().contains("pressure"))
    #expect(!body.lowercased().contains("trigger"))
}

@Test
func aPressureFiredDreamMakesTheNextScheduledTickSkipHonestly() async throws {
    let root = makePressureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedPressureSession(root, id: "s1", rows: [
        (role: "user", content: "the deploy failed again", at: utc(2026, 9, 1, 2, 0)),
        (role: "assistant", content: "same signature as yesterday", at: utc(2026, 9, 1, 2, 1)),
    ])

    let clock = PressureClock(utc(2026, 9, 1, 3, 0))
    let llm = CountingLLM()
    let runner = DreamCycleRunner(dataRoot: root, llm: llm, now: { clock.now })
    let dreamt = try await runner.runNightlyDreamCycle(trigger: .pressure)
    #expect(dreamt.entriesWritten == 1)

    // 03:30 America/Chicago the next morning — the integrity fallback runs and
    // finds the night already dreamt. No second provider call, no second entry,
    // and the skip says WHICH honest reason rather than implying failure.
    clock.set(utc(2026, 9, 1, 8, 30))
    let scheduled = try await runner.runNightlyDreamCycle()

    #expect(scheduled.entriesWritten == 0)
    #expect(scheduled.errors.isEmpty)
    #expect(scheduled.disabled == false)
    #expect(scheduled.skipReason == "already_dreamt")
    #expect(scheduled.trigger == .schedule)
    #expect(llm.calls == 1)
    #expect(pressureDiaryNames(root) == ["2026-08-31.md"])
    // The pressure lane still owns the provenance of the entry that exists.
    #expect(sidecarString(dreamStateSidecar(root), "lastDreamTrigger") == "pressure")
}

@Test
func theScheduledLaneIsUnchangedAndStillWritesThePreviousCentralDay() async throws {
    let root = makePressureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedPressureSession(root, id: "s1", rows: [
        (role: "user", content: "long day", at: utc(2026, 9, 1, 2, 0)),
        (role: "assistant", content: "it was", at: utc(2026, 9, 1, 2, 1)),
    ])

    // 03:30 America/Chicago on Sep 1 writes the Aug 31 entry, as it always has.
    let clock = PressureClock(utc(2026, 9, 1, 8, 30))
    let runner = DreamCycleRunner(dataRoot: root, llm: CountingLLM(), now: { clock.now })
    let report = try await runner.runNightlyDreamCycle()

    #expect(report.entriesWritten == 1)
    #expect(report.trigger == .schedule)
    #expect(pressureDiaryNames(root) == ["2026-08-31.md"])
    #expect(sidecarString(dreamStateSidecar(root), "lastDreamTrigger") == "schedule")
}

@Test
func aDisabledCycleRefusesThePressureLaneExactlyLikeTheScheduledOne() async throws {
    let root = makePressureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! """
    {"trainingPolicy":{"dream_scheduler":false},"personalityPolicy":{"dream_cycle_enabled":true}}
    """.data(using: .utf8)!.write(to: dir.appendingPathComponent("policy.json"))
    seedPressureSession(root, id: "s1", rows: [
        (role: "user", content: "hi", at: utc(2026, 9, 1, 2, 0)),
    ])

    let llm = CountingLLM()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: llm,
        now: { utc(2026, 9, 1, 3, 0) }
    )
    let report = try await runner.runNightlyDreamCycle(trigger: .pressure)

    #expect(report.disabled)
    #expect(report.trigger == .pressure)
    #expect(report.entriesWritten == 0)
    #expect(llm.calls == 0)
}
