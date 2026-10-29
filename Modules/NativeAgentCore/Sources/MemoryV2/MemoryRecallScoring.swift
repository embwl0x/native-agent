import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryRecallScoring.swift` | `MemoryRecallScoring`: shared relevance candidate-window bound, timestamp delegation, decay, literal kind extraction and record correction classification; mutation exceptions require explicit correction kind |

// MARK: - Semantics tunables

/// Shared near-verbatim threshold for tombstones and semantic duplicates, which also require matching quantities and negations.
/// Cosine cannot separate all bge paraphrases from contradictions; the memory manager judges claim identity.
public let memoryNearVerbatimSimilarity: Double = 0.96

/// Kind-scoped recency decay: half-life in DAYS per kind.
/// Shapes RANK only — never existence; disuse does not erase the record.
/// Kinds absent from this table — identity/relationship/preference AND
/// nil/legacy — are exempt (factor 1.0): decay only acts on data that carries
/// the volatile-class kind signal.
/// Explicit metadata can supply long-lived kinds outside `MemoryKindStamp.taxonomy`; those decay slowly too.
public let memoryDecayHalfLifeDays: [String: Double] = [
    "volatile": 60, "project": 60, "operational": 60,
    "decision": 180, "note": 180, "incident": 180,
    // Moment age decay reads updatedAt; recall changes only use_count and
    // last_used_at, so access does not refresh this clock.
    "moment": 60,
]

/// Recall relevance and decay mathematics.
public enum MemoryRecallScoring {
    /// One candidate-window rule for judgment and its paging receipt.
    public static func relevanceCandidateLimit(topK: Int, count: Int) -> Int {
        let bounded = min(max(topK, 0), count)
        return bounded > count / 12 ? count : min(count, max(bounded * 12, 60))
    }

    /// BM25 adds at most one standard deviation of query-specific dense scores before kind-recency decay.
    public static func lexicalBoostWeight(denseSimilarities: [Double]) -> Double {
        guard denseSimilarities.count >= 2 else { return 0 }
        let count = Double(denseSimilarities.count)
        let mean = denseSimilarities.reduce(0, +) / count
        let variance = denseSimilarities.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / count
        return variance.squareRoot()
    }

    /// Parse either ISO8601 variant the codebase writes (fractional + plain).
    public static func parseTimestamp(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(s)
    }

    /// Multiplier in (0, 1]: pow(0.5, age/halfLife) for kinds with a configured
    /// half-life; 1.0 (exempt) for everything else or unparseable timestamps.
    public static func decayFactor(kind: String?, updatedAt: String, now: Date = Date()) -> Double {
        guard let kind, let halfLifeDays = memoryDecayHalfLifeDays[kind] else { return 1.0 }
        guard let updated = parseTimestamp(updatedAt) else { return 1.0 }
        let ageDays = max(0, now.timeIntervalSince(updated)) / 86_400
        return pow(0.5, ageDays / halfLifeDays)
    }

    /// Age is a bounded ranking preference, not evidence that an active fact
    /// stopped being true. Keep at least 90% of relevance even after many
    /// half-lives; lifecycle/supersession owns invalidation. Fresh near-ties
    /// still win without burying an old direct answer under newer tangents.
    public static func recallRecencyFactor(kind: String?, updatedAt: String, now: Date = Date()) -> Double {
        0.9 + 0.1 * decayFactor(kind: kind, updatedAt: updatedAt, now: now)
    }

    /// Kind values are literal: only a missing/non-string or empty value is absent.
    public static func kind(of metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata, case .string(let k)? = obj["kind"] else { return nil }
        return k.isEmpty ? nil : k
    }

    /// Mutation exceptions require the explicit kind, not projection-only tags
    /// or historical correction metadata shapes.
    static func isExplicitCorrection(_ metadata: JSONValue?) -> Bool {
        kind(of: metadata) == "correction"
    }

    public static func isCorrection(_ record: MemoryRecord, tags: [String]) -> Bool {
        if record.memoryKind?.lowercased() == "correction" || tags.contains("correction") { return true }
        let metadata: [String: JSONValue]
        if case .object(let object)? = record.extras { metadata = object } else { metadata = [:] }
        guard let correction = record.correction ?? metadata["correction"] else { return false }
        switch correction {
        case .null, .bool(false): return false
        case .object(let object):
            if case .bool(let current)? = object["current"] { return current }
            if case .bool(let active)? = object["active"] { return active }
            return !object.isEmpty
        case .array(let values): return !values.isEmpty
        case .string(let value): return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bool(true), .int, .double: return true
        }
    }

    public static func lexicalTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map { RecallLexicalNormalization.term(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Selection and ranking share unique lexical query terms with question stopwords removed.
    public static func lexicalContentTerms(_ text: String?) -> [String] {
        guard let text else { return [] }
        return Array(
            Set(lexicalTokens(text)).subtracting(RecallLexicalNormalization.stopWords)
        )
    }

    struct LexicalDocument: Sendable {
        let termCounts: [String: Int]
        let length: Int

        init(_ text: String) {
            let tokens = lexicalTokens(text)
            length = tokens.count
            termCounts = tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }

    /// Raw BM25 over prepared terms and the caller's selected document cohort.
    package static func bm25Scores(
        queryTerms: [String],
        documents: [(termCounts: [String: Int], length: Int)],
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [Double] {
        guard !queryTerms.isEmpty, !documents.isEmpty else {
            return Array(repeating: 0, count: documents.count)
        }

        let docLengths = documents.map(\.length)
        let avgLength = Double(max(1, docLengths.reduce(0, +))) / Double(max(1, documents.count))

        var docFreq: [String: Int] = [:]
        for document in documents {
            for term in queryTerms where document.termCounts[term] != nil {
                docFreq[term, default: 0] += 1
            }
        }

        let n = Double(documents.count)
        var rawScores: [Double] = []
        rawScores.reserveCapacity(documents.count)
        for (index, document) in documents.enumerated() {
            guard document.length > 0 else {
                rawScores.append(0)
                continue
            }
            let tf = document.termCounts
            let dl = Double(max(1, docLengths[index]))
            var score = 0.0
            for term in queryTerms {
                guard let fInt = tf[term], fInt > 0 else { continue }
                let df = Double(docFreq[term] ?? 0)
                guard df > 0 else { continue }
                let idf = log(1.0 + ((n - df + 0.5) / (df + 0.5)))
                let f = Double(fInt)
                let denom = f + k1 * (1.0 - b + b * (dl / avgLength))
                if denom > 0 {
                    score += idf * ((f * (k1 + 1.0)) / denom)
                }
            }
            rawScores.append(score)
        }

        return rawScores
    }
}
