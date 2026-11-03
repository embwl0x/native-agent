// KnowledgeGraph tokenization and ranking over canonical SQLite candidates.
// MemoryStorage owns memory.sqlite and its schema; the checked SQLite reader
// uses that owner's pool.
// SwiftNativeKnowledgeGraphIndexer and KnowledgeGraphStore own Swift writes
// through the shared pool, including memory and studio projections.

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph.swift` | Canonical graph candidate ranking and entity search |

// MARK: - Stopwords + tokenizer

/// Common words excluded from graph name tokens.
public let knowledgeGraphStopwords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "he", "her",
    "his", "i", "in", "is", "it", "me", "my", "of", "on", "or", "our", "she",
    "that", "the", "their", "these", "this", "those", "to", "was", "we", "were",
    "with", "you", "your",
]

/// Lowercase Unicode alphanumeric/underscore runs, excluding stopwords.
public func knowledgeGraphNameTokens(_ name: String) -> Set<String> {
    let lowered = name.lowercased()
    var tokens: Set<String> = []
    var current = ""
    var wordChars = CharacterSet.alphanumerics
    wordChars.insert(charactersIn: "_")
    for scalar in lowered.unicodeScalars {
        if wordChars.contains(scalar) {
            current.unicodeScalars.append(scalar)
        } else if !current.isEmpty {
            if !knowledgeGraphStopwords.contains(current) { tokens.insert(current) }
            current = ""
        }
    }
    if !current.isEmpty && !knowledgeGraphStopwords.contains(current) {
        tokens.insert(current)
    }
    return tokens
}

/// Pure in-memory ranking view of canonical SQLite candidates.
public struct KnowledgeGraphStore: Sendable {
    /// Canonical candidates keyed by id; ranking ties preserve `entityOrder`.
    public let entities: [String: JSONValue]
    /// Stable entity ranking order.
    public let entityOrder: [String]
    public init(
        entities: [String: JSONValue],
        entityOrder: [String]
    ) {
        self.entities = entities
        self.entityOrder = entityOrder
    }

    public func searchEntities(_ q: String) -> [JSONValue] {
        searchEntities(q, now: Date())
    }

    /// Recency is capped at popularity's ceiling, below one name-token overlap.
    static let recencyMaximumScore = 0.30

    /// Bucketed recency bonus; absent, invalid or future timestamps earn zero.
    static func recencyScore(lastSeen: String?, now: Date) -> Double {
        guard let raw = lastSeen?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let seen = NativeTimestampFormat.parseISO8601FractionalFirst(raw) else { return 0 }
        let ageDays = now.timeIntervalSince(seen) / 86_400
        guard ageDays >= 0 else { return 0 }
        switch ageDays {
        case ..<7: return recencyMaximumScore
        case ..<30: return recencyMaximumScore * 2.0 / 3.0
        case ..<90: return recencyMaximumScore / 3.0
        case ..<365: return recencyMaximumScore / 6.0
        default: return 0
        }
    }

    /// Rank against an explicit clock for recency buckets.
    public func searchEntities(_ q: String, now: Date) -> [JSONValue] {
        // Trim newlines and tabs as well as spaces before exact-name matching.
        let qLower = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let qTokens = knowledgeGraphNameTokens(q)
        if qLower.isEmpty && qTokens.isEmpty { return [] }

        var scored: [(score: Double, index: Int, ent: JSONValue)] = []
        var idx = 0
        for id in entityOrder {
            defer { idx += 1 }
            guard case .object(let ent)? = entities[id] else { continue }
            let name = ent["name"]?.stringValue ?? ""
            let aliases: [String] = {
                guard case .array(let a)? = ent["aliases"] else { return [] }
                return a.map { $0.stringValue ?? "" }
            }()
            let summary = ent["summary"]?.stringValue ?? ""

            let nameBlob = ([name] + aliases).joined(separator: " ").lowercased()
            let fullBlob = ([name] + aliases + [summary]).joined(separator: " ").lowercased()

            var nameTokens = knowledgeGraphNameTokens(name)
            for alias in aliases { nameTokens.formUnion(knowledgeGraphNameTokens(alias)) }
            let summaryTokens = knowledgeGraphNameTokens(summary)
            let searchableTokens = nameTokens.union(summaryTokens)

            let exactName = !qLower.isEmpty && nameBlob.contains(qLower)
            let exactSummary = !qLower.isEmpty && fullBlob.contains(qLower)
            let overlap = qTokens.intersection(searchableTokens)
            let nameOverlap = qTokens.intersection(nameTokens)
            let summaryOverlap = qTokens.intersection(summaryTokens)

            if !(exactName || exactSummary || !overlap.isEmpty) { continue }

            // Negative mention counts reduce popularity; only the upper bound is clamped.
            let mentions: Int = {
                guard let v = ent["mention_count"] else { return 0 }
                let n = v.intForGraph ?? 0
                return min(10, n)
            }()

            var score = 0.0
            if exactName {
                score += 6.0
            } else if exactSummary {
                score += 2.5
            }
            score += Double(nameOverlap.count) * 2.0
            for token in nameOverlap where token.count >= 8 {
                score += min(2.5, Double(token.count) / 8.0)
            }
            score += Double(summaryOverlap.count) * 0.75
            if !qTokens.isEmpty && !searchableTokens.isEmpty {
                score += Double(overlap.count) / Double(max(qTokens.count, 1))
            }
            score += Double(mentions) * 0.03
            score += Self.recencyScore(
                lastSeen: ent["last_seen"]?.stringValue, now: now
            )

            scored.append((score, idx, .object(ent)))
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        return scored.map { result in
            guard case .object(var entity) = result.ent else { return result.ent }
            entity["score"] = .double(result.score)
            return .object(entity)
        }
    }

}

// MARK: - JSONValue graph helpers

extension JSONValue {
    /// Mention counts truncate doubles toward zero; unparseable values return nil.
    fileprivate var intForGraph: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}
