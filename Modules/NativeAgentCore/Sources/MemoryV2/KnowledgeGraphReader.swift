// Checked reads from the canonical MemoryV2 SQLite graph, with legacy JSON
// compatibility only before SQLite exists. An unreadable store throws.
//
// Checked graph read envelopes:
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
    /// Assemble the loaded legacy store in insertion and first-page edge order.
    private func legacySnapshotChecked(
        store: KnowledgeGraphStore, maxPages: Int
    ) throws -> JSONValue {
        try Task.checkCancellation()
        let pageLimit = max(1, maxPages)
        let count = store.entityOrder.count
        guard count / 100 + (count % 100 == 0 ? 0 : 1) <= pageLimit else {
            throw KnowledgeGraphReadError.paginationLimitExceeded(pageLimit)
        }
        let entities = store.entityOrder.compactMap { store.entities[$0] }
        var firstPageByID: [String: Int] = [:]
        for (index, entity) in entities.enumerated() {
            guard case .object(let object) = entity,
                  case .string(let id)? = object["id"], !id.isEmpty else { continue }
            if firstPageByID[id] == nil { firstPageByID[id] = index / 100 }
        }
        let orderedEdges = store.edges.enumerated().compactMap { index, edge -> (page: Int, index: Int, edge: JSONValue)? in
            guard case .object(let object) = edge else { return nil }
            let page = min(firstPageByID[Self.snapshotString(object["from"]) ?? ""] ?? .max,
                           firstPageByID[Self.snapshotString(object["to"]) ?? ""] ?? .max)
            return page == .max ? nil : (page, index, edge)
        }.sorted { $0.page == $1.page ? $0.index < $1.index : $0.page < $1.page }
        try Task.checkCancellation()
        var seenEdges = Set<String>()
        let edges = orderedEdges.compactMap { item in
            seenEdges.insert(Self.snapshotEdgeIdentity(item.edge)).inserted ? item.edge : nil
        }
        return .object([
            "entities": .array(entities), "edges": .array(edges),
            "total_entities": .int(Int64(entities.count)), "total_edges": .int(Int64(edges.count)),
            "page": .int(0),
        ])
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

/// Entity lookup yields a neighbors envelope or an explicit not-found result.
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

    /// Pre-SQLite JSON path under `PersistenceCore.defaultDataRoot()`.
    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    }

    /// Existing SQLite is authoritative, including an empty graph; its loader imports JSON once.
    /// Unreadable SQLite throws without consulting JSON.
    /// Only absent SQLite admits JSON: a missing JSON file is empty; corrupt JSON throws.
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
            // Negative pages clamp to zero.
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
            // An entity hit returns its neighbors envelope.
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
            try legacySnapshotChecked(store: store, maxPages: maxPages)
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
