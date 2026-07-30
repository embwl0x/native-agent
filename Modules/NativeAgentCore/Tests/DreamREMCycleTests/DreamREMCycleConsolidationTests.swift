import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore

// Spec called for XCTest; this package uses swift-testing throughout
// (see NativeAgentCoreTests.swift). Matching repo convention.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rem-consolidation-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes <root>/dream_diary/<date>.md with the given body — matches
/// the retired daemon (YYYY-MM-DD.md). `nameOverride` lets tests inject
/// malformed filenames to exercise the validator.
private func writeDiaryEntry(
    root: URL,
    date: String,
    content: String,
    nameOverride: String? = nil
) throws {
    let dir = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = nameOverride ?? "\(date).md"
    try content.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
}

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: s)!
}

// 1
@Test func REMProposal_round_trips_via_Codable() throws {
    let original = REMProposal(
        id: "abc",
        targetDoc: "GROWTH",
        proposalText: "be kinder",
        evidenceDates: ["2026-01-01", "2026-01-02"],
        confidence: 0.71,
        createdAt: "2026-05-31T00:00:00Z"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(REMProposal.self, from: data)
    #expect(decoded == original)
}

// 2
@Test func mockLLMClient_returns_scripted_responses_in_order() async throws {
    let mock = MockLLMClient(scriptedResponses: ["a", "b", "c"])
    let r1 = try await mock.complete(prompt: "x", system: nil, model: nil)
    let r2 = try await mock.complete(prompt: "x", system: nil, model: nil)
    let r3 = try await mock.complete(prompt: "x", system: nil, model: nil)
    #expect(r1 == "a")
    #expect(r2 == "b")
    #expect(r3 == "c")
}

// 3
@Test func mockLLMClient_loops_at_end_of_scripted_list() async throws {
    let mock = MockLLMClient(scriptedResponses: ["a", "b"])
    _ = try await mock.complete(prompt: "", system: nil, model: nil)
    _ = try await mock.complete(prompt: "", system: nil, model: nil)
    let r3 = try await mock.complete(prompt: "", system: nil, model: nil)
    let r4 = try await mock.complete(prompt: "", system: nil, model: nil)
    #expect(r3 == "a")
    #expect(r4 == "b")
}

// 4
@Test func mockLLMClient_tracks_call_count() async throws {
    let mock = MockLLMClient(scriptedResponses: ["x"])
    #expect(mock.callCount == 0)
    _ = try await mock.complete(prompt: "", system: nil, model: nil)
    _ = try await mock.complete(prompt: "", system: nil, model: nil)
    #expect(mock.callCount == 2)
}

// 5
@Test func dreamDiaryReader_returns_empty_for_no_dir() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let result = try await reader.entriesSince(nil)
    #expect(result.isEmpty)
}

// 6
@Test func dreamDiaryReader_returns_entries_sorted_by_date() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-01-03", content: "c")
    try writeDiaryEntry(root: root, date: "2026-01-01", content: "a")
    try writeDiaryEntry(root: root, date: "2026-01-02", content: "b")
    let reader = DreamDiaryReader(dataRoot: root)
    let result = try await reader.entriesSince(nil)
    #expect(result.count == 3)
    #expect(result.map { $0.date } == ["2026-01-01", "2026-01-02", "2026-01-03"])
    #expect(result[0].filename == "2026-01-01.md")
    #expect(result[0].content == "a")
}

@Test func dreamDiaryReader_accepts_swift_runner_session_suffixed_entries() async throws {
    let root = tempDir()
    try writeDiaryEntry(
        root: root,
        date: "2026-01-01",
        content: "legacy",
        nameOverride: "2026-01-01.md"
    )
    try writeDiaryEntry(
        root: root,
        date: "2026-01-01",
        content: "session a",
        nameOverride: "2026-01-01_sessionA.md"
    )
    try writeDiaryEntry(
        root: root,
        date: "2026-01-02",
        content: "session b",
        nameOverride: "2026-01-02_telegram_42.md"
    )
    let reader = DreamDiaryReader(dataRoot: root)
    let result = try await reader.entriesSince(nil)
    #expect(result.map { $0.date } == ["2026-01-01", "2026-01-01", "2026-01-02"])
    #expect(result.map { $0.filename }.contains("2026-01-01_sessionA.md"))
    #expect(result.map { $0.filename }.contains("2026-01-02_telegram_42.md"))
}

