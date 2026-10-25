import Foundation
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
// Blueprint: | `MemoryV2+Spotlight.swift` | Canonical generation-proven rebuild shared by launch and repair, serialized with incremental Spotlight projections before taking its snapshot; isolated roots never alter system Spotlight |
#endif

// MARK: - Phase C: Core Spotlight indexer for memory records.
//
// Carves:
//   * QUERYING Spotlight from within the app (CSUserQuery / CSSearchQuery)
//     is OUT OF SCOPE here — in-app recall goes through
//     SwiftNativeMemoryV2.recall. System Spotlight (cmd+space) surfaces
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

// MARK: - Isolated backend

public actor MockSpotlightIndexClient: SpotlightIndexClient {
    public init() {}
    public func index(_ items: [SpotlightItem]) async throws {}
    public func delete(ids: [String]) async throws {}
    public func deleteAll(domainIdentifier: String) async throws {}
}

// MARK: - SwiftNativeMemoryIndexer
//
// Bridges MemoryRecord-ish tuples into SpotlightItem and pushes them through
// a SpotlightIndexClient. Stays minimal — Phase C is just "the index path
// exists and round-trips"; richer attribute-set fields land later.
/// .spotlight_reindexed is this owner's generation fingerprint: local
/// backup/export and memory PrivacyMap, never phone sync.
public actor SwiftNativeMemoryIndexer {
    public static let defaultDomain = "memory.nativeagent"
    private let client: any SpotlightIndexClient
    private let domain: String

    public init(client: any SpotlightIndexClient, domain: String = SwiftNativeMemoryIndexer.defaultDomain) {
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

    static func makeItem(id: String, text: String, kind: String?, domain: String = defaultDomain) -> SpotlightItem {
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

extension SwiftNativeMemoryIndexer {
    public static func reindex(dataRoot: URL, client: any SpotlightIndexClient) async throws -> ReindexOutcome {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let task = await storage.enqueueSpotlightProjection {
            try await reindex(dataRoot: dataRoot, storage: storage, client: client)
        }
        return try await task.value
    }

    private static func reindex(dataRoot: URL, storage: MemoryStorage,
                                client: any SpotlightIndexClient) async throws -> ReindexOutcome {
        let marker = markerURL(dataRoot: dataRoot)
        let generation = try await storage.spotlightGenerationFingerprint()
        let memories = try await storage.listMemories(
            persona: nil,
            status: "active",
            limit: nil
        )
        // A cold write awaiting admission stays out, as the incremental hooks keep it.
        let batch = memories.filter { !MemoryStorage.metadataFlag($0.metadata, MemoryStorage.pendingAdmissionKey) }
            .map { (id: $0.id, text: $0.content, kind: $0.status as String?) }

        // Delete the old proof BEFORE clearing the derived index. A crash
        // or failure after `removeAll()` must read as unconfirmed rather
        // than reporting the old SQLite count over an empty Spotlight
        // domain.
        try clearMarker(at: marker)

        let indexer = SwiftNativeMemoryIndexer(client: client)
        try await indexer.removeAll()
        try await indexer.indexBatch(batch)

        let completedGeneration = try await storage.spotlightGenerationFingerprint()
        guard completedGeneration == generation else {
            // A concurrent canonical write makes this batch stale. There
            // is intentionally no marker. The queued incremental operations
            // repair this batch next; a future rebuild uses the new generation.
            return .changedDuringReindex
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            Data((generation + "\n").utf8),
            to: marker
        )
        return .indexed(count: batch.count)
    }

    public static func markerURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".spotlight_reindexed", isDirectory: false)
    }

    private static func clearMarker(at marker: URL) throws {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
    }

    public static func liveClient(dataRoot: URL) -> any SpotlightIndexClient {
        #if canImport(CoreSpotlight) && !os(Linux)
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            return SystemSpotlightIndexClient()
        }
        #endif
        // An injected/test root must not replace the user's system Spotlight
        // domain merely because the UI is hosted in this app process.
        return MockSpotlightIndexClient()
    }
}

/// Honest launch-only owner for the one-time Spotlight projection. MemoryV2
/// itself remains canonical; this type owns no memory state and advertises no
/// CloudKit subscription that the runtime cannot actually provide.
public actor MemorySpotlightBootstrap {
    public static let shared = MemorySpotlightBootstrap()
    private var didReindex = false
    private let dataRootOverride: URL?
    private let indexClientOverride: (any SpotlightIndexClient)?

    private init() {
        dataRootOverride = nil
        indexClientOverride = nil
    }

    /// Hermetic seam for the launch projection's exact durable behavior. The
    /// mounted app uses `shared`; an injected root never touches the user's
    /// Spotlight domain.
    public init(dataRoot: URL, indexClient: any SpotlightIndexClient) {
        dataRootOverride = dataRoot
        indexClientOverride = indexClient
    }

    /// Read every active memory through SwiftNativeMemoryV2.shared and push
    /// CSSearchableItems to the system Spotlight index. The sentinel is
    /// written only after success, so a crash retries on the next launch.
    public func reindexAll() async {
        if didReindex { return }
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let marker = SwiftNativeMemoryIndexer.markerURL(dataRoot: dataRoot)
        let storage: MemoryStorage
        do {
            storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        } catch {
            return
        }
        let generation: String
        do {
            generation = try await storage.spotlightGenerationFingerprint()
        } catch {
            return
        }
        if let markerData = try? Data(contentsOf: marker),
           String(data: markerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == generation {
            didReindex = true
            return
        }
        do {
            if case .indexed = try await SwiftNativeMemoryIndexer.reindex(
                dataRoot: dataRoot,
                client: indexClientOverride ?? SwiftNativeMemoryIndexer.liveClient(dataRoot: dataRoot)
            ) {
                didReindex = true
            }
        } catch {
            // No durable generation proof: launch must reconcile again.
        }
    }
}

extension SwiftNativeMemoryIndexer {
    public enum ReindexOutcome: Equatable, Sendable {
        case indexed(count: Int)
        case changedDuringReindex
        case failed(message: String, cause: String? = nil)
    }
}
