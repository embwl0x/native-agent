// Read canonical graph rows through checked envelopes shared by Mac decoders; missing or unreadable storage throws.
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: bounded checked canonical reads |

// MARK: - Errors

public enum KnowledgeGraphReadError: Error, LocalizedError, Sendable {
    /// Surface unreadable storage detail verbatim to the user.
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

public enum KnowledgeGraphEntityResult: Sendable {
    case found(JSONValue)
    case notFound
}

// MARK: - SwiftNative impl

public struct SwiftNativeKnowledgeGraphReader: Sendable {
    public let graphPath: URL

    public init(graphPath: URL) {
        self.graphPath = graphPath
    }

    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    public func allEntitiesChecked(page: Int) async throws -> JSONValue {
        try Task.checkCancellation()
        return try await KnowledgeGraphStore.pageFromMemoryV2(
            memoryDir: graphPath.deletingLastPathComponent(), page: page)
    }

    public func searchChecked(q: String) async throws -> JSONValue {
        try Task.checkCancellation()
        return try await KnowledgeGraphStore.searchFromMemoryV2(
            memoryDir: graphPath.deletingLastPathComponent(), query: q)
    }

    public func entityChecked(id: String) async throws -> KnowledgeGraphEntityResult {
        try Task.checkCancellation()
        return try await KnowledgeGraphStore.entityFromMemoryV2(
            memoryDir: graphPath.deletingLastPathComponent(), id: id)
    }

    public func entitiesChecked(ids: [String]) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        guard !ids.isEmpty else { return [:] }
        return try await KnowledgeGraphStore.entitiesFromMemoryV2(
            memoryDir: graphPath.deletingLastPathComponent(), ids: ids)
    }

    public func completeSnapshotChecked(maxPages: Int = 500, surface: String? = nil, personaID: String? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        return try await KnowledgeGraphStore.completeSnapshotFromMemoryV2(
            memoryDir: graphPath.deletingLastPathComponent(), maxPages: maxPages,
            surface: surface, personaID: personaID)
    }
}

// MARK: - Factory

public func makeKnowledgeGraphReader(
    graphPath: URL? = nil
) -> SwiftNativeKnowledgeGraphReader {
    return SwiftNativeKnowledgeGraphReader(
        graphPath: graphPath ?? SwiftNativeKnowledgeGraphReader.defaultPath()
    )
}
