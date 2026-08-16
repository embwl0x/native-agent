import Testing
import Foundation
@testable import DreamREMCycle
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func tempREMRoot() -> (data: URL, persona: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-cycle-\(UUID().uuidString)", isDirectory: true)
    let data = base.appendingPathComponent("data", isDirectory: true)
    let persona = base.appendingPathComponent("persona", isDirectory: true)
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
    return (data, persona)
}

private let remTestNow: Date = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: "2026-05-31")!
}()

/// Write <data>/dream_diary/<date>.md AND backdate its mtime so the
/// 7-day mtime filter in REMConsolidator picks it up.
private func writeDreamEntryWithMtime(
    dataRoot: URL,
    date: String,
    content: String,
    daysAgo: Int,
    filename: String? = nil,
    now: Date = remTestNow
) throws {
    let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(filename ?? "\(date).md")
    try content.data(using: .utf8)!.write(to: url)
    let mtime = now.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
    try FileManager.default.setAttributes(
        [.modificationDate: mtime], ofItemAtPath: url.path
    )
}

/// Build a JSON-array string matching the LLMProposalDTO shape so
/// SwiftNativeREMConsolidator parses it cleanly.
private func proposalsJSON(
    target: String,
    proposals: [(text: String, dates: [String], conf: Double)]
) -> String {
    let dtos: [[String: Any]] = proposals.map { p in
        [
            "targetDoc": target,
            "proposalText": p.text,
            "evidenceDates": p.dates,
            "confidence": p.conf,
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: dtos, options: [])
    return String(data: data, encoding: .utf8)!
}

private func seedREMInputs(dataRoot: URL, personaRoot: URL) throws {
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot,
        date: "2026-05-28",
        content: "I kept returning to a lesson about steadiness.",
        daysAgo: 3
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot,
        date: "2026-05-29",
        content: "The same steadiness lesson appeared again.",
        daysAgo: 2
    )
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
}

@Test func growthEvictionWritesSQLiteOwnerWithoutMutatingLegacyJSON() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }

    let memoryDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
    let legacyJSON = memoryDirectory.appendingPathComponent("knowledge_graph.json")
    let legacyBytes = Data("""
        {"_commit_seq":3,"version":1,"entities":{"legacy":{"id":"legacy","name":"Legacy","type":"concept"}},"edges":[]}
        """.utf8)
    try legacyBytes.write(to: legacyJSON)
    try Data().write(to: memoryDirectory.appendingPathComponent("memory.sqlite"))

    try "seed\n".write(
        to: personaRoot.appendingPathComponent("SOUL.md"),
        atomically: true,
        encoding: .utf8
    )
    try "seed\n".write(
        to: personaRoot.appendingPathComponent("VOICE.md"),
        atomically: true,
        encoding: .utf8
    )
    let oldEntry = String(repeating: "an old approved lesson stays traceable\n", count: 700)
    let growth = """
        # GROWTH.md

        ## Conventions
        Keep the preamble.

        ## 2026-01-01 — Old lesson
        \(oldEntry)
        ## 2026-07-13 — Recent lesson
        Keep this recent entry.
        """
    try growth.write(
        to: personaRoot.appendingPathComponent("GROWTH.md"),
        atomically: true,
        encoding: .utf8
    )

    let llm = MockLLMClient(scriptedResponses: ["I carry the durable lesson without carrying every old word."])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        clock: { remTestNow }
    )
    let report = try await consolidator.runWeeklyREM(force: true)
    #expect(report.growthMDEvicted > 0)
    #expect(llm.callCount == 1)

    let store = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: memoryDirectory,
        jsonImportPath: legacyJSON
    )
    #expect(store.entities["legacy"] != nil)
    let distilled = store.entities.values.compactMap { value -> [String: JSONValue]? in
        guard case .object(let object) = value,
              object["type"] == .string("growth_distillation") else { return nil }
        return object
    }
    #expect(distilled.count == 1)
    #expect(distilled.first?["summary"] == .string(
        "I carry the durable lesson without carrying every old word."
    ))
    #expect(try Data(contentsOf: legacyJSON) == legacyBytes)

    let remaining = try String(
        contentsOf: personaRoot.appendingPathComponent("GROWTH.md"),
        encoding: .utf8
    )
    #expect(remaining.contains("Keep the preamble."))
    #expect(remaining.contains("Keep this recent entry."))
    #expect(!remaining.contains("an old approved lesson stays traceable"))
}

