import Testing
import Foundation
@testable import PersistenceCore

// MARK: - FileChangeEvents — the anti-deadlock wrapper
//
// LEDGER: core.persistence.FileChangeEvents
//
// ZERO direct tests before this file, yet it is the AsyncStream face that four
// production await-loops actually consume: WorkshopCompiledProcedureRuntime.swift:319,
// WorkshopExecution+Executor.swift:1538, WorkflowOrchestration+Client.swift:1374,
// and NativeContextFlowRuntime.swift:676/688.
//
// THE SILENT FAILURE is a pure SLOWDOWN, which is why nobody catches it.
// `emitInitial` is the whole read-before-watch race closer: a waiter that
// constructs the stream AFTER the file already changed has no further edge
// coming. Drop the initial emission and that waiter blocks until its OUTER
// deadline — a Workshop execution that "took 30s" gets blamed on the
// subprocess, not on the watcher that never yielded. `cancel()` failing to
// finish the continuation is the same failure with no deadline at all: the
// awaiting task stays suspended forever and its task-group never returns.
//
// EVERY WAIT HERE IS BOUNDED. An un-timed `for await` on a stream that never
// yields would wedge the whole `--no-parallel` suite instead of failing it, so
// each case races the stream against a deadline and asserts on the winner.
@Suite("FileChangeEvents")
struct FileChangeEventsTests {

    private static let deadline = Duration.seconds(5)

    /// Case 1 — THE RACE CLOSER. The file is written BEFORE the stream exists,
    /// so no further edge is coming. `emitInitial` must still yield, or every
    /// start-after-the-change waiter in production hangs to its outer deadline.
    @Test func emitInitial_yieldsForAChangeThatAlreadyHappened() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("execution.jsonl")
        try Data("{\"row\":1}\n".utf8).write(to: path)

        let events = FileChangeEvents(paths: [path], emitInitial: true)
        defer { events.cancel() }

        let seen = await collectElements(from: events.stream, atLeast: 1, within: Self.deadline)
        #expect(seen.count >= 1, "emitInitial must close the read-before-watch race with no further write")
        #expect(seen.first?.standardizedFileURL == path.standardizedFileURL)
    }

    /// The counterpart that proves case 1 is measuring `emitInitial` and not
    /// some incidental edge: with the flag OFF and no write, nothing arrives
    /// inside a short bound. (Short on purpose — this one is an absence proof,
    /// so it pays its bound on every run.)
    @Test func emitInitialDisabled_yieldsNothingWithoutAWrite() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("execution.jsonl")
        try Data("{\"row\":1}\n".utf8).write(to: path)

        let events = FileChangeEvents(paths: [path], emitInitial: false)
        defer { events.cancel() }

        let seen = await collectElements(from: events.stream, atLeast: 1, within: .milliseconds(400))
        #expect(seen.isEmpty, "without emitInitial a pre-existing change must not synthesize an edge")
    }

    /// Case 2 — the ordinary path: a write after construction yields. Uses
    /// `emitInitial: false` so the yield can only have come from the watcher.
    @Test func writeAfterConstruction_yieldsTheChangedPath() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("execution.jsonl")
        try Data("{\"row\":1}\n".utf8).write(to: path)

        let events = FileChangeEvents(paths: [path], emitInitial: false)
        defer { events.cancel() }

        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"row\":2}\n".utf8))
        try handle.close()

        let seen = await collectElements(from: events.stream, atLeast: 1, within: Self.deadline)
        #expect(seen.count >= 1, "a post-construction append must produce an edge")
        #expect(seen.first?.standardizedFileURL == path.standardizedFileURL)
    }

    /// Case 3 — TERMINATION. `cancel()` must finish the continuation, not merely
    /// stop the watcher. A stream that stays open after cancel leaves every
    /// `for await` in the four production consumers suspended forever, and their
    /// enclosing task groups never return.
    @Test func cancel_terminatesTheStreamRatherThanSuspendingTheWaiter() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("execution.jsonl")
        try Data("{\"row\":1}\n".utf8).write(to: path)

        let events = FileChangeEvents(paths: [path], emitInitial: false)
        let drained = Task { () -> Bool in
            for await _ in events.stream {}
            return true   // reached ONLY if the stream finished
        }
        events.cancel()
        // Idempotence: a second cancel (and the deinit path) must not trap.
        events.cancel()

        let finished = await withDeadline(Self.deadline) { await drained.value }
        #expect(finished == true, "cancel() must finish the stream so the awaiting task resumes")
        drained.cancel()
    }

    /// Duplicate paths are collapsed before the initial emission, so a caller
    /// that passes the same file twice does not get two edges for one change and
    /// double-drive its wait loop.
    @Test func duplicatePathsAreDeduplicatedForTheInitialEmission() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("execution.jsonl")
        try Data("{\"row\":1}\n".utf8).write(to: path)

        let events = FileChangeEvents(
            paths: [path, path, path.standardizedFileURL],
            emitInitial: true
        )
        defer { events.cancel() }

        // One continuous consumer, bounded: asking for TWO elements and getting
        // one is the observable form of dedup.
        let seen = await collectElements(from: events.stream, atLeast: 2, within: .milliseconds(500))
        #expect(seen.count == 1, "one path must produce one initial edge, however many times it was passed")
        #expect(seen.first?.standardizedFileURL == path.standardizedFileURL)
    }
}

// MARK: - Bounded await helpers
//
// Never `for await` on a production stream without a deadline in a test: a
// missed edge must FAIL the suite, not wedge it.

/// Consumes `stream` with ONE iterator until it has `target` elements or the
/// bound expires, then cancels the consumer. Polling a bounded window (rather
/// than a bare `for await`) is what keeps a missed edge a FAILURE instead of a
/// wedged suite.
private func collectElements(
    from stream: AsyncStream<URL>,
    atLeast target: Int,
    within duration: Duration
) async -> [URL] {
    let box = CollectedURLs()
    let consumer = Task {
        for await url in stream {
            await box.add(url)
        }
    }
    defer { consumer.cancel() }

    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if await box.count >= target { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await box.items
}

private func makeWatchDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("file-change-events-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private actor CollectedURLs {
    private(set) var items: [URL] = []
    var count: Int { items.count }
    func add(_ url: URL) { items.append(url) }
}

/// Runs `body` against a wall-clock bound. Returns nil when the bound wins.
/// The losing child is cancelled, so nothing survives the test.
private func withDeadline<T: Sendable>(
    _ duration: Duration,
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: duration)
            return nil
        }
        let winner = await group.next() ?? nil
        group.cancelAll()
        return winner
    }
}
