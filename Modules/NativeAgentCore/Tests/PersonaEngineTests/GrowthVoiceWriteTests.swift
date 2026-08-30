import Testing
import Foundation
@testable import PersonaEngine
import NativeAgentCore
import PersistenceCore

// MARK: - Growth + Voice persona MUTATION writer tests (wave 35 W13)
//
// Covers the native port of the three persona-MUTATION writers:
//   appendPersonalityGrowth  <- Runtime.append_personality_growth
//   personaWrite             <- _exec_persona_write
//   personaAppendSection     <- _exec_persona_append_section
//
// Asserts Python parity against hand-seeded on-disk state.

private func gvTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrowthVoiceWriteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func gvEngine(_ root: URL) -> (engine: SwiftNativePersonaEngine, personaRoot: URL, dataRoot: URL) {
    let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try? FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    let engine = SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    return (engine, personaRoot, dataRoot)
}

private func gvSeedSoul(_ personaRoot: URL) throws {
    try "# Soul".write(to: personaRoot.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
}

// MARK: - appendPersonalityGrowth

@Test("appendPersonalityGrowth NO-OPs before onboarding (no SOUL.md)")
func growth_preOnboarding_noop() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let wrote = try await engine.appendPersonalityGrowth(kind: "correction", text: "hello", sourceRunId: nil)
    #expect(wrote == false)
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("GROWTH.md").path))
}

@Test("appendPersonalityGrowth NO-OPs on empty/whitespace-only text")
func growth_emptyText_noop() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let wrote = try await engine.appendPersonalityGrowth(kind: "correction", text: "   \n\t ", sourceRunId: nil)
    #expect(wrote == false)
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("GROWTH.md").path))
}

@Test("appendPersonalityGrowth scaffolds GROWTH.md when missing, then appends the entry line")
func growth_scaffoldsAndAppends() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let wrote = try await engine.appendPersonalityGrowth(kind: "drift_note", text: "tone   was   off", sourceRunId: nil)
    #expect(wrote == true)
    let growthURL = personaRoot.appendingPathComponent("GROWTH.md")
    let body = try String(contentsOf: growthURL, encoding: .utf8)
    #expect(body.contains("Growth"))
    #expect(body.contains("## Entries"))
    #expect(body.contains("\u{B7} drift_note \u{B7} tone was off"))
    #expect(body.hasSuffix("\n"))
    #expect(body.contains("- 20"))
}

@Test("appendPersonalityGrowth appends a run suffix when sourceRunId is set")
func growth_runSuffix() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    _ = try await engine.appendPersonalityGrowth(kind: "dream_candidate", text: "x learns y", sourceRunId: "dream:2026-06-02")
    let body = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body.contains("\u{B7} dream_candidate \u{B7} x learns y \u{B7} run dream:2026-06-02"))
}

@Test("appendPersonalityGrowth appends to an EXISTING GROWTH.md without re-scaffolding")
func growth_appendsToExisting() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let growthURL = personaRoot.appendingPathComponent("GROWTH.md")
    try "# Custom Growth\n\nseed line".write(to: growthURL, atomically: true, encoding: .utf8)
    _ = try await engine.appendPersonalityGrowth(kind: "correction", text: "be terser", sourceRunId: nil)
    let body = try String(contentsOf: growthURL, encoding: .utf8)
    #expect(body.hasPrefix("# Custom Growth\n\nseed line\n- "))
    #expect(body.contains("\u{B7} correction \u{B7} be terser"))
    #expect(!body.contains("## Entries"))
}

@Test("appendPersonalityGrowth preserves an unreadable GROWTH.md")
func growth_refusesUnreadableExistingDocument() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let growthURL = personaRoot.appendingPathComponent("GROWTH.md")
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
    try invalidUTF8.write(to: growthURL)

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.appendPersonalityGrowth(
            kind: "correction",
            text: "must not replace authority",
            sourceRunId: nil
        )
    }
    #expect(try Data(contentsOf: growthURL) == invalidUTF8)
}

