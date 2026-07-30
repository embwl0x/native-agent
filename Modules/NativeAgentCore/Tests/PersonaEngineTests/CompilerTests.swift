import Testing
import Foundation
@testable import PersonaEngine
import PersistenceCore

// MARK: - Fixtures

private func makeTempPersonaRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaCompilerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private func writeCanonical(_ root: URL,
                            soul: String = "soul body\n",
                            voice: String = "voice body\n",
                            user: String = "user body\n",
                            growth: String = "growth body\n",
                            agents: String = "agents body\n") throws {
    try write(soul, to: root.appendingPathComponent("SOUL.md"))
    try write(voice, to: root.appendingPathComponent("VOICE.md"))
    try write(user, to: root.appendingPathComponent("USER.md"))
    try write(growth, to: root.appendingPathComponent("GROWTH.md"))
    try write(agents, to: root.appendingPathComponent("AGENTS.md"))
}

private func makeCompiler(root: URL, dataRoot: URL? = nil) -> PersonaCompiler {
    // Default the engine's dataRoot to a temp dir SIBLING of the persona root
    // so growthSummary's profile.json read (W39 W05 parity fix) stays hermetic
    // and resolves to the daemon default ("AI") instead of leaking the real
    // production <dataRoot>/memory/profile.json into the test.
    let resolvedDataRoot = dataRoot
        ?? root.deletingLastPathComponent()
            .appendingPathComponent("DataRoot-\(UUID().uuidString)", isDirectory: true)
    return PersonaCompiler(engine: SwiftNativePersonaEngine(root: root, dataRoot: resolvedDataRoot))
}

/// Seeds `<dataRoot>/memory/profile.json` with a chosen personaKind so
/// growthSummary's activeKind read can be exercised without the real profile.
private func seedProfileKind(_ dataRoot: URL, personaKind: String) throws {
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    // Build the JSON via JSONSerialization so any quote/backslash/control char
    // in `personaKind` is escaped (a hand-spliced string would emit invalid
    // JSON and the fallback tests could pass for the wrong reason).
    let data = try JSONSerialization.data(withJSONObject: ["personaKind": personaKind])
    try data.write(to: memDir.appendingPathComponent("profile.json"))
}

// Overload that ALSO pins the dataRoot (where `<dataRoot>/memory/profile.json`
// is resolved). The default `SwiftNativePersonaEngine(root:)` init leaves
// `dataRoot` at `PersistenceCore.defaultDataRoot()` — the real machine path —
// which is fine for tests that only exercise the persona-ROOT-only `compile()`
// path, but NOT for `growthSummary`, whose daemon-parity `activeKind` /
// `fingerprint` now read profile.json via `loadProfile(dataRoot:)`. Seeding an
// isolated empty dataRoot makes those reads fall back to `.defaults`
// (personaKind == "AI") deterministically, independent of the host machine.
private func makeCompiler(root: URL, dataRoot: URL) -> PersonaCompiler {
    PersonaCompiler(engine: SwiftNativePersonaEngine(root: root, dataRoot: dataRoot))
}

// An empty temp data root (no memory/profile.json) → loadProfile → .defaults.
private func makeEmptyDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaCompilerTests-data-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Test
func compile_with_default_persona_only() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Default")
    #expect(packet.personaId == "canonical")
    #expect(packet.activeDocs["SOUL"] == "soul body\n")
    #expect(packet.activeDocs["VOICE"] == "voice body\n")
    #expect(packet.compiledSystemPrompt.contains("soul body"))
    #expect(packet.compiledSystemPrompt.contains("voice body"))
}

@Test
func compile_uses_persona_user_doc_and_ignores_split_generated_user_doc() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    try writeCanonical(
        root,
        user: "<!-- USER_MD_AUTOGEN_START -->\n- the user values meaningful, intentional notifications from Agent over engagement spam.\n- the user likes Agent's little goofs and quirks.\n<!-- USER_MD_AUTOGEN_END -->\n"
    )
    try write(
        "- \"the user values meaningful, intentional notifications from his AI assistant rather than engagement-focused spam - specifically appreciating personal check-ins that acknowledge continuity, care, and genuine\n- Your name is the user and you have a close relationship with someone named Agent.\n",
        to: dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("USER.md")
    )

    let packet = try await makeCompiler(root: root, dataRoot: dataRoot).compile(surface: "chat")

    #expect(packet.activeDocs["USER"]?.contains("the user likes Agent's little goofs and quirks") == true)
    #expect(packet.activeDocs["USER"]?.contains("Your name is the user") == false)
    #expect(packet.activeDocs["USER"]?.contains("genuine\n") == false)
}

