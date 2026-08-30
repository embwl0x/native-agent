import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp
import MemoryV2
import NativeAgentCore

private func memoryRowPinRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemoryRowPin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Memory row pin control")
struct MemoryRowPinEvalTests {
    @Test func pinMergesMetadataAndCompletesCanonicalProjectionBeforeSuccess() async throws {
        let root = try memoryRowPinRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let metadata: JSONValue = .object([
            "kind": .string("note"),
            "source_history": .array([.string("orchard-observation")]),
            "recall_count": .int(3),
        ])
        _ = try await storage.insertMemory(StoredMemory(id: "pin-target", content: "The orchard gate opens at dusk.", metadata: metadata))
        let recorder = MemoryPinProjectionRecorder()
        await storage.attachKnowledgeGraphHook { row, deleted in
            guard !deleted, case .object(let values)? = row.metadata,
                  case .bool(let pinned)? = values["pinned"] else { return }
            await recorder.record(pinned)
        }
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: MemoryStorageBridge(storage: storage))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        for pinned in [true, false] {
            let response = try await client.updateMemory(id: "pin-target", pinned: pinned, memory: memory)
            #expect(response["status"] as? String == "ok")
            let row = try #require(try await storage.memory(id: "pin-target"))
            #expect(row.metadata == .object([
                "kind": .string("note"), "source_history": .array([.string("orchard-observation")]),
                "recall_count": .int(3), "pinned": .bool(pinned),
            ]))
            #expect(await recorder.values.last == pinned)
        }
        #expect(await recorder.values == [true, false])
        _ = try await memory.deleteMemoryIfPresent(id: "pin-target")
        do {
            _ = try await client.updateMemory(id: "pin-target", pinned: true, memory: memory)
            Issue.record("pinning a deleted row must not return success")
        } catch {
            #expect((error as NSError).code == 404)
        }
        #expect(await recorder.values == [true, false])
    }

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

private actor MemoryPinProjectionRecorder {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}
