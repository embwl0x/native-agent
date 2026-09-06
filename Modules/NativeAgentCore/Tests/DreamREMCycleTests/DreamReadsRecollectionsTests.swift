import Testing
import Foundation
import PersistenceCore
@testable import DreamREMCycle
import NativeAgentCore

/// ONE consolidation owner — NORTHSTAR clause 1, sweep item 45.
///
/// The chat lane distills a session's older turns into recollection rows as
/// they age. Before this, the dream lane re-read raw turns and summarized the
/// same lived session a second time; now it reads the recollection where one
/// exists, through `ChatSessionRecollections` — the single accessor both sides
/// agree on.

private let cannedDream = """
{"title":"Held Thread","summary":"The day circled one thread and let it rest.","mood":"quiet","emerging_themes":["continuity"],"surprising_moments":["nothing insisted"]}
"""

private final class PromptCapturingLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return _prompts.last }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _prompts.count }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        record(prompt)
        return cannedDream
    }

    private func record(_ prompt: String) {
        lock.lock()
        defer { lock.unlock() }
        _prompts.append(prompt)
    }
}

private func recollectionTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DreamRecollections-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func enableDreams(_ root: URL) {
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = """
    {"trainingPolicy":{"dream_scheduler":true},"personalityPolicy":{"dream_cycle_enabled":true}}
    """
    try! Data(json.utf8).write(to: dir.appendingPathComponent("policy.json"))
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Seed a transcript whose older turns have ALREADY been consolidated: one
/// recollection row standing for them, then the raw keep-tail.
private func seedConsolidatedSession(
    _ root: URL,
    id: String,
    recollection: String,
    coversFrom: Date,
    coversUntil: Date,
    writtenAt: Date,
    tail: [(role: String, content: String, at: Date)]
) {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var rows: [JSONValue] = [
        .object([
            "id": .string("compact-\(id)"),
            "sessionId": .string(id),
            "role": .string("system"),
            "content": .string(recollection),
            "createdAt": .string(iso(writtenAt)),
            "source": .string("native_autocompaction"),
            "metadata": .object([
                "kind": .string(ChatSessionRecollections.rowKind),
                "messages_replaced": .int(12),
                "lane": .string("aging"),
                "distill": .string("llm"),
                ChatSessionRecollections.coversFromKey: .string(iso(coversFrom)),
                ChatSessionRecollections.coversUntilKey: .string(iso(coversUntil)),
            ]),
        ]),
    ]
    for row in tail {
        rows.append(.object([
            "role": .string(row.role),
            "content": .string(row.content),
            "createdAt": .string(iso(row.at)),
        ]))
    }
    var body = ""
    for row in rows { body += (try! row.serialize(pretty: false)) + "\n" }
    let url = dir.appendingPathComponent("\(id).jsonl")
    try! Data(body.utf8).write(to: url)
    let newest = max(writtenAt, tail.map(\.at).max() ?? writtenAt)
    try! FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: url.path)
}

/// `throws` rather than `try!`: this ran before `dream_diary` existed, and the
/// write's NSCocoaErrorDomain 4 took down the whole test PROCESS instead of
/// recording one issue.
private func writeDreamMark(_ root: URL, _ date: Date) throws {
    let dir = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = JSONValue.object(["lastDreamedAt": .string(iso(date))])
    try Data((try body.serialize(pretty: false)).utf8)
        .write(to: dir.appendingPathComponent(".dream_state.json"))
}

