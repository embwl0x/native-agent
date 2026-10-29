import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaCompiler+Normalization.swift` | `PersonaCompiler`: `normalize` |

extension PersonaCompiler {
    // MARK: - Profile normalization

    /// Normalize current fields, consume the gender alias and preserve unknown keys.
    public static func normalize(
        raw: [String: Any],
        defaults: CompiledPersonalityProfile
    ) -> CompiledPersonalityProfile {
        var personaKind = stringOr(raw["personaKind"], or: nil)
            ?? stringOr(raw["gender"], or: nil)
            ?? defaults.personaKind
        personaKind = personaKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["male", "female", "ai", "custom"]
        if !allowed.contains(personaKind.lowercased()) {
            personaKind = defaults.personaKind
        }
        let personaCanonical: String =
            (personaKind.lowercased() == "ai") ? "AI" : personaKind.capitalized

        // Trait values are defaulted and clamped; unknown trait names are ignored.
        let rawTraits = raw["traits"] as? [String: Any] ?? [:]
        let traits = CompiledPersonalityTraits(
            warmth: clampFloat(rawTraits["warmth"], fallback: defaults.traits.warmth),
            directness: clampFloat(rawTraits["directness"], fallback: defaults.traits.directness),
            humor: clampFloat(rawTraits["humor"], fallback: defaults.traits.humor),
            proactivity: clampFloat(rawTraits["proactivity"], fallback: defaults.traits.proactivity),
            rigor: clampFloat(rawTraits["rigor"], fallback: defaults.traits.rigor),
            autonomy: clampFloat(rawTraits["autonomy"], fallback: defaults.traits.autonomy),
            creativity: clampFloat(rawTraits["creativity"], fallback: defaults.traits.creativity),
            brevity: clampFloat(rawTraits["brevity"], fallback: defaults.traits.brevity)
        )

        let name = capString(raw["name"], fallback: defaults.name, cap: 80)
        let essence = capString(raw["essence"], fallback: defaults.essence, cap: 1000)
        let voice = capString(raw["voice"], fallback: defaults.voice, cap: 1000)
        let customDirective = capString(raw["customDirective"], fallback: "", cap: 2000)

        let examples = trimList(
            raw["examples"] as? [Any] ?? defaults.examples.map { $0 as Any },
            itemCap: 500, listCap: 12
        )
        let forbiddenPatterns = trimList(
            raw["forbiddenPatterns"] as? [Any] ?? defaults.forbiddenPatterns.map { $0 as Any },
            itemCap: 300, listCap: 16
        )
        let instincts = trimList(
            raw["instincts"] as? [Any] ?? defaults.instincts.map { $0 as Any },
            itemCap: 500, listCap: 16
        )
        let boundaries = trimList(
            raw["boundaries"] as? [Any] ?? defaults.boundaries.map { $0 as Any },
            itemCap: 500, listCap: 16
        )

        let rawOverrides = (raw["surfaceOverrides"] as? [String: Any])
            ?? defaults.surfaceOverrides.mapValues { $0 as Any }
        var surfaceOverrides: [String: String] = [:]
        for (key, value) in rawOverrides {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            let kCapped = String(k.prefix(40))
            let v: String
            if let s = value as? String {
                v = s
            } else if let n = value as? NSNumber {
                v = n.stringValue
            } else if let b = value as? Bool {
                v = b ? "true" : "false"
            } else {
                continue
            }
            let vTrim = v.trimmingCharacters(in: .whitespacesAndNewlines)
            surfaceOverrides[kCapped] = String(vTrim.prefix(1000))
        }

        // updatedAt: raw value if present, else now ISO8601.
        let updatedAt = stringOr(raw["updatedAt"], or: nil) ?? NativeTimestampFormat.fractionalZulu(Date())

        // Carry unknown keys verbatim; traits are rebuilt and gender is consumed.
        var extras: [String: JSONValue] = [:]
        for (key, value) in raw {
            if Self.normalizedKeys.contains(key) { continue }
            if key == "traits" || key == "gender" { continue }
            extras[key] = JSONValue(fromFoundation: value)
        }

        return CompiledPersonalityProfile(
            schemaVersion: 2,
            personaEngineVersion: "2.0",
            name: name,
            personaKind: personaCanonical,
            essence: essence,
            voice: voice,
            customDirective: customDirective,
            traits: traits,
            examples: examples,
            forbiddenPatterns: forbiddenPatterns,
            instincts: instincts,
            boundaries: boundaries,
            surfaceOverrides: surfaceOverrides,
            updatedAt: updatedAt,
            extras: extras
        )
    }

    /// Keep this set aligned with explicit profile fields so only unknown keys become extras.
    static let normalizedKeys: Set<String> = [
        "schemaVersion", "personaEngineVersion", "name", "personaKind",
        "essence", "voice", "customDirective", "traits", "examples",
        "forbiddenPatterns", "instincts", "boundaries", "surfaceOverrides",
        "updatedAt",
    ]

    private static func stringOr(_ value: Any?, or fallback: String?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        return fallback
    }

    private static func capString(_ value: Any?, fallback: String, cap: Int) -> String {
        let s = (value as? String) ?? fallback
        let trimmed = (s.isEmpty ? fallback : s).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(cap))
    }

    /// Accept numeric values and strings, clamp to [0, 1], otherwise use the supplied default.
    private static func clampFloat(_ value: Any?, fallback: Double) -> Double {
        let candidate: Double?
        if let d = value as? Double { candidate = d }
        else if let i = value as? Int { candidate = Double(i) }
        else if let n = value as? NSNumber { candidate = n.doubleValue }
        else if let s = value as? String, let d = Double(s) { candidate = d }
        else { candidate = nil }
        guard let v = candidate, v.isFinite else { return fallback }
        return min(1.0, max(0.0, v))
    }

    private static func trimList(_ raw: [Any], itemCap: Int, listCap: Int) -> [String] {
        var out: [String] = []
        for item in raw {
            let s: String
            if let str = item as? String { s = str } else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(String(trimmed.prefix(itemCap)))
            if out.count >= listCap { break }
        }
        return out
    }



}
