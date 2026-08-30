import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / contextflow.residentWorkObservation

@Suite("Resident work observation", .serialized)
struct ResidentWorkObservationEvalTests {
    @Test("terminal Workshop history does not retain live watchers")
    func terminalWorkshopHistoryIsNotWatched() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executionRoot = root.appendingPathComponent("workshop/executions", isDirectory: true)
        let completed = executionRoot.appendingPathComponent("completed/execution.json")
        let running = executionRoot.appendingPathComponent("running/execution.json")
        let unreadable = executionRoot.appendingPathComponent("unreadable/execution.json")
        for record in [completed, running, unreadable] {
            try FileManager.default.createDirectory(
                at: record.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data(#"{"status":"completed"}"#.utf8).write(to: completed)
        try Data(#"{"status":"running"}"#.utf8).write(to: running)
        try Data(#"not-json"#.utf8).write(to: unreadable)

        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(
                embedder: MockEmbeddingProvider(dimensions: 32),
                storage: InMemoryMemoryStorage()
            )
        )
        await runtime.start()
        defer { Task { await runtime.stop() } }

        let status = try await waitForStatus(runtime) { $0.isWatching }
        let watchedPaths = Set(status.watchedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        #expect(watchedPaths.contains(executionRoot.standardizedFileURL.path))
        #expect(!watchedPaths.contains(completed.standardizedFileURL.path))
        #expect(watchedPaths.contains(running.standardizedFileURL.path))
        #expect(watchedPaths.contains(unreadable.standardizedFileURL.path))
        await runtime.stop()
    }

    @Test("existing and newly-created Desk feeds produce one invalidation edge")
    func deskFeedCreationAndWriteAreObserved() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("desk/desk_ops.jsonl")
        // The target is deliberately absent at arm time, but its immediate
        // parent must exist for the kqueue watcher to hold a real directory
        // vnode. An absent parent has no vnode to observe and cannot report
        // this creation edge.
        try FileManager.default.createDirectory(
            at: feed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(
                embedder: MockEmbeddingProvider(dimensions: 32),
                storage: InMemoryMemoryStorage()
            )
        )
        await runtime.start()
        defer { Task { await runtime.stop() } }

        let initial = try await waitForStatus(runtime) {
            $0.isWatching
                && $0.watchedPaths.contains(feed.path)
                && $0.missingPaths.contains(feed.path)
        }
        #expect(initial.missingPaths.contains(feed.path), "Absent feed must be reported as an observed missing target.")

        try Data(#"{"kind":"fixture"}\n"#.utf8).write(to: feed)
        let afterCreation = try await waitForStatus(runtime) { $0.invalidationCount == 1 }
        #expect(afterCreation.invalidationCount == 1)

        let handle = try FileHandle(forWritingTo: feed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"fixture-update"}\n"#.utf8))
        try handle.close()
        let afterWrite = try await waitForStatus(runtime) { $0.invalidationCount == 2 }
        #expect(afterWrite.invalidationCount == 2)
        await runtime.stop()
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-work-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForStatus(_ runtime: NativeContextFlowRuntime, where predicate: (NativeResidentWorkObservationStatus) -> Bool) async throws -> NativeResidentWorkObservationStatus {
        for _ in 0..<100 {
            let status = await runtime.residentWorkObservationStatus()
            if predicate(status) { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ResidentWorkObservationEval", code: 1, userInfo: [NSLocalizedDescriptionKey: "observer did not reach expected state"])
    }
}
