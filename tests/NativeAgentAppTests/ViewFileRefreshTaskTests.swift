import Foundation
import Testing
@testable import NativeAgentApp

private actor ViewRefreshProbe {
    private var value = 0

    func record() { value += 1 }
    func count() -> Int { value }
}

@Suite("File-driven view refresh lifecycle", .serialized)
struct ViewFileRefreshTaskTests {
    @Test func initialReadBurstCoalescingIdleAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("view-file-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let probe = ViewRefreshProbe()

        let task = Task { @MainActor in
            await ViewFileRefreshTask.run(
                paths: [path],
                debounceDelay: .milliseconds(35)
            ) {
                await probe.record()
            }
        }

        try await waitUntil { await probe.count() == 1 }

        for value in 0..<12 {
            try Data("{\"value\":\(value)}".utf8).write(to: path, options: .atomic)
        }
        try await waitUntil { await probe.count() >= 2 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(await probe.count() == 2)

        // No signal means no wake: this wait is longer than the debounce and
        // would expose an accidental periodic fallback.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.count() == 2)

        task.cancel()
        await task.value
        try Data("{\"value\":99}".utf8).write(to: path, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.count() == 2)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for file-driven refresh")
    }
}
