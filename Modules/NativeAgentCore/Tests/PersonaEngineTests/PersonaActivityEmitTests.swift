import Testing
import Foundation
@testable import PersonaEngine
import NativeAgentCore
import PersistenceCore

// MARK: - record_activity parity tests (wave 36 W16)
//
// Pins the §6.76 item-B / §6.137 #6 fix: the native `savePersonalityDoc` seam
// now emits the daemon's
//   record_activity("memory", "{doc_id}.md updated", "Personality document saved", "ok")
// row to `<dataRoot>/activity/events.jsonl` (the SAME feed the daemon's
// `activity()` reader tails), byte-identical to `append_jsonl(json.dumps(
// sort_keys=True))`. Also pins the NEGATIVE parity: the OTHER persona writers
// (save_personality, append_personality_growth) emit NO daemon row and so emit
// none here either.

private func aeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaActivityEmitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func aeEngine(_ root: URL) -> (engine: SwiftNativePersonaEngine, personaRoot: URL, dataRoot: URL) {
    let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let engine = SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    return (engine, personaRoot, dataRoot)
}

private func aeSeedSoul(_ personaRoot: URL) throws {
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# Existing Soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
}

private func aeActivityPath(_ dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
}

/// Read the activity feed as a list of [String: Any] event dicts.
private func aeReadEvents(_ dataRoot: URL) -> [[String: Any]] {
    let path = aeActivityPath(dataRoot)
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

// MARK: - positive emit

@Test("savePersonalityDoc emits the daemon record_activity row (kind/title/detail/status parity)")
func emit_savePersonalityDoc_emitsRow() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = aeEngine(root)
    try aeSeedSoul(personaRoot)

    _ = try await engine.savePersonalityDoc(id: "voice", content: "# My Voice")

    let events = aeReadEvents(dataRoot)
    #expect(events.count == 1)
    let ev = try #require(events.first)
    #expect(ev["kind"] as? String == "memory")
    // docId is UPPER-cased even though the caller passed "voice".
    #expect(ev["title"] as? String == "VOICE.md updated")
    #expect(ev["detail"] as? String == "Personality document saved")
    #expect(ev["status"] as? String == "ok")
    // missionId is null on the persona path (daemon passes mission_id=None).
    #expect(ev["executionId"] is NSNull)
    // payload defaults to {} (daemon `payload or {}`).
    #expect((ev["payload"] as? [String: Any])?.isEmpty == true)
    // id + createdAt are present and non-empty.
    #expect((ev["id"] as? String)?.isEmpty == false)
    let createdAt = try #require(ev["createdAt"] as? String)
    #expect(!createdAt.isEmpty)
    // createdAt parity: now_iso() = datetime.now(utc).isoformat() renders the
    // OFFSET form `...+00:00`, NOT the `Z` form. The activity feed must match
    // the daemon's other rows, so the emitted stamp ends in `+00:00`.
    #expect(createdAt.hasSuffix("+00:00"))
    #expect(!createdAt.hasSuffix("Z"))
    // id is a lowercase dashed uuid4 string (str(uuid4()) parity).
    let id = try #require(ev["id"] as? String)
    #expect(id == id.lowercased())
    #expect(id.contains("-"))
}

@Test("savePersonalityDoc activity row is sort_keys-ordered JSONL (daemon append_jsonl byte parity)")
func emit_savePersonalityDoc_sortKeysByteShape() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = aeEngine(root)
    try aeSeedSoul(personaRoot)

    _ = try await engine.savePersonalityDoc(id: "AGENTS", content: "# facts")

    let text = try String(contentsOf: aeActivityPath(dataRoot), encoding: .utf8)
    // One line, newline-terminated (append_jsonl writes `... + "\n"`).
    #expect(text.hasSuffix("\n"))
    let line = String(text.dropLast())
    // Keys appear in UTF-8 byte (== ASCII lexicographic) order, matching
    // json.dumps(sort_keys=True): createdAt, detail, executionId, id, kind,
    // payload, status, title. (P2-2 renamed the envelope key missionId ->
    // executionId, which also moved its sort position: e < i.)
    let expectedOrder = ["\"createdAt\"", "\"detail\"", "\"executionId\"", "\"id\"",
                         "\"kind\"", "\"payload\"", "\"status\"", "\"title\""]
    var cursor = line.startIndex
    for key in expectedOrder {
        guard let r = line.range(of: key, range: cursor..<line.endIndex) else {
            Issue.record("key \(key) not found in order in: \(line)")
            return
        }
        cursor = r.upperBound
    }
    // Separator shape matches Python json.dumps(sort_keys=True) DEFAULTS
    // (", " / ": "), which is what the daemon's append_jsonl uses (it passes
    // no compact `separators=`). PersistenceCore's non-pretty encode emits the
    // same ": " / ", ".
    #expect(line.contains("\"kind\": \"memory\""))
}

@Test("savePersonalityDoc emits exactly ONE row per write (no double-emit)")
func emit_savePersonalityDoc_oneRowPerWrite() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = aeEngine(root)
    try aeSeedSoul(personaRoot)

    _ = try await engine.savePersonalityDoc(id: "VOICE", content: "a")
    _ = try await engine.savePersonalityDoc(id: "GROWTH", content: "b")

    let events = aeReadEvents(dataRoot)
    #expect(events.count == 2)
    #expect(events[0]["title"] as? String == "VOICE.md updated")
    #expect(events[1]["title"] as? String == "GROWTH.md updated")
}

// MARK: - negative emit (the OTHER writers must NOT emit a row)

@Test("savePersonality (profile.json) emits NO activity row (daemon parity: cache clear only)")
func emit_savePersonality_noRow() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = aeEngine(root)

    _ = try await engine.savePersonality(body: ["voice": .string("warm")])

    #expect(aeReadEvents(dataRoot).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: aeActivityPath(dataRoot).path))
}

@Test("appendPersonalityGrowth emits NO activity row (daemon parity: cache clear only)")
func emit_appendGrowth_noRow() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = aeEngine(root)
    try aeSeedSoul(personaRoot)

    _ = try await engine.appendPersonalityGrowth(kind: "dream", text: "learned a thing", sourceRunId: nil)

    #expect(aeReadEvents(dataRoot).isEmpty)
}

@Test("personaWrite / personaAppendSection emit NO activity row (agent tools return a dict only)")
func emit_personaTools_noRow() async throws {
    let root = try aeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = aeEngine(root)
    try aeSeedSoul(personaRoot)

    _ = try await engine.personaWrite(kind: "voice", content: "# V", skillName: nil)
    _ = try await engine.personaAppendSection(kind: "growth", title: "Note", content: "x")

    #expect(aeReadEvents(dataRoot).isEmpty)
}