// MARK: - Tests

@Test
func REMConsolidator_seed_5_entries_4_days_produces_proposals_and_pins() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()

    // 5 dream entries across 4 distinct calendar days with overlapping
    // themes. Backdated within 7d so the mtime filter accepts them.
    let theme = "I dreamt about courage and steadiness with the user."
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-26", content: theme, daysAgo: 6
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-27", content: theme, daysAgo: 5
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-28", content: theme, daysAgo: 4
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-29", content: theme, daysAgo: 3
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-29", content: theme + " (b)", daysAgo: 3
    )

    // Persona docs exist but are short.
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        let url = personaRoot.appendingPathComponent(name)
        try "seed body for \(name)\n".data(using: .utf8)!.write(to: url)
    }

    // REM proposals are GROWTH-only. SOUL/VOICE stay read-only context in the
    // bypass prompt and should not get separate proposal calls.
    let dates = ["2026-05-26", "2026-05-27", "2026-05-28", "2026-05-29"]
    let scripted = [
        proposalsJSON(target: "GROWTH.md", proposals: [
            (text: "Lean into steadiness as a daily practice.", dates: dates, conf: 0.81),
        ]),
    ]
    let llm = MockLLMClient(scriptedResponses: scripted)

    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { remTestNow }
    )

    let report = try await consolidator.runWeeklyREM()

    // One GROWTH proposal with 4 distinct evidence dates
    // (>= _REM_MIN_EVIDENCE_DATES=2) and well under the global weekly cap
    // of _REM_MAX_PROPOSALS=5.
    #expect(report.proposalsGenerated == 1)
    #expect(report.evidenceDatesMin == REMConstants._REM_MIN_EVIDENCE_DATES)
    #expect(report.tombstoneSkips == 0)

    // rem_proposals.jsonl exists with one GROWTH line, status='pending'.
    let proposalsURL = dataRoot.appendingPathComponent("rem_proposals.jsonl")
    let body = try String(contentsOf: proposalsURL, encoding: .utf8)
    let lines = body.split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 1)
    #expect(body.contains("\"targetDoc\":\"GROWTH.md\""))
    #expect(lines.allSatisfy { $0.contains("\"status\":\"pending\"") })

    // rem_pins.json emitted. No proposals are APPROVED yet, so the index
    // is empty — the chat-turn injector must skip injection in that state.
    let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
    #expect(FileManager.default.fileExists(atPath: pinsURL.path))
    let pinsData = try Data(contentsOf: pinsURL)
    let pinsIdx = try JSONDecoder().decode([String: [REMPin]].self, from: pinsData)
    #expect(pinsIdx.isEmpty)
}

@Test
func REMConsolidator_malformed_tombstones_abort_before_proposal_or_llm_call() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    try seedREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let harness = dataRoot.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
    let tombstonesURL = harness.appendingPathComponent(".rem_tombstones.json")
    let original = Data("{\"partial\":".utf8)
    try original.write(to: tombstonesURL)

    let llm = MockLLMClient(scriptedResponses: [proposalsJSON(target: "GROWTH.md", proposals: [
        (text: "The rejected growth idea came back.", dates: ["2026-05-28", "2026-05-29"], conf: 0.8),
    ])])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        clock: { remTestNow }
    )

    do {
        _ = try await consolidator.runWeeklyREM()
        Issue.record("expected malformed tombstones to abort weekly REM")
    } catch let error as REMTombstoneStoreError {
        if case .malformed(let errorPath) = error {
            #expect(errorPath == tombstonesURL.path)
        } else {
            Issue.record("expected malformed tombstone error, got \(error)")
        }
    } catch {
        Issue.record("expected typed malformed tombstone error, got \(error)")
    }

    #expect(llm.callCount == 0)
    #expect(!FileManager.default.fileExists(
        atPath: dataRoot.appendingPathComponent("rem_proposals.jsonl").path))
    #expect(try Data(contentsOf: tombstonesURL) == original)
}