@Test("appendPersonalityGrowth caps cleaned text at 1000 code points")
func growth_capsAt1000() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let long = String(repeating: "a", count: 2000)
    _ = try await engine.appendPersonalityGrowth(kind: "k", text: long, sourceRunId: nil)
    let body = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    let capped = String(repeating: "a", count: 1000)
    #expect(body.contains("\u{B7} k \u{B7} \(capped)\n"))
    #expect(!body.contains(String(repeating: "a", count: 1001)))
}

// MARK: - personaWrite

@Test("personaWrite replaces VOICE.md and reports bytesWritten")
func write_voiceReplace() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let result = try await engine.personaWrite(kind: "voice", content: "new voice doc", skillName: nil)
    #expect(result.kind == "voice")
    #expect(result.path == personaRoot.appendingPathComponent("VOICE.md").path)
    #expect(result.backupPath == nil)
    #expect(result.bytesWritten == Array("new voice doc".utf8).count)
    #expect(result.bytesAppended == nil)
    let body = try String(contentsOf: personaRoot.appendingPathComponent("VOICE.md"), encoding: .utf8)
    #expect(body == "new voice doc")
}

@Test("personaWrite backs up the prior VOICE.md content before replacing")
func write_backsUpPrior() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let voiceURL = personaRoot.appendingPathComponent("VOICE.md")
    try "OLD VOICE".write(to: voiceURL, atomically: true, encoding: .utf8)
    let result = try await engine.personaWrite(kind: "voice", content: "NEW VOICE", skillName: nil)
    #expect(result.backupPath != nil)
    let backupURL = URL(fileURLWithPath: result.backupPath!)
    let backup = try String(contentsOf: backupURL, encoding: .utf8)
    #expect(backup == "OLD VOICE")
    #expect(backupURL.lastPathComponent.hasPrefix("VOICE.md.pre-"))
    #expect(backupURL.lastPathComponent.hasSuffix(".bak"))
    #expect((try String(contentsOf: voiceURL, encoding: .utf8)) == "NEW VOICE")
}

@Test("personaWrite canonicalizes a fullwidth/whitespace kind (NFKC + strip + lower)")
func write_canonicalizesKind() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let result = try await engine.personaWrite(kind: "  \u{FF36}\u{FF2F}\u{FF29}\u{FF23}\u{FF25}  ", content: "v", skillName: nil)
    #expect(result.kind == "voice")
    #expect(result.path == personaRoot.appendingPathComponent("VOICE.md").path)
}

@Test("personaWrite rejects an unknown kind with invalidInput")
func write_rejectsUnknownKind() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = gvEngine(root)
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(kind: "bogus", content: "x", skillName: nil)
    }
}

@Test("personaWrite rejects USER.md because MemoryV2 owns the projection")
func write_rejectsUserDoc() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let userURL = personaRoot.appendingPathComponent("USER.md")
    try "original user projection".write(to: userURL, atomically: true, encoding: .utf8)

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(kind: "user", content: "direct rewrite", skillName: nil)
    }
    #expect((try String(contentsOf: userURL, encoding: .utf8)) == "original user projection")
}

@Test("personaWrite kind=skill requires a valid skill_name and resolves the body path")
func write_skillNameResolution() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = gvEngine(root)
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(kind: "skill", content: "x", skillName: nil)
    }
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(kind: "skill", content: "x", skillName: "../evil")
    }
    let skillBody = "# My Skill\n\nUse this when persona writes need a clean skill body."
    let result = try await engine.personaWrite(kind: "skill", content: skillBody, skillName: "my_skill")
    let expected = dataRoot.appendingPathComponent("skills/bodies/my_skill.md").path
    #expect(result.path == expected)
    #expect((try String(contentsOf: URL(fileURLWithPath: expected), encoding: .utf8)) == skillBody)
}

@Test("personaWrite kind=skill rejects dirty skill bodies")
func write_skillBodyHygieneRejectsDirtyBody() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = gvEngine(root)
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(
            kind: "skill",
            content: "# Dirty Skill\n\nUse this when the python daemon should run.",
            skillName: "dirty_skill"
        )
    }
    #expect(!FileManager.default.fileExists(
        atPath: dataRoot.appendingPathComponent("skills/bodies/dirty_skill.md").path
    ))
}

// MARK: - personaAppendSection

