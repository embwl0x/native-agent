// Reader protocol + factory for the read-only KnowledgeGraph query surface.
//
// Mirrors the wave-pattern used by MacAssistantStatus / CommandPalette:
//   - a `KnowledgeGraphReader` protocol with the three read calls,
//   - `SwiftNativeKnowledgeGraphReader` (reads the Swift MemoryV2 SQLite KG,
//     falling back to the local JSON file when SQLite has not been initialized),
//   - `makeKnowledgeGraphReader()` factory.
//
// The SwiftNative reader returns the SAME envelopes the daemon routes do:
//   all  -> {"entities": [...], "edges": [...], "total_entities", "total_edges", "page"}
//   search -> {"results": [...]}
//   entity -> {"entity": {...}|null, "edges": [...], "neighbors": {...}}
// Entity/edge objects are passthrough from the stored file (no field
// reshaping), so the Mac decode models (KGEntity / KGEntityResponse /
// KGSearchResponse / KGNeighborsResponse) decode them identically.
//
// U5 W-C (2026-06-11) — empty-vs-error:
//   - The protocol gains THROWING variants (`allEntitiesChecked` /
//     `searchChecked` / `entityChecked`) with default implementations, so
//     existing conformers and the optional-returning call sites
//     (SwiftToolDispatcher search_kg, MCPSubprocessClient) keep compiling
//     unchanged. New/honest callers (KnowledgeGraphView) use the checked
//     variants and surface the error.
//   - An UNREADABLE memory.sqlite now propagates as an error. It must never
//     fall back to the (possibly months-stale) knowledge_graph.json — that
//     was the resurrected-entities bug: corrupt DB silently rendered the
//     June-2 JSON snapshot as a healthy graph.
//   - A MISSING memory.sqlite (fresh install, test fixture) still falls back
//     to the JSON file; a missing JSON file is a legitimate empty graph.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Errors

public enum KnowledgeGraphReadError: Error, LocalizedError, Sendable {
    /// The backing store exists but could not be read. The associated detail
    /// is human-renderable (KnowledgeGraphView shows it verbatim).
    case storeUnreadable(String)
    case malformedEnvelope(String)
    case paginationLimitExceeded(Int)
    case queryLimitExceeded(maximumBytes: Int, maximumTokens: Int)
    case relationshipLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .storeUnreadable(let detail):
            return "Knowledge graph store could not be read: \(detail)"
        case .malformedEnvelope(let detail):
            return "Knowledge graph projection was malformed: \(detail)"
        case .paginationLimitExceeded(let limit):
            return "Knowledge graph projection exceeded its \(limit)-page safety bound"
        case .queryLimitExceeded(let bytes, let tokens):
            return "Knowledge graph query exceeded its safety bound (\(bytes) bytes / \(tokens) tokens)"
        case .relationshipLimitExceeded(let limit):
            return "Knowledge graph projection exceeded its \(limit)-relationship safety bound"
        }
    }
}

// MARK: - Protocol

public protocol KnowledgeGraphReader: Sendable {
    /// GET /v1/knowledge_graph?page=  — full envelope, or nil when unavailable.
    func allEntities(page: Int) async -> JSONValue?
    /// GET /v1/knowledge_graph/search?q=  — {"results": [...]}, or nil when unavailable.
    func search(q: String) async -> JSONValue?
    /// GET /v1/knowledge_graph/entity/{id}  — neighbors envelope, or nil to fall
    /// back. `notFound` distinguishes an unknown id from an unavailable native read.
    func entity(id: String) async -> KnowledgeGraphEntityResult?

    // U5 W-C: throwing variants — an unreadable store surfaces as an ERROR
    // (with detail) instead of collapsing into the nil/empty ambiguity above.
    // Default implementations are provided so existing conformers compile.
    func allEntitiesChecked(page: Int) async throws -> JSONValue
    func searchChecked(q: String) async throws -> JSONValue
    func entityChecked(id: String) async throws -> KnowledgeGraphEntityResult
    func completeSnapshotChecked(maxPages: Int) async throws -> JSONValue
}

public extension KnowledgeGraphReader {
    func allEntitiesChecked(page: Int) async throws -> JSONValue {
        guard let v = await allEntities(page: page) else {
            throw KnowledgeGraphReadError.storeUnreadable("reader unavailable")
        }
        return v
    }
    func searchChecked(q: String) async throws -> JSONValue {
        guard let v = await search(q: q) else {
            throw KnowledgeGraphReadError.storeUnreadable("reader unavailable")
        }
        return v
    }
    func entityChecked(id: String) async throws -> KnowledgeGraphEntityResult {
        guard let v = await entity(id: id) else {
            throw KnowledgeGraphReadError.storeUnreadable("reader unavailable")
        }
        return v
    }

