import Testing
import Foundation
@testable import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// Desk 903 phase 2, the last clause of it: "The dream felt-summary must cite
// the entry id so the causal chain is auditable." These prove the chain runs
// from the dream artifact back to `journal.jsonl` — the entry id appears
// VERBATIM in the written dream, and a change-only `dream.studio_citation`
// receipt names what was cited. A felt node that came from anywhere else is
// the ordinary case: the dream reads exactly as it did before, and no receipt
// is emitted at all.

private func makeCitationRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DreamStudioCitationTests-\(UUID().uuidString)", isDirectory: true)
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

private func seedCitationSession(_ root: URL, id: String, lines: [(String, String)]) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var body = ""
    for (role, content) in lines {
        body += "{\"role\":\"\(role)\",\"content\":\"\(content)\"}\n"
    }
    try! body.data(using: .utf8)!
        .write(to: dir.appendingPathComponent("\(id).jsonl"))
}

private func latestDiaryBody(_ root: URL) -> String {
    let dir = root.appendingPathComponent("dream_diary", isDirectory: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".md") }
        .sorted()
    guard let name = names.last,
          let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

private let citationDreamJSON = """
{"title":"Quiet Loop","summary":"A reflective beat from today.","mood":"contemplative","emerging_themes":["circular thinking"],"surprising_moments":["she named it herself"]}
"""

private final class FixedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return _prompts.last }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return citationDreamJSON
    }
}

/// Captures every receipt the runner hands out.
private final class ReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _receipts: [(kind: String, payload: JSONValue)] = []
    var receipts: [(kind: String, payload: JSONValue)] {
        lock.lock(); defer { lock.unlock() }; return _receipts
    }
    var sink: DreamReceiptSink {
        { [self] kind, payload in lock.withLock { _receipts.append((kind, payload)) } }
    }
    /// The string ids under `entries` of the first receipt of `kind`.
    func entries(ofKind kind: String) -> [String]? {
        guard let hit = receipts.first(where: { $0.kind == kind }) else { return nil }
        guard case .object(let obj) = hit.payload,
              case .array(let items)? = obj["entries"] else { return [] }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}

private let feltText = "the day has a good feel — from 2 felt moments.\n- warm — a judgment that landed"

// MARK: - A felt node carrying a studio entry id

/// The metadata key the studio seam stamps → the id appears VERBATIM in the
/// written dream, and the change-only receipt lists exactly that id.
@Test
func dreamCitesStudioEntryFromFeltNodeMetadata() async throws {
    let root = makeCitationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedCitationSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let receipts = ReceiptRecorder()
    let entryID = "2026-09-01T18-22-04Z-a71c"
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: FixedLLM(),
        feltSummaryProvider: { feltText },
        feltOriginProvider: {
            [DreamFeltOrigin(metadata: ["studioEntryId": entryID])]
        },
        receiptSink: receipts.sink
    )

    let report = try await runner.runNightlyDreamCycle()
    #expect(report.entriesWritten == 1)

    let body = latestDiaryBody(root)
    #expect(body.contains("(studio entry \(entryID))"),
            "the dream artifact must cite the entry verbatim: \(body)")
    #expect(body.contains("_Felt from:"), "citation line missing: \(body)")

    #expect(receipts.entries(ofKind: DreamCycleRunner.studioCitationReceiptKind) == [entryID])
}

/// The seam writes the id as `subject.id` too (subject type `studio_entry`), so
/// a node carrying only that half still cites.
@Test
func dreamCitesStudioEntryFromFeltNodeSubject() async throws {
    let root = makeCitationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedCitationSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let receipts = ReceiptRecorder()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: FixedLLM(),
        feltSummaryProvider: { feltText },
        feltOriginProvider: {
            [DreamFeltOrigin(subjectType: "studio_entry", subjectID: "entry-42")]
        },
        receiptSink: receipts.sink
    )

    _ = try await runner.runNightlyDreamCycle()
    #expect(latestDiaryBody(root).contains("(studio entry entry-42)"))
    #expect(receipts.entries(ofKind: DreamCycleRunner.studioCitationReceiptKind) == ["entry-42"])
}