// 7
@Test func dreamDiaryReader_filters_by_since_timestamp() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-01-01", content: "a")
    try writeDiaryEntry(root: root, date: "2026-01-02", content: "b")
    try writeDiaryEntry(root: root, date: "2026-01-03", content: "c")
    let reader = DreamDiaryReader(dataRoot: root)
    let result = try await reader.entriesSince(iso("2026-01-01"))
    #expect(result.map { $0.date } == ["2026-01-02", "2026-01-03"])
}

// 8
@Test func remConsolidator_consolidate_no_entries_returns_empty() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let mock = MockLLMClient(scriptedResponses: ["[]"])
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let result = try await con.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["GROWTH": "doc"]
    )
    #expect(result.isEmpty)
    #expect(mock.callCount == 0)
}

// 9
@Test func remConsolidator_consolidate_calls_llm_per_persona_doc() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-02-01", content: "entry")
    let reader = DreamDiaryReader(dataRoot: root)
    let mock = MockLLMClient(scriptedResponses: ["[]"])
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    _ = try await con.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["SOUL": "s", "VOICE": "v", "GROWTH": "g"]
    )
    #expect(mock.callCount == 3)
}

// 10
@Test func remConsolidator_parseLLMResponse_valid_JSON_returns_proposals() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [
      {"targetDoc":"GROWTH","proposalText":"p1","evidenceDates":["2026-01-01"],"confidence":0.5},
      {"targetDoc":"GROWTH","proposalText":"p2","evidenceDates":["2026-01-02"],"confidence":0.8}
    ]
    """
    let mock = MockLLMClient()
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 2)
    #expect(parsed[0].proposalText == "p1")
    let err = await con.lastParseError
    #expect(err == nil)
    let errs = await con.lastParseErrors
    #expect(errs.isEmpty)
}

// 11
@Test func remConsolidator_parseLLMResponse_invalid_JSON_sets_lastParseError_returns_empty() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let mock = MockLLMClient()
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let parsed = await con.parseLLMResponse("not json", target: "GROWTH")
    #expect(parsed.isEmpty)
    let err = await con.lastParseError
    #expect(err != nil)
    let errs = await con.lastParseErrors
    #expect(errs.count == 1)
}

// 12
@Test func remConsolidator_consolidate_full_pipeline_with_mock() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-02-01", content: "entry")
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [{"targetDoc":"GROWTH","proposalText":"unique-proposal","evidenceDates":["2026-02-01"],"confidence":0.9}]
    """
    let mock = MockLLMClient(scriptedResponses: [raw])
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let result = try await con.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["GROWTH": "doc"]
    )
    #expect(result.count == 1)
    #expect(result[0].proposalText == "unique-proposal")
    #expect(result[0].targetDoc == "GROWTH.md")
}