    /// Materialize one complete, bounded read projection from the canonical
    /// graph owner. The ordinary read API is paged and scopes edges to each
    /// page, which is ideal for the Mac view but unsuitable for an iCloud
    /// snapshot. This helper walks those same checked pages, deduplicates
    /// cross-page edge appearances, and never reads the retired JSON file
    /// directly when SQLite is authoritative.
    func completeSnapshotChecked(maxPages: Int = 500) async throws -> JSONValue {
        try await completeSnapshotByPagingChecked(maxPages: maxPages)
    }

    /// Default complete-snapshot implementation for non-SQLite conformers and
    /// the legacy pre-SQLite JSON compatibility lane.
    func completeSnapshotByPagingChecked(maxPages: Int = 500) async throws -> JSONValue {
        let pageLimit = max(1, maxPages)
        var entities: [JSONValue] = []
        var edges: [JSONValue] = []
        var seenEdges = Set<String>()
        var expectedEntities: Int?

        for page in 0..<pageLimit {
            guard case .object(let envelope) = try await allEntitiesChecked(page: page),
                  case .array(let pageEntities)? = envelope["entities"] else {
                throw KnowledgeGraphReadError.malformedEnvelope(
                    "page \(page) did not contain an entities array"
                )
            }
            let total = Self.snapshotInteger(envelope["total_entities"])
                ?? Self.snapshotInteger(envelope["total"])
                ?? pageEntities.count
            if let expectedEntities, expectedEntities != total {
                throw KnowledgeGraphReadError.malformedEnvelope(
                    "entity total changed from \(expectedEntities) to \(total) during the read"
                )
            }
            expectedEntities = total
            entities.append(contentsOf: pageEntities)

            if case .array(let pageEdges)? = envelope["edges"] {
                for edge in pageEdges {
                    let identity = Self.snapshotEdgeIdentity(edge)
                    if seenEdges.insert(identity).inserted {
                        edges.append(edge)
                    }
                }
            }

            if entities.count >= total {
                return .object([
                    "entities": .array(entities),
                    "edges": .array(edges),
                    "total_entities": .int(Int64(entities.count)),
                    "total_edges": .int(Int64(edges.count)),
                    "page": .int(0),
                ])
            }
            if pageEntities.isEmpty {
                throw KnowledgeGraphReadError.malformedEnvelope(
                    "page \(page) was empty before the declared total \(total) was reached"
                )
            }
        }
        throw KnowledgeGraphReadError.paginationLimitExceeded(pageLimit)
    }

    private static func snapshotInteger(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    private static func snapshotString(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        default: return nil
        }
    }

    private static func snapshotEdgeIdentity(_ value: JSONValue) -> String {
        guard case .object(let edge) = value else {
            return "malformed:\(String(describing: value))"
        }
        if let id = snapshotString(edge["id"]), !id.isEmpty {
            return "id:\(id)"
        }
        let from = snapshotString(edge["from"]) ?? ""
        let to = snapshotString(edge["to"]) ?? ""
        let kind = snapshotString(edge["type"])
            ?? snapshotString(edge["kind"])
            ?? ""
        return "edge:\(from)\u{0}\(to)\u{0}\(kind)"
    }
}

/// Result of an entity lookup: either the neighbors envelope, or an explicit
/// not-found marker so the caller can reproduce the daemon's 404 contract.
public enum KnowledgeGraphEntityResult: Sendable {
    case found(JSONValue)
    case notFound
}

// MARK: - SwiftNative impl

public struct SwiftNativeKnowledgeGraphReader: KnowledgeGraphReader {
    /// Absolute path to `<dataRoot>/memory/knowledge_graph.json`.
    public let graphPath: URL

    public init(graphPath: URL, flushURL: URL? = nil) {
        self.graphPath = graphPath
        _ = flushURL
    }

    /// Compatibility initializer retained for tests that used to inject a flush
    /// URLSession. The Swift-only reader ignores the network arguments.
    init(graphPath: URL, flushURL: URL?, session: URLSession) {
        self.graphPath = graphPath
        _ = flushURL
        _ = session
    }