@Test
func compile_with_custom_persona_overrides_SOUL() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    try write("CUSTOM SOUL\n", to: root
        .appendingPathComponent("Agent")
        .appendingPathComponent("SOUL.md"))
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Custom")
    #expect(packet.personaId == "Agent")
    #expect(packet.activeDocs["SOUL"] == "CUSTOM SOUL\n")
    #expect(packet.activeDocs["VOICE"] == "voice body\n")
}

@Test
func compile_with_partial_custom_persona() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    try write("CUSTOM VOICE\n", to: root
        .appendingPathComponent("Agent")
        .appendingPathComponent("VOICE.md"))
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Custom")
    #expect(packet.activeDocs["VOICE"] == "CUSTOM VOICE\n")
    #expect(packet.activeDocs["SOUL"] == "soul body\n")
    #expect(packet.activeDocs["USER"] == "user body\n")
}

@Test
func compile_with_surface_override_appended_to_system_prompt() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    try write("DREAMS ARE WEIRD\n", to: root
        .appendingPathComponent("surfaces")
        .appendingPathComponent("dream.md"))
    let packet = try await makeCompiler(root: root).compile(surface: "dream")
    #expect(packet.compiledSystemPrompt.contains("Surface guidance for dream:"))
    #expect(packet.compiledSystemPrompt.contains("DREAMS ARE WEIRD"))
    #expect(packet.activeDocs["surface:dream"] == "DREAMS ARE WEIRD\n")
}

@Test
func compile_active_persona_selected_via_active_json() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    // Two candidate dirs — without active.json we'd pick the
    // alphabetically-first ("Alpha"). active.json forces "Zeta".
    try write("A\n", to: root.appendingPathComponent("Alpha").appendingPathComponent("SOUL.md"))
    try write("Z\n", to: root.appendingPathComponent("Zeta").appendingPathComponent("SOUL.md"))
    try write(#"{"persona":"Zeta"}"#, to: root.appendingPathComponent("active.json"))
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaId == "Zeta")
    #expect(packet.activeDocs["SOUL"] == "Z\n")
}

@Test
func compile_default_persona_when_no_active_json() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Default")
    #expect(packet.personaId == "canonical")
}

@Test
func compile_personaKind_is_Custom_when_custom_dir_present() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    try write("hi\n", to: root.appendingPathComponent("Agent").appendingPathComponent("SOUL.md"))
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Custom")
}

@Test
func compile_personaKind_is_Default_when_only_canonical() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    // Add a subdir that is NOT a custom persona (no marker doc).
    try write("[]\n", to: root.appendingPathComponent("Agent").appendingPathComponent("notes.jsonl"))
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.personaKind == "Default")
}

@Test
func compile_fingerprint_stable_across_calls_same_input() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let compiler = makeCompiler(root: root)
    let a = try await compiler.compile(surface: "chat").fingerprint
    let b = try await compiler.compile(surface: "chat").fingerprint
    #expect(a == b)
    #expect(a.count == 16)
}

@Test
func compile_fingerprint_changes_when_SOUL_modified() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let beforeFp = try await makeCompiler(root: root).compile(surface: "chat").fingerprint
    try write("SOUL EDITED\n", to: root.appendingPathComponent("SOUL.md"))
    let afterFp = try await makeCompiler(root: root).compile(surface: "chat").fingerprint
    #expect(beforeFp != afterFp)
}

@Test
func compile_fingerprint_changes_per_surface() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let compiler = makeCompiler(root: root)
    let chat = try await compiler.compile(surface: "chat").fingerprint
    let dream = try await compiler.compile(surface: "dream").fingerprint
    #expect(chat != dream)
}

@Test
func compile_traits_extracted_from_GROWTH_frontmatter() async throws {
    let root = try makeTempPersonaRoot()
    let growth = """
    ---
    traits:
      curiosity: 0.7
      warmth: high
      iterations: 12
    ---

    body text here
    TRAIT: directness = true
    """
    try writeCanonical(root, growth: growth)
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.traits["curiosity"] == .double(0.7))
    #expect(packet.traits["warmth"] == .string("high"))
    #expect(packet.traits["iterations"] == .int(12))
    #expect(packet.traits["directness"] == .bool(true))
}

@Test
func compile_traits_empty_dict_when_no_growth_metadata() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root, growth: "free-form notes, no traits to be found here\n")
    let packet = try await makeCompiler(root: root).compile(surface: "chat")
    #expect(packet.traits.isEmpty)
}

