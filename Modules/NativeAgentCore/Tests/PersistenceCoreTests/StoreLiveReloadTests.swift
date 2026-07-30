import Foundation
import Testing
@testable import PersistenceCore

private actor ReloadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor InFlightReloadCounter {
    private(set) var value = 0
    private(set) var running = 0
    private(set) var maximumRunning = 0
    func begin() {
        value += 1
        running += 1
        maximumRunning = max(maximumRunning, running)
    }
    func finish() { running -= 1 }
}

private actor WatchEventCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor StoreEventRecorder {
    private(set) var changes: [StoreChange] = []
    func record(_ change: StoreChange) { changes.append(change) }
    func contains(store: StoreChange.Store, path: URL) -> Bool {
        changes.contains { $0.store == store && $0.path.standardizedFileURL == path.standardizedFileURL }
    }
}

private func eventually(
    // The canonical Core gate runs this target beside CPU-heavy causal/model
    // simulations. The condition is an actor-owned semantic boundary, not a
    // latency assertion; give a starved cooperative task enough wall time to
    // be scheduled without weakening what the test requires.
    timeout: Duration = .seconds(15),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

@Test func storeReloadDebouncerCoalescesBurstAndGatesVisibility() async throws {
    let counter = ReloadCounter()
    let gate = StoreReloadDebouncer(delay: .milliseconds(40)) { await counter.increment() }
    await gate.setVisible(true)
    for _ in 0..<20 { await gate.signal() }
    #expect(await eventually { await counter.value == 1 })

    await gate.setVisible(false)
    for _ in 0..<20 { await gate.signal() }
    try await Task.sleep(for: .milliseconds(80))
    #expect(await counter.value == 1)
    await gate.setVisible(true)
    #expect(await eventually { await counter.value == 2 })
}

@Test func storeReloadDebouncerAllowsOnlyOneReloadInFlight() async throws {
    let counter = InFlightReloadCounter()
    let gate = StoreReloadDebouncer(delay: .milliseconds(30)) {
        await counter.begin()
        try? await Task.sleep(for: .milliseconds(100))
        await counter.finish()
    }
    await gate.setVisible(true)
    await gate.signal()
    // Synchronize on the semantic boundary instead of assuming a 30 ms task
    // fires within 60 ms while the full parallel shard is CPU-saturated.
    #expect(await eventually { await counter.running == 1 })
    for _ in 0..<20 { await gate.signal() }
    #expect(await eventually { await counter.value == 2 })
    #expect(await counter.maximumRunning == 1)
}

@Test func storeChangeBusMulticastsTokens() async {
    let bus = StoreChangeBus()
    let path = URL(fileURLWithPath: "/tmp/store-change-test")
    let expected = StoreChange(store: .desk, path: path)
    let firstStream = bus.changes()
    let secondStream = bus.changes()
    let first = Task { await firstStream.first(where: { _ in true }) }
    let second = Task { await secondStream.first(where: { _ in true }) }
    bus.emit(expected)
    #expect(await first.value == expected)
    #expect(await second.value == expected)
}

@Test func githubCommandObservationBatchWritesAndInvalidatesOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-command-batch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = StoreChangeBus()
    let store = GitHubCommandStore(dataRoot: root, changeBus: bus)
    let recorder = StoreEventRecorder()
    let stream = bus.changes()
    let collector = Task {
        for await change in stream { await recorder.record(change) }
    }
    defer { collector.cancel() }

    let observations = (1...85).map { number in
        GitHubCommandObservation(
            repository: "example/widgets",
            number: number,
            kind: .issue,
            title: "Tracked item \(number)",
            isOpen: true,
            observedVersion: "v\(number)"
        )
    }
    let results = try await store.observe(observations)

    #expect(results.count == observations.count)
    #expect(try await store.liveState().items.count == observations.count)
    #expect(await eventually { await recorder.changes.count == 1 })
    #expect(await recorder.changes == [StoreChange(store: .githubCommand, path: store.opsPath)])
}

@Test func canonicalStoreWritersEmitInvalidationTokens() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-change-writers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bus = StoreChangeBus()
    let desk = SwiftNativeDeskStore(dataRoot: root, changeBus: bus)
    let github = GitHubCommandStore(dataRoot: root, changeBus: bus)
    let recorder = StoreEventRecorder()
    let stream = bus.changes()
    let collector = Task {
        for await change in stream {
            await recorder.record(change)
        }
    }
    defer { collector.cancel() }

    _ = try await desk.createItem(kind: .plan, project: "test", title: "Live Desk")
    _ = try await github.detect(
        repository: "example/widgets",
        number: 1,
        kind: .issue,
        title: "Live GitHub lane"
    )

    #expect(await eventually { await recorder.contains(store: .desk, path: desk.opsPath) })
    #expect(await eventually { await recorder.contains(store: .githubCommand, path: github.opsPath) })
}

@Test func fileChangeWatcherRearmsAfterRename() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-watcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("ops.jsonl")
    try Data("first\n".utf8).write(to: path)

    let events = WatchEventCounter()
    let watcher = FileChangeWatcher(paths: [path]) { _ in
        Task { await events.increment() }
    }
    defer { watcher.cancel() }
    try await Task.sleep(for: .milliseconds(80))

    let replacement = directory.appendingPathComponent("replacement")
    try Data("replacement\n".utf8).write(to: replacement)
    try FileManager.default.moveItem(at: replacement, to: path.deletingLastPathComponent().appendingPathComponent("staged"))
    try FileManager.default.removeItem(at: path)
    try FileManager.default.moveItem(at: directory.appendingPathComponent("staged"), to: path)
    #expect(await eventually { await events.value >= 1 })
    // Let rename/create notifications settle so the next assertion can only
    // be satisfied by the append on the newly armed target vnode.
    try await Task.sleep(for: .milliseconds(80))
    let afterReplacement = await events.value

    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("after-rename\n".utf8)); try handle.close()
    #expect(await eventually { await events.value > afterReplacement })
}

@Test func fileChangeWatcherArmsInitiallyMissingFileThroughParent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-watcher-missing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("ops.jsonl")
    let events = WatchEventCounter()
    let watcher = FileChangeWatcher(paths: [path]) { _ in
        Task { await events.increment() }
    }
    defer { watcher.cancel() }
    try await Task.sleep(for: .milliseconds(80))

    try Data("created\n".utf8).write(to: path)
    #expect(await eventually { await events.value >= 1 })
    try await Task.sleep(for: .milliseconds(80))
    let afterCreation = await events.value

    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("appended\n".utf8))
    try handle.close()
    #expect(await eventually { await events.value > afterCreation })
}
