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

    @MainActor
    @Test func canonicalSessionReplacementRefreshesSharedMacSessionStateWithoutPolling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-session-live-refresh-\(UUID().uuidString)", isDirectory: true)
        let chatRoot = root.appendingPathComponent("chat", isDirectory: true)
        let path = chatRoot.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let active = try JSONDecoder().decode(ChatSession.self, from: Data("""
        {"id":"active","title":"Active","createdAt":"2026-08-09T12:00:00Z"}
        """.utf8))
        let bridge = try JSONDecoder().decode(ChatSession.self, from: Data("""
        {"id":"bridge","title":"Bridge session","createdAt":"2026-08-09T12:01:00Z"}
        """.utf8))
        try JSONEncoder().encode([active]).write(to: path, options: .atomic)

        let model = AppModel()
        model.chatSessions = []
        let task = Task { @MainActor in
            await ViewFileRefreshTask.run(
                paths: [path],
                debounceDelay: .milliseconds(35)
            ) {
                await model.refreshChatSessionIndex {
                    let data = try Data(contentsOf: path)
                    return try JSONDecoder().decode([ChatSession].self, from: data)
                }
            }
        }

        try await waitUntil { await MainActor.run { model.chatSessions.map(\.id) == [active.id] } }
        try JSONEncoder().encode([bridge, active]).write(to: path, options: .atomic)
        try await waitUntil {
            await MainActor.run { model.chatSessions.map(\.id) == [bridge.id, active.id] }
        }

        task.cancel()
        await task.value
        let before = model.chatSessions
        try JSONEncoder().encode([active]).write(to: path, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.chatSessions == before)
    }

    // 10s deadline, not 2s: positive steps (a refresh SHOULD land) only need
    // the deadline to exceed worst-case scheduler noise under full-suite
    // parallelism — a green run still returns at the first 10ms poll that
    // observes the count.
    private func waitUntil(
        timeout: Duration = .seconds(10),
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
