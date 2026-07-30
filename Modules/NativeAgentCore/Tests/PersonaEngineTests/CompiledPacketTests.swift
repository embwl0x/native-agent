import Testing
import Foundation
@testable import PersonaEngine
import PersistenceCore

// MARK: - Fixtures

private func makeTempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CompiledPacketTests-\(tag)-\(UUID().uuidString)")
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

/// Seed the 5 canonical persona docs at the given root.
private func writeAllDocs(_ root: URL,
                          soul: String = "soul body\n",
                          voice: String = "voice body\n",
                          growth: String = "growth body\n",
                          user: String = "user body\n",
                          agents: String = "agents body\n") throws {
    try write(soul, to: root.appendingPathComponent("SOUL.md"))
    try write(voice, to: root.appendingPathComponent("VOICE.md"))
    try write(growth, to: root.appendingPathComponent("GROWTH.md"))
    try write(user, to: root.appendingPathComponent("USER.md"))
    try write(agents, to: root.appendingPathComponent("AGENTS.md"))
}

/// Seed a deterministic profile.json (all fields explicit, including
/// updatedAt) so the fingerprint over the resulting normalized profile is
/// stable across runs.
private func writeProfile(_ dataRoot: URL, name: String = "Agent") throws {
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let json: [String: Any] = [
        "name": name,
        "personaKind": "custom",
        "essence": "a sharp, grounded operator",
        "voice": "direct, specific, no filler",
        "customDirective": "stay terse",
        "traits": [
            "warmth": 0.45,
            "directness": 0.82,
            "humor": 0.12,
            "proactivity": 0.78,
            "rigor": 0.86,
            "autonomy": 0.82,
            "creativity": 0.58,
            "brevity": 0.74,
        ],
        "examples": ["lead with the answer", "show the work"],
        "forbiddenPatterns": ["corporate filler"],
        "instincts": ["verify before claim"],
        "boundaries": ["no invented tool results"],
        "surfaceOverrides": [
            "chat": "",
            "telegram": "keep it short",
            "dream": "reflect like maintenance pass",
            "autonomy": "stay inside sandbox",
        ],
        "updatedAt": "2026-01-01T00:00:00+00:00",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: memDir.appendingPathComponent("profile.json"))
}

private func makeCompiler(personaRoot: URL, dataRoot: URL) -> PersonaCompiler {
    PersonaCompiler(engine: SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot))
}

// MARK: - Tests

@Test
func compiledPacket_returns_wire_struct() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    #expect(wire.surface == "chat")
    #expect(wire.fingerprint.count == 16)
    #expect(wire.compiled.hasPrefix("{"))
    #expect(wire.compiled.contains("\n  \"schemaVersion\": 2,"))
    #expect(wire.compiled.contains("\"fingerprint\": \"\(wire.fingerprint)\""))
}

@Test
func compiledPacket_fingerprint_equals_handComputed() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)

    // Drive the same load path as the runtime.
    let profile = PersonaCompiler.loadProfile(dataRoot: dataRoot)
    let docs: [String: String] = [
        "SOUL": "soul body\n",
        "VOICE": "voice body\n",
        "GROWTH": "growth body\n",
        "USER": "user body\n",
        "AGENTS": "agents body\n",
    ]
    let expected = PersonaCompiler.personaFingerprint(profile: profile, docs: docs)

    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    #expect(wire.fingerprint == expected)
}

@Test
func compiledPacket_uses_persona_user_doc_and_ignores_split_generated_user_doc() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(
        personaRoot,
        user: "<!-- USER_MD_AUTOGEN_START -->\n- the user values meaningful, intentional notifications from Agent over engagement spam.\n- the user likes Agent's little goofs and quirks.\n<!-- USER_MD_AUTOGEN_END -->\n"
    )
    try writeProfile(dataRoot)
    try write(
        "- \"the user values meaningful, intentional notifications from his AI assistant rather than engagement-focused spam - specifically appreciating personal check-ins that acknowledge continuity, care, and genuine\n- Your name is the user and you have a close relationship with someone named Agent.\n",
        to: dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("USER.md")
    )

    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")

    #expect(wire.compiled.contains("the user likes Agent's little goofs and quirks"))
    #expect(!wire.compiled.contains("Your name is the user"))
    #expect(!wire.compiled.contains("acknowledge continuity, care, and genuine\n"))
}