@Test func remConsolidator_normalizes_growth_proposal_to_self_lesson_only() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [
      {
        "targetDoc":"GROWTH",
        "proposalText":"Pattern across three dreams: the user pushed on whether Agent was understanding or performing, and the whole scenario kept circling Telegram, builder mode, and the old daemon. What this teaches: I learned that my growth notes should name the internal reflex directly instead of retelling the whole dream scenario.",
        "evidenceDates":["2026-01-01"],
        "confidence":0.8
      }
    ]
    """
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    let text = parsed[0].proposalText
    // 2026-06-05 design tightening: normalizer now strips "I learned (that)"
    // prefixes too — proposals should read as declarative reflexes in her
    // subconscious voice, not lesson-prose. Cap is _REM_PROPOSAL_TEXT_CAP.
    #expect(!text.hasPrefix("I learned"))
    #expect(!text.lowercased().contains("pattern across"))
    #expect(!text.contains("Telegram"))
    #expect(text.count <= REMConstants._REM_PROPOSAL_TEXT_CAP)
    #expect(text.lowercased().contains("growth notes"))
}

// 13 — malformed filenames (non-date stems, .json leftovers) are skipped
@Test func dreamDiaryReader_skips_malformed_filenames() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-03-01", content: "good")
    try writeDiaryEntry(root: root, date: "ignored", content: "bad", nameOverride: "notadate.md")
    try writeDiaryEntry(root: root, date: "ignored", content: "bad", nameOverride: "2026-03-02.json")
    try writeDiaryEntry(root: root, date: "ignored", content: "bad", nameOverride: "2026-3-1.md")
    let reader = DreamDiaryReader(dataRoot: root)
    let result = try await reader.entriesSince(nil)
    #expect(result.map { $0.date } == ["2026-03-01"])
}

// 14 — lastParseErrors plural accumulates one entry per failed doc, and
// consolidate() clears prior state on each call (legacy `lastParseError`
// reports the most-recent entry).
@Test func remConsolidator_lastParseErrors_plural_accumulates_across_docs() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-04-01", content: "x")
    let reader = DreamDiaryReader(dataRoot: root)
    // First doc returns garbage; second GROWTH doc returns valid JSON. Previously
    // the second clear masked the first error.
    let good = """
    [{"targetDoc":"GROWTH","proposalText":"ok","evidenceDates":["2026-04-01"],"confidence":0.5}]
    """
    let mock = MockLLMClient(scriptedResponses: ["nope-not-json", good])
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let result = try await con.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["AGENTS": "s", "GROWTH": "v"]   // sorted → AGENTS first, GROWTH second
    )
    #expect(result.count == 1)
    let errs = await con.lastParseErrors
    #expect(errs.count == 1)   // AGENTS failed
    let legacy = await con.lastParseError
    #expect(legacy != nil)     // back-compat getter still surfaces it

    // Second consolidate run resets the error buffer.
    let mock2 = MockLLMClient(scriptedResponses: [good])
    let con2 = SwiftNativeREMConsolidator(llm: mock2, diary: reader)
    _ = try await con2.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["GROWTH": "v"]
    )
    let errs2 = await con2.lastParseErrors
    #expect(errs2.isEmpty)
}

// 15 — cross-target proposals are dropped and the drop count is exposed
@Test func remConsolidator_parseLLMResponse_drops_cross_target_proposals() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [
      {"targetDoc":"GROWTH","proposalText":"keep","evidenceDates":["2026-01-01"],"confidence":0.5},
      {"targetDoc":"VOICE","proposalText":"drop","evidenceDates":["2026-01-01"],"confidence":0.5},
      {"targetDoc":"SOUL","proposalText":"drop","evidenceDates":["2026-01-01"],"confidence":0.5}
    ]
    """
    let mock = MockLLMClient()
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "keep")
    let drops = await con.lastTargetMismatchDrops
    #expect(drops == 2)
}