@Test
func fingerprint_method_matches_full_compile_fingerprint() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root)
    let compiler = makeCompiler(root: root)
    let viaCompile = try await compiler.compile(surface: "chat").fingerprint
    let viaShortcut = try await compiler.fingerprint(surface: "chat")
    #expect(viaCompile == viaShortcut)
}

// MARK: - compileProfile (structured personality profile)

private func makeTempDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaProfileTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test
func compileProfile_missing_file_returns_defaults() async throws {
    let dataRoot = try makeTempDataRoot()
    let compiler = PersonaCompiler()
    let profile = await compiler.compileProfile(dataRoot: dataRoot)
    #expect(profile.schemaVersion == 2)
    #expect(profile.personaEngineVersion == "2.0")
    #expect(profile.name == "NativeAgent")
    #expect(profile.personaKind == "AI")
    #expect(profile.essence == CompiledPersonalityProfile.defaults.essence)
    #expect(profile.traits.rigor == 0.86)
    #expect(profile.traits.autonomy == 0.82)
    #expect(profile.traits.creativity == 0.58)
    #expect(profile.traits.brevity == 0.74)
    #expect(profile.forbiddenPatterns.count == 3)
}

@Test
func compileProfile_reads_profile_json_and_normalizes() async throws {
    let dataRoot = try makeTempDataRoot()
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let json: [String: Any] = [
        "name": "Agent",
        "personaKind": "custom",
        "essence": "  custom essence  ",
        "voice": "custom voice",
        "customDirective": "stay terse",
        "traits": [
            "warmth": 0.9,
            "directness": 0.5,
            "humor": 1.5,           // clamped to 1.0
            "proactivity": -0.3,    // clamped to 0.0
            "rigor": 0.7,
            "autonomy": 0.6,
            "creativity": 0.4,
            "brevity": 0.5
        ],
        "examples": ["a", "  ", "b"],
        "forbiddenPatterns": ["no filler"],
        "instincts": ["act"],
        "boundaries": ["no destruction"],
        "surfaceOverrides": ["chat": "be tight", "": "skipped"]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: memDir.appendingPathComponent("profile.json"))

    let compiler = PersonaCompiler()
    let profile = await compiler.compileProfile(dataRoot: dataRoot)
    #expect(profile.name == "Agent")
    #expect(profile.personaKind == "Custom")
    #expect(profile.essence == "custom essence")
    #expect(profile.customDirective == "stay terse")
    #expect(profile.traits.humor == 1.0)
    #expect(profile.traits.proactivity == 0.0)
    #expect(profile.traits.warmth == 0.9)
    #expect(profile.examples == ["a", "b"])
    #expect(profile.surfaceOverrides["chat"] == "be tight")
    #expect(profile.surfaceOverrides[""] == nil)
}

@Test
func compileProfile_invalid_personaKind_falls_back_to_default() async throws {
    let dataRoot = try makeTempDataRoot()
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let json: [String: Any] = ["personaKind": "alien"]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: memDir.appendingPathComponent("profile.json"))

    let profile = await PersonaCompiler().compileProfile(dataRoot: dataRoot)
    #expect(profile.personaKind == "AI")
}

// MARK: - growthSummary (READ enrichment — /v1/personality/growth, wave 38 W14)
//
// Characterization tests for `PersonaCompiler.growthSummary`, the native twin
// of the daemon's `personality_growth_summary()`
// that `NativeClient.swiftPersonalityGrowth()` calls behind the (DEFAULT-OFF)
// `.personaEngine` gate. The read was flag-flipped in a prior wave but had NO
// characterization test pinning its parity surface — these close that gap and
// PIN the one DORMANT divergence vs the daemon (the missing-GROWTH scaffold).
//
// Daemon shape recap:
//   docs    = self.personality_docs()["docs"]
//   content = docs[id==GROWTH].content            # FULL unsliced GROWTH.md
//   lines   = [l for l in content.splitlines() if l.strip()]   # non-empty
//   growthEntries   = len(lines)
//   feedbackMemories = count(memory tagged "persona-feedback")
//   engineVersion = "2.0"; nextActions = the fixed 3-line copy.

