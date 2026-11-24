import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryRecallScoring.swift` | `MemoryRecallScoring`: candidate bounds, decay and explicit kinds |

// MARK: - Semantics tunables

/// Shared near-verbatim threshold for tombstones and semantic duplicates, which also require matching quantities and negations. Cosine cannot separate all bge
/// paraphrases from contradictions; the memory manager judges claim identity.
public let memoryNearVerbatimSimilarity: Double = 0.96

/// Kind-specific half-lives affect rank, never existence. Kinds without a configured half-life retain factor 1.0; explicit long-lived kinds outside the
/// taxonomy may decay slowly.
public let memoryDecayHalfLifeDays: [String: Double] = [
    "volatile": 60, "project": 60, "operational": 60,
    "decision": 180, "note": 180, "incident": 180,
    // Moment age decay reads updatedAt; recall changes only use_count and last_used_at, so access does not refresh this clock.
    "moment": 60,
]

public enum MemoryRecallScoring {
    /// Share candidate-window limits between judgment and paging receipts.
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

    /// Accept both fractional and plain ISO8601 forms written by the owners.
    public static func parseTimestamp(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(s)
    }

    /// Only configured kinds with readable timestamps decay; all others retain full relevance.
    public static func decayFactor(kind: String?, updatedAt: String, now: Date = Date()) -> Double {
        guard let kind, let halfLifeDays = memoryDecayHalfLifeDays[kind] else { return 1.0 }
        guard let updated = parseTimestamp(updatedAt) else { return 1.0 }
        let ageDays = max(0, now.timeIntervalSince(updated)) / 86_400
        return pow(0.5, ageDays / halfLifeDays)
    }

    /// Retain at least 90% relevance: age breaks near-ties but lifecycle and supersession alone invalidate facts.
    public static func recallRecencyFactor(kind: String?, updatedAt: String, now: Date = Date()) -> Double {
        0.9 + 0.1 * decayFactor(kind: kind, updatedAt: updatedAt, now: now)
    }

    /// Kind values are literal: only a missing/non-string or empty value is absent.
    public static func kind(of metadata: JSONValue?) -> String? {
        metadata?.objectValue?["kind"]?.nonemptyString
    }

    /// Mutation exceptions require explicit kind, never derived tags or correction metadata.
    static func isExplicitCorrection(_ metadata: JSONValue?) -> Bool {
        kind(of: metadata) == "correction"
    }

    public static func isCorrection(_ record: MemoryRecord, tags: [String]) -> Bool {
        if record.memoryKind?.lowercased() == "correction" || tags.contains("correction") { return true }
        let metadata: [String: JSONValue]
        if case .object(let object)? = record.extras { metadata = object } else { metadata = [:] }
        return metadata["correction"] == .bool(true)
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

    package static func bm25Scores(
        queryTerms: [String],
        documents: [(termCounts: [String: Int], length: Int)],
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [Double] {
        LexicalIndex(documents).scores(queryTerms: queryTerms, k1: k1, b: b)
    }

    struct LexicalIndex: Sendable {
        private let lengths: [Int]
        private let totalLength: Int
        private let postings: [String: [(row: Int, frequency: Int)]]

        init(_ documents: [(termCounts: [String: Int], length: Int)]) {
            lengths = documents.map(\.length)
            totalLength = lengths.reduce(0, +)
            var postings: [String: [(row: Int, frequency: Int)]] = [:]
            for (row, document) in documents.enumerated() {
                for (term, frequency) in document.termCounts {
                    postings[term, default: []].append((row, frequency))
                }
            }
            self.postings = postings
        }

        func scores(queryTerms: [String], rows: Set<Int>? = nil, k1: Double = 1.2, b: Double = 0.75) -> [Double] {
            var scores = [Double](repeating: 0, count: lengths.count)
            let count = rows?.count ?? lengths.count
            guard count > 0, !queryTerms.isEmpty else { return scores }
            let length = rows?.reduce(0) { $0 + lengths[$1] } ?? totalLength
            let n = Double(count)
            let average = Double(max(1, length)) / n
            let multiplicity = queryTerms.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            for term in queryTerms {
                guard let posting = postings[term] else { continue }
                let hits = rows.map { rows in posting.filter { rows.contains($0.row) } } ?? posting
                let df = Double(hits.count * multiplicity[term, default: 0])
                let idf = log(1.0 + (n - df + 0.5) / (df + 0.5))
                for (row, frequency) in hits where lengths[row] > 0 && frequency > 0 {
                    let f = Double(frequency)
                    let denom = f + k1 * (1.0 - b + b * (Double(lengths[row]) / average))
                    if denom > 0 { scores[row] += idf * ((f * (k1 + 1.0)) / denom) }
                }
            }
            return scores
        }
    }
}
