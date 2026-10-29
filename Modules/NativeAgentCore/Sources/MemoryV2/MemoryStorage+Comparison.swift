import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Comparison.swift` | `MemoryStorage`: comparison-key modes, scope/epoch checks and quantity/polarity matching; callers own candidate execution |

extension MemoryStorage {
    enum ComparisonMode { case recall, canonical, proposal }

    /// Comparison keys never replace stored text or raw integrity fingerprints.
    static func comparisonKey(_ content: String, mode: ComparisonMode) -> String {
        var text = content
        if mode == .proposal {
            text = text.replacingOccurrences(of: #"(?i)\b(?:a|an|the)\s+"#, with: "", options: .regularExpression)
        }
        if mode == .canonical {
            text = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        }
        text = text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mode == .canonical ? text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'` ")) : text
    }

    /// Callers retain candidate order, execution and admission's recency rule.
    static func semanticDuplicate(
        _ left: String, _ right: String, similarity: Double
    ) -> Bool {
        return similarity >= memoryNearVerbatimSimilarity && sameQuantityAndNegation(left, right)
    }

    /// Similar wording cannot reassert a changed quantity or polarity.
    /// This lexical check recognizes ASCII digits and English negation only;
    /// it is not a multilingual proof of equivalent meaning. Semantic memory
    /// interpretation remains responsible for judging changed claims.
    static func sameQuantityAndNegation(_ old: String, _ new: String) -> Bool {
        func matches(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'") }
        }
        let digits = #"[0-9]+"#
        let negations = #"\b(?:no\s+longer|not|never|cannot)\b|n['’]t\b"#
        return matches(digits, in: old) == matches(digits, in: new)
            && matches(negations, in: old).count == matches(negations, in: new).count
    }

    /// Persona and read-surface scope, independent of lifecycle. Undisclosable
    /// rows retain a persona-local bucket.
    static func disclosureScopeKey(personaId: String, metadata: JSONValue?) -> String {
        let persona = personaId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var tags: [String] = []
        if case .object(let object)? = metadata, case .array(let values)? = object["tags"] {
            tags = values.compactMap { if case .string(let tag) = $0 { return tag }; return nil }
        }
        guard let classification = MemoryRecordDisclosurePolicy.classify(
            personaID: personaId, status: "active", lifecycle: nil, tags: tags, metadata: metadata
        ) else { return "\(persona)|undisclosable" }
        return "\(persona)|\(classification.privacy.rawValue)|" + classification.permittedSurfaces.sorted().joined(separator: ",")
    }

    /// Unstamped or different vector spaces cannot be compared semantically.
    static func comparableEpochs(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }
}
