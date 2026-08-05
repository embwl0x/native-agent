// SwiftNative read-only port of the daemon KnowledgeGraph query surface.
//
// Source of truth: the retired daemon (class KnowledgeGraph) +
// the retired daemon route handlers:
//   GET  /v1/knowledge_graph                  -> all_entities(page=)
//   GET  /v1/knowledge_graph/search?q=        -> {"results": search_entities(q)}
//   GET  /v1/knowledge_graph/entity/{id}      -> neighbors(entity_id) (404 if missing)
//
// This module ports ONLY the read path: it reads
// `<dataRoot>/memory/knowledge_graph.json`, applies the SAME load-time
// normalization the Python `_load()` does (entity kind→type, edge kind→type,
// orphan-edge drop, default-concept / default-mentions provenance), and runs
// the SAME pure scoring (`search_entities`) + pagination (`all_entities`) +
// adjacency (`neighbors`) logic. Entity / edge dictionaries are returned as
// the raw stored JSONValue objects (passthrough, no field reshaping), so the
// Mac KnowledgeGraphView decode models (KGEntity / KGEntityResponse /
// KGSearchResponse / KGNeighborsResponse) decode them identically. (The
// re-serialized bytes are not byte-for-byte identical to the daemon's
// json.dumps — key order differs — but Decodable ignores key order.)
//
// WRITE paths (forget_entity, merge_two_entities, add_edge, extract_*) and the
// batched flush/timer persistence machinery are deliberately NOT ported here —
// they require the cross-process file lock and stay
// HTTP-backed. See CUTOVER_PLAN.md §6.34.
//
// The `/v1/graph/*` family is a SEPARATE subsystem (Runtime.build_graph_index
// over executions + memories + embeddings) and is NOT in scope for this module.

import Foundation
import PersistenceCore

// MARK: - Stopwords + tokenizer

/// Mirrors `GRAPH_STOPWORDS` in the retired daemon (L25-30).
public let knowledgeGraphStopwords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "he", "her",
    "his", "i", "in", "is", "it", "me", "my", "of", "on", "or", "our", "she",
    "that", "the", "their", "these", "this", "those", "to", "was", "we", "were",
    "with", "you", "your",
]