@Test func remConsolidator_parseLLMResponse_drops_non_growth_target_passes() async throws {
    let root = tempDir()
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [
      {"targetDoc":"SOUL","proposalText":"drop","evidenceDates":["2026-01-01"],"confidence":0.5}
    ]
    """
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let parsed = await con.parseLLMResponse(raw, target: "SOUL")
    #expect(parsed.isEmpty)
    let drops = await con.lastTargetMismatchDrops
    #expect(drops == 1)
}

// 16 — proposals whose evidenceDates aren't in the set sent to the LLM
// (or aren't YYYY-MM-DD) are dropped, with the count exposed.
@Test func remConsolidator_consolidate_drops_unknown_evidence_dates() async throws {
    let root = tempDir()
    try writeDiaryEntry(root: root, date: "2026-02-10", content: "x")
    try writeDiaryEntry(root: root, date: "2026-02-11", content: "y")
    let reader = DreamDiaryReader(dataRoot: root)
    let raw = """
    [
      {"targetDoc":"GROWTH","proposalText":"keep","evidenceDates":["2026-02-10","2026-02-11"],"confidence":0.7},
      {"targetDoc":"GROWTH","proposalText":"drop-unknown","evidenceDates":["2025-12-31"],"confidence":0.7},
      {"targetDoc":"GROWTH","proposalText":"drop-malformed","evidenceDates":["02/10/2026"],"confidence":0.7}
    ]
    """
    let mock = MockLLMClient(scriptedResponses: [raw])
    let con = SwiftNativeREMConsolidator(llm: mock, diary: reader)
    let result = try await con.consolidate(
        since: iso("2026-01-01"),
        personaDocs: ["GROWTH": "doc"]
    )
    #expect(result.count == 1)
    #expect(result[0].proposalText == "keep")
    let drops = await con.lastEvidenceDateDrops
    #expect(drops == 2)
}

// MARK: - 2026-07-03 REM repair: tolerant extraction + empty-text rejection

@Test func remConsolidator_parseLLMResponse_fenced_JSON_parses() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let raw = """
    ```json
    [{"targetDoc":"GROWTH","proposalText":"Reflex one lands.","evidenceDates":["2026-06-22"],"confidence":0.7}]
    ```
    """
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "Reflex one lands.")
    #expect(await con.lastParseErrors.isEmpty)
}

@Test func remConsolidator_parseLLMResponse_prose_wrapped_JSON_parses() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let raw = """
    Here are this week's proposals:
    [{"targetDoc":"GROWTH.md","proposalText":"Reflex two lands.","evidenceDates":["2026-06-22","2026-06-24"],"confidence":0.9}]
    Let me know if these look right.
    """
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "Reflex two lands.")
}

@Test func remConsolidator_parseLLMResponse_empty_text_after_normalize_is_dropped_loudly() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let raw = """
    [{"targetDoc":"GROWTH","proposalText":"   ","evidenceDates":["2026-06-22"],"confidence":0.5},
     {"targetDoc":"GROWTH","proposalText":"Survivor reflex.","evidenceDates":["2026-06-23"],"confidence":0.6}]
    """
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "Survivor reflex.")
    let errs = await con.lastParseErrors
    #expect(errs.count == 1)
    #expect(errs[0].contains("proposal text empty"))
}

@Test func remConsolidator_parseLLMResponse_honest_empty_array_is_clean() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let parsed = await con.parseLLMResponse("```json\n[]\n```", target: "GROWTH")
    #expect(parsed.isEmpty)
    #expect(await con.lastParseErrors.isEmpty)
}

@Test func remConsolidator_extractJSONArray_shapes() {
    #expect(SwiftNativeREMConsolidator.extractJSONArray("[1]") == "[1]")
    #expect(SwiftNativeREMConsolidator.extractJSONArray("```json\n[1]\n```") == "[1]")
    #expect(SwiftNativeREMConsolidator.extractJSONArray("prose [1,2] trailing") == "[1,2]")
    #expect(SwiftNativeREMConsolidator.extractJSONArray("no array here") == "no array here")
}

@Test func remConsolidator_parse_survives_bracketed_prose_around_array() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let raw = """
    Here are the proposals [draft]:
    [{"targetDoc":"GROWTH","proposalText":"Reflex three lands.","evidenceDates":["2026-06-22"],"confidence":0.8}]
    Notes: [none]
    """
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "Reflex three lands.")
}

@Test func remConsolidator_parse_finds_array_inside_object_wrapper() async throws {
    let reader = DreamDiaryReader(dataRoot: tempDir())
    let con = SwiftNativeREMConsolidator(llm: MockLLMClient(), diary: reader)
    let raw = """
    {"proposals": [{"targetDoc":"GROWTH","proposalText":"Reflex four lands.","evidenceDates":["2026-06-23"],"confidence":0.7}]}
    """
    let parsed = await con.parseLLMResponse(raw, target: "GROWTH")
    #expect(parsed.count == 1)
    #expect(parsed[0].proposalText == "Reflex four lands.")
}

@Test func remConsolidator_candidateSpans_respects_strings_and_escapes() {
    let spans = SwiftNativeREMConsolidator.candidateJSONArraySpans(
        #"pre [a] mid [{"k":"br ] acket \" quote"}] post"#
    )
    #expect(spans.count == 2)
    #expect(spans[0] == "[a]")
    #expect(spans[1] == #"[{"k":"br ] acket \" quote"}]"#)
}

// MARK: - 2026-07-03 REMGrowthWriter (the missing approve→GROWTH write)

@Test func growthWriter_appends_entry_in_house_style() async throws {
    let dir = tempDir()
    let growth = dir.appendingPathComponent("GROWTH.md")
    try "# GROWTH.md\n\n## existing reflex\nBody here.\n".write(to: growth, atomically: true, encoding: .utf8)
    let text = "Verify at the glass, not the compile. Build-green proves nothing about pixels."
    let appended = try await REMGrowthWriter.appendApprovedLesson(personaRoot: dir, proposalText: text)
    #expect(appended)
    let body = try String(contentsOf: growth, encoding: .utf8)
    // Body only — no machine-derived heading (User, 2026-07-03: a heading
    // echoing the first clause is per-turn prompt tax).
    #expect(!body.contains("## verify at the glass"))
    #expect(body.contains("\n" + text + "\n"))
    #expect(body.hasPrefix("# GROWTH.md"))
}

@Test func growthWriter_is_idempotent_on_exact_text() async throws {
    let dir = tempDir()
    let growth = dir.appendingPathComponent("GROWTH.md")
    try "# GROWTH.md\n".write(to: growth, atomically: true, encoding: .utf8)
    let text = "Pressure is calibration, not doubt."
    #expect(try await REMGrowthWriter.appendApprovedLesson(personaRoot: dir, proposalText: text))
    #expect(try await REMGrowthWriter.appendApprovedLesson(personaRoot: dir, proposalText: text) == false)
    let body = try String(contentsOf: growth, encoding: .utf8)
    #expect(body.components(separatedBy: text).count == 2)
}

@Test func growthWriter_creates_missing_doc_only_in_real_persona_root() async throws {
    let dir = tempDir()
    // SOUL.md marks a real persona root mid-migration: create is allowed.
    try "# SOUL".write(to: dir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    let text = "A lesson that must not vanish."
    #expect(try await REMGrowthWriter.appendApprovedLesson(personaRoot: dir, proposalText: text))
    let body = try String(contentsOf: dir.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body.hasPrefix("# GROWTH.md"))
    #expect(body.contains(text))
}

@Test func growthWriter_throws_on_unready_root_instead_of_minting_stray_doc() async throws {
    let dir = tempDir()
    // No SOUL.md, no GROWTH.md — the resolver's last-resort fallback shape.
    await #expect(throws: REMGrowthWriter.PersonaRootUnready.self) {
        try await REMGrowthWriter.appendApprovedLesson(
            personaRoot: dir, proposalText: "Must not land here.")
    }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("GROWTH.md").path))
}

@Test func growthWriter_substring_of_longer_paragraph_does_not_skip() async throws {
    let dir = tempDir()
    let growth = dir.appendingPathComponent("GROWTH.md")
    try "# GROWTH.md\n\n## existing\nPrefix words Pressure is care inside a longer paragraph.\n"
        .write(to: growth, atomically: true, encoding: .utf8)
    // The new lesson is a SUBSTRING of the existing paragraph — must still append.
    #expect(try await REMGrowthWriter.appendApprovedLesson(
        personaRoot: dir, proposalText: "Pressure is care"))
    let body = try String(contentsOf: growth, encoding: .utf8)
    #expect(body.contains("\nPressure is care\n"))
    #expect(!body.contains("## pressure is care"))
}