@Test
func compiledPacket_fingerprint_independent_of_surface() async throws {
    // Daemon's persona_fingerprint hashes profile + FULL UNSLICED docs —
    // surface does NOT participate. Surface-specific cache keys are layered
    // OUTSIDE the fingerprint (compiled_personality_packet L35516).
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let compiler = makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
    let chat = try await compiler.compiledPacket(surface: "chat").fingerprint
    let dream = try await compiler.compiledPacket(surface: "dream").fingerprint
    let doctor = try await compiler.compiledPacket(surface: "doctor").fingerprint
    #expect(chat == dream)
    #expect(chat == doctor)
}

@Test
func compiledPacket_fingerprint_changes_when_SOUL_edited() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let compiler = makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
    let before = try await compiler.compiledPacket(surface: "chat").fingerprint
    try write("EDITED SOUL\n", to: personaRoot.appendingPathComponent("SOUL.md"))
    let after = try await compiler.compiledPacket(surface: "chat").fingerprint
    #expect(before != after)
}

@Test
func compiledPacket_unknown_surface_canonicalizes_to_chat() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let compiler = makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
    let unknown = try await compiler.compiledPacket(surface: "operating")
    let chat = try await compiler.compiledPacket(surface: "chat")
    #expect(unknown.surface == "chat")
    #expect(unknown.compiled == chat.compiled)
}

@Test
func compiledPacket_chat_contains_expected_top_level_keys() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    let keys = [
        "schemaVersion", "personaEngineVersion", "fingerprint", "surface",
        "name", "personaKind", "essence", "voice", "customDirective",
        "surfaceDirective", "personaInstruction", "voiceBrief",
        "soulDocuments", "traitInstructions",
        "examples", "forbiddenPatterns", "instincts", "boundaries",
        "precedence", "adherenceRule",
    ]
    for k in keys {
        #expect(wire.compiled.contains("\"\(k)\":"), "compiled missing key: \(k)")
    }
}

@Test
func compiledPacket_chat_keys_are_in_daemon_insertion_order() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    let order = [
        "\"schemaVersion\"", "\"personaEngineVersion\"", "\"fingerprint\"",
        "\"surface\"", "\"name\"", "\"personaKind\"", "\"essence\"",
        "\"voice\"", "\"customDirective\"", "\"surfaceDirective\"",
        "\"personaInstruction\"", "\"voiceBrief\"", "\"soulDocuments\"",
        "\"traitInstructions\"", "\"examples\"", "\"forbiddenPatterns\"",
        "\"instincts\"", "\"boundaries\"", "\"precedence\"", "\"adherenceRule\"",
    ]
    var cursor = wire.compiled.startIndex
    for key in order {
        guard let r = wire.compiled.range(of: key, range: cursor..<wire.compiled.endIndex) else {
            Issue.record("Key \(key) not found after previous position")
            return
        }
        cursor = r.upperBound
    }
}

@Test
func compiledPacket_doctor_has_no_trait_instructions() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "doctor")
    // Empty arrays render as "[]" (no inner newline) per json.dumps(indent=2).
    #expect(wire.compiled.contains("\"traitInstructions\": []"))
}

@Test
func compiledPacket_chat_has_eight_trait_instructions() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    let expected = ["warmth", "directness", "humor", "proactivity",
                    "rigor", "autonomy", "creativity", "brevity"]
    for name in expected {
        // f"{value:.2f}" -> 2-decimal format, e.g. "warmth: 0.45 (medium)"
        #expect(wire.compiled.contains("\"\(name): "),
                "missing trait line for \(name)")
    }
    // Spot-check format + bucket thresholds.
    #expect(wire.compiled.contains("warmth: 0.45 (medium)"))
    #expect(wire.compiled.contains("directness: 0.82 (high)"))
    #expect(wire.compiled.contains("humor: 0.12 (low)"))
    #expect(wire.compiled.contains("brevity: 0.74 (high)"))
}

@Test
func compiledPacket_surfaceDirective_uses_profile_override() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "telegram")
    #expect(wire.compiled.contains("\"surfaceDirective\": \"keep it short\""))
}

