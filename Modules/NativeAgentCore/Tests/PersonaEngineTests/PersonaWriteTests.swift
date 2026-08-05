import Testing
import Foundation
@testable import PersonaEngine
import NativeAgentCore
import PersistenceCore

// MARK: - Persona WRITE path tests (wave 32 W19)
//
// Covers the native port of POST /v1/personality (save_personality) and
// POST /v1/personality/docs (save_personality_doc), including the onboarding
// sentinel gate (allow + both deny cases), the 30K code-point cap, profile
// merge+normalize+byte-shape, and the unknown-doc-id error.

private func makeWriteTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaWriteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Build an engine whose persona root and data root are both under a fresh
/// temp dir. Persona docs live at `<root>/persona`; profile.json at
/// `<root>/data/memory/profile.json`.
private func makeEngine(_ root: URL) -> (engine: SwiftNativePersonaEngine, personaRoot: URL, dataRoot: URL) {
    let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let engine = SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    return (engine, personaRoot, dataRoot)
}

// MARK: - savePersonalityDoc — onboarding gate

@Test("savePersonalityDoc DENIES a non-SOUL doc before onboarding (no SOUL.md)")
func saveDoc_preOnboarding_nonSoul_denied() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    // No SOUL.md exists → not initialized.

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.savePersonalityDoc(id: "VOICE", content: "x")
    }
    // The matching detail string.
    do {
        _ = try await engine.savePersonalityDoc(id: "VOICE", content: "x")
        Issue.record("expected onboardingRequired")
    } catch let PersonaWriteError.onboardingRequired(detail) {
        #expect(detail.contains("Complete first-run onboarding"))
    }
    // And nothing was written.
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("VOICE.md").path))
}

@Test("savePersonalityDoc DENIES a SOUL write before onboarding (onboarding owns SOUL)")
func saveDoc_preOnboarding_soul_denied() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)

    do {
        _ = try await engine.savePersonalityDoc(id: "SOUL", content: "# new soul")
        Issue.record("expected onboardingRequired for SOUL")
    } catch let PersonaWriteError.onboardingRequired(detail) {
        #expect(detail.contains("/v1/onboarding/complete"))
    }
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path))
}

@Test("savePersonalityDoc ALLOWS edits once SOUL.md exists (persona initialized)")
func saveDoc_postOnboarding_allowed() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    // Seed SOUL.md → persona initialized.
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# Existing Soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let saved = try await engine.savePersonalityDoc(id: "voice", content: "# My Voice\nDirect.")
    #expect(saved.id == "VOICE")
    #expect(saved.title == "Voice")
    #expect(saved.filename == "VOICE.md")
    #expect(saved.content == "# My Voice\nDirect.")
    #expect(saved.path == personaRoot.appendingPathComponent("VOICE.md").path)
    #expect(saved.updatedAt != nil)
    // File on disk holds the content.
    let onDisk = try String(contentsOf: personaRoot.appendingPathComponent("VOICE.md"), encoding: .utf8)
    #expect(onDisk == "# My Voice\nDirect.")
}

@Test("savePersonalityDoc ALLOWS re-writing SOUL once it exists")
func saveDoc_postOnboarding_soul_allowed() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# v1".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let saved = try await engine.savePersonalityDoc(id: "SOUL", content: "# v2 soul")
    #expect(saved.id == "SOUL")
    #expect(saved.content == "# v2 soul")
    let onDisk = try String(contentsOf: personaRoot.appendingPathComponent("SOUL.md"), encoding: .utf8)
    #expect(onDisk == "# v2 soul")
}

@Test("savePersonalityDoc caps content at 30000 code points")
func saveDoc_capsAt30K() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let big = String(repeating: "a", count: 40_000)
    let saved = try await engine.savePersonalityDoc(id: "VOICE", content: big)
    #expect(saved.content.unicodeScalars.count == 30_000)
}

@Test("savePersonalityDoc rejects USER.md because MemoryV2 owns the projection")
func saveDoc_userRejectedMemoryOwned() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
    let userURL = personaRoot.appendingPathComponent("USER.md")
    try Data("original generated facts".utf8).write(to: userURL)

    do {
        _ = try await engine.savePersonalityDoc(id: " user ", content: "manual overwrite")
        Issue.record("expected invalidInput for USER.md")
    } catch let PersonaWriteError.invalidInput(detail) {
        #expect(detail.contains("MemoryV2"))
        #expect(detail.contains("commit_memory"))
    }
    #expect((try String(contentsOf: userURL, encoding: .utf8)) == "original generated facts")
    #expect(try readActivityRows(dataRoot: dataRoot).isEmpty)
}

