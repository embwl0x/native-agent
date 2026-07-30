import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

// MARK: - Phase C: Core Spotlight indexer for memory records.
//
// Carves:
//   * QUERYING Spotlight from within the app (CSUserQuery / CSSearchQuery)
//     is OUT OF SCOPE here — in-app queries still go through
//     JSONLEmbeddingStore.search. System Spotlight (cmd+space) surfaces
//     items automatically once they're indexed.
//   * On platforms without CoreSpotlight (Linux / CI), the system backend
//     is unavailable; tests use MockSpotlightIndexClient.
//   * CSSearchableItemAttributeSet has dozens of richer fields
//     (location/image/contact/...) — only title / contentDescription /
//     keywords are wired here.

public struct SpotlightItem: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let contentDescription: String
    public let keywords: [String]
    public let domainIdentifier: String

    public init(
        id: String,
        title: String,
        contentDescription: String,
        keywords: [String],
        domainIdentifier: String
    ) {
        self.id = id
        self.title = title
        self.contentDescription = contentDescription
        self.keywords = keywords
        self.domainIdentifier = domainIdentifier
    }
}

public protocol SpotlightIndexClient: Sendable {
    func index(_ items: [SpotlightItem]) async throws
    func delete(ids: [String]) async throws
    func deleteAll(domainIdentifier: String) async throws
}

// MARK: - System backend (CSSearchableIndex)

#if canImport(CoreSpotlight) && !os(Linux)
public final class SystemSpotlightIndexClient: SpotlightIndexClient, @unchecked Sendable {
    public init() {}

    public func index(_ items: [SpotlightItem]) async throws {
        let mapped: [CSSearchableItem] = items.map { item in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = item.title
            attrs.contentDescription = item.contentDescription
            attrs.keywords = item.keywords
            return CSSearchableItem(
                uniqueIdentifier: item.id,
                domainIdentifier: item.domainIdentifier,
                attributeSet: attrs
            )
        }
        try await CSSearchableIndex.default().indexSearchableItems(mapped)
    }

    public func delete(ids: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids)
    }

    public func deleteAll(domainIdentifier: String) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }
}
#endif

// MARK: - In-memory mock for tests

public actor MockSpotlightIndexClient: SpotlightIndexClient {
    public private(set) var indexed: [String: SpotlightItem] = [:]

    public init() {}

    public func index(_ items: [SpotlightItem]) async throws {
        for item in items {
            indexed[item.id] = item
        }
    }

    public func delete(ids: [String]) async throws {
        for id in ids {
            indexed.removeValue(forKey: id)
        }
    }

    public func deleteAll(domainIdentifier: String) async throws {
        let prefix = domainIdentifier + "."
        for (id, item) in indexed where item.domainIdentifier == domainIdentifier || item.domainIdentifier.hasPrefix(prefix) {
            indexed.removeValue(forKey: id)
        }
    }

    public func snapshot() async -> [String: SpotlightItem] {
        indexed
    }
}

// MARK: - SwiftNativeMemoryIndexer
//
// Bridges MemoryRecord-ish tuples into SpotlightItem and pushes them through
// a SpotlightIndexClient. Stays minimal — Phase C is just "the index path
// exists and round-trips"; richer attribute-set fields land later.
public actor SwiftNativeMemoryIndexer {
    private let client: any SpotlightIndexClient
    private let domain: String

    public init(client: any SpotlightIndexClient, domain: String = "memory.nativeagent") {
        self.client = client
        self.domain = domain
    }

    public func indexRecord(id: String, text: String, kind: String?) async throws {
        let item = Self.makeItem(id: id, text: text, kind: kind, domain: domain)
        try await client.index([item])
    }

    public func indexBatch(_ records: [(id: String, text: String, kind: String?)]) async throws {
        let items = records.map { Self.makeItem(id: $0.id, text: $0.text, kind: $0.kind, domain: domain) }
        try await client.index(items)
    }

    public func remove(id: String) async throws {
        try await client.delete(ids: [id])
    }

    public func removeAll() async throws {
        try await client.deleteAll(domainIdentifier: domain)
    }

    private static func makeItem(id: String, text: String, kind: String?, domain: String) -> SpotlightItem {
        let title = String(text.prefix(80))
        let keywords: [String] = kind.map { [$0] } ?? []
        return SpotlightItem(
            id: id,
            title: title,
            contentDescription: text,
            keywords: keywords,
            domainIdentifier: domain
        )
    }
}
