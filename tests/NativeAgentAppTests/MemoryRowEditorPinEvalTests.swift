import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.memory.rowEditor.pin

@MainActor
@Suite("Memory row editor pin")
struct MemoryRowEditorPinEvalTests {
    @Test("the row editor claims a pin only after the canonical writer persists it")
    func appliedPinRefreshesFromTheDurableMemoryWriter() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "row-editor-pin",
            content: "This row is backed by a durable memory record."
        ))

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let memory = try #require((try await client.getMemories()).first { $0.id == "row-editor-pin" })
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let outcome = await app.pinMemory(memory, pinned: true)
        #expect(outcome == .applied(pinned: true))
        #expect(outcome.message == "Memory pinned")
        #expect(outcome.systemImage == "checkmark.circle")

        let reloaded = try #require((try await client.getMemories()).first { $0.id == memory.id })
        #expect(reloaded.pinned == true)

        let unpinOutcome = await app.pinMemory(reloaded, pinned: false)
        #expect(unpinOutcome == .applied(pinned: false))
        let unpinned = try #require((try await client.getMemories()).first { $0.id == memory.id })
        #expect(unpinned.pinned == false)
    }

    @Test("queued, refused, malformed, and failed receipts do not claim that a row was pinned")
    func adverseReceiptsRemainDistinctFromAppliedPinning() async throws {
        #expect(MemoryRowEditorPinOutcome.resolve(
            result: ["status": "pending_approval"],
            pinned: true
        ) == .pendingApproval(pinned: true))
        #expect(MemoryRowEditorPinOutcome.resolve(
            result: ["status": "refused", "reason": "policy requires approval"],
            pinned: true
        ) == .refused("policy requires approval"))
        #expect(MemoryRowEditorPinOutcome.resolve(
            result: ["status": "ok-but-not-committed"],
            pinned: true
        ) == .failed("the memory writer returned an unrecognized outcome"))

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: "stored-row",
            content: "This row proves a failed pin does not alter another record."
        ))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        var missing = try #require((try await client.getMemories()).first { $0.id == "stored-row" })
        missing.id = "missing-row"
        let failure = await app.pinMemory(missing, pinned: true)

        #expect(failure.isAdverse)
        #expect(failure.message.contains("Memory update failed:"))
        let unchanged = try #require((try await client.getMemories()).first { $0.id == "stored-row" })
        #expect(unchanged.pinned != true)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-row-editor-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