@Test("savePersonalityDoc rejects an unknown doc id")
func saveDoc_unknownId() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    do {
        _ = try await engine.savePersonalityDoc(id: "NOTES", content: "x")
        Issue.record("expected unknownDocument")
    } catch let PersonaWriteError.unknownDocument(id) {
        #expect(id == "NOTES")
    }
}

// MARK: - savePersonality — merge / normalize / write

@Test("savePersonality writes a normalized profile.json reading back via loadProfile")
func savePersonality_writesAndRoundTrips() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    let body: [String: JSONValue] = [
        "name": .string("Claude"),
        "personaKind": .string("female"),  // normalize canonicalises → "Female"
        "essence": .string("Sharp and on your side."),
        "traits": .object([
            "warmth": .double(0.9),
            "directness": .double(2.0),   // out of range → clamps to 1.0
        ]),
    ]
    let profile = try await engine.savePersonality(body: body)
    #expect(profile.name == "Claude")
    #expect(profile.personaKind == "Female")
    #expect(profile.essence == "Sharp and on your side.")
    #expect(profile.traits.warmth == 0.9)
    #expect(profile.traits.directness == 1.0)  // clamped
    // updatedAt stamped.
    #expect(!profile.updatedAt.isEmpty)

    // File exists at <dataRoot>/memory/profile.json and re-reads identically.
    let profileURL = dataRoot.appendingPathComponent("memory").appendingPathComponent("profile.json")
    #expect(FileManager.default.fileExists(atPath: profileURL.path))
    let reloaded = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    #expect(reloaded.name == "Claude")
    #expect(reloaded.personaKind == "Female")
    #expect(reloaded.traits.warmth == 0.9)
    #expect(reloaded.traits.directness == 1.0)
}

@Test("savePersonality merges over existing profile (unspecified fields preserved)")
func savePersonality_mergesOverExisting() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    // First write sets name + essence.
    _ = try await engine.savePersonality(body: [
        "name": .string("Claude"),
        "essence": .string("First essence."),
    ])
    // Second write only updates essence — name must survive.
    let profile = try await engine.savePersonality(body: [
        "essence": .string("Second essence."),
    ])
    #expect(profile.name == "Claude")
    #expect(profile.essence == "Second essence.")

    let reloaded = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    #expect(reloaded.name == "Claude")
    #expect(reloaded.essence == "Second essence.")
}

@Test("savePersonality serializes canonical profile JSON bytes")
func savePersonality_writesCanonicalProfileJSON() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    _ = try await engine.savePersonality(body: [
        "name": .string("Claude"),
        "personaKind": .string("AI"),
    ])
    let profileURL = dataRoot.appendingPathComponent("memory").appendingPathComponent("profile.json")
    let swiftText = try String(contentsOf: profileURL, encoding: .utf8)

    let parsed = try JSONValue.parse(Data(swiftText.utf8))
    let expected = String(data: try parsed.serializedData(pretty: true), encoding: .utf8) ?? ""
    #expect(swiftText == expected, "Swift profile.json must be canonical pretty JSON")
}

// MARK: - savePersonality — VOICE field write coverage (wave 41 W07)
//
// CONTEXT (CUTOVER §6.220 wave-40 W04, re-verified this wave from primary
// source): there is NO `POST /v1/personality/voice` route and NO
// `set_personality_voice` daemon method — the persona `voice` PROFILE field is
// mutated ONLY through `POST /v1/personality` → `Runtime.save_personality(body)`
//, a plain `merged.update(body); write_json(...)` with
// ZERO GROWTH append and ZERO `record_activity`. The native mirror is
// `SwiftNativePersonaEngine.savePersonality(body:)` (PersonaEngine+Writes.swift
// L161), gated behind `.personaEngineWrites` (DEFAULT-OFF) via
// `NativeClient.savePersonality` (NativeClient.swift L6234/6279), which already
// carries `"voice": profile.voice` (L6239). The reopen kept recurring because no
// test NAMED `voice` as the field persisted through this seam, nor pinned the
// cross-process flock that serializes it against a concurrent daemon writer.
// These two tests close that gap WITHOUT inventing the phantom GROWTH/activity
// semantics the brief described — emitting those would ship a Python↔Swift
// divergence (native would log; HTTP `save_personality` would not).

