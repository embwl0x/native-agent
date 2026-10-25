// Checked reads from the canonical MemoryV2 SQLite graph, with legacy JSON
// compatibility only before SQLite exists. An unreadable store throws.
//
// The SwiftNative reader returns the SAME envelopes the daemon routes do:
//   all  -> {"entities": [...], "edges": [...], "total_entities", "total_edges", "page"}
//   search -> {"results": [...]}
//   entity -> {"entity": {...}|null, "edges": [...], "neighbors": {...}}
// Entity/edge objects are passthrough from the stored file (no field
// reshaping), so the Mac decode models (KGEntity / KGEntityResponse /
// KGSearchResponse / KGNeighborsResponse) decode them identically.
//
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: one checked backend admission for bounded single and batched SQLite reads, optional entity enrichment and immutable legacy snapshots |

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

extension SwiftNativeKnowledgeGraphReader {
    /// Page one immutable legacy store, preserving insertion order and
    /// deduplicating cross-page edges without re-reading its JSON file.
    private func completeSnapshotByPagingChecked(
        store: KnowledgeGraphStore, maxPages: Int
    ) async throws -> JSONValue {
        let pageLimit = max(1, maxPages)
        var entities: [JSONValue] = []
        var edges: [JSONValue] = []
        var seenEdges = Set<String>()
        var expectedEntities: Int?

        for page in 0..<pageLimit {
            try Task.checkCancellation()
            guard case .object(let envelope) = store.allEntities(page: page),
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
        case .double(let value): return Int(exactly: value.rounded(.towardZero))
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

public struct SwiftNativeKnowledgeGraphReader: Sendable {
    /// Absolute path to `<dataRoot>/memory/knowledge_graph.json`.
    public let graphPath: URL

    public init(graphPath: URL) {
        self.graphPath = graphPath
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
    private func readChecked<T: Sendable>(
        sqlite: @Sendable (URL) async throws -> T,
        legacy: @Sendable (KnowledgeGraphStore) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let memoryDir = graphPath.deletingLastPathComponent()
        let sqlitePath = memoryDir.appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: sqlitePath.path) {
            do {
                return try await sqlite(memoryDir)
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                // Deleted between the existence check and pool open: use the
                // same pre-SQLite compatibility as an initially missing file.
            }
        }
        return try await legacy(KnowledgeGraphStore.loadChecked(path: graphPath))
    }

    public func allEntitiesChecked(page: Int) async throws -> JSONValue {
        try await readChecked { memoryDir in
            try await KnowledgeGraphStore.pageFromMemoryV2(
                memoryDir: memoryDir, jsonImportPath: graphPath, page: page
            )
        } legacy: { store in
            // Reproduce the daemon route's max(0, int(page)) clamp.
            store.allEntities(page: max(0, page))
        }
    }

    public func searchChecked(q: String) async throws -> JSONValue {
        try await readChecked { memoryDir in
            try await KnowledgeGraphStore.searchFromMemoryV2(
                memoryDir: memoryDir, jsonImportPath: graphPath, query: q
            )
        } legacy: { store in
            .object(["results": .array(store.searchEntities(q))])
        }
    }

    public func entityChecked(id: String) async throws -> KnowledgeGraphEntityResult {
        try await readChecked { memoryDir in
            try await KnowledgeGraphStore.entityFromMemoryV2(
                memoryDir: memoryDir, jsonImportPath: graphPath, id: id
            )
        } legacy: { store in
            // The wired entity route returns the neighbors envelope on hit.
            guard store.hasEntity(id) else { return .notFound }
            return .found(store.neighbors(id))
        }
    }

    public func entitiesChecked(ids: [String]) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        guard !ids.isEmpty else { return [:] }
        return try await readChecked { memoryDir in
            try await KnowledgeGraphStore.entitiesFromMemoryV2(
                memoryDir: memoryDir, jsonImportPath: graphPath, ids: ids
            )
        } legacy: { store in
            var entities: [String: JSONValue] = [:]
            for id in ids where store.hasEntity(id) {
                guard case .object(let envelope) = store.neighbors(id),
                      let entity = envelope["entity"], entity != .null else { continue }
                entities[id] = entity
            }
            return entities
        }
    }

    public func completeSnapshotChecked(maxPages: Int = 500) async throws -> JSONValue {
        try await readChecked { memoryDir in
            try await KnowledgeGraphStore.completeSnapshotFromMemoryV2(
                memoryDir: memoryDir, jsonImportPath: graphPath, maxPages: maxPages
            )
        } legacy: { store in
            try await completeSnapshotByPagingChecked(store: store, maxPages: maxPages)
        }
    }
}

// MARK: - Factory

/// Returns the checked reader for the selected graph or the default data root.
public func makeKnowledgeGraphReader(
    graphPath: URL? = nil
) -> SwiftNativeKnowledgeGraphReader {
    return SwiftNativeKnowledgeGraphReader(
        graphPath: graphPath ?? SwiftNativeKnowledgeGraphReader.defaultPath()
    )
}
