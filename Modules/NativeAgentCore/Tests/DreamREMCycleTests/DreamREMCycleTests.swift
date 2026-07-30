import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// MARK: - Recording inner for SwiftNative delegation tests

private final class RecordingDreamREMCycle: DreamREMCycleProtocol, @unchecked Sendable {
    var listCalls: [Int?] = []
    var todayCalls = 0
    var lastDate: String?
    var lastDreamForce: Bool?
    var lastForce: Bool?
    let entriesToReturn: [DreamEntry]
    let entryToReturn: DreamEntry?
    let dreamResult: DreamRunResult
    let remResult: REMRunResult

    init(
        entries: [DreamEntry] = [],
        entry: DreamEntry? = DreamEntry(date: "2026-05-30", filename: "2026-05-30.md", content: "x"),
        dreamResult: DreamRunResult = DreamRunResult(rawResponse: .object(["ok": .bool(true)])),
        remResult: REMRunResult = REMRunResult(rawResponse: .object(["ok": .bool(true)]))
    ) {
        self.entriesToReturn = entries
        self.entryToReturn = entry
        self.dreamResult = dreamResult
        self.remResult = remResult
    }

    func listDreamDiary(limit: Int?) async throws -> [DreamEntry] {
        listCalls.append(limit)
        return entriesToReturn
    }
    func getDreamForToday() async throws -> DreamEntry? {
        todayCalls += 1
        return entryToReturn
    }
    func getDreamForDate(_ date: String) async throws -> DreamEntry? {
        lastDate = date
        return entryToReturn
    }
    func runDream(force: Bool) async throws -> DreamRunResult {
        lastDreamForce = force
        return dreamResult
    }
    func runREM(force: Bool) async throws -> REMRunResult {
        lastForce = force
        return remResult
    }
}

// MARK: - Factory

@Test func placeholderFactoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeDreamREMCycle()
    #expect(impl is SwiftNativeDreamREMCycle)
}

// MARK: - Codable shape

@Test func DreamEntry_round_trips_via_Codable_with_extras() throws {
    let entry = DreamEntry(
        date: "2026-05-30",
        filename: "2026-05-30.md",
        content: "# Diary",
        size: 1234,
        modifiedAt: "2026-05-30T17:39:14.031840+00:00",
        extras: .object(["proposals": .array([]), "novel_key": .int(7)])
    )
    let data = try JSONEncoder().encode(entry)
    let back = try JSONDecoder().decode(DreamEntry.self, from: data)
    #expect(back == entry)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"date\""))
    // modifiedAt encodes back to snake_case `modified_at` to match daemon.
    #expect(s.contains("\"modified_at\""))
    #expect(s.contains("\"novel_key\""))
}

@Test func DreamEntry_decodes_unknown_keys_into_extras() throws {
    let raw = Data("""
    {"date":"2026-05-29","filename":"2026-05-29.md","content":"x","size":42,"modified_at":"2026-05-29T00:00:00Z","novelField":99,"proposals":[{"id":"p1"}]}
    """.utf8)
    let entry = try JSONDecoder().decode(DreamEntry.self, from: raw)
    #expect(entry.date == "2026-05-29")
    #expect(entry.filename == "2026-05-29.md")
    #expect(entry.size == 42)
    #expect(entry.modifiedAt == "2026-05-29T00:00:00Z")
    guard case .object(let extras)? = entry.extras else {
        Issue.record("extras should be object")
        return
    }
    #expect(extras["novelField"] != nil)
    #expect(extras["proposals"] != nil)
}

@Test func DreamRunResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "ok": .bool(true),
        "wrote": .string("2026-05-30.md"),
        "stats": .object(["msgs": .int(102), "ms": .int(10655)]),
    ])
    let r = DreamRunResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(DreamRunResult.self, from: data)
    #expect(back == r)
    #expect(back.rawResponse == raw)
}

@Test func REMRunResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "promoted": .int(3),
        "proposals_id": .string("rem-2026W22"),
    ])
    let r = REMRunResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(REMRunResult.self, from: data)
    #expect(back == r)
}

// MARK: - SwiftNative — reads are file-backed; cycle POSTs delegate

/// WAVE 33 W20: the three READ endpoints are now a TRUE file-backed Swift port
/// — they read `<dataRoot>/dream_diary/*.md` directly and do NOT touch the
/// `cycleDelegate`. Only `runDream`/`runREM` delegate in these tests; normal
/// production wiring leaves the delegate nil and uses the Swift runner.