@Test
func REMConsolidator_unreadable_tombstones_abort_before_proposal_or_llm_call() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    try seedREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let harness = dataRoot.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
    let tombstonesURL = harness.appendingPathComponent(".rem_tombstones.json")
    let original = Data("{\"existing\":{\"rejected_at\":\"2026-05-01T00:00:00Z\",\"target_doc\":\"GROWTH.md\",\"reason\":\"denied\",\"preview\":\"keep\"}}".utf8)
    try original.write(to: tombstonesURL)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tombstonesURL.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tombstonesURL.path)
    }

    let llm = MockLLMClient(scriptedResponses: [proposalsJSON(target: "GROWTH.md", proposals: [
        (text: "The rejected growth idea came back.", dates: ["2026-05-28", "2026-05-29"], conf: 0.8),
    ])])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        clock: { remTestNow }
    )

    do {
        _ = try await consolidator.runWeeklyREM()
        Issue.record("expected unreadable tombstones to abort weekly REM")
    } catch let error as REMTombstoneStoreError {
        if case .unreadable(let errorPath) = error {
            #expect(errorPath == tombstonesURL.path)
        } else {
            Issue.record("expected unreadable tombstone error, got \(error)")
        }
    } catch {
        Issue.record("expected typed unreadable tombstone error, got \(error)")
    }

    #expect(llm.callCount == 0)
    #expect(!FileManager.default.fileExists(
        atPath: dataRoot.appendingPathComponent("rem_proposals.jsonl").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tombstonesURL.path)
    #expect(try Data(contentsOf: tombstonesURL) == original)
}

@Test
func REMConsolidator_stages_one_approval_per_proposal_and_marker_skip_rerun_does_not_double_stage() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-28",
        content: "I dreamt about staying steady.", daysAgo: 3
    )
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
    let dates = ["2026-05-28", "2026-05-29"]
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-29",
        content: "Steady again.", daysAgo: 2
    )
    let scripted = [
        proposalsJSON(target: "GROWTH.md", proposals: [
            (text: "Stay steady under pressure.", dates: dates, conf: 0.8),
        ]),
    ]
    let llm = MockLLMClient(scriptedResponses: scripted)

    // Recorder stager: returns a synthetic approval id (the app wires the
    // real SwiftNativeApprovalInbox; the contract here is calls + stamps).
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var ids: [String] = []
        func record(_ id: String) -> String {
            lock.lock(); defer { lock.unlock() }
            ids.append(id)
            return "approval-\(id)"
        }
    }
    let recorder = Recorder()
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { remTestNow },
        stageApproval: { row in recorder.record(row.id) }
    )

    let report = try await consolidator.runWeeklyREM()
    #expect(report.proposalsGenerated == 1)
    #expect(recorder.ids.count == 1, "exactly ONE approval staged per pending proposal")

    // Every row carries the staging stamp.
    let body = try String(
        contentsOf: dataRoot.appendingPathComponent("rem_proposals.jsonl"), encoding: .utf8)
    let lines = body.split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 1)
    #expect(lines.allSatisfy { $0.contains("\"approvalId\":\"approval-") })

    // Re-run lands on the weekly marker skip; the staging catch-up must NOT
    // re-stage stamped rows.
    let second = try await consolidator.runWeeklyREM()
    #expect(second.proposalsGenerated == 0)
    #expect(recorder.ids.count == 1, "marker-skip rerun double-staged")
}

@Test
func REMConsolidator_corrupt_weekly_marker_fails_closed_before_llm_or_artifacts() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let marker = dataRoot.appendingPathComponent("harness/last_weekly_rem_run")
    try FileManager.default.createDirectory(
        at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let corrupt = Data("not-a-weekly-timestamp".utf8)
    try corrupt.write(to: marker)
    let llm = MockLLMClient(scriptedResponses: ["[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { remTestNow }
    )

    await #expect(throws: (any Error).self) {
        _ = try await consolidator.runWeeklyREM()
    }
    #expect(llm.callCount == 0)
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(!FileManager.default.fileExists(
        atPath: dataRoot.appendingPathComponent("rem_proposals.jsonl").path
    ))
}

