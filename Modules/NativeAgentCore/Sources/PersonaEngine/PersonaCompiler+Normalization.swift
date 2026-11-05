import Foundation
import CoreFoundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaCompiler+Normalization.swift` | `PersonaCompiler.decodeProfile`. |

extension PersonaCompiler {
    /// Decode only the saved schema; damaged fields cannot become genesis defaults because onboarding owns creation.
    public static func decodeProfile(raw: [String: Any]) throws -> CompiledPersonalityProfile {
        func invalid(_ path: String, _ expected: String) -> PersonaEngineError {
            .underlying("memory/profile.json.\(path) must be \(expected). Repair that field before continuing.")
        }
        func text(_ key: String, cap: Int? = nil, nonempty: Bool = false) throws -> String {
            guard let value = raw[key] as? String else { throw invalid(key, "text") }
            guard !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid(key, "nonempty text")
            }
            if let cap, value.unicodeScalars.count > cap { throw invalid(key, "at most \(cap) code points") }
            return value
        }
        guard let schema = raw["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 2 else {
            throw invalid("schemaVersion", "2")
        }
        guard try text("personaEngineVersion") == "2.0" else { throw invalid("personaEngineVersion", "2.0") }
        let kind = try text("personaKind")
        guard ["Male", "Female", "AI", "Custom"].contains(kind) else {
            throw invalid("personaKind", "Male, Female, AI or Custom")
        }
        guard let values = raw["traits"] as? [String: Any] else { throw invalid("traits", "an object") }
        func trait(_ key: String) throws -> Double {
            guard let number = values[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                throw invalid("traits.\(key)", "a finite number from 0 to 1")
            }
            return number.doubleValue
        }
        let traits = try CompiledPersonalityTraits(
            warmth: trait("warmth"), directness: trait("directness"), humor: trait("humor"),
            proactivity: trait("proactivity"), rigor: trait("rigor"), autonomy: trait("autonomy"),
            creativity: trait("creativity"), brevity: trait("brevity"))
        let updatedAt = try text("updatedAt", nonempty: true)
        guard NativeTimestampFormat.parseISO8601FractionalFirst(updatedAt) != nil else {
            throw invalid("updatedAt", "an ISO 8601 timestamp")
        }
        var extras: [String: JSONValue] = [:]
        for (key, value) in raw where !normalizedKeys.contains(key) {
            extras[key] = JSONValue(fromFoundation: value)
        }
        return try CompiledPersonalityProfile(
            schemaVersion: 2, personaEngineVersion: "2.0", name: text("name", cap: 80, nonempty: true),
            personaKind: kind, traits: traits, updatedAt: updatedAt, extras: extras)
    }

    static let normalizedKeys: Set<String> = [
        "schemaVersion", "personaEngineVersion", "name", "personaKind", "traits", "updatedAt",
    ]
}