/// Write `count` diary files dated descending from `2026-05-30` into a fresh
/// tmp dataRoot's `dream_diary/`. Returns the dataRoot URL.
private func makeTempDiary(_ entries: [(String, String)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("w20-dream-\(UUID().uuidString)", isDirectory: true)
    let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
    for (date, body) in entries {
        let url = diary.appendingPathComponent("\(date).md")
        try body.data(using: .utf8)!.write(to: url)
    }
    return root
}

@Test func swiftNative_reads_are_file_backed_newest_first() async throws {
    let root = try makeTempDiary([
        ("2026-05-28", "oldest"),
        ("2026-05-30", "newest"),
        ("2026-05-29", "middle"),
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    // cycleDelegate is a recorder that would THROW on a read — proving reads
    // never touch it.
    let recorder = RecordingDreamREMCycle()
    let sn = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: recorder)

    let entries = try await sn.listDreamDiary(limit: 10)
    #expect(entries.count == 3)
    #expect(entries.map { $0.date } == ["2026-05-30", "2026-05-29", "2026-05-28"])  // newest first
    #expect(entries[0].content == "newest")
    #expect(entries[0].filename == "2026-05-30.md")
    #expect(entries[0].size == "newest".utf8.count)
    #expect(entries[0].modifiedAt != nil)  // list carries modified_at
    // The reads must NOT have gone through the cycle delegate.
    #expect(recorder.listCalls.isEmpty)
    #expect(recorder.todayCalls == 0)

    let today = try await sn.getDreamForToday()
    #expect(today?.date == "2026-05-30")
    #expect(today?.content == "newest")

    let byDate = try await sn.getDreamForDate("2026-05-29")
    #expect(byDate?.date == "2026-05-29")
    #expect(byDate?.content == "middle")
    #expect(byDate?.modifiedAt == nil)  // by-date OMITS modified_at, matching daemon

    #expect(try await sn.getDreamForDate("1999-01-01") == nil)  // missing -> nil
}

@Test func swiftNative_listDreamDiary_nil_limit_defaults_to_30() async throws {
    // 35 entries; nil limit must cap at the daemon default of 30.
    var specs: [(String, String)] = []
    for i in 0..<35 {
        specs.append((String(format: "2026-04-%02d", i + 1), "e\(i)"))
    }
    let root = try makeTempDiary(specs)
    defer { try? FileManager.default.removeItem(at: root) }
    let sn = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: RecordingDreamREMCycle())
    let entries = try await sn.listDreamDiary(limit: nil)
    #expect(entries.count == 30)
}

@Test func swiftNative_getDreamForDate_rejects_reserved_words() async throws {
    let root = try makeTempDiary([("2026-05-30", "x")])
    defer { try? FileManager.default.removeItem(at: root) }
    let sn = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: RecordingDreamREMCycle())
    #expect(try await sn.getDreamForDate("diary") == nil)
    #expect(try await sn.getDreamForDate("today") == nil)
    #expect(try await sn.getDreamForDate("run") == nil)
    #expect(try await sn.getDreamForDate("") == nil)
}

@Test func swiftNative_run_POSTs_delegate_to_cycle() async throws {
    let root = try makeTempDiary([])
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecordingDreamREMCycle()
    let sn = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: recorder)

    let dr = try await sn.runDream(force: true)
    if case .object(let obj) = dr.rawResponse, case .bool(let v)? = obj["ok"] {
        #expect(v == true)
    } else {
        Issue.record("expected ok bool from delegate")
    }
    #expect(recorder.lastDreamForce == true)

    _ = try await sn.runREM(force: false)
    #expect(recorder.lastForce == false)
}

// MARK: - FileBackedDreamDiary direct unit coverage

@Test func fileBackedDreamDiary_empty_dir_returns_empty() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("w20-empty-\(UUID().uuidString)", isDirectory: true)
    // No dream_diary dir created at all.
    let reader = FileBackedDreamDiary(dataRoot: root)
    #expect(reader.listEntries(limit: 30).isEmpty)
    #expect(reader.latestEntry() == nil)
    #expect(try reader.getEntry("2026-05-30") == nil)
}