@Test
func compiledPacket_doctor_truncates_SOUL_to_800_codepoints() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    // SOUL body: 1200 chars of 'A' followed by a SENTINEL the test scans for
    // to prove the prefix-not-suffix cut (the SENTINEL would survive a
    // suffix cut, prove its absence after a prefix cut).
    let soul = String(repeating: "A", count: 1200) + "SENTINEL_NOT_IN_FIRST_800\n"
    try writeAllDocs(personaRoot, soul: soul)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "doctor")
    #expect(!wire.compiled.contains("SENTINEL_NOT_IN_FIRST_800"))
    // soulDocuments.SOUL should now be exactly 800 'A's (after strip).
    let needle = "\"SOUL\": \"" + String(repeating: "A", count: 800) + "\""
    #expect(wire.compiled.contains(needle))
}

@Test
func compiledPacket_chat_soulDocuments_omits_AGENTS() async throws {
    // slice_for_surface chat = {SOUL, VOICE, GROWTH, USER} — AGENTS dropped.
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot,
                     soul: "S\n", voice: "V\n", growth: "G\n",
                     user: "U\n", agents: "AGENTS_SENTINEL\n")
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    // The compiled output contains soulDocuments which must NOT have AGENTS.
    // Slice the substring between "soulDocuments" and the next top-level
    // key ("traitInstructions") to scope the search.
    guard let lhs = wire.compiled.range(of: "\"soulDocuments\":") else {
        Issue.record("no soulDocuments block"); return
    }
    guard let rhs = wire.compiled.range(of: "\"traitInstructions\":",
                                        range: lhs.upperBound..<wire.compiled.endIndex) else {
        Issue.record("no traitInstructions terminator"); return
    }
    let slice = wire.compiled[lhs.upperBound..<rhs.lowerBound]
    #expect(!slice.contains("AGENTS"))
    #expect(!slice.contains("AGENTS_SENTINEL"))
    // Sanity: chat-included keys ARE there in slice order.
    let chatKeys = ["\"SOUL\"", "\"VOICE\"", "\"GROWTH\"", "\"USER\""]
    var cursor = slice.startIndex
    for k in chatKeys {
        guard let r = slice.range(of: k, range: cursor..<slice.endIndex) else {
            Issue.record("slice missing \(k)"); return
        }
        cursor = r.upperBound
    }
}

@Test
func compiledPacket_compiled_is_valid_json() async throws {
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    try writeProfile(dataRoot)
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    let data = Data(wire.compiled.utf8)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(parsed != nil)
    #expect(parsed?["schemaVersion"] as? Int == 2)
    #expect(parsed?["surface"] as? String == "chat")
    #expect(parsed?["fingerprint"] as? String == wire.fingerprint)
    let traits = parsed?["traitInstructions"] as? [String]
    #expect(traits?.count == 8)
    #expect(traits?.first?.hasPrefix("warmth: ") == true)
}

@Test
func traitInstruction_thresholds_match_python() async throws {
    // Direct spot-checks on the formatting function via a synthesized profile.
    let personaRoot = try makeTempDir("persona")
    let dataRoot = try makeTempDir("data")
    try writeAllDocs(personaRoot)
    let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
    let traits: [String: Double] = [
        "warmth": 0.0,        // low
        "directness": 0.33,   // low (<0.34)
        "humor": 0.34,        // medium
        "proactivity": 0.66,  // medium (<0.67)
        "rigor": 0.67,        // high
        "autonomy": 1.0,      // high
        "creativity": 0.5,    // medium
        "brevity": 0.05,      // low
    ]
    let json: [String: Any] = [
        "name": "Test",
        "personaKind": "ai",
        "traits": traits,
        "updatedAt": "2026-01-01T00:00:00+00:00",
    ]
    try JSONSerialization.data(withJSONObject: json).write(
        to: memDir.appendingPathComponent("profile.json"))
    let wire = try await makeCompiler(personaRoot: personaRoot, dataRoot: dataRoot)
        .compiledPacket(surface: "chat")
    #expect(wire.compiled.contains("warmth: 0.00 (low)"))
    #expect(wire.compiled.contains("directness: 0.33 (low)"))
    #expect(wire.compiled.contains("humor: 0.34 (medium)"))
    #expect(wire.compiled.contains("proactivity: 0.66 (medium)"))
    #expect(wire.compiled.contains("rigor: 0.67 (high)"))
    #expect(wire.compiled.contains("autonomy: 1.00 (high)"))
    #expect(wire.compiled.contains("creativity: 0.50 (medium)"))
    #expect(wire.compiled.contains("brevity: 0.05 (low)"))
}
