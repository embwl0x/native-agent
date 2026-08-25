import ApprovalInbox
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private actor LivingStatusWatchProbe {
    private var refreshCount = 0

    func record() { refreshCount += 1 }
    func count() -> Int { refreshCount }
}

private func awaitLivingStatusRefresh(
    _ probe: LivingStatusWatchProbe,
    atLeast target: Int,
    timeout: Duration = .seconds(5)
) async -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        let count = await probe.count()
        if count >= target { return count }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await probe.count()
}

// EVAL FENCE: app.mind / loop.LivingStatusPanel.fileWatch
//
// The mounted Activity card must react to the same durable stores its snapshot
// reads. This drives each canonical input through an external writer or its
// persisted file boundary, then verifies an unrelated retired memory file
// cannot manufacture a liveness refresh.
@MainActor
@Test("Living Status refreshes for canonical persisted inputs, not retired files")
func livingStatusFileWatchRefreshesOnlyItsCanonicalInputs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("living-status-watch-\(UUID().uuidString)", isDirectory: true)
    let evaluationStartedAt = Date()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("dream_diary", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = LivingStatusFileWatch.watchedPaths(dataRoot: root)
    #expect(paths.count == 5)
    #expect(!paths.contains(root.appendingPathComponent("memory/knowledge_graph.json")))

    let probe = LivingStatusWatchProbe()
    let observation = Task { @MainActor in
        await LivingStatusFileWatch.observe(
            dataRoot: root,
            debounceDelay: .milliseconds(30)
        ) {
            await probe.record()
        }
    }
    defer { observation.cancel() }

    #expect(await awaitLivingStatusRefresh(probe, atLeast: 1) >= 1,
            "the mounted panel watcher did not perform its initial read")

    var expectedRefreshes = await probe.count()
    let desk = SwiftNativeDeskStore(dataRoot: root)
    _ = try await desk.createItem(kind: .plan, project: "watch-eval", title: "Desk changed externally")
    expectedRefreshes += 1
    #expect(await awaitLivingStatusRefresh(probe, atLeast: expectedRefreshes) >= expectedRefreshes,
            "a canonical Desk commit did not refresh Living Status")

    let approvals = SwiftNativeApprovalInbox(root: root)
    _ = try await approvals.create(.object([
        "title": .string("Refresh Living Status"),
        "action": .string("living-status.eval"),
        "risk": .string("confirm"),
        "reason": .string("exercise the canonical approval inbox"),
        "payload": .object([:]),
    ]))
    expectedRefreshes += 1
    #expect(await awaitLivingStatusRefresh(probe, atLeast: expectedRefreshes) >= expectedRefreshes,
            "a canonical approval write did not refresh Living Status")

    let dream = root.appendingPathComponent("dream_diary/2026-08-24_watch.md")
    try Data("# Watch proof\nA new dream entry.".utf8).write(to: dream, options: .atomic)
    expectedRefreshes += 1
    #expect(await awaitLivingStatusRefresh(probe, atLeast: expectedRefreshes) >= expectedRefreshes,
            "a dream-diary entry did not refresh Living Status")

    let organism = root.appendingPathComponent("cognition/organism_state.json")
    try Data("{\"availability\":\"ready\"}".utf8).write(to: organism, options: .atomic)
    expectedRefreshes += 1
    #expect(await awaitLivingStatusRefresh(probe, atLeast: expectedRefreshes) >= expectedRefreshes,
            "an externally persisted organism state did not refresh Living Status")

    // Every arm has a concrete durable producer in this evaluation. Missing
    // targets are watched through their parent directory by the primitive, but
    // do not count as evidence that the card is live until a writer has made
    // the target real in this bounded run.
    for path in paths {
        #expect(FileManager.default.fileExists(atPath: path.path),
                "watched input was never produced: \(path.path)")
        let values = try path.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = try #require(values.contentModificationDate,
                                      "watched input has no modification time: \(path.path)")
        #expect(modifiedAt >= evaluationStartedAt.addingTimeInterval(-1),
                "watched input was not written during the evaluation: \(path.path)")
    }

    // The legacy graph is neither read by the card nor a substitute for a
    // successful source read. Its write must not create a false live signal.
    let retiredDirectory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
    let beforeRetiredWrite = await probe.count()
    try Data("{\"retired\":true}".utf8).write(
        to: retiredDirectory.appendingPathComponent("knowledge_graph.json"),
        options: .atomic
    )
    try await Task.sleep(for: .milliseconds(150))
    #expect(await probe.count() == beforeRetiredWrite,
            "a retired, unread file incorrectly refreshed Living Status")

    observation.cancel()
    await observation.value
}
