import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

private actor BootstrapRecordingSpotlightClient: SpotlightIndexClient {
    enum Event: Equatable, Sendable {
        case removeAll
        case index([String])
    }

    private let mutateAfterIndex: (@Sendable () async -> Void)?
    private var events: [Event] = []

    init(mutateAfterIndex: (@Sendable () async -> Void)? = nil) {
        self.mutateAfterIndex = mutateAfterIndex
    }

    func index(_ items: [SpotlightItem]) async throws {
        events.append(.index(items.map(\.id)))
        if let mutateAfterIndex {
            await mutateAfterIndex()
        }
    }

    func delete(ids: [String]) async throws {}

    func deleteAll(domainIdentifier: String) async throws {
        events.append(.removeAll)
    }

    func recordedEvents() -> [Event] { events }
}

// EVAL FENCE: app.background / app.background.memorySpotlightBootstrap
@Suite("Memory Spotlight launch bootstrap", .serialized)
struct MemorySpotlightBootstrapEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-spotlight-bootstrap-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("bootstrap clears the derived domain before indexing, skips skill pointers, and runs once")
    func bootstrapOrdersAndFiltersTheProjection() async throws {
        let dataRoot = try root("ordered")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "ordinary-memory",
            content: "Index this durable memory.",
            source: "spotlight-bootstrap-eval"
        ))
        _ = try await storage.insertMemory(StoredMemory(
            id: SwiftNativeMemoryV2.skillPointerIDPrefix + "private-skill",
            content: "Never expose a skill pointer through Spotlight.",
            source: "spotlight-bootstrap-eval"
        ))
        let client = BootstrapRecordingSpotlightClient()
        let bootstrap = MemorySpotlightBootstrap(dataRoot: dataRoot, indexClient: client)

        await bootstrap.reindexAll()
        #expect(await client.recordedEvents() == [
            .removeAll,
            .index(["ordinary-memory"])
        ])

        let marker = dataRoot.appendingPathComponent("memory/.spotlight_reindexed")
        let generation = try await storage.projectionGenerationFingerprint()
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == generation)

        await bootstrap.reindexAll()
        #expect(await client.recordedEvents() == [
            .removeAll,
            .index(["ordinary-memory"])
        ])
    }

    @Test("a post-index source mutation leaves no bootstrap sentinel")
    func bootstrapDoesNotConfirmAStaleGeneration() async throws {
        let dataRoot = try root("generation-race")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "before-race",
            content: "This batch becomes stale after indexing.",
            source: "spotlight-bootstrap-eval"
        ))
        let client = BootstrapRecordingSpotlightClient {
            _ = try? await storage.insertMemory(StoredMemory(
                id: "after-race",
                content: "This write changes the canonical projection generation.",
                source: "spotlight-bootstrap-eval"
            ))
        }
        let bootstrap = MemorySpotlightBootstrap(dataRoot: dataRoot, indexClient: client)

        await bootstrap.reindexAll()
        let marker = dataRoot.appendingPathComponent("memory/.spotlight_reindexed")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