@Test func fileBackedDreamDiary_rejects_path_traversal() async throws {
    // A diary entry that would escape the dream_diary dir must NOT be readable.
    // Plant a sentinel one level up so a successful traversal would surface it.
    let root = try makeTempDiary([("2026-05-30", "legit")])
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = root.appendingPathComponent("SECRET.md")
    try "should-never-be-read".data(using: .utf8)!.write(to: sentinel)

    let reader = FileBackedDreamDiary(dataRoot: root)
    // `../SECRET` -> root/dream_diary/../SECRET.md == root/SECRET.md. Must be badPath.
    #expect(try reader.getEntryResult("../SECRET") == .badPath)
    #expect(try reader.getEntry("../SECRET") == nil)
    #expect(try reader.getEntryResult("..") == .badPath)
    #expect(try reader.getEntryResult("a/b") == .badPath)
    #expect(try reader.getEntryResult("a\\b") == .badPath)
    // The legit entry still reads.
    if case .entry(let e) = try reader.getEntryResult("2026-05-30") {
        #expect(e.content == "legit")
    } else {
        Issue.record("legit entry should read as .entry")
    }
}

@Test func fileBackedDreamDiary_getEntryResult_distinguishes_badpath_notfound_entry() async throws {
    let root = try makeTempDiary([("2026-05-30", "x")])
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = FileBackedDreamDiary(dataRoot: root)
    #expect(try reader.getEntryResult("") == .badPath)
    #expect(try reader.getEntryResult("diary") == .badPath)
    #expect(try reader.getEntryResult("today") == .badPath)
    #expect(try reader.getEntryResult("run") == .badPath)
    #expect(try reader.getEntryResult("1999-01-01") == .notFound)
    if case .entry = try reader.getEntryResult("2026-05-30") {} else {
        Issue.record("present date should be .entry")
    }
}

@Test func fileBackedDreamDiary_limit_clamp_floor_and_ceiling() async throws {
    var specs: [(String, String)] = []
    for i in 0..<5 { specs.append((String(format: "2026-03-%02d", i + 1), "e\(i)")) }
    let root = try makeTempDiary(specs)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = FileBackedDreamDiary(dataRoot: root)
    // limit 0 clamps to 1 (max(1, min(0,365))).
    #expect(reader.listEntries(limit: 0).count == 1)
    // huge limit clamps to 365 (but only 5 files exist).
    #expect(reader.listEntries(limit: 10_000).count == 5)
}

// MARK: - WAVE 35 W15: gate (cycle prep) — mirrors daemon is_enabled()

@Test func gatePolicy_dream_requires_both_gates() async throws {
    // Daemon: dream_scheduler AND dream_cycle_enabled.
    // Defaults: scheduler False, cycleEnabled True → composite default OFF.
    #expect(DreamREMGatePolicy().dreamEnabled == false)
    #expect(DreamREMGatePolicy(dreamScheduler: true, dreamCycleEnabled: true).dreamEnabled == true)
    #expect(DreamREMGatePolicy(dreamScheduler: true, dreamCycleEnabled: false).dreamEnabled == false)
    #expect(DreamREMGatePolicy(dreamScheduler: false, dreamCycleEnabled: true).dreamEnabled == false)
}

@Test func gatePolicy_rem_single_gate_default_on() async throws {
    // Daemon: rem_cycle_enabled default True.
    #expect(DreamREMGatePolicy().remEnabled == true)
    #expect(DreamREMGatePolicy(remCycleEnabled: false).remEnabled == false)
}

@Test func swiftNative_gate_short_circuits_runDream_without_delegating() async throws {
    let root = try makeTempDiary([])
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecordingDreamREMCycle()
    // dream gate OFF (default: scheduler false).
    let impl = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: recorder, gate: DreamREMGatePolicy())
    do {
        _ = try await impl.runDream(force: true)
        Issue.record("expected cycleDisabled throw")
    } catch let err as DreamREMCycleError {
        if case .cycleDisabled(let e, let d) = err {
            #expect(e == "dream_cycle_disabled")
            #expect(d == DreamREMGatePolicy.dreamDisabledDetail)
        } else {
            Issue.record("wrong error: \(err)")
        }
    }
    // CRITICAL: the delegate was NOT contacted (force never recorded). force:true
    // must NOT bypass the gate.
    #expect(recorder.lastDreamForce == nil)
}

@Test func swiftNative_gate_short_circuits_runREM_without_delegating() async throws {
    let root = try makeTempDiary([])
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecordingDreamREMCycle()
    let impl = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: recorder, gate: DreamREMGatePolicy(remCycleEnabled: false))
    do {
        _ = try await impl.runREM(force: true)
        Issue.record("expected cycleDisabled throw")
    } catch let err as DreamREMCycleError {
        if case .cycleDisabled(let e, let d) = err {
            #expect(e == "rem_cycle_disabled")
            #expect(d == DreamREMGatePolicy.remDisabledDetail)
        } else {
            Issue.record("wrong error: \(err)")
        }
    }
    #expect(recorder.lastForce == nil)
}

