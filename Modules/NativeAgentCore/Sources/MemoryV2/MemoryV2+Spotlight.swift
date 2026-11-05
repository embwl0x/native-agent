import Foundation
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
import NativeAgentShared
// Blueprint: | `MemoryV2+Spotlight.swift` | generation-proven rebuilds and serialized projection |
#endif

// MARK: - Core Spotlight indexer for memory records.
// System Spotlight surfaces indexed items; in-app recall stays with MemoryV2. Keep title, description and keywords as the indexed projection; unavailable
// platforms expose no system backend.

public struct SpotlightItem: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let contentDescription: String
    public let keywords: [String]
    public let domainIdentifier: String
    public let expirationDate: Date?

    public init(
        id: String,
        title: String,
        contentDescription: String,
        keywords: [String],
        domainIdentifier: String,
        expirationDate: Date?
    ) {
        self.id = id
        self.title = title
        self.contentDescription = contentDescription
        self.keywords = keywords
        self.domainIdentifier = domainIdentifier
        self.expirationDate = expirationDate
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
            let searchable = CSSearchableItem(
                uniqueIdentifier: item.id,
                domainIdentifier: item.domainIdentifier,
                attributeSet: attrs
            )
            if let expiry = item.expirationDate { searchable.expirationDate = expiry }
            return searchable
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
/// .spotlight_reindexed is this owner's generation fingerprint: local backup/export and memory PrivacyMap, never phone sync.
public actor SwiftNativeMemoryIndexer {
    public static let defaultDomain = "memory.nativeagent"
    private let client: any SpotlightIndexClient
    private let domain: String

    public init(client: any SpotlightIndexClient, domain: String = SwiftNativeMemoryIndexer.defaultDomain) {
        self.client = client
        self.domain = domain
    }

    public func indexRecord(id: String, text: String, kind: String?, validTo: String?) async throws {
        // The canonical readback supplies the interval, not the hook's wake hint.
        try MemoryStorage.validateTemporalEvidence(id: id, validFrom: nil, validTo: validTo, observedAt: nil)
        guard MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: validTo, at: Date()) else {
            try await remove(id: id)
            return
        }
        let item = Self.makeItem(id: id, text: text, kind: kind,
                                 expirationDate: validTo.flatMap(MemoryRecallScoring.parseTimestamp), domain: domain)
        try await client.index([item])
    }

    public func remove(id: String) async throws {
        try await client.delete(ids: [id])
    }

    static func makeItem(id: String, text: String, kind: String?, expirationDate: Date?, domain: String = defaultDomain) -> SpotlightItem {
        let title = String(text.prefix(80))
        let keywords: [String] = kind.map { [$0] } ?? []
        return SpotlightItem(
            id: id,
            title: title,
            contentDescription: text,
            keywords: keywords,
            domainIdentifier: domain,
            expirationDate: expirationDate
        )
    }
}

extension SwiftNativeMemoryIndexer {
    public static func reconcileAtLaunch(dataRoot: URL) async {
        let storage: MemoryStorage
        do {
            storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        } catch {
            nativeLog("MemoryV2 Spotlight launch storage failed: %@", String(describing: error))
            return
        }
        do {
            let generation = try await storage.spotlightSnapshot().fingerprint
            if let markerData = try? Data(contentsOf: markerURL(dataRoot: dataRoot)),
               String(data: markerData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == generation { return }
        } catch {
            await recordProjectionFailure(
                "Spotlight launch fingerprint failed: \(error)", dataRoot: dataRoot, storage: storage)
            return
        }
        do {
            _ = try await reindex(dataRoot: dataRoot, client: liveClient(dataRoot: dataRoot))
        } catch {
            nativeLog("MemoryV2 Spotlight launch failed: %@", String(describing: error))
        }
    }

    public static func reindex(dataRoot: URL, client: any SpotlightIndexClient) async throws -> ReindexOutcome {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let task = await storage.enqueueSpotlightProjection {
            do {
                return try await reindex(dataRoot: dataRoot, storage: storage, client: client)
            } catch {
                await recordProjectionFailure("Spotlight rebuild failed: \(error)", dataRoot: dataRoot, storage: storage)
                throw error
            }
        }
        return try await task.value
    }

    private static func reindex(dataRoot: URL, storage: MemoryStorage,
                                client: any SpotlightIndexClient) async throws -> ReindexOutcome {
        let marker = markerURL(dataRoot: dataRoot)
        let snapshot = try await storage.spotlightSnapshot()

        // Delete generation proof before clearing the index so interruption cannot report a confirmed count over an empty domain.
        try clearMarker(at: marker)

        try await client.deleteAll(domainIdentifier: defaultDomain)
        try await client.index(snapshot.items)

        let completedGeneration = try await storage.spotlightSnapshot().fingerprint
        guard completedGeneration == snapshot.fingerprint else {
            // A racing canonical write leaves the batch unconfirmed; queued mutations repair it and the next rebuild uses the new generation.
            return .changedDuringReindex
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            Data((snapshot.fingerprint + "\n").utf8),
            to: marker
        )
        await storage.recordSpotlightProjectionFailure(nil)
        return .indexed(count: snapshot.items.count)
    }

    static func recordProjectionFailure(_ message: String, dataRoot: URL, storage: MemoryStorage) async {
        var detail = String(message.prefix(2_048))
        do { try clearMarker(at: markerURL(dataRoot: dataRoot)) }
        catch { detail += "; could not invalidate Spotlight proof: \(error)" }
        await storage.recordSpotlightProjectionFailure(detail)
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
        // Isolated data roots must never replace the user's system Spotlight domain.
        return MockSpotlightIndexClient()
    }
}

extension SwiftNativeMemoryIndexer {
    public enum ReindexOutcome: Equatable, Sendable {
        case indexed(count: Int)
        case changedDuringReindex
        case failed(message: String, cause: String? = nil)
    }
}
