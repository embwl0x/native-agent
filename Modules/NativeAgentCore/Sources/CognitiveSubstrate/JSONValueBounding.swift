import Privacy
import Foundation
import PersistenceCore

// Blueprint: | `JSONValueBounding.swift` | `JSONValueBounding`: shared recursive metadata bounds, depth limits and secret redaction for substrate, continuity and somatic persistence |

/// Recursively bounds persisted metadata using `bounds` for depth, string length, array size and key count.
/// Object keys are trimmed to 80 characters; secret key paths and credential values become `"[redacted]"`.
/// Values at `maximumDepth` become `"[bounded]"`.
enum JSONValueBounding {
    static func bounded(
        _ value: JSONValue,
        bounds: OrganismMetadataBounds,
        keyPath: String = "",
        depth: Int = 0
    ) -> JSONValue {
        guard depth < bounds.maximumDepth else { return .string("[bounded]") }
        if containsSecretMarker(keyPath) { return .string("[redacted]") }
        switch value {
        case .string(let string):
            if containsSecretLikeValue(string) { return .string("[redacted]") }
            return .string(String(string.prefix(bounds.maximumStringCharacters)))
        case .array(let values):
            return .array(values.prefix(bounds.maximumArrayItems).map {
                bounded(
                    $0,
                    bounds: bounds,
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
                    keyPath: keyPath.isEmpty ? cleanKey.lowercased() : "\(keyPath).\(cleanKey.lowercased())",
                    depth: depth + 1
                )
            }
            return .object(out)
        default:
            return value
        }
    }

    /// Depth cap for substrate and continuity metadata, beyond realistic nesting.
    static let uncappedDepth = 32

    static func containsSecretMarker(_ key: String) -> Bool {
        ["secret", "token", "password", "apikey", "api_key", "authorization", "credential"].contains {
            key.contains($0)
        }
    }

    /// Token-start prefixes catch truncated credentials and AWS keys without a minimum tail length.
    private static let secretValueMarkers = [
        "bearer ",
        "sk-", "sk_live_", "rk_live_",
        "xoxb-", "xapp-",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "aiza",
        "akia",
    ]

    /// Shared cognitive credential detection checks short prefixes, then the canonical redactor.
    static func containsSecretLikeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if secretValueMarkers.contains(where: { startsAToken($0, in: lower) }) { return true }
        return NativeAgentSecretRedactor.redactText(value) != value
    }

    /// A marker starts a token at the string's start or after a non-alphanumeric character;
    /// embedded suffixes in ordinary desk/task labels remain ordinary text.
    static func startsAToken(_ marker: String, in lower: String) -> Bool {
        var searchStart = lower.startIndex
        while let range = lower.range(of: marker, range: searchStart..<lower.endIndex) {
            if range.lowerBound == lower.startIndex { return true }
            let previous = lower[lower.index(before: range.lowerBound)]
            if !previous.isLetter, !previous.isNumber { return true }
            searchStart = lower.index(after: range.lowerBound)
        }
        return false
    }
}
