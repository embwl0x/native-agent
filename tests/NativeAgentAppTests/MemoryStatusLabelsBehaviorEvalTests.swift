import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

@Suite("Memory status labels", .serialized)
struct MemoryStatusLabelsBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-status-labels-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // app.mind / ui.memory.statusLabels
    @Test("the real status reader labels a populated canonical store as readable")
    func populatedStoreReportsARealCount() async throws {
        let root = try temporaryRoot("populated")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "status-memory",
            content: "Remember that release notes need source links."
        ))

        let status = try await NativeClient(baseURL: "", dataRootOverride: root).getMemoryV2Status()
        #expect(status.status == "ready")
        #expect(status.counts?.active == 1)
        #expect(MemoryStatusPlainCopy.storageAvailability(
            status: status.status,
            snapshotReadable: true
        ) == .readable)
    }

    // app.mind / ui.memory.statusLabels
    @Test("the real status reader distinguishes a readable empty store from a failed read")
    func emptyStoreRemainsAnHonestNoMemoriesState() async throws {
        let root = try temporaryRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let status = try await NativeClient(baseURL: "", dataRootOverride: root).getMemoryV2Status()
        #expect(status.status == "empty")
        #expect(status.counts?.active == 0)
        #expect(MemoryStatusPlainCopy.storageAvailability(
            status: status.status,
            snapshotReadable: true
        ) == .readable)
        #expect(MemoryStatusPlainCopy.headline(
            savedCount: 0,
            health: .working(loadCount: 1),
            storage: .readable
        ) == "No memories saved yet.")
    }

    // app.mind / ui.memory.statusLabels
    @Test("an obstructed memory root cannot manufacture a no-memories label")
    func unreadableStoreProjectsAnUnavailableStatus() async throws {
        let root = try temporaryRoot("obstructed")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("memory"))

        let status = try await NativeClient(baseURL: "", dataRootOverride: root).getMemoryV2Status()
        let availability = MemoryStatusPlainCopy.storageAvailability(
            status: status.status,
            snapshotReadable: false
        )
        #expect(status.status == "unavailable")
        #expect(availability == .unavailable)
        #expect(MemoryStatusPlainCopy.headline(
            savedCount: 0,
            health: .working(loadCount: 1),
            storage: availability
        ) == "Saved memories could not be read.")
        #expect(MemoryStatusPlainCopy.countsLine(
            savedCount: 0,
            pinned: 0,
            pendingProposals: 0,
            storage: availability
        ).contains("does not mean none are saved"))
    }
}
