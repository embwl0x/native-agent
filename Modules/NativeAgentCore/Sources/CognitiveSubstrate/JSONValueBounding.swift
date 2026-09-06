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

    /// Short, obvious credential prefixes. Matched only where they START a
    /// token (see `startsAToken`), so an ordinary word that merely ENDS in one
    /// is left alone. Deliberately tail-length-blind: the canonical redactor
    /// below already owns the high-entropy shapes, and this layer is what
    /// catches a truncated or fixture-length credential the regexes miss.
    private static let secretValueMarkers = [
        "bearer ",
        "sk-", "sk_live_", "rk_live_",
        "xoxb-", "xapp-",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "aiza",
        // AWS access-key ids. The canonical redactor carries no AWS pattern, so
        // on the cognitive side this marker is the only thing that catches one.
        "akia",
    ]

    /// THE cognitive-side secret filter. Every organism path that decides
    /// whether a bounded string may be kept routes through this one predicate
    /// (metadata values here, adapter source components in
    /// `CognitiveSomaticSignalAdapter`, evidence lines in
    /// `OrganismDreamRepair`), so the three can never disagree about what a
    /// credential looks like.
    ///
    /// Two layers, cheapest first — it runs per somatic signal:
    ///   1. ANCHORED MARKERS, a handful of substring scans over a bounded
    ///      string.
    ///   2. The CANONICAL redactor, `NativeAgentSecretRedactor` — the project's
    ///      eight durable-receipt patterns (private-key blocks, GitHub tokens,
    ///      OpenAI / Anthropic / Stripe keys, Slack tokens, Google API keys,
    ///      bearer tokens). Deferring to it rather than keeping a private list
    ///      is what stops this filter drifting behind the owner every other
    ///      subsystem redacts against.
    static func containsSecretLikeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if secretValueMarkers.contains(where: { startsAToken($0, in: lower) }) { return true }
        return NativeAgentSecretRedactor.redactText(value) != value
    }

    /// A credential marker only counts when it STARTS a token — at the very
    /// beginning of the value, or immediately after a non-alphanumeric.
    ///
    /// The unanchored `contains("sk-")` this replaces also matched the TAIL of
    /// ordinary words: every `desk-…` label (likewise `task-`, `risk-`,
    /// `disk-`) was rewritten to `[redacted]`, so payload-free metadata such as
    /// a horizon token for a Desk item never reached the organism at all. The
    /// project's other redactors already anchor these same prefixes on a word
    /// boundary (the connector / workflow secret patterns use `\bsk-`); this
    /// makes the shared metadata bounder agree with them.
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