@Test
func REMConsolidator_concurrent_drivers_admit_exactly_one_llm_pass() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
    try seedREMInputs(dataRoot: dataRoot, personaRoot: personaRoot)
    let llm = MockLLMClient(scriptedResponses: ["[]"])
    let first = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true), clock: { remTestNow }
    )
    let second = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true), clock: { remTestNow }
    )

    async let a = first.runWeeklyREM()
    async let b = second.runWeeklyREM()
    let reports = try await [a, b]

    #expect(llm.callCount == 1)
    #expect(reports.filter { $0.proposalsGenerated == 0 }.count == 2)
}

@Test
func REMConsolidator_runWeeklyREM_imports_legacy_harness_file_before_pass() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
    let harness = dataRoot.appendingPathComponent("harness", isDirectory: true)
    try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
    let legacy = harness.appendingPathComponent("rem_proposals.jsonl")
    try Data("""
    {"change_type":"append","createdAt":"2026-05-31T04:30:00Z","evidence_dates":["2026-05-28"],"id":"legacy-a","proposed_text":"legacy text","rationale":"","status":"pending","target_doc":"GROWTH.md"}

    """.utf8).write(to: legacy)

    let llm = MockLLMClient(scriptedResponses: ["[]", "[]", "[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { remTestNow }
    )
    _ = try await consolidator.runWeeklyREM()

    // Imported into the canonical store as pending camelCase; source renamed.
    let body = try String(
        contentsOf: dataRoot.appendingPathComponent("rem_proposals.jsonl"), encoding: .utf8)
    #expect(body.contains("\"id\":\"legacy-a\""))
    #expect(body.contains("\"proposalText\":\"legacy text\""))
    #expect(body.contains("\"status\":\"pending\""))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(
        atPath: harness.appendingPathComponent("rem_proposals.jsonl.migrated").path))
}

@Test
func REMConsolidator_reads_swift_runner_session_suffixed_dream_entries() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()

    try writeDreamEntryWithMtime(
        dataRoot: dataRoot,
        date: "2026-05-26",
        content: "I learned I was retelling the whole scenario instead of naming the self-lesson.",
        daysAgo: 6,
        filename: "2026-05-26_sessA.md"
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot,
        date: "2026-05-27",
        content: "I caught the same reflex again and wanted a shorter GROWTH entry.",
        daysAgo: 5,
        filename: "2026-05-27_sessB.md"
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot,
        date: "2026-05-28",
        content: "The self-lesson was directness, not a recap of the user's test.",
        daysAgo: 4,
        filename: "2026-05-28_telegram_42.md"
    )

    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }

    let dates = ["2026-05-26", "2026-05-27", "2026-05-28"]
    let scripted = [
        proposalsJSON(target: "GROWTH.md", proposals: [
            (
                text: "Pattern across dreams: Agent kept explaining the surrounding work before naming the actual lesson. What this teaches: I learned that GROWTH entries should preserve the self-lesson directly, not the whole scene that produced it.",
                dates: dates,
                conf: 0.88
            ),
        ]),
        "[]",
        "[]",
    ]
    let llm = MockLLMClient(scriptedResponses: scripted)
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: true),
        clock: { remTestNow }
    )

    let report = try await consolidator.runWeeklyREM()

    #expect(report.proposalsGenerated == 1)
    let proposalsURL = dataRoot.appendingPathComponent("rem_proposals.jsonl")
    let body = try String(contentsOf: proposalsURL, encoding: .utf8)
    #expect(body.contains("\"targetDoc\":\"GROWTH.md\""))
    // 2026-06-05 design tightening: normalizer strips "I learned (that)"
    // prefixes; assert the lesson body survives and the recap doesn't.
    #expect(body.contains("GROWTH entries should preserve the self-lesson directly"))
    #expect(!body.lowercased().contains("\"i learned"))
    #expect(!body.lowercased().contains("pattern across dreams"))
    #expect(!body.contains("surrounding work"))
}