@Test
func dreamReadsTheRecollectionInsteadOfResummarizing() async throws {
    let root = recollectionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    let now = Date()
    seedConsolidatedSession(
        root,
        id: "consolidated",
        recollection: "I spent the morning with User on the consolidation lane; he was tired but decisive.",
        coversFrom: now.addingTimeInterval(-7_200),
        coversUntil: now.addingTimeInterval(-3_600),
        writtenAt: now.addingTimeInterval(-300),
        tail: [
            (role: "user", content: "still with me?", at: now.addingTimeInterval(-120)),
            (role: "assistant", content: "right here.", at: now.addingTimeInterval(-60)),
        ]
    )

    let llm = PromptCapturingLLM()
    let report = try await DreamCycleRunner(dataRoot: root, llm: llm).runNightlyDreamCycle()

    #expect(report.entriesWritten == 1)
    let prompt = try #require(llm.lastPrompt)
    // The recollection reached the dream — as a recollection, labelled as such,
    // NOT re-derived from turns the chat lane already consolidated away.
    #expect(prompt.contains("[\(DreamCycleRunner.recollectionRole)]"))
    #expect(prompt.contains("consolidation lane"))
    #expect(prompt.contains("still with me?"))
}

@Test
func dreamSkipsARecollectionOfMaterialItAlreadyDreamed() async throws {
    let root = recollectionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    enableDreams(root)
    let now = Date()
    // The recollection was WRITTEN minutes ago but stands for turns from before
    // the last dream. Comparing the mark against its write time would re-dream
    // that stretch; comparing against its coverage does not.
    seedConsolidatedSession(
        root,
        id: "already-dreamed",
        recollection: "material this lane consumed raw last night",
        coversFrom: now.addingTimeInterval(-40_000),
        coversUntil: now.addingTimeInterval(-30_000),
        writtenAt: now.addingTimeInterval(-120),
        tail: [
            (role: "user", content: "fresh turn after the dream", at: now.addingTimeInterval(-60)),
        ]
    )
    try writeDreamMark(root, now.addingTimeInterval(-20_000))

    let llm = PromptCapturingLLM()
    let report = try await DreamCycleRunner(dataRoot: root, llm: llm).runNightlyDreamCycle()

    #expect(report.entriesWritten == 1)
    let prompt = try #require(llm.lastPrompt)
    #expect(!prompt.contains("consumed raw last night"))
    #expect(prompt.contains("fresh turn after the dream"))
}

@Test
func recollectionAccessorRecognizesOnlyRecollectionRows() throws {
    let ordinary = JSONValue.object([
        "role": .string("assistant"),
        "content": .string("an ordinary turn"),
    ])
    #expect(ChatSessionRecollections.recollection(fromTranscriptRow: ordinary, sessionId: "s") == nil)

    let recollection = JSONValue.object([
        "id": .string("compact-1"),
        "role": .string("system"),
        "content": .string("what I remember"),
        "createdAt": .string("2026-09-01T12:00:00.000Z"),
        "metadata": .object([
            "kind": .string(ChatSessionRecollections.rowKind),
            "messages_replaced": .int(7),
            "distill": .string("llm"),
            ChatSessionRecollections.coversUntilKey: .string("2026-08-31T09:00:00.000Z"),
        ]),
    ])
    let parsed = try #require(
        ChatSessionRecollections.recollection(fromTranscriptRow: recollection, sessionId: "s")
    )
    #expect(parsed.text == "what I remember")
    #expect(parsed.messagesReplaced == 7)
    #expect(parsed.distilled)
    // Coverage, not write time, is what a consumer compares its mark against.
    #expect(parsed.consolidatedThrough == parsed.coversUntil)
    #expect(parsed.consolidatedThrough != parsed.createdAt)

    // Legacy rows (written before coverage was recorded) fall back honestly.
    let legacy = JSONValue.object([
        "role": .string("system"),
        "content": .string("older recollection"),
        "createdAt": .string("2026-07-01T12:00:00.000Z"),
        "metadata": .object(["kind": .string(ChatSessionRecollections.rowKind)]),
    ])
    let legacyParsed = try #require(
        ChatSessionRecollections.recollection(fromTranscriptRow: legacy, sessionId: "s")
    )
    #expect(legacyParsed.consolidatedThrough == legacyParsed.createdAt)
    #expect(!legacyParsed.distilled)

    // Microsecond ISO (the live transcript shape) parses.
    #expect(ChatSessionRecollections.parseTimestamp(.string("2026-05-07T11:33:32.167835+00:00")) != nil)
}