// MARK: - A felt node that came from anywhere else

/// A felt node with no studio entry id → the dream is byte-identical to one run
/// with no origin provider at all, and NO receipt is emitted.
@Test
func feltNodeWithoutStudioEntryLeavesTheDreamUnchangedAndSilent() async throws {
    func dreamBody(origins: [DreamFeltOrigin], receipts: ReceiptRecorder) async throws -> String {
        let root = makeCitationRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        enableDreams(root)
        seedCitationSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])
        let runner = DreamCycleRunner(
            dataRoot: root,
            llm: FixedLLM(),
            feltSummaryProvider: { feltText },
            feltOriginProvider: { origins },
            receiptSink: receipts.sink
        )
        let report = try await runner.runNightlyDreamCycle()
        #expect(report.entriesWritten == 1)
        return latestDiaryBody(root)
    }

    let baselineReceipts = ReceiptRecorder()
    let baseline = try await dreamBody(origins: [], receipts: baselineReceipts)

    let otherReceipts = ReceiptRecorder()
    let withOtherNode = try await dreamBody(
        origins: [
            DreamFeltOrigin(
                subjectType: "conversation",
                subjectID: "sess-9",
                metadata: ["feltValence": "0.4"]
            )
        ],
        receipts: otherReceipts
    )

    #expect(!withOtherNode.isEmpty)
    #expect(withOtherNode == baseline, "a non-studio felt node must not change the dream")
    #expect(!withOtherNode.contains("studio entry"))
    #expect(!withOtherNode.contains("_Felt from:"))
    #expect(otherReceipts.receipts.isEmpty, "no citation → no receipt")
    #expect(baselineReceipts.receipts.isEmpty)
}

/// No felt summary → nothing to attribute, so a studio-derived node cites
/// nothing and stays silent. Feeling-silence stays silence.
@Test
func studioOriginWithoutFeltSummaryCitesNothing() async throws {
    let root = makeCitationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    seedCitationSession(root, id: "s1", lines: [("user", "hi"), ("assistant", "hello")])

    let receipts = ReceiptRecorder()
    let runner = DreamCycleRunner(
        dataRoot: root,
        llm: FixedLLM(),
        feltSummaryProvider: { nil },
        feltOriginProvider: { [DreamFeltOrigin(metadata: ["studioEntryId": "entry-7"])] },
        receiptSink: receipts.sink
    )
    _ = try await runner.runNightlyDreamCycle()

    #expect(!latestDiaryBody(root).contains("studio entry"))
    #expect(receipts.receipts.isEmpty)
}

// MARK: - Pure law

/// Deduped, order-preserving, and capped — an id repeated across felt nodes is
/// one citation, not four.
@Test
func studioCitationsAreDedupedAndCapped() {
    let origins =
        [DreamFeltOrigin(metadata: ["studioEntryId": "a"]),
         DreamFeltOrigin(metadata: ["studioEntryId": "a"]),
         DreamFeltOrigin(subjectType: "conversation", subjectID: "sess"),
         DreamFeltOrigin(metadata: ["studioEntryId": "b"]),
         DreamFeltOrigin(metadata: ["studioEntryId": "c"]),
         DreamFeltOrigin(metadata: ["studioEntryId": "d"]),
         DreamFeltOrigin(metadata: ["studioEntryId": "e"])]
    let cited = DreamCycleRunner.studioEntryCitations(from: origins, feltSummary: feltText)
    #expect(cited == ["a", "b", "c", "d"])
    #expect(DreamCycleRunner.studioCitationLine(cited)
        == "_Felt from: (studio entry a) (studio entry b) (studio entry c) (studio entry d)_\n\n")
    #expect(DreamCycleRunner.studioCitationLine([]).isEmpty)
    // A whitespace-only felt summary is silence too.
    #expect(DreamCycleRunner.studioEntryCitations(from: origins, feltSummary: "  \n ").isEmpty)
}