@Test("growthSummary counts non-empty GROWTH.md lines (daemon splitlines/strip parity)")
func growthSummary_countsNonEmptyLines() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    // 3 non-empty lines + 2 blank lines (one whitespace-only). The daemon's
    // `if line.strip()` drops both blank forms; so does the Swift reducer.
    try writeCanonical(
        root,
        growth: "- entry one\n\n- entry two\n   \n- entry three\n"
    )
    // Seed profile.json with a FIXED updatedAt so the fingerprint is
    // deterministic. With NO profile.json, `loadProfile` → `normalize` stamps a
    // fresh `now()` into `updatedAt` on every call (the daemon avoids this by
    // PERSISTING the normalized profile on first read — Swift loadProfile is a
    // pure read), which the fingerprint folds in → non-reproducible between two
    // calls. Pinning updatedAt removes that timing variance.
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let profileJSON = #"{"personaKind":"AI","updatedAt":"2026-01-01T00:00:00.000+00:00"}"#
    try Data(profileJSON.utf8).write(to: memDir.appendingPathComponent("profile.json"))

    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { 0 }
    )
    #expect(summary.engineVersion == "2.0")
    #expect(summary.growthEntries == 3)
    #expect(summary.feedbackMemories == 0)
    #expect(summary.nextActions == PersonaCompiler.growthNextActions)
    #expect(summary.nextActions.count == 3)
    // W39 W05 / §6.200 #5 parity: activeKind mirrors the daemon's
    // `personality().get("personaKind")` (profile.json field, default "AI"),
    // NOT the compiled packet's filesystem-derived personaKind ("Default").
    // With no profile.json seeded, the daemon-parity default is "AI".
    #expect(summary.activeKind == "AI")
    // fingerprint is the chat-surface packet fingerprint, non-nil and
    // non-empty for a populated persona root.
    // §6.200 #5 FIX: activeKind mirrors the daemon's
    // `self.personality().get("personaKind")` — the NORMALIZED profile kind
    // (here "AI"). It is NOT the prompt-builder packet's "Default" (a value the
    // daemon never emits here).
    #expect(summary.activeKind == "AI")
    // fingerprint is the SURFACE-INDEPENDENT byte-equivalent daemon packet
    // fingerprint (compiledPacket), non-nil + non-empty, and EQUAL to the
    // compiled-packet fingerprint on the SAME root+dataRoot+profile.
    #expect(summary.fingerprint?.isEmpty == false)
    let packetFp = try await makeCompiler(root: root, dataRoot: dataRoot)
        .compiledPacket(surface: "chat").fingerprint
    #expect(summary.fingerprint == packetFp)
    #expect(!summary.createdAt.isEmpty)
}

@Test("growthSummary activeKind reads profile.json personaKind, not the packet kind (W39 W05 parity)")
func growthSummary_activeKindFromProfileNotPacket() async throws {
    // The persona root has the canonical marker docs but NO custom-persona
    // subdir, so resolveActivePersona returns the packet kind "Default". The
    // daemon's personality_growth_summary instead reads profile.json's
    // personaKind. Seed profile.json = "female" and assert activeKind tracks
    // THAT (canonicalised to "Female"), proving the fix decoupled activeKind
    // from the filesystem packet kind.
    let root = try makeTempPersonaRoot()
    try writeCanonical(root, growth: "- a\n")
    let dataRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaCompilerDataRoot-\(UUID().uuidString)", isDirectory: true)
    try seedProfileKind(dataRoot, personaKind: "female")
    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { 0 }
    )
    // profile.json "female" → daemon canonicalisation "Female"; the packet
    // kind ("Default") must NOT appear.
    #expect(summary.activeKind == "Female")
    #expect(summary.activeKind != "Default")
}

@Test("growthSummary activeKind: an out-of-allowlist profile kind falls back to AI (daemon parity)")
func growthSummary_activeKindOutOfAllowlistFallsBackToAI() async throws {
    let root = try makeTempPersonaRoot()
    try writeCanonical(root, growth: "- a\n")
    let dataRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaCompilerDataRoot-\(UUID().uuidString)", isDirectory: true)
    // "Default" is NOT in the daemon allowlist {male,female,ai,custom}, so the
    // daemon (and now the Swift twin) falls back to "AI". This is the exact
    // pre-fix bug value; pinning it here guards against a regression that
    // re-leaks the packet kind.
    try seedProfileKind(dataRoot, personaKind: "Default")
    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { 0 }
    )
    #expect(summary.activeKind == "AI")
}