@Test("savePersonality persists the voice field through the native write path (read-back)")
func savePersonality_voiceFieldRoundTrips() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    // Happy path: a body that sets ONLY `voice` (the field the reopen names) must
    // merge → normalize → write profile.json and survive a read-back. This is the
    // real voice-write surface — `voice` is just one of `merged.update(body)`'s
    // keys, capped at 1000 code points by `PersonaCompiler.normalize` (L455).
    let voiceTarget = "Dry, sharp, fast. Lead with the read, then the next move."
    let profile = try await engine.savePersonality(body: [
        "voice": .string(voiceTarget),
    ])
    #expect(profile.voice == voiceTarget, "savePersonality must persist the body voice field")
    #expect(!profile.updatedAt.isEmpty, "updatedAt stamped")

    // It is on disk and re-reads identically (proves the write, not just the
    // in-memory return value).
    let profileURL = dataRoot.appendingPathComponent("memory").appendingPathComponent("profile.json")
    #expect(FileManager.default.fileExists(atPath: profileURL.path))
    let reloaded = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    #expect(reloaded.voice == voiceTarget, "voice must survive a profile.json read-back")

    // A subsequent merge that does NOT touch voice must preserve it (merged.update
    // parity — voice is not clobbered by an unrelated field write).
    let after = try await engine.savePersonality(body: ["essence": .string("Sharp.")])
    #expect(after.voice == voiceTarget, "voice must survive an unrelated-field save (merge preserves it)")
    #expect(after.essence == "Sharp.")

    // The voice cap is enforced exactly like the daemon (1000 code points).
    let over = String(repeating: "v", count: 1200)
    let capped = try await engine.savePersonality(body: ["voice": .string(over)])
    #expect(capped.voice.count == 1000, "voice must cap at 1000 code points (normalize parity)")
}

@Test("savePersonality voice writes serialize under the cross-process flock (no lost update)")
func savePersonality_voiceFlockContention() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    // Seed profile.json so both contenders read a real existing profile.
    let memoryDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    let profileURL = memoryDir.appendingPathComponent("profile.json")
    try Data(#"{"name":"Claude","voice":"seed voice"}"#.utf8).write(to: profileURL)

    // Contender A: a native voice write through savePersonality (takes
    // `withFileLock(profile.json)` internally — PersonaEngine+Writes.swift L167).
    // Contender B: a raw "daemon-style" writer that mutates a DIFFERENT key
    // (`name`) under the SAME `<path>.lock` flock convention
    //. With the lock,
    // BOTH effects survive — the read-modify-write blocks serialize. Without it,
    // one read-modify-write would clobber the other and a field would be lost.
    let core = SwiftNativePersistenceCore()
    let voiceTarget = "native-written voice"
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try? await engine.savePersonality(body: ["voice": .string(voiceTarget)])
        }
        group.addTask {
            try? await core.withFileLock(profileURL) {
                let bytes = (try? Data(contentsOf: profileURL)) ?? Data()
                var obj = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]) ?? [:]
                // Widen the race window so a missing flock would manifest as a
                // lost update rather than passing by luck.
                try? await Task.sleep(nanoseconds: 40_000_000)
                obj["name"] = "DaemonName"
                let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                try out.write(to: profileURL, options: .atomic)
            }
        }
    }

    // Final on-disk state must reflect BOTH writers — neither read-modify-write
    // trash-canned the other. (Last-writer-wins on the SAME key is fine; the
    // invariant is that DISTINCT-key effects from serialized R-M-W both persist.)
    let reloaded = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    #expect(reloaded.voice == voiceTarget, "native voice write lost — flock did not serialize the R-M-W")
    #expect(reloaded.name == "DaemonName", "daemon-style name write lost — flock did not serialize the R-M-W")
}

// MARK: - WRITE protocol + factory wiring (wave 33 W06)
//
// These pin the app write seam: the write methods are reachable through the
// `PersonaEngineWriting` protocol and the `makePersonaEngineWriter` factory.

