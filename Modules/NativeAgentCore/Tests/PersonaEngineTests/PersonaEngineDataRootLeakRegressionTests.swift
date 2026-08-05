import Testing
import Foundation
@testable import PersonaEngine
import NativeAgentCore
import PersistenceCore

// MARK: - Persona-engine dataRoot LEAK regression (2026-08-05 hermetic sweep)
//
// THE BUG. `SwiftNativePersonaEngine(root:)` defaults `dataRoot:` to
// `PersistenceCore.defaultDataRoot()` — the LIVE data root under `swift test`.
// 110 test call sites constructed it bare, so every `savePersonalityDoc` in the
// suite appended a real `"<DOC>.md updated"` row to the user's
// `data/activity/events.jsonl` (739 phantom rows before the sweep). Build-green
// hid it completely: the write succeeds, the test asserts on the persona doc,
// and the activity row lands somewhere nobody looked.
//
// This suite reproduces the LEAK SHAPE rather than the symptom: it saves a doc
// through a hermetically-pinned engine and proves the activity row landed in
// the HERMETIC root — and that a second root standing in for "live" received
// nothing. Point `hermeticPersona`'s dataRoot at the stand-in root and this
// suite fails on both halves; that is the mutation check.

private func leakTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaLeakRegression-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func activityPath(_ dataRoot: URL) -> URL {
    dataRoot
        .appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
}

private func activityTitles(_ dataRoot: URL) -> [String] {
    guard let text = try? String(contentsOf: activityPath(dataRoot), encoding: .utf8) else {
        return []
    }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["title"] as? String
    }
}

@Suite("persona engine dataRoot leak regression")
struct PersonaEngineDataRootLeakRegressionTests {

    @Test("savePersonalityDoc writes the activity row into the HERMETIC root, not the live one")
    func savePersonalityDoc_activityRowStaysInHermeticRoot() async throws {
        let box = try leakTempRoot()
        defer { try? FileManager.default.removeItem(at: box) }

        let personaRoot = box.appendingPathComponent("persona", isDirectory: true)
        let hermeticData = box.appendingPathComponent("hermetic-data", isDirectory: true)
        // Stand-in for the LIVE data root: whatever the leak would have hit.
        // Nothing in this test may ever write here.
        let standInLive = box.appendingPathComponent("stand-in-live-data", isDirectory: true)
        for dir in [personaRoot, hermeticData, standInLive] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // savePersonalityDoc is gated on an initialized persona (SOUL.md).
        try Data("# Soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

        let engine = hermeticPersona(root: personaRoot, dataRoot: hermeticData)
        let saved = try await engine.savePersonalityDoc(id: "voice", content: "# Hermetic Voice")

        // 1. The doc round-trips.
        #expect(saved.id == "VOICE")
        #expect(saved.content == "# Hermetic Voice")
        let onDisk = try String(
            contentsOf: personaRoot.appendingPathComponent("VOICE.md"), encoding: .utf8)
        #expect(onDisk == "# Hermetic Voice")
        let reloaded = try #require(try await engine.getPersonaDoc(id: "VOICE"))
        #expect(reloaded.content == "# Hermetic Voice")

        // 2. The activity row landed in the HERMETIC root.
        #expect(FileManager.default.fileExists(atPath: activityPath(hermeticData).path))
        #expect(activityTitles(hermeticData) == ["VOICE.md updated"])

        // 3. The stand-in "live" root was never touched — the leak shape itself.
        #expect(!FileManager.default.fileExists(atPath: activityPath(standInLive).path))
        #expect(activityTitles(standInLive).isEmpty)
    }

    @Test("the hermetic helper never resolves to the process default data root")
    func hermeticPersonaDataRoot_isNotTheDefaultDataRoot() async throws {
        let personaRoot = try leakTempRoot()
        defer { try? FileManager.default.removeItem(at: personaRoot) }
        let engine = hermeticPersona(root: personaRoot)
        let pinned = await engine.dataRootURL
        #expect(pinned.standardizedFileURL != PersistenceCore.defaultDataRoot().standardizedFileURL)
        // …and it must be a real, writable directory, not a bare URL.
        #expect(FileManager.default.fileExists(atPath: pinned.path))
    }
}
