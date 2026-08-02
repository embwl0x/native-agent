import Foundation
import Testing
@testable import PersistenceCore

// fix-watcher-deinit-race (2026-08-02), Track C of
// docs/build_plans/lifecycle-prevention-design.md.
//
// `FileChangeWatcher.sources` was mutated on the watcher's serial queue
// (arm/install) but read AND mutated OFF that queue by `deinit`, which runs on
// whatever thread drops the last reference. The two failure modes: a torn
// dictionary access (crash), or a source armed after deinit's sweep — a vnode
// source that is never cancelled, i.e. an O_EVTONLY descriptor leaked for the
// process lifetime.
//
// The fd-count assertions below are the observable half of that leak; the
// concurrency test is the race itself, run hot enough to trip an unsynchronized
// implementation.
@Suite("FileChangeWatcher lifecycle")
struct FileChangeWatcherLifecycleTests {
    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Descriptor close runs on the watcher queue via the source's cancel
    /// handler, so settle instead of sampling once.
    private func waitForDescriptors(atMost limit: Int, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = openDescriptorCount()
        while count > limit, Date() < deadline {
            usleep(20_000)
            count = openDescriptorCount()
        }
        return count
    }

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileChangeWatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("watchers dropped without cancel() close every descriptor")
    func deinitClosesDescriptors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<8).map { root.appendingPathComponent("f\($0).json") }
        for path in paths { try Data("{}".utf8).write(to: path) }

        // Warm one cycle so lazily-created runtime descriptors don't count.
        do { _ = FileChangeWatcher(paths: paths) { _ in } }
        _ = waitForDescriptors(atMost: 0, timeout: 1)
        let baseline = openDescriptorCount()

        for _ in 0..<20 {
            // No cancel(): `deinit` is the only teardown path here.
            _ = FileChangeWatcher(paths: paths) { _ in }
        }
        let settled = waitForDescriptors(atMost: baseline + 8)
        #expect(settled <= baseline + 8, "descriptors leaked: \(settled) vs baseline \(baseline)")
    }

    @Test("cancel() followed by deinit tears down exactly once")
    func cancelThenDeinitIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("once.json")
        try Data("{}".utf8).write(to: path)

        do { _ = FileChangeWatcher(paths: [path]) { _ in } }
        _ = waitForDescriptors(atMost: 0, timeout: 1)
        let baseline = openDescriptorCount()

        for _ in 0..<20 {
            let watcher = FileChangeWatcher(paths: [path]) { _ in }
            watcher.cancel()
            watcher.cancel()
        }
        let settled = waitForDescriptors(atMost: baseline + 4)
        #expect(settled <= baseline + 4, "descriptors leaked: \(settled) vs baseline \(baseline)")
    }

    @Test("dropping watchers while their queue re-arms neither crashes nor leaks")
    func concurrentRearmAndDeinitIsSafe() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<4).map { root.appendingPathComponent("hot\($0).json") }
        for path in paths { try Data("{}".utf8).write(to: path) }

        do { _ = FileChangeWatcher(paths: paths) { _ in } }
        _ = waitForDescriptors(atMost: 0, timeout: 1)
        let baseline = openDescriptorCount()

        let stop = DispatchSemaphore(value: 0)
        let churn = Thread {
            var i = 0
            while stop.wait(timeout: .now()) == .timedOut {
                for path in paths {
                    // Atomic replace → rename/delete edges → the watcher
                    // re-arms ON its queue while the main thread drops it.
                    let tmp = path.deletingLastPathComponent()
                        .appendingPathComponent("tmp-\(i).json")
                    try? Data("{\"i\":\(i)}".utf8).write(to: tmp)
                    _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
                }
                i += 1
            }
        }
        churn.start()

        for _ in 0..<150 {
            // Deliberately no cancel(): deinit races the re-arm, which is the
            // exact window that was unsynchronized.
            _ = FileChangeWatcher(paths: paths) { _ in }
        }
        stop.signal()
        Thread.sleep(forTimeInterval: 0.2)

        let settled = waitForDescriptors(atMost: baseline + 8, timeout: 10)
        #expect(settled <= baseline + 8, "descriptors leaked under churn: \(settled) vs \(baseline)")
    }

    // fix-watcher-suspended-source-release (2026-08-02).
    //
    // `makeFileSystemObjectSource` hands back a SUSPENDED source. If `tearDown`
    // wins the window between "source created" and "source published+resumed",
    // `install` used to just `cancel()` and return. Cancelling a suspended
    // source defers its cancel handler until a resume that never comes — the
    // O_EVTONLY descriptor leaks — and releasing a still-suspended dispatch
    // object trips "BUG IN CLIENT OF LIBDISPATCH: Release of a suspended
    // object", which traps the process.
    //
    // The seam below IS that window: `afterSourceCreated` fires on the watcher
    // queue after creation and before publish/resume, so tearing down from
    // inside it reproduces the race with zero timing dependence. The observable
    // assertion is that the cancel handler still runs (descriptor closed); the
    // trap, if it regresses, kills this test process outright.
    @Test("a source torn down before it is resumed still closes its descriptor")
    func teardownBeforeResumeClosesDescriptor() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("suspended.json")
        try Data("{}".utf8).write(to: path)

        let closed = DispatchSemaphore(value: 0)
        let closedFD = ClosedFDBox()
        let seam = FileChangeWatcher.TestSeam(
            afterSourceCreated: { watcher, _ in
                // Exactly the losing race: teardown lands while the source is
                // created but neither published nor resumed.
                watcher.tearDownForTesting()
            },
            afterSourceClosed: { fd in
                closedFD.store(fd)
                closed.signal()
            }
        )

        do {
            let watcher = FileChangeWatcher(paths: [path], handler: { _ in }, seam: seam)
            // Idempotent teardown from a second thread must not double-cancel.
            watcher.cancel()
        }

        #expect(
            closed.wait(timeout: .now() + 5) == .success,
            "cancel handler never ran: the source was cancelled while suspended, leaking its fd"
        )
        let fd = closedFD.load()
        #expect(fd >= 0, "expected a real descriptor to have been closed")
    }

    /// Minimal lock box so the seam's `@Sendable` closure can hand a value back.
    private final class ClosedFDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32 = -1
        func store(_ newValue: Int32) { lock.lock(); value = newValue; lock.unlock() }
        func load() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
    }
}