    /// Resolve the path the daemon used:
    ///   the retired daemon `_kg_path = root / "memory" / "knowledge_graph.json"`
    /// where `root` is the data root. PersistenceCore.defaultDataRoot() mirrors
    /// the daemon's data-root resolution (env NATIVE_AGENT_DATA_ROOT, literal
    /// tilde, default ~/.nativeagent).
    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    }

    /// Honest store-load policy (U5 W-C):
    ///   1. memory.sqlite present + readable              -> SQLite store,
    ///      including a legitimately empty graph. The SQLite loader performs
    ///      the one-time JSON import synchronously before it returns, so a
    ///      second fallback here could only resurrect stale legacy state.
    ///   2. memory.sqlite present + UNREADABLE            -> THROW. No JSON
    ///      fallback: stale JSON rendering as healthy is the resurrection bug.
    ///   3. memory.sqlite missing                          -> JSON; a missing
    ///      JSON file is a legitimate empty graph, a corrupt one THROWS.
    private func loadStore() async throws -> KnowledgeGraphStore {
        let memoryDir = graphPath.deletingLastPathComponent()
        let sqlitePath = memoryDir.appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: sqlitePath.path) {
            do {
                let s = try await KnowledgeGraphStore.loadFromMemoryV2(
                    memoryDir: memoryDir,
                    jsonImportPath: graphPath
                )
                return s
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // Deleted between the exists-check and the open — JSON fallback.
            }
            // NOTE: `.unreadable` (and any other error) PROPAGATES here.
        }
        return try KnowledgeGraphStore.loadChecked(path: graphPath)
    }

    public func allEntities(page: Int) async -> JSONValue? {
        try? await allEntitiesChecked(page: page)
    }

    public func search(q: String) async -> JSONValue? {
        // The daemon route returned HTTP 400 for an empty `q`
        //. In Swift-only mode an empty query returns
        // nil so the caller can surface a local unsupported/bad-request response.
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return try? await searchChecked(q: q)
    }

    public func entity(id: String) async -> KnowledgeGraphEntityResult? {
        try? await entityChecked(id: id)
    }

    public func allEntitiesChecked(page: Int) async throws -> JSONValue {
        if Task.isCancelled { throw CancellationError() }
        let memoryDir = graphPath.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: memoryDir.appendingPathComponent("memory.sqlite").path
        ) {
            do {
                return try await KnowledgeGraphStore.pageFromMemoryV2(
                    memoryDir: memoryDir,
                    jsonImportPath: graphPath,
                    page: page
                )
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // Deleted between existence check and pool open: pre-SQLite
                // JSON compatibility remains the only valid fallback.
            }
        }
        let s = try await loadStore()
        // Reproduce the daemon ROUTE's `max(0, int(page))` clamp
        // at this route-replacement boundary.
        return s.allEntities(page: max(0, page))
    }

    public func searchChecked(q: String) async throws -> JSONValue {
        if Task.isCancelled { throw CancellationError() }
        let memoryDir = graphPath.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: memoryDir.appendingPathComponent("memory.sqlite").path
        ) {
            do {
                return try await KnowledgeGraphStore.searchFromMemoryV2(
                    memoryDir: memoryDir,
                    jsonImportPath: graphPath,
                    query: q
                )
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // See allEntitiesChecked: deletion races may use legacy JSON.
            }
        }
        let s = try await loadStore()
        // searchEntities("") is [] — the empty-q 400 contract lives in the
        // optional `search(q:)` shim and in the Mac client.
        return .object(["results": .array(s.searchEntities(q))])
    }

    public func entityChecked(id: String) async throws -> KnowledgeGraphEntityResult {
        if Task.isCancelled { throw CancellationError() }
        let memoryDir = graphPath.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: memoryDir.appendingPathComponent("memory.sqlite").path
        ) {
            do {
                return try await KnowledgeGraphStore.entityFromMemoryV2(
                    memoryDir: memoryDir,
                    jsonImportPath: graphPath,
                    id: id
                )
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // See allEntitiesChecked: deletion races may use legacy JSON.
            }
        }
        let s = try await loadStore()
        // Daemon route: get_entity(id) is checked
        // first; if missing -> 404. neighbors() is what the WIRED route returns
        // for a present id. The Mac getKGEntity decodes KGNeighborsResponse, so
        // we return the neighbors envelope on hit and notFound otherwise.
        guard s.hasEntity(id) else { return .notFound }
        return .found(s.neighbors(id))
    }

    public func completeSnapshotChecked(maxPages: Int = 500) async throws -> JSONValue {
        if Task.isCancelled { throw CancellationError() }
        let memoryDir = graphPath.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: memoryDir.appendingPathComponent("memory.sqlite").path
        ) {
            do {
                return try await KnowledgeGraphStore.completeSnapshotFromMemoryV2(
                    memoryDir: memoryDir,
                    jsonImportPath: graphPath,
                    maxPages: maxPages
                )
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // Deleted between existence check and pool open.
            }
        }
        return try await completeSnapshotByPagingChecked(maxPages: maxPages)
    }
}

// MARK: - Factory

/// Returns the SwiftNative reader. `graphPath` is injectable for tests;
/// production callers omit it and get `defaultPath()`.
public func makeKnowledgeGraphReader(
    graphPath: URL? = nil
) -> any KnowledgeGraphReader {
    return SwiftNativeKnowledgeGraphReader(
        graphPath: graphPath ?? SwiftNativeKnowledgeGraphReader.defaultPath(),
        flushURL: nil
    )
}