@Test func swiftNative_gate_enabled_delegates_to_test_runner() async throws {
    let root = try makeTempDiary([])
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecordingDreamREMCycle()
    let impl = SwiftNativeDreamREMCycle(
        dataRoot: root, cycleDelegate: recorder,
        gate: DreamREMGatePolicy(dreamScheduler: true, dreamCycleEnabled: true, remCycleEnabled: true)
    )
    _ = try await impl.runDream(force: false)
    _ = try await impl.runREM(force: false)
    #expect(recorder.lastDreamForce == false)
    #expect(recorder.lastForce == false)
}

@Test func swiftNative_nil_gate_always_delegates() async throws {
    // No gate supplied in the delegate test path -> behavior unchanged:
    // delegate receives manual run requests.
    let root = try makeTempDiary([])
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecordingDreamREMCycle()
    let impl = SwiftNativeDreamREMCycle(dataRoot: root, cycleDelegate: recorder)
    _ = try await impl.runDream(force: true)
    _ = try await impl.runREM(force: true)
    #expect(recorder.lastDreamForce == true)
    #expect(recorder.lastForce == true)
}

// MARK: - WAVE 35 W15: schedule (schedule lookup) — mirrors cron _next_target

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func dateAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, cal: Calendar) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
    return cal.date(from: c)!
}

@Test func schedule_todayKey_formats_local_ymd() async throws {
    let cal = utcCalendar()
    let now = dateAt(2026, 6, 2, 14, 5, cal: cal)
    #expect(DreamREMSchedule.todayKey(now: now, calendar: cal) == "2026-06-02")
}

@Test func schedule_dreamEntryDateKey_uses_previous_central_day() async throws {
    let cal = DreamREMSchedule.centralCalendar()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let run = dateAt(2026, 6, 17, 8, 30, cal: utc)
    #expect(DreamREMSchedule.todayKey(now: run, calendar: cal) == "2026-06-17")
    #expect(DreamREMSchedule.dreamEntryDateKey(now: run, calendar: cal) == "2026-06-16")
}

@Test func schedule_nextDreamRun_today_then_tomorrow() async throws {
    let cal = utcCalendar()
    // Before 3:30 → fires TODAY at 3:30.
    let before = dateAt(2026, 6, 2, 1, 0, cal: cal)
    #expect(DreamREMSchedule.nextDreamRun(after: before, calendar: cal)
        == dateAt(2026, 6, 2, 3, 30, cal: cal))
    // After 3:30 → rolls to TOMORROW at 3:30 (target <= now in daemon math).
    let after = dateAt(2026, 6, 2, 9, 0, cal: cal)
    #expect(DreamREMSchedule.nextDreamRun(after: after, calendar: cal)
        == dateAt(2026, 6, 3, 3, 30, cal: cal))
}

@Test func schedule_nextREMRun_targets_sunday_430am() async throws {
    let cal = utcCalendar()
    // 2026-06-02 is a TUESDAY (Python weekday 1). Next Sunday is 2026-06-07.
    let tue = dateAt(2026, 6, 2, 12, 0, cal: cal)
    let next = DreamREMSchedule.nextREMRun(after: tue, calendar: cal)
    #expect(next == dateAt(2026, 6, 7, 4, 30, cal: cal))
    // Confirm 2026-06-07 really is Sunday in this calendar.
    #expect(cal.component(.weekday, from: dateAt(2026, 6, 7, 4, 30, cal: cal)) == 1) // 1 == Sunday
}

@Test func schedule_nextREMRun_on_sunday_before_and_after_430am() async throws {
    let cal = utcCalendar()
    // 2026-06-07 is Sunday. Before 4:30am → fires today.
    let sunEarly = dateAt(2026, 6, 7, 1, 0, cal: cal)
    #expect(DreamREMSchedule.nextREMRun(after: sunEarly, calendar: cal)
        == dateAt(2026, 6, 7, 4, 30, cal: cal))
    // On Sunday AFTER 4:30am → daemon's days_ahead==0 && target<=now bumps a full week.
    let sunLate = dateAt(2026, 6, 7, 9, 0, cal: cal)
    #expect(DreamREMSchedule.nextREMRun(after: sunLate, calendar: cal)
        == dateAt(2026, 6, 14, 4, 30, cal: cal))
}