@Test("PersonaEngineWriting protocol dispatch reaches the native doc write")
func writeProtocol_dispatch_savesDoc() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    // Erase to the write protocol — proves the methods satisfy the contract the
    // NativeClient write gate calls through (`any PersonaEngineWriting`).
    let writer: any PersonaEngineWriting = engine
    let saved = try await writer.savePersonalityDoc(id: "GROWTH", content: "# Growth\nfacts")
    #expect(saved.id == "GROWTH")
    #expect(saved.content == "# Growth\nfacts")
    let onDisk = try String(contentsOf: personaRoot.appendingPathComponent("GROWTH.md"), encoding: .utf8)
    #expect(onDisk == "# Growth\nfacts")
}

@Test("SwiftNativePersonaEngine writes docs when rooted at the persona directory")
func swiftNative_directRootSavesDoc() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: root.appendingPathComponent("SOUL.md"))

    let writer: any PersonaEngineWriting = hermeticPersona(root: root)
    let saved = try await writer.savePersonalityDoc(id: "voice", content: "# V")
    #expect(saved.id == "VOICE")
    #expect(saved.content == "# V")
    let onDisk = try String(contentsOf: root.appendingPathComponent("VOICE.md"), encoding: .utf8)
    #expect(onDisk == "# V")
}

@Test("SwiftNativePersonaEngine enforces the onboarding gate (no SOUL.md -> deny)")
func swiftNative_onboardingGate() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // No SOUL.md -> not initialized.
    let writer: any PersonaEngineWriting = hermeticPersona(root: root)
    await #expect(throws: PersonaWriteError.self) {
        _ = try await writer.savePersonalityDoc(id: "USER", content: "x")
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("USER.md").path))
}

@Test("makePersonaEngineWriter vends the SwiftNative writer")
func factory_writerReturnsSwiftNative() async throws {
    #expect(makePersonaEngineWriter() is SwiftNativePersonaEngine,
            "factory must vend the native SwiftNativePersonaEngine")
}

// MARK: - WAVE 34 W05 — lossless extras preservation ({**raw} semantics)
//
// Python `normalize_personality` preserves any profile.json key OUTSIDE the
// fixed set via `{**default, **{k:v for k,v in raw.items() if k not in
// {"traits","gender"}}, ...}`. The Swift
// `CompiledPersonalityProfile` was a fixed struct that DROPPED them — a flipped
// write would PERSIST that loss (the §6.76 W19 item-B.2 gap). These pin that
// extras survive normalize, a save round-trip, a merge, the on-disk byte shape,
// and the compiled-packet fingerprint.

@Test("normalize preserves unknown profile keys as extras (Python {**raw} semantics)")
func extras_preservedThroughNormalize() async throws {
    let raw: [String: Any] = [
        "name": "Claude",
        "personaKind": "female",
        // unknown keys — must be carried verbatim:
        "customFieldX": "keepme",
        "experimentalNumber": 42,
        "nested": ["a": 1, "b": [true, "x"]],
        // these two are consumed/rebuilt and must NOT appear in extras:
        "gender": "female",
        "traits": ["warmth": 0.9],
    ]
    let profile = PersonaCompiler.normalize(raw: raw, defaults: .defaults)
    #expect(profile.extras["customFieldX"] == .string("keepme"))
    #expect(profile.extras["experimentalNumber"] == .int(42))
    #expect(profile.extras["nested"] == .object(["a": .int(1), "b": .array([.bool(true), .string("x")])]))
    // gender + traits are consumed, never carried as extras.
    #expect(profile.extras["gender"] == nil)
    #expect(profile.extras["traits"] == nil)
    // Known keys are NOT duplicated into extras.
    #expect(profile.extras["name"] == nil)
    #expect(profile.extras["personaKind"] == nil)
}

@Test("savePersonality persists extras and they survive a read-back")
func extras_persistAndReadBack() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    // Seed profile.json directly with an unknown key, simulating a daemon write
    // (or a future schema rev / hand edit) the Swift struct doesn't model.
    let memoryDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    let seeded = #"{"name":"Claude","futureKey":"survive","futureCount":7}"#
    try Data(seeded.utf8).write(to: memoryDir.appendingPathComponent("profile.json"))

    // A normal save that touches only a known field.
    let saved = try await engine.savePersonality(body: ["essence": .string("new essence")])
    #expect(saved.essence == "new essence")
    // The unknown keys survived the merge+normalize+write.
    #expect(saved.extras["futureKey"] == .string("survive"))
    #expect(saved.extras["futureCount"] == .int(7))

    // And they are present in the on-disk file (read back through loadProfile).
    let reloaded = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    #expect(reloaded.extras["futureKey"] == .string("survive"))
    #expect(reloaded.extras["futureCount"] == .int(7))
    #expect(reloaded.name == "Claude")  // known field also preserved.
}