// §6.200 #5 REGRESSION — activeKind is sourced from the NORMALIZED profile
// (daemon `self.personality().get("personaKind")`), NOT the prompt-builder's
// `resolveActivePersona` (which returns "Default" for a canonical persona).
//
// Seeds an EXPLICIT profile.json with personaKind="Female" and asserts the
// growth summary reports "Female" — proving the read follows the profile, not
// the "Default" the prompt-builder packet would have emitted (the prompt-builder
// still says "Default" here because there is no custom-persona SUBDIR, so the
// two sources demonstrably differ on the same root).
@Test("growthSummary: activeKind follows the normalized profile, not the prompt-builder Default (§6.200 #5)")
func growthSummary_activeKindFromProfileNotPromptBuilder() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    try writeCanonical(root, growth: "- g\n")
    // Seed profile.json with a non-default personaKind.
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let profileJSON = #"{"personaKind":"Female","name":"Aria"}"#
    try Data(profileJSON.utf8).write(to: memDir.appendingPathComponent("profile.json"))

    let compiler = makeCompiler(root: root, dataRoot: dataRoot)
    let summary = try await compiler.growthSummary(feedbackMemoryProvider: { 0 })
    // Daemon-parity: normalized profile personaKind canonicalizes "Female".
    #expect(summary.activeKind == "Female")
    // The prompt-builder packet on this same (no-custom-subdir) root still
    // returns "Default" — proving growthSummary does NOT use it.
    let promptBuilderKind = try await compiler.compile(surface: "chat").personaKind
    #expect(promptBuilderKind == "Default")
    #expect(summary.activeKind != promptBuilderKind)
}

@Test("growthSummary threads the feedback-memory provider count through verbatim")
func growthSummary_feedbackMemoryCount() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    try writeCanonical(root, growth: "- only line\n")
    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { 7 }
    )
    #expect(summary.growthEntries == 1)
    #expect(summary.feedbackMemories == 7)
}

@Test("growthSummary: a throwing feedback provider degrades to 0 (try? parity)")
func growthSummary_feedbackProviderThrows() async throws {
    struct Boom: Error {}
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    try writeCanonical(root, growth: "- a\n- b\n")
    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { throw Boom() }
    )
    // The compiler swallows a provider error (try? → nil → 0), so a failed
    // memory read never fails the whole growth read.
    #expect(summary.growthEntries == 2)
    #expect(summary.feedbackMemories == 0)
}

@Test("growthSummary: absent feedback provider yields feedbackMemories == 0")
func growthSummary_noFeedbackProvider() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    try writeCanonical(root, growth: "x\n")
    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary()
    #expect(summary.feedbackMemories == 0)
    #expect(summary.growthEntries == 1)
}

// DORMANT DIVERGENCE PIN (wave 38 W14 §6.180 finding).
//
// When GROWTH.md is ABSENT but the persona is otherwise initialized
// (SOUL.md present), the DAEMON's `personality_growth_summary` reads via
// `personality_doc_contents(create_missing=True)`, which SCAFFOLDS a default
// GROWTH.md and then counts the scaffold's non-empty lines (a NON-ZERO count).
// The Swift `growthSummary` reads via `compile(surface:)` → `readDoc`, which
// returns nil for a missing file (NO scaffold-on-read by design — a read path
// must not write), so `growthEntries == 0`.
//
// This divergence is DORMANT today: `.personaEngine` is DEFAULT-OFF and the
// fetched `PersonalityGrowthSummary` has ZERO UI consumers (the Mac/iOS
// "Growth" tiles read `ImprovementSummary.personalityGrowthEntries`, a
// SEPARATE daemon-only route). This test PINS the current Swift behavior so
// the divergence is a VISIBLE flip-prereq, not a silent regression: before
// `.personaEngine` flips with a live growth-summary consumer, EITHER mirror
// the daemon's scaffold-on-read (rejected — write-on-read), OR have the daemon
// growth summary read with create_missing=False so both report 0 for a missing
// GROWTH.md.
@Test("growthSummary: missing GROWTH.md → 0 entries (no scaffold-on-read; daemon-divergence pin)")
func growthSummary_missingGrowthDoc_noScaffold() async throws {
    let root = try makeTempPersonaRoot()
    let dataRoot = try makeEmptyDataRoot()
    // Persona initialized (SOUL present) but GROWTH.md deliberately absent.
    try write("soul body\n", to: root.appendingPathComponent("SOUL.md"))
    try write("voice body\n", to: root.appendingPathComponent("VOICE.md"))
    try write("user body\n", to: root.appendingPathComponent("USER.md"))
    try write("agents body\n", to: root.appendingPathComponent("AGENTS.md"))

    let summary = try await makeCompiler(root: root, dataRoot: dataRoot).growthSummary(
        feedbackMemoryProvider: { 0 }
    )
    // Swift: no scaffold-on-read → empty body → 0 non-empty lines.
    #expect(summary.growthEntries == 0)
    // The read must NOT have created GROWTH.md as a side effect.
    let growthURL = root.appendingPathComponent("GROWTH.md")
    #expect(FileManager.default.fileExists(atPath: growthURL.path) == false)
}