@Test("personaAppendSection appends a titled section to an existing doc")
func append_section() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let voiceURL = personaRoot.appendingPathComponent("VOICE.md")
    try "# Voice\n\nbody".write(to: voiceURL, atomically: true, encoding: .utf8)
    let result = try await engine.personaAppendSection(kind: "voice", title: "  New Note  ", content: "the note body")
    #expect(result.kind == "voice")
    #expect(result.bytesAppended == Array("\n\n## New Note\nthe note body".utf8).count)
    #expect(result.bytesWritten == nil)
    let body = try String(contentsOf: voiceURL, encoding: .utf8)
    #expect(body == "# Voice\n\nbody\n\n## New Note\nthe note body")
    #expect(result.backupPath != nil)
    #expect((try String(contentsOf: URL(fileURLWithPath: result.backupPath!), encoding: .utf8)) == "# Voice\n\nbody")
}

@Test("personaAppendSection creates the file when missing (no backup)")
func append_createsWhenMissing() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let result = try await engine.personaAppendSection(kind: "growth", title: "T", content: "C")
    #expect(result.backupPath == nil)
    let body = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(body == "\n\n## T\nC")
}

@Test("personaAppendSection preserves an unreadable canonical document")
func append_refusesUnreadableExistingDocument() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let voiceURL = personaRoot.appendingPathComponent("VOICE.md")
    let invalidUTF8 = Data([0xF5, 0x80, 0x80, 0x80])
    try invalidUTF8.write(to: voiceURL)

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaAppendSection(
            kind: "voice",
            title: "Unsafe append",
            content: "must not replace authority"
        )
    }
    #expect(try Data(contentsOf: voiceURL) == invalidUTF8)
    let backups = try FileManager.default.contentsOfDirectory(
        at: personaRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("VOICE.md.pre-") }
    #expect(backups.isEmpty)
}

@Test("personaAppendSection rejects an empty title and the skill kind (not in append set)")
func append_rejects() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = gvEngine(root)
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaAppendSection(kind: "voice", title: "   ", content: "c")
    }
    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaAppendSection(kind: "skill", title: "T", content: "c")
    }
}

@Test("personaAppendSection rejects USER.md because MemoryV2 owns the projection")
func append_rejectsUserDoc() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    let userURL = personaRoot.appendingPathComponent("USER.md")
    try "original user projection".write(to: userURL, atomically: true, encoding: .utf8)

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaAppendSection(kind: "user", title: "T", content: "C")
    }
    #expect((try String(contentsOf: userURL, encoding: .utf8)) == "original user projection")
}

// MARK: - flock convention

@Test("growth and voice writers take the cross-process path-lock flock")
func writers_useFlockConvention() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    _ = try await engine.appendPersonalityGrowth(kind: "k", text: "t", sourceRunId: nil)
    #expect(FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("GROWTH.md.lock").path))
    _ = try await engine.personaWrite(kind: "voice", content: "v", skillName: nil)
    #expect(FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("VOICE.md.lock").path))
}

// REPORTS-ONLY -> executable boundary checks (Wave 1):
// core.misc / persona.write.growthAndVoice
@Test("failed persona writes leave existing canonical bytes untouched")
func growthAndVoiceFailuresDoNotPartiallyMutatePersonaFiles() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    let voice = personaRoot.appendingPathComponent("VOICE.md")
    try "stable voice".write(to: voice, atomically: true, encoding: .utf8)

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.personaWrite(kind: "unknown-kind", content: "replacement", skillName: nil)
    }
    #expect(try String(contentsOf: voice, encoding: .utf8) == "stable voice")
    #expect(try await engine.appendPersonalityGrowth(kind: "note", text: " \n ", sourceRunId: nil) == false)
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("GROWTH.md").path))
}

@Test("growth writer serializes a deterministic run identity into durable content")
func growthWriteCarriesTheProvidedRunIdentityWithoutInventingOne() async throws {
    let root = try gvTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = gvEngine(root)
    try gvSeedSoul(personaRoot)
    #expect(try await engine.appendPersonalityGrowth(
        kind: "correction", text: "be precise", sourceRunId: "run-fixed"
    ))
    let text = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(text.contains("correction \u{B7} be precise \u{B7} run run-fixed"))
    #expect(!text.contains("run nil"))
}