@Test("savePersonality on-disk extras match canonical JSON byte shape")
func extras_byteShapeMatchesCanonicalJSON() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    let memoryDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    // Unknown keys deliberately chosen to sort INTERLEAVED with known keys
    // ("aaaExtra" sorts before "boundaries"; "zzzExtra" sorts last) so the
    // test proves they land in the correct sort_keys position, not appended.
    let seeded = #"{"name":"Claude","aaaExtra":"first","zzzExtra":{"k":1}}"#
    try Data(seeded.utf8).write(to: memoryDir.appendingPathComponent("profile.json"))

    _ = try await engine.savePersonality(body: ["personaKind": .string("AI")])
    let profileURL = memoryDir.appendingPathComponent("profile.json")
    let swiftText = try String(contentsOf: profileURL, encoding: .utf8)

    let parsed = try JSONValue.parse(Data(swiftText.utf8))
    guard case .object(let obj) = parsed else {
        Issue.record("profile.json did not parse as object")
        return
    }
    #expect(obj["aaaExtra"] == .string("first"))
    #expect(obj["zzzExtra"] == .object(["k": .int(1)]))
    let expected = String(data: try parsed.serializedData(pretty: true), encoding: .utf8) ?? ""
    #expect(swiftText == expected, "Swift profile.json (incl. extras) must be canonical pretty JSON")
}

@Test("a body key may override an extra; absent body keys preserve extras (merged.update)")
func extras_bodyOverrideAndPreserve() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)

    let memoryDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    let seeded = #"{"name":"Claude","extraA":"old","extraB":"keep"}"#
    try Data(seeded.utf8).write(to: memoryDir.appendingPathComponent("profile.json"))

    // Body overrides extraA, leaves extraB alone — Python `merged.update(body)`.
    let saved = try await engine.savePersonality(body: [
        "extraA": .string("new"),
    ])
    #expect(saved.extras["extraA"] == .string("new"), "body key must override the on-disk extra")
    #expect(saved.extras["extraB"] == .string("keep"), "untouched extra must survive")
}

@Test("compiled-packet fingerprint folds in profile extras (daemon parity)")
func extras_inFingerprint() async throws {
    // The daemon's compiled packet hashes `{profile, docs}` where profile carries
    // extras. Two profiles identical except for an extra key MUST fingerprint
    // differently (the extra is part of the hashed profile object).
    let base = CompiledPersonalityProfile.defaults
    let withExtra = CompiledPersonalityProfile(
        schemaVersion: base.schemaVersion,
        personaEngineVersion: base.personaEngineVersion,
        name: base.name, personaKind: base.personaKind,
        essence: base.essence, voice: base.voice, customDirective: base.customDirective,
        traits: base.traits, examples: base.examples, forbiddenPatterns: base.forbiddenPatterns,
        instincts: base.instincts, boundaries: base.boundaries,
        surfaceOverrides: base.surfaceOverrides, updatedAt: base.updatedAt,
        extras: ["futureKey": .string("v")]
    )
    let docs = ["SOUL": "# soul", "VOICE": "# voice"]
    let fpBase = PersonaCompiler.personaFingerprint(profile: base, docs: docs)
    let fpExtra = PersonaCompiler.personaFingerprint(profile: withExtra, docs: docs)
    #expect(fpBase != fpExtra, "an extra profile key must change the fingerprint (folded into the hash)")
}

// MARK: - WAVE 34 W05 — missing-doc default-value PERSISTENCE
//
// `scaffoldMissingDocs` atomically writes the default body for any missing
// mutable fixed doc once SOUL.md exists. USER.md is deliberately skipped because
// MemoryV2 owns that projection. This pins that the scaffold persists mutable
// docs, is a no-op pre-onboarding, and never clobbers an existing doc.

@Test("scaffoldMissingDocs is a NO-OP before onboarding (no SOUL.md)")
func scaffold_preOnboarding_noop() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    // No SOUL.md → not initialized.

    let written = try await engine.scaffoldMissingDocs()
    #expect(written.isEmpty, "pre-onboarding scaffold must write nothing")
    for name in ["VOICE.md", "GROWTH.md", "USER.md", "AGENTS.md"] {
        #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent(name).path),
                "\(name) must not be created before onboarding")
    }
}

