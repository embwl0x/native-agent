// EVAL COVERAGE — app.mind / ui.memory.toolbar.refresh.
//
// Exercises the production operation used by MemoryView's toolbar
// against an isolated, real MemoryV2 SQLite store. No source inspection and no
// fake app-model reader are involved.

import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("Memory toolbar refresh — durable stack truth", .serialized)
struct MemoryToolbarRefreshBehaviorTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-toolbar-refresh-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("the toolbar operation re-reads the native stack and app-model memory rows after the durable store changes")
    func refreshRereadsNativeStackAndMemoryRows() async throws {
        let dataRoot = try root("fresh")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)

        let before = await MemoryToolbarRefreshOperation.run(appModel: app, dataRoot: dataRoot)
        #expect(before.nativeStack.storageReadable == true)
        #expect(before.nativeStack.sqliteRecordCount == 0)

        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "toolbar-refresh-memory",
            content: "The toolbar must re-read this durable memory.",
            source: "memory-toolbar-refresh-eval"
        ))

        let after = await MemoryToolbarRefreshOperation.run(appModel: app, dataRoot: dataRoot)
        #expect(after.nativeStack.storageReadable == true)
        #expect(after.nativeStack.sqliteRecordCount == 1)
        #expect(app.memories.map(\.id) == ["toolbar-refresh-memory"])
        #expect(after.presentation == MemoryToolbarRefreshPresentation(
            text: "Memory refreshed.",
            systemImage: "arrow.clockwise",
            isAdverse: false
        ))

    }

    @Test("an unreadable store remains visibly adverse and keeps the last known memory rows instead of claiming an empty refresh")
    func unreadableStoreDoesNotBecomeAnEmptySuccess() async throws {
        let dataRoot = try root("unreadable")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "last-known-memory",
            content: "This row must not be erased by a failed refresh.",
            source: "memory-toolbar-refresh-eval"
        ))
        _ = await MemoryToolbarRefreshOperation.run(appModel: app, dataRoot: dataRoot)
        #expect(app.memories.map(\.id) == ["last-known-memory"])

        let memoryDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.removeItem(at: memoryDirectory)
        try Data("not a memory directory".utf8).write(to: memoryDirectory)

        let failed = await MemoryToolbarRefreshOperation.run(appModel: app, dataRoot: dataRoot)
        #expect(failed.nativeStack.storageReadable == false)
        #expect(failed.presentation.isAdverse)
        #expect(failed.presentation.text.contains("could not be read"))
        #expect(app.memories.map(\.id) == ["last-known-memory"],
                "the real failing reader must retain known rows and mark the refresh stale, not replace them with []")
        #expect(app.isPanelStale(.memories))

        #expect(failed.presentation == MemoryToolbarRefreshPresentation(
            text: "Saved memories could not be read. Existing memory data is shown only where it was already loaded.",
            systemImage: "exclamationmark.triangle",
            isAdverse: true
        ))
    }
}
