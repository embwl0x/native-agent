import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import KnowledgeGraph

@Test func agentSearchProjectionBoundsRawEntityMetadataWithoutLosingSearchIdentity() throws {
    let oversizedMetadata = (0..<200).map { JSONValue.string("provenance-\($0)-" + String(repeating: "x", count: 100)) }
    let results: [JSONValue] = (0..<30).map { index in
        .object([
            "id": .string("entity-\(index)"),
            "name": .string("Entity \(index)"),
            "type": .string("fact"),
            "summary": .string(String(repeating: "s", count: 2_000)),
            "score": .double(Double(30 - index)),
            "aliases": .array((0..<20).map { .string("alias-\($0)") }),
            "memory_ids": .array(oversizedMetadata),
            "nested": .object(["raw": .array(oversizedMetadata)]),
        ])
    }

    let bounded = KnowledgeGraphSearchProjection.bounded(
        .object(["results": .array(results)]),
        requestedLimit: 10
    )
    guard case .object(let envelope) = bounded,
          case .array(let projected)? = envelope["results"],
          case .object(let first)? = projected.first else {
        Issue.record("expected bounded search envelope")
        return
    }

    #expect(envelope["total_results"] == .int(30))
    #expect(envelope["returned_results"] == .int(10))
    #expect(envelope["truncated"] == .bool(true))
    #expect(first["id"] == .string("entity-0"))
    #expect(first["score"] == .double(30))
    #expect(first["memory_ids"] == nil)
    #expect(first["nested"] == nil)
    guard case .string(let summary)? = first["summary"],
          case .array(let aliases)? = first["aliases"] else {
        Issue.record("expected summary and aliases")
        return
    }
    #expect(summary.count == 1_203)
    #expect(aliases.count == 10)

    let serialized = try bounded.serialize(pretty: false)
    #expect(serialized.count < 20_000)
}

// MARK: - Helpers

private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

/// Build a normalized store from a raw document dictionary (no disk).
private func store(_ raw: [String: JSONValue]) -> KnowledgeGraphStore {
    KnowledgeGraphStore.normalize(raw)
}

private func entityIds(_ vals: [JSONValue]) -> [String] {
    vals.compactMap { v in
        if case .object(let o) = v, case .string(let id)? = o["id"] { return id }
        return nil
    }
}

private func stringField(_ v: JSONValue, _ key: String) -> String? {
    if case .object(let o) = v, case .string(let s)? = o[key] { return s }
    return nil
}

private func intField(_ v: JSONValue, _ key: String) -> Int? {
    guard case .object(let o) = v else { return nil }
    switch o[key] {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    case .string(let s): return Int(s)
    default: return nil
    }
}

private func tempMemoryDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// A small fixture graph reused across tests.
private let fixtureRaw: [String: JSONValue] = [
    "entities": .object([
        "e1": obj([
            "id": .string("e1"), "name": .string("Example User"),
            "type": .string("person"), "aliases": .array([.string("the user")]),
            "summary": .string("the user who owns NativeAgent"),
            "mention_count": .int(8),
        ]),
        "e2": obj([
            "id": .string("e2"), "name": .string("NativeAgent"),
            // legacy "kind" only — must normalize to type.
            "kind": .string("project"),
            "summary": .string("a macOS assistant built by the user"),
            "mention_count": .int(20),
        ]),
        "e3": obj([
            "id": .string("e3"), "name": .string("Claude"),
            // neither type nor kind -> default-concept provenance.
            "summary": .string("the assistant persona"),
        ]),
        // nameless entity -> dropped on normalize.
        "e4": obj(["id": .string("e4"), "type": .string("ghost")]),
    ]),
    "edges": .array([
        // valid edge
        obj(["from": .string("e1"), "to": .string("e2"), "type": .string("owns")]),
        // kind-only edge -> normalize to type
        obj(["from": .string("e2"), "to": .string("e3"), "kind": .string("embodies")]),
        // orphan edge (e9 missing) -> dropped
        obj(["from": .string("e1"), "to": .string("e9"), "type": .string("dangling")]),
        // endpoint-less, type empty -> dropped
        obj(["type": .string("")]),
    ]),
    "version": .int(1),
]

// MARK: - Tokenizer / stopwords

@Test func tokenizerStripsStopwordsAndLowercases() {
    let toks = knowledgeGraphNameTokens("The Quick Brown FOX and a Dog")
    // "the", "and", "a" are stopwords; rest lowercased.
    #expect(toks == ["quick", "brown", "fox", "dog"])
}

@Test func tokenizerSplitsOnNonWordAndKeepsUnderscore() {
    let toks = knowledgeGraphNameTokens("native_agent v2.0!! macOS")
    #expect(toks.contains("native_agent"))
    #expect(toks.contains("v2"))
    #expect(toks.contains("0"))
    #expect(toks.contains("macos"))
}

// MARK: - Normalization (mirrors _load)

