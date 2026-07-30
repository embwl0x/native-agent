import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private final class DeskReloadProbe {
    var count = 0
    func reload() { count += 1 }
}

@Suite("Desk live reloader lifecycle", .serialized)
@MainActor
struct DeskLiveReloaderLifecycleTests {
    @Test func hiddenEdgesCatchUpOnceAndStopCancelsLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-live-reloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ops.jsonl")
        let probe = DeskReloadProbe()
        let reloader = DeskLiveReloader(
            debounceDelay: .milliseconds(20),
            visibilityResolver: { true }
        )
        defer { reloader.stop() }

        reloader.activate(paths: [path]) { probe.reload() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 1)

        reloader.deactivate()
        for _ in 0..<10 { reloader.sourceDidChange() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 1)

        reloader.activate(paths: [path]) { probe.reload() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 2)

        reloader.setSceneActive(false)
        reloader.sourceDidChange()
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 2)
        reloader.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 3)

        reloader.stop()
        reloader.sourceDidChange()
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 3)
    }
}