@Test("scaffoldMissingDocs persists missing docs once SOUL.md exists")
func scaffold_postOnboarding_writes() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let written = try await engine.scaffoldMissingDocs()
    #expect(Set(written) == ["VOICE", "GROWTH", "AGENTS"],
            "only mutable non-SOUL docs must be scaffolded; got \(written)")
    // Each mutable doc is now on disk with its default body.
    for spec in [("VOICE", "VOICE.md"), ("GROWTH", "GROWTH.md"), ("AGENTS", "AGENTS.md")] {
        let url = personaRoot.appendingPathComponent(spec.1)
        #expect(FileManager.default.fileExists(atPath: url.path), "\(spec.1) must be persisted")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let expected = SwiftNativePersonaEngine.defaultPersonalityDocContent(
            id: spec.0,
            profile: PersonaCompiler.loadProfile(dataRoot: root.appendingPathComponent("data"))
        )
        // GROWTH carries a now_iso() stamp; compare a stable prefix for it.
        if spec.0 == "GROWTH" {
            #expect(onDisk.hasPrefix("# NativeAgent Growth"), "GROWTH default body")
        } else {
            #expect(onDisk == expected, "\(spec.1) body must equal the daemon default content")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("USER.md").path),
            "USER.md must be regenerated by MemoryV2, not persona scaffolding")
    // SOUL is never auto-scaffolded; the seed content is untouched.
    let soul = try String(contentsOf: personaRoot.appendingPathComponent("SOUL.md"), encoding: .utf8)
    #expect(soul == "# soul", "SOUL.md must never be overwritten by scaffold")
}

@Test("scaffoldMissingDocs never clobbers an existing doc")
func scaffold_doesNotClobberExisting() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
    // VOICE already exists with real content — must be left alone.
    try Data("# my real voice".utf8).write(to: personaRoot.appendingPathComponent("VOICE.md"))

    let written = try await engine.scaffoldMissingDocs()
    #expect(!written.contains("VOICE"), "existing VOICE must not be rewritten")
    let voice = try String(contentsOf: personaRoot.appendingPathComponent("VOICE.md"), encoding: .utf8)
    #expect(voice == "# my real voice", "existing VOICE content must be preserved")
    // A second scaffold is fully idempotent — nothing left to write.
    let again = try await engine.scaffoldMissingDocs()
    #expect(again.isEmpty, "second scaffold must be a no-op (all docs now exist)")
}

@Test("scaffoldMissingDocs is reachable through the PersonaEngineWriting protocol")
func scaffold_reachableThroughProtocol() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, _) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let writer: any PersonaEngineWriting = engine
    let written = try await writer.scaffoldMissingDocs()
    #expect(!written.isEmpty, "protocol dispatch must reach the native scaffold")

    let again = try await writer.scaffoldMissingDocs()
    #expect(again.isEmpty, "all docs now exist -> native scaffold is a no-op")
}

// MARK: - record_activity parity (wave 36 W06 — closes §6.76 item B.1 / §6.138)
//
// The daemon's `save_personality_doc` emits, inside its `with file_lock(path)`
// block, `record_activity("memory", "{doc_id}.md updated", "Personality
// document saved", "ok")` — a durable append to
// `<root>/activity/events.jsonl`. The native `savePersonalityDoc` previously
// dropped this row, silently losing a feed entry under `.personaEngineWrites`.
// These pin that the native write now emits the byte-identical row, ONLY on the
// success path, with the canonicalized doc id.

/// Read every JSONL row from `<dataRoot>/activity/events.jsonl` (empty if the
/// file does not exist yet).
private func readActivityRows(dataRoot: URL) throws -> [[String: Any]] {
    let path = dataRoot
        .appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    let text = try String(contentsOf: path, encoding: .utf8)
    var rows: [[String: Any]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        rows.append(obj)
    }
    return rows
}

