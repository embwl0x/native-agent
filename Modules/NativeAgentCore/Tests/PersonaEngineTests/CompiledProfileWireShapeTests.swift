import Foundation
import Testing
import PersistenceCore
@testable import PersonaEngine

// Ledger row: persona.profile.customEncoder
//
// Silent-failure class: WRONG VALUE on a persisted wire. `CompiledPersonalityProfile`
// hand-writes `CodingKeys` / `init(from:)` / `encode(to:)` specifically to OMIT
// the `extras` carry-over dictionary, so the Codable wire shape stays
// byte-identical to the pre-extras layout. The lossless extras carry-over is
// done EXPLICITLY at the two write boundaries instead.
//
// Two silent regressions this pins:
//   * `extras` leaking into the synthesized wire — an unsorted, unbounded blob
//     appears inside profile.json / the compiled packet and every consumer that
//     diffs the profile sees phantom churn every write;
//   * a field quietly dropped from the hand-written `encode(to:)` — e.g.
//     `customDirective` or `forbiddenPatterns` — which erases part of Agent's
//     persona on the next round-trip with no error at all.

private let expectedWireKeys: Set<String> = [
    "schemaVersion", "personaEngineVersion", "name", "personaKind", "essence",
    "voice", "customDirective", "traits", "examples", "forbiddenPatterns",
    "instincts", "boundaries", "surfaceOverrides", "updatedAt",
]

private func profile(extras: [String: JSONValue] = [:]) -> CompiledPersonalityProfile {
    CompiledPersonalityProfile(
        schemaVersion: 2,
        personaEngineVersion: "2.0",
        name: "Test Persona",
        personaKind: "AI",
        essence: "An essence line.",
        voice: "Dry, sharp, fast.",
        customDirective: "Never hedge; lead with the claim.",
        traits: CompiledPersonalityTraits(
            warmth: 0.45, directness: 0.82, humor: 0.12, proactivity: 0.78,
            rigor: 0.86, autonomy: 0.82, creativity: 0.58, brevity: 0.74
        ),
        examples: ["Lead with the useful answer."],
        forbiddenPatterns: ["Corporate filler.", "Claiming actions that did not happen."],
        instincts: ["Prefer action over discussion."],
        boundaries: ["Never modify security settings."],
        surfaceOverrides: ["telegram": "Be terser.", "chat": "Full register."],
        updatedAt: "2026-08-23T10:00:00Z",
        extras: extras
    )
}

private func wireObject(_ value: CompiledPersonalityProfile) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let object = try JSONSerialization.jsonObject(with: try encoder.encode(value))
    guard let dictionary = object as? [String: Any] else {
        throw NSError(domain: "CompiledProfileWireShapeTests", code: 1)
    }
    return dictionary
}

@Test("the encoder emits exactly the fourteen pre-extras keys")
func compiledProfileEmitsPreExtrasKeys() throws {
    #expect(Set(try wireObject(profile()).keys) == expectedWireKeys)
}

@Test("extras never leak onto the Codable wire, no matter what is in them")
func compiledProfileExtrasNeverLeak() throws {
    let noisyExtras: [String: JSONValue] = [
        "gender": .string("she"),
        "legacyField": .array([.string("a"), .int(1)]),
        "futureSchemaRev": .object(["depth": .int(3)]),
        // A key that COLLIDES with a known field name is the worst case: a
        // leaking extras dict could shadow the real value.
        "name": .string("SHOULD NOT APPEAR"),
    ]
    let withExtras = try wireObject(profile(extras: noisyExtras))
    let without = try wireObject(profile())

    #expect(Set(withExtras.keys) == expectedWireKeys)
    #expect(withExtras["extras"] == nil)
    #expect(withExtras["name"] as? String == "Test Persona")

    // Byte-for-byte: an extras-carrying profile serializes identically to one
    // without, which is the whole contract.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(profile(extras: noisyExtras)) == encoder.encode(profile()))
    #expect(Set(without.keys) == Set(withExtras.keys))
}

@Test("every persona field survives an encode → decode round-trip")
func compiledProfileRoundTripsEveryField() throws {
    let original = profile(extras: ["gender": .string("she")])
    let decoded = try JSONDecoder().decode(
        CompiledPersonalityProfile.self, from: try JSONEncoder().encode(original)
    )

    #expect(decoded.schemaVersion == original.schemaVersion)
    #expect(decoded.personaEngineVersion == original.personaEngineVersion)
    #expect(decoded.name == original.name)
    #expect(decoded.personaKind == original.personaKind)
    #expect(decoded.essence == original.essence)
    #expect(decoded.voice == original.voice)
    #expect(decoded.customDirective == original.customDirective)
    #expect(decoded.traits == original.traits)
    #expect(decoded.examples == original.examples)
    #expect(decoded.forbiddenPatterns == original.forbiddenPatterns)
    #expect(decoded.instincts == original.instincts)
    #expect(decoded.boundaries == original.boundaries)
    #expect(decoded.surfaceOverrides == original.surfaceOverrides)
    #expect(decoded.updatedAt == original.updatedAt)
    // The decoder deliberately resets extras — this Codable is NOT the lossless
    // path, and pretending otherwise would hide the explicit carry-over.
    #expect(decoded.extras.isEmpty)
    // Re-encoding is a fixpoint, so a decode/encode cycle never churns the file.
    let stable = JSONEncoder()
    stable.outputFormatting = [.sortedKeys]
    #expect(try stable.encode(decoded) == stable.encode(profile()))
}

@Test("a decode missing any required key fails loudly instead of seeding a blank persona")
func compiledProfileDecodeFailsClosedOnMissingKeys() throws {
    let encoder = JSONEncoder()
    let complete = try JSONSerialization.jsonObject(
        with: try encoder.encode(profile())
    ) as? [String: Any] ?? [:]

    for key in expectedWireKeys {
        var broken = complete
        broken.removeValue(forKey: key)
        let bytes = try JSONSerialization.data(withJSONObject: broken)
        #expect(throws: (any Error).self, "missing '\(key)' decoded to a silent default") {
            _ = try JSONDecoder().decode(CompiledPersonalityProfile.self, from: bytes)
        }
    }
}

@Test("the shipped defaults are a valid wire value and survive the round-trip")
func compiledProfileDefaultsRoundTrip() throws {
    let defaults = CompiledPersonalityProfile.defaults
    #expect(Set(try wireObject(defaults).keys) == expectedWireKeys)
    let decoded = try JSONDecoder().decode(
        CompiledPersonalityProfile.self, from: try JSONEncoder().encode(defaults)
    )
    #expect(decoded == defaults)
    #expect(!decoded.name.isEmpty)
    #expect(!decoded.essence.isEmpty)
    #expect(decoded.schemaVersion == 2)
}
