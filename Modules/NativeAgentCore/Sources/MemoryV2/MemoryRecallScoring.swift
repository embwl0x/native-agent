import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryRecallScoring.swift` | `MemoryRecallScoring`: timestamp delegation, decay, literal kind extraction and record correction classification; mutation exceptions require explicit correction kind |

// MARK: - Wave-1 semantics tunables (Agent's canon, 2026-06-09)

/// Cosine at/above which a candidate memory counts as a PARAPHRASE of a
/// tombstoned claim and is blocked. High on purpose: only true restatements of
/// the deleted claim match; contradictions ("hates" after deleting "likes")
/// score lower and walk in as new information. Config constant per Agent —
/// tuned on REAL MiniLM output (2026-06-09 calibration, see
/// realMiniLM_tombstone_threshold_calibration): paraphrase=0.945,
/// narrower-claim=0.895, contradiction=0.890. Agent's initial 0.95 estimate
/// sat ABOVE the paraphrase — gate inert; 0.92 splits the measured gap so the
/// paraphrase blocks while contradiction + narrower claims walk in.
public let memoryTombstoneMatchThreshold: Double = 0.92

/// Single-valued kinds for the narrow supersession pass: two values can't both
/// be true, so a NEWER active fact of the same kind archives the older one.
/// Multi-valued kinds (preference, attribute, ...) coexist by design.
public let memorySupersessionSingleValuedKinds: Set<String> = ["location", "employment", "identity"]

/// Mechanism guard inside Agent's narrow lane: same-kind alone could collide
/// unrelated facts (employment carries both work-at and work-as). Supersession
/// additionally requires this cosine floor so only same-topic facts collide.
public let memorySupersessionCosineFloor: Double = 0.55

/// Kind-scoped recency decay (Agent's canon): half-life in DAYS per kind.
/// Shapes RANK only — never existence (eviction stays the consolidator's job).
/// Kinds absent from this table — identity/relationship/preference AND
/// nil/legacy — are exempt (factor 1.0): decay only acts on data that carries
/// the volatile-class kind signal.
/// Long-lived-but-not-permanent kinds decay too, just much slower: a decision
/// or an incident stays relevant for months, not forever, so 180d lets a fresh
/// one outrank a stale one without ever pushing it out of reach. NOTE: the
/// STAMP path can't mint these kinds (`MemoryKindStamp.taxonomy` lacks them),
/// but rows written with explicit metadata already carry them (29 live rows
/// as of 2026-08-28) — the entries are live for those, not inert.
public let memoryDecayHalfLifeDays: [String: Double] = [
    "volatile": 60, "project": 60, "operational": 60,
    "decision": 180, "note": 180, "incident": 180,
    // Moment age decay reads updatedAt; recall changes only use_count and
    // last_used_at, so access does not refresh this clock.
    "moment": 60,
]

/// Additive lexical boost used by hybrid recall. The base dense cosine remains
/// intact, then normalized BM25 can add up to this amount before kind-recency
/// decay is applied. This keeps old cosine score semantics mostly stable while
/// giving exact names/keywords enough authority to recover short Telegram turns.
public let memoryBM25LexicalBoost: Double = 0.25

/// Pure decay math, separated for testability.
public enum MemoryRecallScoring {
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

    /// The unique query terms the lexical lane actually scores: lexical tokens
    /// minus the shape-of-a-question stopwords. 2026-09-06: SELECTION and
    /// RANKING must use this one rule, or a bounded prefilter fills its cap
    /// with rows that only matched filler and the scorer never sees the rows
    /// that carry the content terms.
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

    /// BM25 over the already-loaded candidate set. Recall already performs a
    /// full candidate sweep for cosine, so this avoids a schema migration while
    /// restoring the daemon-era lexical signal.
    static func normalizedBM25Scores(
        query: String?,
        lexicalDocuments documents: [LexicalDocument],
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [Double] {
        guard let query else { return Array(repeating: 0, count: documents.count) }
        // 2026-09-06: query STOPWORDS used to score as content terms. The
        // boost is normalized by the best candidate's raw score, so a row that
        // merely shared "what"/"does"/"me" with the question could take the
        // whole +0.25 from the row that answered it ("What does User call me?"
        // ranked the gender-address rule first and her titles third). The
        // ROUTER has always filtered these before ranking; this lane now uses
        // the same list. Documents keep every token — BM25's length
        // normalization is supposed to see the real document length.
        //
        // 2026-09-06: a query made of nothing but stopwords ("who are you")
        // gets ZERO lexical signal rather than falling back to the unfiltered
        // terms — a fallback just puts the filler back in charge of the boost.
        // The dense lane carries such a question.
        let queryTerms = lexicalContentTerms(query)
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

        guard let maxScore = rawScores.max(), maxScore > 0 else {
            return Array(repeating: 0, count: documents.count)
        }
        return rawScores.map { $0 / maxScore }
    }
}