@Test func normalizeReconcilesKindToTypeAndDropsNameless() {
    let s = store(fixtureRaw)
    // e4 (nameless) dropped.
    #expect(s.entities["e4"] == nil)
    #expect(Set(s.entityOrder) == ["e1", "e2", "e3"])
    // e2 legacy "kind" -> "type"=project, kind removed.
    if case .object(let e2)? = s.entities["e2"] {
        #expect(e2["type"] == .string("project"))
        #expect(e2["kind"] == nil)
    } else { Issue.record("e2 missing") }
    // e3 default-concept.
    if case .object(let e3)? = s.entities["e3"] {
        #expect(e3["type"] == .string("concept"))
        #expect(e3["provenance"] == .string("default-concept"))
    } else { Issue.record("e3 missing") }
}

@Test func normalizeDropsOrphanAndEndpointlessEdges() {
    let s = store(fixtureRaw)
    // Only the two valid edges survive (e1->e2 owns, e2->e3 embodies).
    #expect(s.edges.count == 2)
    // kind-only edge normalized to type.
    let hasEmbodies = s.edges.contains { e in
        stringField(e, "type") == "embodies" && stringField(e, "from") == "e2"
    }
    #expect(hasEmbodies)
    let hasDangling = s.edges.contains { stringField($0, "type") == "dangling" }
    #expect(!hasDangling)
}

// MARK: - all_entities

@Test func allEntitiesReturnsEnvelopeWithScopedEdges() {
    let s = store(fixtureRaw)
    guard case .object(let env) = s.allEntities(page: 0, pageSize: 100) else {
        Issue.record("not an object"); return
    }
    #expect(env["total_entities"] == .int(3))
    #expect(env["total_edges"] == .int(2))
    #expect(env["page"] == .int(0))
    if case .array(let ents)? = env["entities"] {
        #expect(Set(entityIds(ents)) == ["e1", "e2", "e3"])
    } else { Issue.record("entities missing") }
    if case .array(let edges)? = env["edges"] {
        #expect(edges.count == 2)
    } else { Issue.record("edges missing") }
}

@Test func allEntitiesPaginates() {
    let s = store(fixtureRaw)
    guard case .object(let p0) = s.allEntities(page: 0, pageSize: 2),
          case .array(let e0)? = p0["entities"] else { Issue.record("p0"); return }
    #expect(e0.count == 2)
    #expect(p0["total_entities"] == .int(3))
    guard case .object(let p1) = s.allEntities(page: 1, pageSize: 2),
          case .array(let e1)? = p1["entities"] else { Issue.record("p1"); return }
    #expect(e1.count == 1)
    #expect(p1["page"] == .int(1))
}

// MARK: - search_entities

@Test func searchReturnsEmptyForEmptyQuery() {
    let s = store(fixtureRaw)
    #expect(s.searchEntities("").isEmpty)
    #expect(s.searchEntities("   ").isEmpty)
}

@Test func searchExactNameScoresHighest() {
    let s = store(fixtureRaw)
    let results = s.searchEntities("NativeAgent")
    #expect(!results.isEmpty)
    // e2 (name == NativeAgent) ranks first.
    #expect(stringField(results[0], "id") == "e2")
}

@Test func searchMatchesAliasAndSummaryTokens() {
    let s = store(fixtureRaw)
    // "the user" matches e1 name+alias and appears in e2 summary ("built by the user").
    let results = s.searchEntities("the user")
    let ids = results.compactMap { stringField($0, "id") }
    #expect(ids.contains("e1"))
    #expect(ids.contains("e2"))
    // e1 (exact name + alias) should outrank e2 (summary-only mention).
    #expect(ids.firstIndex(of: "e1")! < ids.firstIndex(of: "e2")!)
}

@Test func searchNoMatchReturnsEmpty() {
    let s = store(fixtureRaw)
    #expect(s.searchEntities("zzzznotpresent").isEmpty)
}

@Test func searchResultsArePassthroughEntities() {
    let s = store(fixtureRaw)
    let results = s.searchEntities("Claude")
    #expect(results.count == 1)
    // The returned object must carry the original fields verbatim (id/name/type/summary).
    #expect(stringField(results[0], "name") == "Claude")
    #expect(stringField(results[0], "type") == "concept")
    #expect(stringField(results[0], "summary") == "the assistant persona")
}

// MARK: - neighbors / hasEntity

@Test func neighborsReturnsTouchingEdgesAndNodes() {
    let s = store(fixtureRaw)
    guard case .object(let n) = s.neighbors("e2") else { Issue.record("not obj"); return }
    // e2 touches e1 (owns) and e3 (embodies).
    if case .array(let edges)? = n["edges"] { #expect(edges.count == 2) }
    if case .object(let neigh)? = n["neighbors"] {
        #expect(Set(neigh.keys) == ["e1", "e3"])
    } else { Issue.record("neighbors missing") }
    #expect(stringField(n["entity"] ?? .null, "id") == "e2")
}

@Test func hasEntityReflectsPresence() {
    let s = store(fixtureRaw)
    #expect(s.hasEntity("e1"))
    #expect(!s.hasEntity("e4")) // dropped (nameless)
    #expect(!s.hasEntity("nope"))
}

// MARK: - Load from disk + empty fallback

@Test func loadMissingFileReturnsEmptyStore() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_does_not_exist_\(UUID().uuidString).json")
    let s = KnowledgeGraphStore.load(path: tmp)
    #expect(s.entities.isEmpty)
    #expect(s.edges.isEmpty)
    // Envelope is still well-formed.
    guard case .object(let env) = s.allEntities(page: 0) else { Issue.record("env"); return }
    #expect(env["total_entities"] == .int(0))
}

