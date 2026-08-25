import Foundation
import Testing
@testable import NativeAgentApp
import MemoryV2

private func memoryRowPinRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemoryRowPin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Memory row pin control")
struct MemoryRowPinEvalTests {
    // app.mind / ui.memory.row.pin
    @Test("pin and unpin mutate the exact clone-backed row returned to the Memory view")
    func pinRoundTripsThroughTheCanonicalMemoryStore() async throws {
        let root = try memoryRowPinRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "pin-target",
            content: "User prefers release evidence before a merge."
        ))

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let initialRows = try await client.getMemories()
        #expect(initialRows.first(where: { $0.id == "pin-target" })?.pinned == false)

        _ = try await client.updateMemory(id: "pin-target", pinned: true)
        let pinnedRows = try await client.getMemories()
        let pinned = try #require(pinnedRows.first { $0.id == "pin-target" })
        #expect(pinned.pinned == true)

        _ = try await client.updateMemory(id: "pin-target", pinned: false)
        let unpinnedRows = try await client.getMemories()
        let unpinned = try #require(unpinnedRows.first { $0.id == "pin-target" })
        #expect(unpinned.pinned == false)
    }

    // app.mind / ui.memory.row.pin
    @MainActor
    @Test("a failed row pin remains a visible error toast")
    func failedPinDoesNotSilentlyLeaveTheRowLookingUpdated() async throws {
        let root = try memoryRowPinRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "present-row",
            content: "The visible row is backed by this clone."
        ))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let rows = try await client.getMemories()
        var missing = try #require(rows.first { $0.id == "present-row" })
        missing.id = "missing-row"

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.pinMemory(missing, pinned: true)

        #expect(app.statusText.contains("Memory update failed:"))
        #expect(app.systemToasts.queue.last?.kind == .error)
        #expect(app.systemToasts.queue.last?.text.contains("Memory update failed:") == true)
        let durable = try await storage.memory(id: "present-row")
        #expect(durable?.metadata == nil)
    }
}
