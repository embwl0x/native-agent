// KnowledgeGraph query normalization, ranking, pagination and adjacency.
// MemoryStorage owns memory.sqlite and its schema; the checked SQLite reader
// uses that owner's pool. Legacy JSON is available only before SQLite exists.
// SwiftNativeKnowledgeGraphIndexer and KnowledgeGraphStore own Swift writes
// through the shared pool, including memory and studio projections.

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph.swift` | Graph normalization, checked legacy JSON admission and entity search |

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

// MARK: - JSON load error

/// Error for the checked JSON load path: the file exists but cannot be read
/// or parsed. A missing file is NOT an error (legitimate empty graph).
public enum KnowledgeGraphJSONLoadError: Error, Sendable {
    case unreadable(path: String, detail: String)
}

// MARK: - KnowledgeGraphStore (read-only)

/// Pure, read-only in-memory view over a loaded knowledge_graph.json document.
/// Construct via `loadChecked(path:)` or `normalize`. All query methods are
/// deterministic functions of the loaded data — no disk writes, no locks.
/// Legacy graph JSON and the consumed import marker remain under memory's
/// local backup/export and PrivacyMap scope. Phone snapshots project the
/// checked graph, never these files; MemoryStorage owns SQLite's kg_* schema.
public struct KnowledgeGraphStore: Sendable {
    /// Normalized entities keyed by id (insertion order preserved via `entityOrder`).
    public let entities: [String: JSONValue]
    /// Stable entity iteration and pagination order.
    public let entityOrder: [String]
    /// Normalized, orphan-pruned edge list.
    public let edges: [JSONValue]
    public init(
        entities: [String: JSONValue],
        entityOrder: [String],
        edges: [JSONValue]
    ) {
        self.entities = entities
        self.entityOrder = entityOrder
        self.edges = edges
    }

    /// A missing file is a legitimate empty graph; an existing unreadable or
    /// malformed file is an error. Recover textual entity-key order before
    /// normalization because JSONSerialization discards insertion order.
    public static func loadChecked(path: URL) throws -> KnowledgeGraphStore {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return KnowledgeGraphStore(entities: [:], entityOrder: [], edges: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw KnowledgeGraphJSONLoadError.unreadable(
                path: path.path, detail: String(describing: error)
            )
        }
        guard let parsed = try? JSONValue.parse(data),
              case .object(let raw) = parsed else {
            throw KnowledgeGraphJSONLoadError.unreadable(
                path: path.path, detail: "file is not a JSON object"
            )
        }
        return normalize(raw, entityKeyOrder: extractEntitiesKeyOrder(from: data))
    }

    /// Normalize entities and edges in textual key order, or lexicographic order when none is supplied.
    public static func normalize(
        _ raw: [String: JSONValue],
        entityKeyOrder: [String]? = nil
    ) -> KnowledgeGraphStore {
        var entities: [String: JSONValue] = [:]
        var order: [String] = []
        if case .object(let rawEntities)? = raw["entities"] {
            let orderedKeys: [String] = {
                if let pinned = entityKeyOrder {
                    // Keep existing pinned keys, then append unscanned keys.
                    var seen = Set<String>()
                    var out: [String] = []
                    for k in pinned where rawEntities[k] != nil {
                        if seen.insert(k).inserted { out.append(k) }
                    }
                    for k in rawEntities.keys where !seen.contains(k) {
                        out.append(k); seen.insert(k)
                    }
                    return out
                }
                return rawEntities.keys.sorted()
            }()
            for k in orderedKeys {
                guard let v = rawEntities[k] else { continue }
                guard case .object(var e) = v else { continue }
                // Drop falsy names before string conversion can make them nonempty.
                guard e["name"]?.isTruthy == true else { continue }
                // Falsy type/kind values become empty before whitespace trimming.
                let typeS = (e["type"]?.pythonStrOrEmpty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let kindS = (e["kind"]?.pythonStrOrEmpty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !typeS.isEmpty {
                    e.removeValue(forKey: "kind")
                } else if !kindS.isEmpty {
                    e["type"] = .string(kindS)
                    e.removeValue(forKey: "kind")
                } else {
                    e["type"] = .string("concept")
                    if e["provenance"] == nil { e["provenance"] = .string("default-concept") }
                }
                entities[k] = .object(e)
                order.append(k)
            }
        }

        // Reconcile edge kind→type, default to mentions, and drop missing/orphan endpoints.
        var normalizedEdges: [JSONValue] = []
        let entityIds = Set(entities.keys)
        if case .array(let rawEdges)? = raw["edges"] {
            for ev in rawEdges {
                guard case .object(var e) = ev else { continue }
                let typeS = (e["type"]?.pythonStrOrEmpty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let kindS = (e["kind"]?.pythonStrOrEmpty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !typeS.isEmpty && !kindS.isEmpty && typeS != kindS {
                    e["type"] = .string(typeS)
                    e.removeValue(forKey: "kind")
                } else if !typeS.isEmpty {
                    e["type"] = .string(typeS)
                    e.removeValue(forKey: "kind")
                } else if !kindS.isEmpty {
                    e["type"] = .string(kindS)
                    e.removeValue(forKey: "kind")
                } else {
                    e.removeValue(forKey: "kind")
                    if e["from"]?.isTruthy == true && e["to"]?.isTruthy == true {
                        e["type"] = .string("mentions")
                        if e["provenance"] == nil { e["provenance"] = .string("default-mentions") }
                    } else {
                        e.removeValue(forKey: "type")
                    }
                }
                // Endpoints and type must all be truthy.
                guard e["from"]?.isTruthy == true,
                      e["to"]?.isTruthy == true,
                      e["type"]?.isTruthy == true else { continue }
                // Only string endpoints can match entity keys; never stringify them.
                guard let fromKey = e["from"]?.stringValue,
                      let toKey = e["to"]?.stringValue,
                      entityIds.contains(fromKey), entityIds.contains(toKey) else { continue }
                normalizedEdges.append(.object(e))
            }
        }

        return KnowledgeGraphStore(
            entities: entities,
            entityOrder: order,
            edges: normalizedEdges
        )
    }

    /// Recover textual entity-key order before JSONSerialization discards it; skip nested values and strings.
    static func extractEntitiesKeyOrder(from data: Data) -> [String]? {
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        while i < n && bytes[i] != UInt8(ascii: "{") { i += 1 }
        guard i < n else { return nil }
        i += 1 // past root '{'
        func scanString(_ start: Int) -> (value: [UInt8], next: Int)? {
            var j = start
            guard j < n && bytes[j] == UInt8(ascii: "\"") else { return nil }
            j += 1
            var out: [UInt8] = []
            while j < n {
                let c = bytes[j]
                if c == UInt8(ascii: "\\") {
                    if j + 1 < n { out.append(c); out.append(bytes[j + 1]); j += 2; continue }
                }
                if c == UInt8(ascii: "\"") { return (out, j + 1) }
                out.append(c); j += 1
            }
            return nil
        }
        var entitiesBodyStart: Int? = nil
        while i < n {
            while i < n, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\n")
                || bytes[i] == UInt8(ascii: "\t") || bytes[i] == UInt8(ascii: "\r")
                || bytes[i] == UInt8(ascii: ",") { i += 1 }
            guard i < n, bytes[i] == UInt8(ascii: "\"") else { break }
            guard let (keyBytes, afterKey) = scanString(i) else { return nil }
            i = afterKey
            while i < n && bytes[i] != UInt8(ascii: ":") { i += 1 }
            guard i < n else { return nil }
            i += 1
            while i < n, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\n")
                || bytes[i] == UInt8(ascii: "\t") || bytes[i] == UInt8(ascii: "\r") { i += 1 }
            guard i < n else { return nil }
            if String(decoding: keyBytes, as: UTF8.self) == "entities",
               bytes[i] == UInt8(ascii: "{") {
                entitiesBodyStart = i + 1
                break
            }
            // Otherwise skip this value (string / object / array / scalar).
            i = skipValue(bytes, i, n)
            if i < 0 { return nil }
        }
        guard let bodyStart = entitiesBodyStart else { return [] }
        var keys: [String] = []
        var k = bodyStart
        while k < n {
            while k < n, bytes[k] == UInt8(ascii: " ") || bytes[k] == UInt8(ascii: "\n")
                || bytes[k] == UInt8(ascii: "\t") || bytes[k] == UInt8(ascii: "\r")
                || bytes[k] == UInt8(ascii: ",") { k += 1 }
            guard k < n else { break }
            if bytes[k] == UInt8(ascii: "}") { break } // end of entities object
            guard bytes[k] == UInt8(ascii: "\"") else { return keys.isEmpty ? nil : keys }
            guard let (keyBytes, afterKey) = scanString(k) else { return keys.isEmpty ? nil : keys }
            keys.append(String(decoding: keyBytes, as: UTF8.self))
            k = afterKey
            while k < n && bytes[k] != UInt8(ascii: ":") { k += 1 }
            guard k < n else { break }
            k += 1
            while k < n, bytes[k] == UInt8(ascii: " ") || bytes[k] == UInt8(ascii: "\n")
                || bytes[k] == UInt8(ascii: "\t") || bytes[k] == UInt8(ascii: "\r") { k += 1 }
            k = skipValue(bytes, k, n)
            if k < 0 { break }
        }
        return keys
    }

    /// Skip a single JSON value starting at index `i` (string/object/array/scalar),
    /// returning the index just past it, or -1 on malformed input.
    private static func skipValue(_ bytes: [UInt8], _ start: Int, _ n: Int) -> Int {
        var i = start
        guard i < n else { return -1 }
        let c = bytes[i]
        if c == UInt8(ascii: "\"") {
            i += 1
            while i < n {
                if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
                i += 1
            }
            return -1
        }
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
            let open = c
            let close: UInt8 = (open == UInt8(ascii: "{")) ? UInt8(ascii: "}") : UInt8(ascii: "]")
            var depth = 0
            while i < n {
                let ch = bytes[i]
                if ch == UInt8(ascii: "\"") {
                    // skip string contents
                    i += 1
                    while i < n {
                        if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                        if bytes[i] == UInt8(ascii: "\"") { break }
                        i += 1
                    }
                    i += 1
                    continue
                }
                if ch == open { depth += 1 }
                else if ch == close { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return -1
        }
        // scalar: number / true / false / null — read until delimiter.
        while i < n {
            let ch = bytes[i]
            if ch == UInt8(ascii: ",") || ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]")
                || ch == UInt8(ascii: " ") || ch == UInt8(ascii: "\n")
                || ch == UInt8(ascii: "\t") || ch == UInt8(ascii: "\r") { return i }
            i += 1
        }
        return i
    }

    // MARK: Queries

    /// Echo the supplied page; the checked reader clamps it before calling. Slice offsets are nonnegative.
    public func allEntities(page: Int = 0, pageSize: Int = 100) -> JSONValue {
        let allIds = entityOrder
        // Out-of-range or overflowing offsets yield an empty page.
        let (start, overflow) = max(0, page).multipliedReportingOverflow(by: pageSize)
        let pageKeys: [String]
        if pageSize > 0, !overflow, start < allIds.count {
            let end = start + min(pageSize, allIds.count - start)
            pageKeys = Array(allIds[start..<end])
        } else {
            pageKeys = []
        }
        let pageEnts: [JSONValue] = pageKeys.compactMap { entities[$0] }
        // Scope page edges by returned entities' string id fields, which may differ from their dictionary keys.
        var pageIdSet = Set<String>()
        for ent in pageEnts {
            if case .object(let o) = ent, let idStr = o["id"]?.stringValue, !idStr.isEmpty {
                pageIdSet.insert(idStr)
            }
        }
        let pageEdges: [JSONValue] = edges.filter { edge in
            guard case .object(let e) = edge else { return false }
            let from = e["from"]?.stringValue ?? ""
            let to = e["to"]?.stringValue ?? ""
            return pageIdSet.contains(from) || pageIdSet.contains(to)
        }
        return .object([
            "entities": .array(pageEnts),
            "edges": .array(pageEdges),
            "total_entities": .int(Int64(allIds.count)),
            "total_edges": .int(Int64(edges.count)),
            "page": .int(Int64(page)),
        ])
    }

    /// Rank matching entities by descending score, preserving entity order on ties.
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
            let name = ent["name"]?.pythonStrOrEmpty ?? ""
            let aliases: [String] = {
                guard case .array(let a)? = ent["aliases"] else { return [] }
                return a.map { $0.pythonStrOrEmpty }
            }()
            let summary = ent["summary"]?.pythonStrOrEmpty ?? ""

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
                lastSeen: ent["last_seen"]?.pythonStrOrEmpty, now: now
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

    /// Return touching edges and neighbors; an unknown id has a null entity.
    public func neighbors(_ entityId: String) -> JSONValue {
        let touching: [JSONValue] = edges.filter { edge in
            guard case .object(let e) = edge else { return false }
            let from = e["from"]?.stringValue ?? ""
            let to = e["to"]?.stringValue ?? ""
            return from == entityId || to == entityId
        }
        var neighborIds: Set<String> = []
        for edge in touching {
            guard case .object(let e) = edge else { continue }
            let from = e["from"]?.stringValue ?? ""
            let to = e["to"]?.stringValue ?? ""
            neighborIds.insert(from == entityId ? to : from)
        }
        var neighborObj: [String: JSONValue] = [:]
        for nid in neighborIds {
            if let ent = entities[nid] { neighborObj[nid] = ent }
        }
        return .object([
            "entity": entities[entityId] ?? .null,
            "edges": .array(touching),
            "neighbors": .object(neighborObj),
        ])
    }

    public func hasEntity(_ entityId: String) -> Bool {
        entities[entityId] != nil
    }
}

// MARK: - JSONValue graph helpers

extension JSONValue {
    /// Scalar text view: falsy values and collections become empty strings.
    fileprivate var pythonStrOrEmpty: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "True" : ""          // False -> falsy -> ""
        case .int(let i): return i == 0 ? "" : String(i)    // 0 -> falsy -> ""
        case .double(let d): return d == 0 ? "" : String(d) // 0.0 -> falsy -> ""
        case .string(let s): return s                        // "" stays ""
        case .array(let a): return a.isEmpty ? "" : ""       // [] -> "", non-empty unused here
        case .object(let o): return o.isEmpty ? "" : ""      // {} -> "", non-empty unused here
        }
    }

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