@Test func loadFromDiskRoundTrips() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_\(UUID().uuidString).json")
    let data = try JSONSerialization.data(withJSONObject: [
        "entities": [
            "x1": ["id": "x1", "name": "Atrium", "type": "project", "summary": "command center"]
        ],
        "edges": [],
        "version": 1,
    ])
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let s = KnowledgeGraphStore.load(path: tmp)
    #expect(s.hasEntity("x1"))
    #expect(stringField(s.searchEntities("Atrium").first ?? .null, "id") == "x1")
}

// MARK: - Factory routing

@Test func factoryReturnsSwiftNative() async {
    let reader = makeKnowledgeGraphReader()
    #expect(reader is SwiftNativeKnowledgeGraphReader)
}

// MARK: - Disk reads

@Test func nilFlushURLReadStillReturnsDiskState() async throws {
    // With no flush URL the barrier is a no-op; the read must still serve the
    // on-disk envelope (proves the barrier is non-blocking and read-safe).
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_nobar_\(UUID().uuidString).json")
    let json = """
    {"entities": {
        "n1": {"id": "n1", "name": "Barrier", "type": "concept"}
    }, "edges": [], "version": 1}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: tmp, flushURL: nil)
    let env = try #require(await reader.allEntities(page: 0))
    if case .object(let dict) = env, case .int(let total)? = dict["total_entities"] {
        #expect(total == 1)
    } else {
        Issue.record("expected total_entities=1 envelope")
    }
}

@Test func nonZeroPageReadsDiskWhenNoDaemon() async throws {
    // With a nil flush URL (test / no-live-daemon path) the verify sandwich is
    // skipped and the reader reads disk directly — for ANY page, including > 0.
    // Two entities; page 1 with the daemon's default page_size=100 is empty.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_pg_\(UUID().uuidString).json")
    let json = """
    {"entities": {
        "a1": {"id": "a1", "name": "Alpha", "type": "concept"},
        "b2": {"id": "b2", "name": "Beta", "type": "concept"}
    }, "edges": [], "version": 1}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: tmp, flushURL: nil)
    let env = try #require(await reader.allEntities(page: 1))
    if case .object(let dict) = env,
       case .int(let total)? = dict["total_entities"],
       case .array(let ents)? = dict["entities"],
       case .int(let pg)? = dict["page"] {
        #expect(total == 2)        // total still reflects the whole graph
        #expect(ents.isEmpty)      // page 1 (size 100) is past the 2 entities
        #expect(pg == 1)
    } else {
        Issue.record("expected page-1 envelope with total_entities=2, empty entities")
    }
}

// MARK: - WAVE 32 W04: deterministic freshness (commit-seq marker)

@Test func storeReadsCommitSeqFromFile() throws {
    // The daemon stamps a top-level "_commit_seq" into the file on every write.
    // The store must surface it so the reader can verify the disk view is fresh.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_seq_\(UUID().uuidString).json")
    let json = """
    {"entities": {"a": {"id": "a", "name": "Alpha", "type": "concept"}},
     "edges": [], "version": 1, "_commit_seq": 42}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let s = KnowledgeGraphStore.load(path: tmp)
    #expect(s.commitSeq == 42)
}

@Test func storeCommitSeqDefaultsToZeroWhenFieldAbsent() throws {
    // Files written by a daemon predating the field (or missing/garbage values)
    // yield commitSeq 0 — which fails the `>=` check against any positive reported
    // seq, so the reader defers to HTTP rather than serving an unverifiable view.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_noseq_\(UUID().uuidString).json")
    let json = """
    {"entities": {"a": {"id": "a", "name": "Alpha", "type": "concept"}},
     "edges": [], "version": 1}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(KnowledgeGraphStore.load(path: tmp).commitSeq == 0)
}

@Test func commitSeqParsesIntDoubleStringMirroringDaemon() {
    // Mirror the daemon's max(0, int(... or 0)) restore: int -> itself,
    // double -> floored, numeric string -> parsed, garbage/missing -> 0,
    // negatives clamp to 0.
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .int(7)]) == 7)
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .double(9.0)]) == 9)
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .string("13")]) == 13)
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .string("nope")]) == 0)
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .int(-5)]) == 0)
    #expect(KnowledgeGraphStore.commitSeq(from: [:]) == 0)
    #expect(KnowledgeGraphStore.commitSeq(from: ["_commit_seq": .null]) == 0)
}

