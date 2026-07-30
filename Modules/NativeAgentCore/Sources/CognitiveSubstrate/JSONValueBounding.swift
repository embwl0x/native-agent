import Foundation
import PersistenceCore

/// Single recursive bounder for persisted `JSONValue` metadata.
///
/// Three copies used to live here — `CognitiveSubstrate.boundMetadataValue`,
/// `ContinuityField.boundedJSONValue`, and `SomaticSignal.boundedValue` — and
/// only the organism copy redacted secrets and depth-capped. That meant the
/// substrate and continuity-field metadata paths persisted UNREDACTED (audit
/// C9). This is the one implementation all three now route through, with
/// redaction ON everywhere (safe direction): a key that looks like a secret
/// marker, or a string value that looks like a credential, becomes
/// `"[redacted]"`; anything past `bounds.maximumDepth` becomes `"[bounded]"`.
///
/// String/array/key caps and depth come from `bounds`; the substrate and
/// continuity-field callers pass a large `maximumDepth` so the cap only guards
/// pathological nesting and never alters realistic metadata output.
enum JSONValueBounding {
    static func bounded(
        _ value: JSONValue,
        bounds: OrganismMetadataBounds,
        redactSecrets: Bool = true,
        keyPath: String = "",
        depth: Int = 0
    ) -> JSONValue {
        guard depth < bounds.maximumDepth else { return .string("[bounded]") }
        if redactSecrets, containsSecretMarker(keyPath) { return .string("[redacted]") }
        switch value {
        case .string(let string):
            if redactSecrets, containsSecretLikeValue(string) { return .string("[redacted]") }
            return .string(String(string.prefix(bounds.maximumStringCharacters)))
        case .array(let values):
            return .array(values.prefix(bounds.maximumArrayItems).map {
                bounded(
                    $0,
                    bounds: bounds,
                    redactSecrets: redactSecrets,
                    keyPath: keyPath,
                    depth: depth + 1
                )
            })
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for key in object.keys.sorted().prefix(bounds.maximumKeys) {
                let cleanKey = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                guard !cleanKey.isEmpty else { continue }
                out[cleanKey] = bounded(
                    object[key] ?? .null,
                    bounds: bounds,
                    redactSecrets: redactSecrets,
                    keyPath: keyPath.isEmpty ? cleanKey.lowercased() : "\(keyPath).\(cleanKey.lowercased())",
                    depth: depth + 1
                )
            }
            return .object(out)
        default:
            return value
        }
    }

    /// A large depth cap for callers (substrate, continuity field) that never
    /// had one — big enough that realistic metadata never hits it, so the only
    /// behavior change for those paths is redaction.
    static let uncappedDepth = 32

    static func containsSecretMarker(_ key: String) -> Bool {
        ["secret", "token", "password", "apikey", "api_key", "authorization", "credential"].contains {
            key.contains($0)
        }
    }

    static func containsSecretLikeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("bearer ")
            || lower.contains("sk-")
            || lower.contains("xoxb-")
            || lower.contains("xapp-")
    }
}