/// Mirrors `_name_tokens(name)` in the retired daemon (L38-39):
///   `{tok for tok in re.findall(r"\w+", name.lower()) if tok not in STOPWORDS}`
///
/// Python's `\w` under the default (Unicode) flags matches `[a-zA-Z0-9_]` plus
/// any Unicode word character. Swift's `CharacterSet.alphanumerics` plus `_`
/// is the closest faithful match; we lower-case first (matching `.lower()`).
public func knowledgeGraphNameTokens(_ name: String) -> Set<String> {
    let lowered = name.lowercased()
    var tokens: Set<String> = []
    var current = ""
    // `\w` == letters, digits, marks, and underscore. Build runs of those,
    // splitting on everything else — matches re.findall(r"\w+", ...).
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

// MARK: - JSON load error (U5 W-C empty-vs-error)

/// Error for the checked JSON load path: the file exists but cannot be read
/// or parsed. A missing file is NOT an error (legitimate empty graph).
public enum KnowledgeGraphJSONLoadError: Error, Sendable {
    case unreadable(path: String, detail: String)
}

// MARK: - KnowledgeGraphStore (read-only)

/// Pure, read-only in-memory view over a loaded knowledge_graph.json document.
/// Construct via `load(path:)` or `init(document:)`. All query methods are
/// deterministic functions of the loaded data — no disk writes, no locks.
public struct KnowledgeGraphStore: Sendable {
    /// Normalized entities keyed by id (insertion order preserved via `entityOrder`).
    public let entities: [String: JSONValue]
    /// Stable iteration order of entity ids (matches Python dict insertion order,
    /// which `all_entities` paginates over with `list(self._data["entities"].values())`).
    public let entityOrder: [String]
    /// Normalized, orphan-pruned edge list.
    public let edges: [JSONValue]
    /// WAVE 32 W04: the deterministic-freshness commit counter stamped into the
    /// file by the daemon's `_flush_locked` (top-level `"_commit_seq"`). 0 when the
    /// file predates the field or is missing/unparseable. The SwiftNative reader's
    /// flush-read-confirm sandwich (`verifiedFreshStore`) requires this to EQUAL the
    /// seq the `/v1/knowledge_graph/flush` route reports across both confirming
    /// flushes (`seq1 == seq2 == commitSeq`). Files written by an older daemon (no
    /// field) yield 0; a LIVE W32 daemon always reports seq >= 1 (it force-stamps off
    /// 0), so a 0 here can never equal the reported seq and the reader safely defers
    /// to the authoritative HTTP path — never serving an unverifiable snapshot.
    public let commitSeq: Int

    public init(
        entities: [String: JSONValue],
        entityOrder: [String],
        edges: [JSONValue],
        commitSeq: Int = 0
    ) {
        self.entities = entities
        self.entityOrder = entityOrder
        self.edges = edges
        self.commitSeq = commitSeq
    }

    /// Load + normalize from the on-disk JSON file. Mirrors `_load()` in
    /// the retired daemon (L108-206). Returns an EMPTY store (not nil)
    /// when the file is missing or unreadable — matching Python, which boots a
    /// fresh `{"entities": {}, "edges": [], "version": 1}` skeleton.
    ///
    /// The daemon writes the file via `json.dumps(self._data, indent=2)` with
    /// NO sort_keys, so the file's textual entity-key
    /// order == Python dict INSERTION order. `all_entities` paginates in that
    /// order and `search_entities` ties break on it (stable sort). Swift's
    /// JSONSerialization does NOT preserve object key order, so we recover the
    /// top-level `"entities"` key order directly from the raw bytes and feed it
    /// to `normalize` (gpt-5.5 review finding #2).
    public static func load(path: URL) -> KnowledgeGraphStore {
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let raw) = parsed else {
            return KnowledgeGraphStore(entities: [:], entityOrder: [], edges: [])
        }
        let keyOrder = extractEntitiesKeyOrder(from: data)
        return normalize(raw, entityKeyOrder: keyOrder)
    }

    /// U5 W-C (2026-06-11): like `load(path:)` but with the empty-vs-error
    /// distinction the honest read path needs. A MISSING file is a legitimate
    /// empty graph (Python boots the skeleton, fresh installs have no file);
    /// a file that EXISTS but cannot be read or parsed is an ERROR — it must
    /// never render as an empty-but-healthy graph. `load(path:)` keeps its
    /// silent-empty contract for the import path and historical callers.
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

    /// WAVE 32 W04: extract the daemon's persisted `"_commit_seq"` from a parsed
    /// graph object. Mirrors the daemon's restore logic (`max(0, int(... or 0))`):
    /// an int -> itself (floored, clamped ≥0), a numeric string -> parsed, anything
    /// else / missing -> 0. The reader uses this to verify the on-disk file is at
    /// least as new as the flush the daemon just confirmed.
    static func commitSeq(from raw: [String: JSONValue]) -> Int {
        switch raw["_commit_seq"] {
        case .some(.int(let i)): return max(0, Int(i))
        case .some(.double(let d)): return max(0, Int(d))
        case .some(.string(let s)): return max(0, Int(s) ?? 0)
        default: return 0
        }
    }

    /// Apply the same skeleton-merge + entity/edge normalization Python does on
    /// load. Kept separate from `load` so tests can pin behavior on an in-memory
    /// document without touching disk.
    ///
    /// `entityKeyOrder`, when supplied, pins the iteration/pagination order to
    /// the file's textual key order (== Python insertion order). When nil
    /// (in-memory tests with no source bytes), keys are visited in a stable
    /// lexicographic order so behavior is still deterministic.
    public static func normalize(
        _ raw: [String: JSONValue],
        entityKeyOrder: [String]? = nil
    ) -> KnowledgeGraphStore {
        // entities: dict[str, dict] — drop non-dict / nameless; reconcile kind→type.
        var entities: [String: JSONValue] = [:]
        var order: [String] = []
        if case .object(let rawEntities)? = raw["entities"] {
            // Visit keys in file/insertion order when known, else stable lexicographic.
            let orderedKeys: [String] = {
                if let pinned = entityKeyOrder {
                    // Keep only keys that actually exist in the parsed object,
                    // in the pinned order; append any parsed keys the byte-scan
                    // missed (defensive — should be empty in practice).
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
                // Must have a TRUTHY name. Python: `if not isinstance(v, dict)
                // or not v.get("name")` — drops when name is missing/None/""/0/
                // false/[]/{}. Preserve retired truthiness exactly rather than
                // routing through a stringifier (which would turn 0/false into
                // the kept strings "0"/"False"). gpt-5.5 review finding #5.
                guard jsonValueIsPythonTruthy(e["name"]) else { continue }
                // Python: `str(e.get("type") or "").strip()` — falsy collapses
                // to "" FIRST (so type:0 -> "" -> default-concept), and .strip()
                // is whitespacesAndNewlines.
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

        // edges: list[dict] — reconcile kind→type, default-mentions, drop
        // endpoint-less / orphan edges. Mirror Python L147-200.
        var normalizedEdges: [JSONValue] = []
        let entityIds = Set(entities.keys)
        if case .array(let rawEdges)? = raw["edges"] {
            for ev in rawEdges {
                guard case .object(var e) = ev else { continue }
                // type/kind: `str(x or "").strip()` (falsy -> "", .strip() incl. newlines).
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
                    // Python: `if e.get("from") and e.get("to")` — TRUTHINESS, not
                    // string-emptiness. A non-string-but-truthy endpoint (e.g.
                    // int 5) passes here in Python (it's later orphan-dropped).
                    if jsonValueIsPythonTruthy(e["from"]) && jsonValueIsPythonTruthy(e["to"]) {
                        e["type"] = .string("mentions")
                        if e["provenance"] == nil { e["provenance"] = .string("default-mentions") }
                    } else {
                        e.removeValue(forKey: "type")
                    }
                }
                // Final keep-gate preserves the retired L182 behavior: `if e.get("from") and
                // e.get("to") and e.get("type")` — TRUTHINESS on all three.
                guard jsonValueIsPythonTruthy(e["from"]),
                      jsonValueIsPythonTruthy(e["to"]),
                      jsonValueIsPythonTruthy(e["type"]) else { continue }
                // Orphan drop preserves the retired L189 behavior: `e.get("from") in _entity_ids`
                // — RAW value membership against the set of (string) entity KEYS.
                // A non-string endpoint can never match a string key, so use the
                // string-only key view (nil -> never matches).
                guard let fromKey = e["from"]?.graphStringKey,
                      let toKey = e["to"]?.graphStringKey,
                      entityIds.contains(fromKey), entityIds.contains(toKey) else { continue }
                normalizedEdges.append(.object(e))
            }
        }

        return KnowledgeGraphStore(
            entities: entities,
            entityOrder: order,
            edges: normalizedEdges,
            commitSeq: commitSeq(from: raw)
        )
    }

    /// Recover the textual key order of the top-level `"entities"` object from
    /// the raw JSON bytes. Swift's JSONSerialization discards object key order;
    /// the daemon writes the file with insertion order intact (no sort_keys), so
    /// scanning the bytes is the only way to reproduce Python's pagination /
    /// stable-sort order. Returns nil on any structural surprise (caller then
    /// falls back to stable lexicographic order — deterministic, just not
    /// byte-for-byte Python order).
    ///
    /// The scanner is a tiny string-aware, brace-depth-aware tokenizer: it finds
    /// the value of the top-level `"entities"` key, then collects the keys that
    /// appear at depth 1 INSIDE that object (i.e. immediate entity-id keys),
    /// skipping nested objects/arrays and string contents.
    static func extractEntitiesKeyOrder(from data: Data) -> [String]? {
        let bytes = [UInt8](data)
        let n = bytes.count
        // Locate the top-level "entities" key. We do a depth-aware scan of the
        // root object and only accept the key when we are at root depth 1.
        var i = 0
        // Skip to first '{'
        while i < n && bytes[i] != UInt8(ascii: "{") { i += 1 }
        guard i < n else { return nil }
        i += 1 // past root '{'
        // Find the "entities" key at root level.
        func scanString(_ start: Int) -> (value: [UInt8], next: Int)? {
            var j = start
            guard j < n && bytes[j] == UInt8(ascii: "\"") else { return nil }
            j += 1
            var out: [UInt8] = []
            while j < n {
                let c = bytes[j]
                if c == UInt8(ascii: "\\") {
                    // Keep the escape + next char verbatim (we only need raw key
                    // matching for ASCII id keys; escapes are rare in ids).
                    if j + 1 < n { out.append(c); out.append(bytes[j + 1]); j += 2; continue }
                }
                if c == UInt8(ascii: "\"") { return (out, j + 1) }
                out.append(c); j += 1
            }
            return nil
        }
        // Walk root-level members until we hit key == "entities".
        var entitiesBodyStart: Int? = nil
        while i < n {
            // skip whitespace/commas
            while i < n, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\n")
                || bytes[i] == UInt8(ascii: "\t") || bytes[i] == UInt8(ascii: "\r")
                || bytes[i] == UInt8(ascii: ",") { i += 1 }
            guard i < n, bytes[i] == UInt8(ascii: "\"") else { break }
            guard let (keyBytes, afterKey) = scanString(i) else { return nil }
            i = afterKey
            // skip to ':'
            while i < n && bytes[i] != UInt8(ascii: ":") { i += 1 }
            guard i < n else { return nil }
            i += 1
            // skip whitespace
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
        // Collect depth-1 keys inside the entities object.
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

    /// Mirrors `all_entities(page, page_size=100)` in knowledge_graph.py (L802-822).
    /// This mirrors the Python METHOD exactly: it does NOT clamp `page` — it
    /// echoes whatever it is given. The daemon ROUTE is what clamps the param
    /// with `max(0, int(...))`, so a negative page never
    /// reaches the method over HTTP. `SwiftNativeKnowledgeGraphReader.allEntities`
    /// reproduces that route-level clamp before calling this method (gpt-5.5
    /// wave-30 review finding — negative-page echo parity). Slicing uses a
    /// non-negative start so a (route-clamped, always ≥0) page never under-runs;
    /// Swift arrays cannot take Python's negative-index slices.
    public func allEntities(page: Int = 0, pageSize: Int = 100) -> JSONValue {
        let allIds = entityOrder
        let start = max(0, page) * pageSize
        let end = min(allIds.count, start + pageSize)
        let pageKeys: [String] = (start < end) ? Array(allIds[start..<end]) : []
        let pageEnts: [JSONValue] = pageKeys.compactMap { entities[$0] }
        // Python scopes page edges by the entity `id` FIELD of the returned
        // entities (`page_ent_ids = {e.get("id") for e in page_ents if e.get("id")}`),
        // NOT the dict key — they usually coincide but can diverge (gpt-5.5
        // review finding #3). Match Python by reading the id field. The id set
        // is string-keyed (graphStringKey), and surviving edge from/to are
        // guaranteed string keys (orphan-drop on load), so membership is exact.
        var pageIdSet = Set<String>()
        for ent in pageEnts {
            if case .object(let o) = ent, let idStr = o["id"]?.graphStringKey, !idStr.isEmpty {
                pageIdSet.insert(idStr)
            }
        }
        let pageEdges: [JSONValue] = edges.filter { edge in
            guard case .object(let e) = edge else { return false }
            let from = e["from"]?.graphStringKey ?? ""
            let to = e["to"]?.graphStringKey ?? ""
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

    /// Mirrors `search_entities(q)` in knowledge_graph.py (L824-865).
    /// Returns the matching entity JSONValue objects in descending score order.
    /// NOTE: Python uses a STABLE sort on score only (`scored.sort(key=score, reverse=True)`),
    /// so ties keep iteration (insertion) order. Swift's `sorted(by:)` is NOT
    /// guaranteed stable; we therefore decorate with the original index and use
    /// it as a deterministic tie-breaker to match Python's stable behavior.
    public func searchEntities(_ q: String) -> [JSONValue] {
        // Python: `q_lower = q.lower().strip()` — str.strip() removes ALL
        // leading/trailing whitespace incl. newlines/tabs, so we must use
        // .whitespacesAndNewlines (NOT .whitespaces, which excludes \n/\r — a
        // query like "\nNativeAgent\n" would otherwise lose its exact-name
        // bonus). gpt-5.5 wave-30 review finding (trim parity).
        let qLower = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let qTokens = knowledgeGraphNameTokens(q)
        if qLower.isEmpty && qTokens.isEmpty { return [] }

        var scored: [(score: Double, index: Int, ent: JSONValue)] = []
        var idx = 0
        for id in entityOrder {
            defer { idx += 1 }
            guard case .object(let ent)? = entities[id] else { continue }
            // Python: `str(ent.get("name") or "")`, `[str(a or "") for a in ...]`,
            // `str(ent.get("summary") or "")` — falsy collapses to "" first.
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

            // Python: `mentions = min(10, int(ent.get("mention_count") or 0))`
            // — note NO lower clamp, so a negative mention_count legitimately
            // REDUCES the score (mentions * 0.03). Earlier draft clamped at 0;
            // that diverged on negative counts (gpt-5.5 review finding #4).
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
            // Python: sum(min(2.5, len(token)/8) for token in name_overlap if len(token) >= 8)
            for token in nameOverlap where token.count >= 8 {
                score += min(2.5, Double(token.count) / 8.0)
            }
            score += Double(summaryOverlap.count) * 0.75
            if !qTokens.isEmpty && !searchableTokens.isEmpty {
                score += Double(overlap.count) / Double(max(qTokens.count, 1))
            }
            score += Double(mentions) * 0.03

            scored.append((score, idx, .object(ent)))
        }

        // Descending by score; stable tie-break by original index (mirrors
        // Python's stable sort preserving insertion order on equal scores).
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        return scored.map { $0.ent }
    }

    /// Mirrors `neighbors(entity_id)` in knowledge_graph.py (L867-884).
    /// Returns nil-entity payload when the id is unknown (matches Python, which
    /// returns `{"entity": None, ...}`; the daemon route 404s only when the
    /// entity is missing — see note in makeKnowledgeGraphReader).
    public func neighbors(_ entityId: String) -> JSONValue {
        // Python: `e.get("from") == entity_id` — raw equality against the
        // (string) route id. Surviving edges have string from/to (orphan-drop on
        // load), so the string-key view is exact; a non-string endpoint yields ""
        // and never equals a real id.
        let touching: [JSONValue] = edges.filter { edge in
            guard case .object(let e) = edge else { return false }
            let from = e["from"]?.graphStringKey ?? ""
            let to = e["to"]?.graphStringKey ?? ""
            return from == entityId || to == entityId
        }
        var neighborIds: Set<String> = []
        for edge in touching {
            guard case .object(let e) = edge else { continue }
            let from = e["from"]?.graphStringKey ?? ""
            let to = e["to"]?.graphStringKey ?? ""
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

    /// True iff the entity id is present (used by the daemon-route 404 contract).
    public func hasEntity(_ entityId: String) -> Bool {
        entities[entityId] != nil
    }
}

// MARK: - JSONValue graph helpers

/// Retired truthiness for a JSON value, matching `if not v.get(key)` /
/// `if v.get(key)`: None/missing, "", 0, 0.0, false, [], {} are falsy;
/// everything else is truthy.
func jsonValueIsPythonTruthy(_ v: JSONValue?) -> Bool {
    guard let v else { return false }
    switch v {
    case .null: return false
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s): return !s.isEmpty
    case .array(let a): return !a.isEmpty
    case .object(let o): return !o.isEmpty
    }
}

extension JSONValue {
    /// Mirrors Python `str(x or "")` for the scalar text fields the graph reads
    /// via that idiom (type, kind, name, summary, aliases). Python's `x or ""`
    /// collapses EVERY falsy value (None / 0 / 0.0 / False / "" / [] / {}) to the
    /// empty string FIRST, so only TRUTHY values are stringified. Earlier this
    /// rendered `0`→"0" and `False`→"False" (the old `stringForGraph`), diverging
    /// from Python where `str(0 or "")` == "" — e.g. an entity `{name:"x",
    /// kind:0}` defaulted to type "concept" in Python but became type "0" here.
    /// gpt-5.5 wave-30 review finding (falsy-stringify parity).
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

    /// Endpoint-key view for edge `from`/`to` matching + orphan-drop. Python
    /// compares the RAW value against `set(self._data["entities"].keys())`
    /// (all str keys) and against other raw endpoint values, so a NON-string
    /// endpoint (e.g. int `1`) can NEVER match a string key `"1"`. Returns the
    /// string itself ONLY for `.string`; nil otherwise so non-string endpoints
    /// never match. gpt-5.5 wave-30 review finding (raw-membership parity).
    fileprivate var graphStringKey: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Int view used for `mention_count`. `.int` -> itself; `.double` -> floored;
    /// `.string` -> parsed (Python: `int(ent.get("mention_count") or 0)` raises on
    /// non-numeric strings, caught and treated as 0 — we mirror by returning nil
    /// on parse failure, and the caller defaults to 0).
    fileprivate var intForGraph: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}