@Test("savePersonalityDoc emits exactly one activity row with the daemon shape")
func saveDoc_emitsActivityRow() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    _ = try await engine.savePersonalityDoc(id: "VOICE", content: "# voice")

    let rows = try readActivityRows(dataRoot: dataRoot)
    #expect(rows.count == 1, "exactly one activity row per successful save")
    let row = try #require(rows.first)
    #expect(row["kind"] as? String == "memory")
    #expect(row["title"] as? String == "VOICE.md updated")
    #expect(row["detail"] as? String == "Personality document saved")
    #expect(row["status"] as? String == "ok")
    #expect(row["missionId"] is NSNull)
    #expect((row["payload"] as? [String: Any])?.isEmpty == true)
    #expect((row["id"] as? String)?.isEmpty == false)
    #expect((row["createdAt"] as? String)?.isEmpty == false)
}

@Test("activity row title uses the CANONICALIZED (uppercase) doc id")
func saveDoc_activityRow_canonicalDocId() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    // Lowercase + surrounding whitespace input → uppercased canonical id in title.
    _ = try await engine.savePersonalityDoc(id: "  voice  ", content: "# voice")
    let rows = try readActivityRows(dataRoot: dataRoot)
    #expect(rows.count == 1)
    #expect(rows.first?["title"] as? String == "VOICE.md updated")
}

@Test("a DENIED (pre-onboarding) save emits NO activity row")
func saveDoc_denied_noActivityRow() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, dataRoot) = makeEngine(root)
    // No SOUL.md → not initialized → write is refused before any I/O.

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.savePersonalityDoc(id: "VOICE", content: "x")
    }
    let rows = try readActivityRows(dataRoot: dataRoot)
    #expect(rows.isEmpty, "a refused save must not leave an activity row")
}

@Test("an UNKNOWN doc id emits NO activity row (throws before the write)")
func saveDoc_unknownId_noActivityRow() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    await #expect(throws: PersonaWriteError.self) {
        _ = try await engine.savePersonalityDoc(id: "NOTES", content: "x")
    }
    #expect(try readActivityRows(dataRoot: dataRoot).isEmpty)
}

@Test("two saves append two rows (append-only, no clobber)")
func saveDoc_twoSaves_twoRows() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    _ = try await engine.savePersonalityDoc(id: "VOICE", content: "# v1")
    _ = try await engine.savePersonalityDoc(id: "GROWTH", content: "# g1")
    let rows = try readActivityRows(dataRoot: dataRoot)
    #expect(rows.count == 2)
    #expect(rows.map { $0["title"] as? String } == ["VOICE.md updated", "GROWTH.md updated"])
}

@Test("emitted activity JSONL line is canonical compact JSON")
func saveDoc_activityRow_byteShapeMatchesCanonicalJSON() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    _ = try await engine.savePersonalityDoc(id: "GROWTH", content: "# g")
    let eventsPath = dataRoot
        .appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let line = try String(contentsOf: eventsPath, encoding: .utf8)
        .trimmingCharacters(in: .newlines)

    let parsed = try JSONValue.parse(Data(line.utf8))
    guard case .object(let obj) = parsed else {
        Issue.record("activity row did not parse as object")
        return
    }
    #expect(obj["kind"] == .string("memory"))
    #expect(obj["title"] == .string("GROWTH.md updated"))
    #expect(obj["detail"] == .string("Personality document saved"))
    #expect(obj["status"] == .string("ok"))
    #expect(obj["missionId"] == .null)
    #expect(obj["payload"] == .object([:]))
    if case .string(let id)? = obj["id"] {
        #expect(!id.isEmpty)
    } else {
        Issue.record("id missing or not a string")
    }
    guard case .string(let createdAt)? = obj["createdAt"] else {
        Issue.record("createdAt missing")
        return
    }
    #expect(createdAt.hasSuffix("+00:00"))
    let re = try NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?\+00:00$"#
    )
    #expect(re.firstMatch(in: createdAt, range: NSRange(createdAt.startIndex..., in: createdAt)) != nil)
    let expected = try parsed.serialize(pretty: false)
    #expect(line == expected, "Swift activity JSONL line must be canonical compact JSON")
}

@Test("activity row is reachable through the PersonaEngineWriting protocol")
func saveDoc_activityRow_reachableThroughProtocol() async throws {
    let root = try makeWriteTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, personaRoot, dataRoot) = makeEngine(root)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

    let writer: any PersonaEngineWriting = engine
    _ = try await writer.savePersonalityDoc(id: "AGENTS", content: "# a")
    let rows = try readActivityRows(dataRoot: dataRoot)
    #expect(rows.count == 1)
    #expect(rows.first?["title"] as? String == "AGENTS.md updated")
}

// MARK: - small helpers
