import Foundation
import Testing
@testable import MemoryV2
import PersistenceCore

@Suite("MemoryV2 owner resolver", .serialized)
struct MemoryOwnerResolverTests {
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memory-owner-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("default-root spellings resolve to the one process actor")
    func defaultRootUsesSharedActor() async throws {
        let root = PersistenceCore.defaultDataRoot()
        let equivalent = root
            .appendingPathComponent("child", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
        #expect(SwiftNativeMemoryV2.usesDefaultDataRoot(equivalent))
        #expect(SwiftNativeMemoryV2.resolvedOwner(dataRoot: equivalent)
            === SwiftNativeMemoryV2.shared)
        let bridge = try #require(await SwiftNativeMemoryV2.shared.underlyingBridge())
        let underlying = await bridge.underlyingStorage()
        let resolvedStorage = try await SwiftNativeMemoryV2.resolvedStorage(
            dataRoot: equivalent
        )
        #expect(resolvedStorage === underlying)
    }

    @Test("alternate roots stay private and exact")
    func alternateRootsRemainIsolated() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: root,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        let second = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: root,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        #expect(first !== SwiftNativeMemoryV2.shared)
        #expect(first !== second)
        let bridge = try #require(await first.underlyingBridge())
        #expect(await bridge.underlyingStorage().path == root
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite"))
        let wrongRoot = root.appendingPathComponent("wrong", isDirectory: true)
        #expect(await first.bindUserMDGenerator(dataRoot: wrongRoot) == nil)
    }

    @Test("USER.md launch binding uses the resolved owner's storage hook")
    func userMDBindingUsesResolvedStorage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("complete\n".utf8).write(to: root.appendingPathComponent(".onboarded"))
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let owner = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: root,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        let generator = try #require(await owner.bindUserMDGenerator(
            dataRoot: root,
            personaRoot: personaRoot,
            debounceInterval: 0
        ))
        _ = try await generator.regenerate()

        let bridge = try #require(await owner.underlyingBridge())
        _ = try await bridge.underlyingStorage().insertMemory(StoredMemory(
            content: "the user prefers one canonical memory owner",
            source: "test",
            metadata: .object(["kind": .string("preference")])
        ))

        let target = personaRoot.appendingPathComponent("USER.md")
        let deadline = Date().addingTimeInterval(2)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            if text.contains("one canonical memory owner") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.contains("one canonical memory owner"))
    }
}