@Test func nilFlushReaderServesFileCarryingCommitSeq() async throws {
    // With no daemon URL the handshake returns clean=true, reportedSeq=0; a file
    // carrying any seq (>=0) passes the gate and is served. This is the test /
    // no-live-daemon path: no Python process is concurrently writing, so the disk
    // view is authoritative.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_nilflush_\(UUID().uuidString).json")
    let json = """
    {"entities": {"a": {"id": "a", "name": "Alpha", "type": "concept"}},
     "edges": [], "version": 1, "_commit_seq": 5}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: tmp, flushURL: nil)
    let env = try #require(await reader.allEntities(page: 0))
    if case .object(let dict) = env, case .int(let total)? = dict["total_entities"] {
        #expect(total == 1)
    } else {
        Issue.record("expected total_entities=1 envelope")
    }
    // search + entity also serve through the gate with a nil flush.
    let s = try #require(await reader.search(q: "Alpha"))
    if case .object(let o) = s, case .array(let r)? = o["results"] {
        #expect(stringField(r.first ?? .null, "id") == "a")
    } else { Issue.record("expected search results") }
    if case .found? = await reader.entity(id: "a") {} else { Issue.record("expected found") }
}

// MARK: - Regression: gpt-5.5 review findings

@Test func loadPreservesFileKeyOrderForPagination() throws {
    // Keys deliberately NOT in lexicographic order so we can tell the byte-scan
    // (insertion order) apart from a .sorted() fallback.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_order_\(UUID().uuidString).json")
    let json = """
    {"entities": {
        "zeta": {"id": "zeta", "name": "Zeta", "type": "concept"},
        "alpha": {"id": "alpha", "name": "Alpha", "type": "concept"},
        "mid": {"id": "mid", "name": "Mid", "type": "concept"}
    }, "edges": [], "version": 1}
    """
    try json.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let s = KnowledgeGraphStore.load(path: tmp)
    // entityOrder must follow FILE order, not sorted order.
    #expect(s.entityOrder == ["zeta", "alpha", "mid"])
    // page 0 size 1 -> first file entity (zeta), not sorted-first (alpha).
    guard case .object(let p0) = s.allEntities(page: 0, pageSize: 1),
          case .array(let e0)? = p0["entities"] else { Issue.record("p0"); return }
    #expect(stringField(e0.first ?? .null, "id") == "zeta")
}

@Test func extractEntitiesKeyOrderScansNestedObjects() {
    // Entity values themselves contain nested objects/arrays + braces in strings;
    // the depth-aware scanner must still return only the top-level entity keys.
    let json = """
    {"version": 1, "entities": {
        "e1": {"id": "e1", "name": "A {brace} in string", "aliases": ["x","y"], "meta": {"k": 1}},
        "e2": {"id": "e2", "name": "B", "tags": [{"t": "z"}]}
    }, "edges": [{"from": "e1", "to": "e2", "type": "rel"}]}
    """
    let order = KnowledgeGraphStore.extractEntitiesKeyOrder(from: json.data(using: .utf8)!)
    #expect(order == ["e1", "e2"])
}

@Test func mentionCountNegativeReducesScore() {
    // Two entities matching "Widget" by exact name; the one with a NEGATIVE
    // mention_count must score LOWER (Python has no lower clamp).
    let raw: [String: JSONValue] = [
        "entities": .object([
            "p": obj(["id": .string("p"), "name": .string("Widget"), "type": .string("concept"), "mention_count": .int(5)]),
            "n": obj(["id": .string("n"), "name": .string("Widget"), "type": .string("concept"), "mention_count": .int(-100)]),
        ]),
        "edges": .array([]),
    ]
    // Pin order so the tie-break can't mask the score difference: p before n.
    let s = KnowledgeGraphStore.normalize(raw, entityKeyOrder: ["p", "n"])
    let ids = s.searchEntities("Widget").compactMap { stringField($0, "id") }
    #expect(ids == ["p", "n"]) // positive-mention entity ranks first
}

@Test func allEntitiesScopesPageEdgesByEntityIdField() {
    // Two entities (id==key, the normal case). Page size 1 returns only the
    // first entity; the page-edge scope must include only edges touching that
    // entity's id FIELD (Python: page_ent_ids from e.get("id")).
    let raw: [String: JSONValue] = [
        "entities": .object([
            "a": obj(["id": .string("a"), "name": .string("One"), "type": .string("concept")]),
            "b": obj(["id": .string("b"), "name": .string("Two"), "type": .string("concept")]),
            "c": obj(["id": .string("c"), "name": .string("Three"), "type": .string("concept")]),
        ]),
        "edges": .array([
            obj(["from": .string("a"), "to": .string("b"), "type": .string("rel")]),
            obj(["from": .string("b"), "to": .string("c"), "type": .string("rel")]),
        ]),
    ]
    let s = KnowledgeGraphStore.normalize(raw, entityKeyOrder: ["a", "b", "c"])
    // Page 0 size 1 -> entity "a"; only the a->b edge touches "a".
    guard case .object(let p0) = s.allEntities(page: 0, pageSize: 1),
          case .array(let e0)? = p0["edges"] else { Issue.record("p0"); return }
    #expect(e0.count == 1)
    #expect(stringField(e0.first ?? .null, "from") == "a")
}

@Test func orphanEdgeDropUsesEntityKeysLikePython() {
    // Mirror Python _load L185: `_entity_ids = set(self._data["entities"].keys())`.
    // An edge whose endpoint is not a present entity KEY is dropped on load,
    // even if some entity's id FIELD would have matched. Pins parity with the
    // Python orphan-drop semantics (the divergence the edge-scope fix surfaced).
    let raw: [String: JSONValue] = [
        "entities": .object([
            "k1": obj(["id": .string("real1"), "name": .string("One"), "type": .string("concept")]),
        ]),
        "edges": .array([
            // references id-field "real1", which is NOT a key -> orphan-dropped.
            obj(["from": .string("real1"), "to": .string("real1"), "type": .string("rel")]),
        ]),
    ]
    let s = KnowledgeGraphStore.normalize(raw)
    #expect(s.edges.isEmpty)
}

@Test func nonStringFalsyNameIsDropped() {
    // name: 0 / false / "" / [] / {} must be DROPPED (Python falsy), not kept as
    // "0"/"False".
    let raw: [String: JSONValue] = [
        "entities": .object([
            "zero": obj(["id": .string("zero"), "name": .int(0), "type": .string("concept")]),
            "false": obj(["id": .string("false"), "name": .bool(false), "type": .string("concept")]),
            "empty": obj(["id": .string("empty"), "name": .string(""), "type": .string("concept")]),
            "good": obj(["id": .string("good"), "name": .string("Good"), "type": .string("concept")]),
        ]),
        "edges": .array([]),
    ]
    let s = KnowledgeGraphStore.normalize(raw)
    #expect(Set(s.entityOrder) == ["good"])
}

@Test func emptyQuerySearchReturnsNilFromReader() async {
    let reader = SwiftNativeKnowledgeGraphReader(graphPath:
        URL(fileURLWithPath: "/nonexistent/kg.json"))
    // Empty / whitespace query -> nil (caller falls through to HTTP 400 path).
    #expect(await reader.search(q: "") == nil)
    #expect(await reader.search(q: "   ") == nil)
}

@Test func swiftNativeReaderServesEnvelopesFromDisk() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_\(UUID().uuidString).json")
    let data = try JSONSerialization.data(withJSONObject: [
        "entities": [
            "a": ["id": "a", "name": "Alpha", "type": "concept"],
            "b": ["id": "b", "name": "Beta", "type": "concept"],
        ],
        "edges": [["from": "a", "to": "b", "type": "rel"]],
        "version": 1,
    ])
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: tmp)

    guard case .object(let all)? = await reader.allEntities(page: 0) else {
        Issue.record("all"); return
    }
    #expect(all["total_entities"] == .int(2))

    guard case .object(let searchEnv)? = await reader.search(q: "Alpha"),
          case .array(let results)? = searchEnv["results"] else {
        Issue.record("search"); return
    }
    #expect(stringField(results.first ?? .null, "id") == "a")

    let ent = await reader.entity(id: "a")
    if case .found(let env)? = ent {
        #expect(stringField(env, "entity") == nil) // entity is an object, not a string
        if case .object(let o) = env { #expect(stringField(o["entity"] ?? .null, "id") == "a") }
    } else { Issue.record("expected found") }

    let missing = await reader.entity(id: "zzz")
    if case .notFound? = missing {} else { Issue.record("expected notFound") }
}

// MARK: - Swift-native MemoryV2 -> KG indexing

@Test func memoryIndexerExtractsEntitiesAndEmbeddingTextIntoSQLiteKG() async throws {
    let dir = try tempMemoryDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)

    try await indexer.indexMemory(KnowledgeGraphMemoryFact(
        id: "mem-kg-1",
        content: "the user uses NativeAgent with Agent on Swift and CoreML.",
        source: "unit",
        status: "active",
        createdAt: "2026-06-04T00:00:00Z",
        updatedAt: "2026-06-04T00:00:00Z"
    ))

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    let native = try #require(graph.searchEntities("NativeAgent").first {
        stringField($0, "name") == "NativeAgent"
    })
    #expect(stringField(native, "embedding_text") == "project: NativeAgent")
    #expect(stringField(native, "last_memory_id") == "mem-kg-1")

    let user = try #require(graph.searchEntities("the user").first {
        stringField($0, "name") == "the user"
    })
    let userID = try #require(stringField(user, "id"))
    let nativeID = try #require(stringField(native, "id"))
    guard case .object(let neighbors) = graph.neighbors(userID),
          case .array(let edges)? = neighbors["edges"] else {
        Issue.record("expected user neighbors envelope")
        return
    }
    let hasMentionEdge = edges.contains { edge in
        guard case .object(let e) = edge else { return false }
        return e["from"] == .string(userID)
            && e["to"] == .string(nativeID)
            && e["type"] == .string("mentions")
    }
    #expect(hasMentionEdge)
}

@Test func memoryIndexerIsIdempotentForSameMemoryContent() async throws {
    let dir = try tempMemoryDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let fact = KnowledgeGraphMemoryFact(
        id: "mem-kg-repeat",
        content: "the user uses NativeAgent with Agent on Swift and CoreML.",
        source: "unit",
        status: "active",
        createdAt: "2026-06-04T00:00:00Z",
        updatedAt: "2026-06-04T00:00:00Z"
    )

    try await indexer.indexMemory(fact)
    try await indexer.indexMemory(fact)

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    let native = try #require(graph.searchEntities("NativeAgent").first {
        stringField($0, "name") == "NativeAgent"
    })
    #expect(intField(native, "mention_count") == 1)
}

@Test func memoryIndexerCreatesSearchableFactNodeWithProvenanceAndEdges() async throws {
    let dir = try tempMemoryDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)

    try await indexer.indexMemory(KnowledgeGraphMemoryFact(
        id: "mem-kg-fact-1",
        content: "the user prefers snappy Telegram replies from Agent and values fast chat context.",
        source: "unit",
        status: "active",
        createdAt: "2026-06-17T00:00:00Z",
        updatedAt: "2026-06-17T00:00:00Z",
        metadata: .object(["kind": .string("preference")])
    ))

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    let fact = try #require(graph.searchEntities("snappy replies").first {
        stringField($0, "type") == "fact"
    })
    #expect(stringField(fact, "memory_id") == "mem-kg-fact-1")
    #expect(stringField(fact, "fact_kind") == "preference")
    #expect(stringField(fact, "last_memory_source") == "unit")

    let user = try #require(graph.searchEntities("the user").first {
        stringField($0, "name") == "the user"
    })
    let telegram = try #require(graph.searchEntities("Telegram").first {
        stringField($0, "name") == "Telegram"
    })
    let userID = try #require(stringField(user, "id"))
    let factID = try #require(stringField(fact, "id"))
    let telegramID = try #require(stringField(telegram, "id"))

    guard case .object(let userNeighbors) = graph.neighbors(userID),
          case .array(let userEdges)? = userNeighbors["edges"] else {
        Issue.record("expected user neighbors envelope")
        return
    }
    #expect(userEdges.contains { edge in
        guard case .object(let e) = edge else { return false }
        return e["from"] == .string(userID)
            && e["to"] == .string(factID)
            && e["type"] == .string("prefers")
    })

    guard case .object(let factNeighbors) = graph.neighbors(factID),
          case .array(let factEdges)? = factNeighbors["edges"] else {
        Issue.record("expected fact neighbors envelope")
        return
    }
    #expect(factEdges.contains { edge in
        guard case .object(let e) = edge else { return false }
        return e["from"] == .string(factID)
            && e["to"] == .string(telegramID)
            && e["type"] == .string("mentions")
    })
}

@Test func memoryIndexerDeletesMemoryFactNodeWithMemoryDelete() async throws {
    let dir = try tempMemoryDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sqlitePath = dir.appendingPathComponent("memory.sqlite")
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
    let fact = KnowledgeGraphMemoryFact(
        id: "mem-kg-delete-fact",
        content: "the user prefers snappy context in NativeAgent.",
        source: "unit",
        status: "active",
        createdAt: "2026-06-17T00:00:00Z",
        updatedAt: "2026-06-17T00:00:00Z",
        metadata: .object(["kind": .string("preference")])
    )

    try await indexer.indexMemory(fact)
    try await indexer.indexMemory(fact, deleted: true)

    let graph = try await KnowledgeGraphStore.loadFromMemoryV2(memoryDir: dir, jsonImportPath: nil)
    #expect(!graph.searchEntities("snappy context").contains {
        stringField($0, "type") == "fact"
            && stringField($0, "memory_id") == "mem-kg-delete-fact"
    })
}

// MARK: - Regression: wave-30 gpt-5.5 review findings (parity hardening)

@Test func searchTrimsNewlinesLikePythonStrip() {
    // Python `q.lower().strip()` strips ALL whitespace incl. \n/\t, so the
    // exact-name bonus must still fire for a newline-wrapped query. Earlier the
    // Swift trim used .whitespaces (no newlines), dropping the exact bonus.
    let raw: [String: JSONValue] = [
        "entities": .object([
            "e": obj(["id": .string("e"), "name": .string("NativeAgent"), "type": .string("project")]),
            // A summary-only match for the SAME token, so without the exact-name
            // bonus the ranking/score would change observably.
            "o": obj(["id": .string("o"), "name": .string("Other"), "type": .string("concept"),
                      "summary": .string("mentions nativeagent in passing")]),
        ]),
        "edges": .array([]),
    ]
    let s = KnowledgeGraphStore.normalize(raw, entityKeyOrder: ["e", "o"])
    let wrapped = s.searchEntities("\n\tNativeAgent\n")
    let plain = s.searchEntities("NativeAgent")
    #expect(wrapped.compactMap { stringField($0, "id") } == plain.compactMap { stringField($0, "id") })
    // e (exact name) must rank first even with the newline-wrapped query.
    #expect(stringField(wrapped.first ?? .null, "id") == "e")
}

@Test func allEntitiesReaderClampsNegativePageEcho() async throws {
    // The daemon ROUTE does `max(0, int(page))` BEFORE calling all_entities, so
    // a negative page echoes back as 0 over HTTP. The native READER reproduces
    // that route-level clamp (the store METHOD itself is unclamped, mirroring the
    // Python method which echoes a raw negative page). Verify at the reader/route
    // boundary, which is what the Mac UI actually calls.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kg_negpage_\(UUID().uuidString).json")
    let data = try JSONSerialization.data(withJSONObject: [
        "entities": ["a": ["id": "a", "name": "Alpha", "type": "concept"]],
        "edges": [], "version": 1,
    ])
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let reader = SwiftNativeKnowledgeGraphReader(graphPath: tmp)
    guard case .object(let env)? = await reader.allEntities(page: -3) else {
        Issue.record("not obj"); return
    }
    #expect(env["page"] == .int(0))
    if case .array(let ents)? = env["entities"] { #expect(!ents.isEmpty) }
}

@Test func storeAllEntitiesEchoesRawPageLikePythonMethod() {
    // The store METHOD is a faithful port of the Python all_entities METHOD,
    // which does NOT clamp — it echoes the raw page (only the route clamps).
    let s = store(fixtureRaw)
    guard case .object(let env) = s.allEntities(page: -3, pageSize: 100) else {
        Issue.record("not obj"); return
    }
    #expect(env["page"] == .int(-3))
}

@Test func falsyTypeKindDefaultsToConceptLikePython() {
    // Python `str(e.get("type") or "").strip()` collapses 0/false/"" to "" first,
    // so an entity {name:"x", kind:0} defaults to type "concept" — NOT "0".
    let raw: [String: JSONValue] = [
        "entities": .object([
            "zk": obj(["id": .string("zk"), "name": .string("ZeroKind"), "kind": .int(0)]),
            "fk": obj(["id": .string("fk"), "name": .string("FalseKind"), "type": .bool(false)]),
        ]),
        "edges": .array([]),
    ]
    let s = KnowledgeGraphStore.normalize(raw, entityKeyOrder: ["zk", "fk"])
    if case .object(let zk)? = s.entities["zk"] {
        #expect(zk["type"] == .string("concept"))
        #expect(zk["provenance"] == .string("default-concept"))
        // Python's entity normalizer only pops "kind" in the type_s / kind_s
        // branches; the default-concept (else) branch leaves the original key
        // intact. kind:0 was falsy (-> default-concept), so kind:0 STAYS. We
        // mirror that exactly (KnowledgeGraph.swift normalize else-branch).
        #expect(zk["kind"] == .int(0))
    } else { Issue.record("zk missing") }
    if case .object(let fk)? = s.entities["fk"] {
        #expect(fk["type"] == .string("concept")) // type:false -> "" -> concept
    } else { Issue.record("fk missing") }
}

@Test func nonStringEdgeEndpointIsOrphanDroppedLikePython() {
    // Python orphan-drop compares the RAW endpoint value against the set of
    // string entity KEYS, so a non-string endpoint (int 1) never matches key
    // "1" and the edge is dropped — even though the entity key "1" exists.
    let raw: [String: JSONValue] = [
        "entities": .object([
            "1": obj(["id": .string("1"), "name": .string("One"), "type": .string("concept")]),
            "2": obj(["id": .string("2"), "name": .string("Two"), "type": .string("concept")]),
        ]),
        "edges": .array([
            // int endpoints — would stringify to "1"/"2" under the old view and
            // wrongly survive; Python drops them (raw int never matches str key).
            obj(["from": .int(1), "to": .int(2), "type": .string("rel")]),
        ]),
    ]
    let s = KnowledgeGraphStore.normalize(raw, entityKeyOrder: ["1", "2"])
    #expect(s.edges.isEmpty)
    // A string-endpoint edge between the same entities DOES survive.
    let raw2: [String: JSONValue] = [
        "entities": .object([
            "1": obj(["id": .string("1"), "name": .string("One"), "type": .string("concept")]),
            "2": obj(["id": .string("2"), "name": .string("Two"), "type": .string("concept")]),
        ]),
        "edges": .array([obj(["from": .string("1"), "to": .string("2"), "type": .string("rel")])]),
    ]
    let s2 = KnowledgeGraphStore.normalize(raw2, entityKeyOrder: ["1", "2"])
    #expect(s2.edges.count == 1)
}

// ── WAVE 37 W15 — forget WRITE port (KnowledgeGraph+Write.swift) ─────────────

/// Write a knowledge_graph.json fixture into a fresh temp dir and return its URL.
private func writeKGFixture(_ doc: JSONValue) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kgforget-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("knowledge_graph.json")
    try doc.serializedData(pretty: true).write(to: path)
    return path
}

@Test func completeSnapshotWalksEveryPageAndDeduplicatesScopedEdges() async throws {
    var entities: [String: JSONValue] = [:]
    var edges: [JSONValue] = []
    for index in 0..<205 {
        let id = String(format: "entity-%03d", index)
        entities[id] = obj([
            "id": .string(id),
            "name": .string("Entity \(index)"),
            "type": .string("concept"),
        ])
        if index > 0 {
            let previous = String(format: "entity-%03d", index - 1)
            edges.append(obj([
                "from": .string(previous),
                "to": .string(id),
                "type": .string("next"),
            ]))
        }
    }
    let path = try writeKGFixture(.object([
        "entities": .object(entities),
        "edges": .array(edges),
        "version": .int(1),
    ]))
    let snapshot = try await SwiftNativeKnowledgeGraphReader(graphPath: path)
        .completeSnapshotChecked()
    guard case .object(let envelope) = snapshot,
          case .array(let projectedEntities)? = envelope["entities"],
          case .array(let projectedEdges)? = envelope["edges"] else {
        Issue.record("complete snapshot envelope was malformed")
        return
    }
    #expect(projectedEntities.count == 205)
    #expect(projectedEdges.count == 204)
    #expect(envelope["total_entities"] == .int(205))
    #expect(envelope["total_edges"] == .int(204))
}

@Test func completeSnapshotFailsClosedWhenItsPageBoundCannotReachTheDeclaredTotal() async throws {
    var entities: [String: JSONValue] = [:]
    for index in 0..<101 {
        let id = "entity-\(index)"
        entities[id] = obj([
            "id": .string(id),
            "name": .string("Entity \(index)"),
            "type": .string("concept"),
        ])
    }
    let path = try writeKGFixture(.object([
        "entities": .object(entities),
        "edges": .array([]),
        "version": .int(1),
    ]))
    do {
        _ = try await SwiftNativeKnowledgeGraphReader(graphPath: path)
            .completeSnapshotChecked(maxPages: 1)
        Issue.record("bounded snapshot unexpectedly accepted a partial graph")
    } catch KnowledgeGraphReadError.paginationLimitExceeded(let limit) {
        #expect(limit == 1)
    }
}

@Test func forgetEntityRemovesEntityAndIncidentEdgesAndBumpsSeq() async throws {
    let doc: JSONValue = .object([
        "entities": .object([
            "a": obj(["id": .string("a"), "name": .string("Alpha"), "type": .string("concept")]),
            "b": obj(["id": .string("b"), "name": .string("Beta"), "type": .string("concept")]),
            "c": obj(["id": .string("c"), "name": .string("Gamma"), "type": .string("concept")]),
        ]),
        "edges": .array([
            obj(["from": .string("a"), "to": .string("b"), "type": .string("rel")]), // touches a -> drop
            obj(["from": .string("c"), "to": .string("a"), "type": .string("rel")]), // touches a -> drop
            obj(["from": .string("b"), "to": .string("c"), "type": .string("rel")]), // survives
        ]),
        "version": .int(1),
        "_commit_seq": .int(7),
    ])
    let path = try writeKGFixture(doc)
    let client = SwiftNativeKnowledgeGraphForgetClient(graphPath: path)

    let result = try await client.forgetEntity(entityId: "a", reason: "test cleanup")
    // Byte-faithful success body (forget_entity L649).
    #expect(result == .object([
        "ok": .bool(true),
        "forgotten": .string("a"),
        "reason": .string("test cleanup"),
    ]))

    // Re-read the file and assert the mutation persisted.
    let after = try JSONValue.parse(Data(contentsOf: path))
    guard case .object(let root) = after,
          case .object(let entities)? = root["entities"],
          case .array(let edges)? = root["edges"] else {
        Issue.record("post-forget file malformed"); return
    }
    #expect(entities["a"] == nil)           // entity gone
    #expect(entities["b"] != nil)           // others intact
    #expect(entities["c"] != nil)
    #expect(edges.count == 1)               // only b->c survives
    if case .object(let e) = edges[0] {
        #expect(e["from"] == .string("b"))
        #expect(e["to"] == .string("c"))
    } else { Issue.record("surviving edge malformed") }
    // _commit_seq bumped 7 -> 8 (matches _flush_locked bump+stamp).
    #expect(SwiftNativeKnowledgeGraphForgetClient.commitSeq(from: root["_commit_seq"]) == 8)
}

@Test func forgetUnknownEntityReturnsNotFoundAndDoesNotWrite() async throws {
    let doc: JSONValue = .object([
        "entities": .object([
            "a": obj(["id": .string("a"), "name": .string("Alpha"), "type": .string("concept")]),
        ]),
        "edges": .array([]),
        "version": .int(1),
        "_commit_seq": .int(3),
    ])
    let path = try writeKGFixture(doc)
    let before = try Data(contentsOf: path)
    let client = SwiftNativeKnowledgeGraphForgetClient(graphPath: path)

    let result = try await client.forgetEntity(entityId: "ghost", reason: "")
    #expect(result == .object(["error": .string("not_found")]))
    // Not-found is a pure read: the file MUST be byte-unchanged (no seq bump,
    // matching the daemon's early `return {"error": "not_found"}` before _save).
    let after = try Data(contentsOf: path)
    #expect(before == after)
}

@Test func forgetEntityOnMissingFileReturnsNotFound() async throws {
    // No fixture written — the empty-graph skeleton has no entities, so any id is
    // not_found (matches the daemon's boot skeleton).
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kgforget-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("knowledge_graph.json")
    let client = SwiftNativeKnowledgeGraphForgetClient(graphPath: path)
    let result = try await client.forgetEntity(entityId: "a", reason: "")
    #expect(result == .object(["error": .string("not_found")]))
}

@Test func forgetFactoryReturnsSwiftNative() async {
    let client = makeKnowledgeGraphForgetClient(
        graphPath: URL(fileURLWithPath: "/tmp/never.json")
    )
    #expect(client is SwiftNativeKnowledgeGraphForgetClient)
}