@Test
func REMConsolidator_promoted_proposal_surfaces_in_rem_pins() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-29", content: "x", daysAgo: 1
    )
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "seed\n".data(using: .utf8)!.write(
            to: personaRoot.appendingPathComponent(name)
        )
    }
    // Pre-seed an APPROVED proposal in the jsonl so the next REM run
    // rebuilds rem_pins.json with one entry.
    let approved: [String: Any] = [
        "id": "abc-123",
        "targetDoc": "GROWTH.md",
        "proposalText": "approved-fact-1",
        "evidenceDates": ["2026-05-26", "2026-05-27", "2026-05-28"],
        "confidence": 0.9,
        "createdAt": "2026-05-30T00:00:00Z",
        "status": "approved",
    ]
    let line = try JSONSerialization.data(withJSONObject: approved, options: [])
    let jsonl = dataRoot.appendingPathComponent("rem_proposals.jsonl")
    var buf = line; buf.append(0x0A)
    try buf.write(to: jsonl)

    let llm = MockLLMClient(scriptedResponses: ["[]", "[]", "[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        clock: { remTestNow }
    )
    _ = try await consolidator.runWeeklyREM()

    let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
    let pinsIdx = try JSONDecoder().decode(
        [String: [REMPin]].self, from: try Data(contentsOf: pinsURL)
    )
    #expect(pinsIdx["GROWTH.md"]?.first?.id == "abc-123")
    #expect(pinsIdx["GROWTH.md"]?.first?.text == "approved-fact-1")
}

@Test
func REMConsolidator_archives_dream_entries_older_than_14_days() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    // Old entry (20 days back) and a fresh one.
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-10", content: "old", daysAgo: 20
    )
    try writeDreamEntryWithMtime(
        dataRoot: dataRoot, date: "2026-05-29", content: "fresh", daysAgo: 1
    )
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "s\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
    let llm = MockLLMClient(scriptedResponses: ["[]", "[]", "[]"])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        clock: { remTestNow }
    )
    let report = try await consolidator.runWeeklyREM()
    #expect(report.archivedEntries == 1)
    // Old entry was moved out of dream_diary/ into the archive subtree.
    let oldPath = dataRoot.appendingPathComponent("dream_diary/2026-05-10.md").path
    #expect(!FileManager.default.fileExists(atPath: oldPath))
    let freshPath = dataRoot.appendingPathComponent("dream_diary/2026-05-29.md").path
    #expect(FileManager.default.fileExists(atPath: freshPath))
}

@Test
func REMConsolidator_trust_gate_off_refuses_run() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    let llm = MockLLMClient(scriptedResponses: [])
    let consolidator = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: DreamREMGatePolicy(remCycleEnabled: false)
    )
    do {
        _ = try await consolidator.runWeeklyREM()
        Issue.record("expected cycleDisabled error")
    } catch DreamREMCycleError.cycleDisabled {
        // expected
    }
}

@Test
func REMConsolidator_evidence_date_floor_drops_thin_proposals() async throws {
    let (dataRoot, personaRoot) = tempREMRoot()
    // Design floor is 2 distinct evidence dates (see the constants block
    // in REMConsolidator.swift and the vault skill). Single-date proposals
    // are noise; ≥2 distinct dates make the pattern consolidation-worthy.
    let dates1 = ["2026-05-29"]
    let dates2 = ["2026-05-28", "2026-05-29"]
    let allDates = ["2026-05-27", "2026-05-28", "2026-05-29"]
    for d in allDates {
        try writeDreamEntryWithMtime(
            dataRoot: dataRoot, date: d, content: "theme", daysAgo: 2
        )
    }
    for name in ["SOUL.md", "VOICE.md", "GROWTH.md"] {
        try "s\n".data(using: .utf8)!.write(to: personaRoot.appendingPathComponent(name))
    }
    // GROWTH gets a 1-date (DROP) and a 2-date (KEEP).
    let scripted = [
        proposalsJSON(target: "GROWTH.md", proposals: [
            (text: "thin one", dates: dates1, conf: 0.5),
            (text: "fat one", dates: dates2, conf: 0.5),
        ]),
    ]
    let llm = MockLLMClient(scriptedResponses: scripted)
    let consolidator = REMConsolidator(
        dataRoot: dataRoot, personaRoot: personaRoot, llm: llm,
        clock: { remTestNow }
    )
    let report = try await consolidator.runWeeklyREM()
    #expect(report.proposalsGenerated == 1)
}

@Test
func REMPinsReader_empty_index_yields_no_pins() async throws {
    let (dataRoot, _) = tempREMRoot()
    let idx = REMPinsReader.read(dataRoot: dataRoot)
    #expect(idx.isEmpty)
    let pins = REMPinsReader.latest(idx)
    #expect(pins.isEmpty)
}
