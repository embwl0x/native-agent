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
    /// Positive steps (a reload SHOULD land) poll with a generous deadline —
    /// the 20ms debounce plus main-actor hops routinely exceed a fixed 80ms
    /// window under full-suite parallelism, which made this test the app
    /// suite's one consistent flake (every count exactly one behind).
    /// Negative steps (a reload must NOT land) keep a bounded settle window:
    /// a false pass there shrinks with the window, a false FAIL on the
    /// positive steps doesn't shrink at all.
    private func waitForCount(
        _ probe: DeskReloadProbe, toReach expected: Int,
        deadline: Duration = .seconds(5)
    ) async throws -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if probe.count >= expected { return probe.count == expected }
            try await Task.sleep(for: .milliseconds(10))
        }
        return probe.count == expected
    }

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
        #expect(try await waitForCount(probe, toReach: 1))

        reloader.deactivate()
        for _ in 0..<10 { reloader.sourceDidChange() }
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 1)

        reloader.activate(paths: [path]) { probe.reload() }
        #expect(try await waitForCount(probe, toReach: 2))

        reloader.setSceneActive(false)
        reloader.sourceDidChange()
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 2)
        reloader.setSceneActive(true)
        #expect(try await waitForCount(probe, toReach: 3))

        reloader.stop()
        reloader.sourceDidChange()
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.count == 3)
    }
}
