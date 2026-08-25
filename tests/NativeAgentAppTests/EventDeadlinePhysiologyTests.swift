import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row `physiology.eventDeadlineFeed`
// (Sources/NativeAgentApp/EventDeadlinePhysiology.swift:7).
//
// This is the shared nervous system for ELEVEN event-driven loops (Pursuit,
// Autonomy, DeskNotify, TriggerScheduler, Delegation, Maintenance,
// GitHubTracking, Heartbeat, WorkshopExecution, Workshop, ViewFileRefresh) and
// it had ZERO coverage. The three silent breaks named in the ledger row are
// each pinned below:
//
//   (1) `bufferingNewest(1)` coalesces a burst into one edge — correct for an
//       invalidation, FATAL if a consumer ever treats an edge as a count.
//   (2) it creates the PARENT directory but never the file, so the watcher
//       binds to a directory that exists.
//   (3) StoreChangeBus fan-in: if the bus half stops publishing, every one of
//       the eleven loops silently stops ticking with no error and no row.
//
// The negative control (an unrelated store on an unrelated path yields NO
// edge) is the mutation tooth: delete the `stores.contains || paths.contains`
// filter and it fails.
@Suite("Event/deadline physiology feed")
struct EventDeadlinePhysiologyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Bounded wait for the first invalidation edge. Never unbounded: a feed
    /// that can never fire must read as `false` in finite time, not hang.
    ///
    /// A POSITIVE step keeps re-publishing while it waits. That is not a
    /// timing hack — `StoreChangeBus.changes()` buffers `.bufferingNewest(32)`,
    /// so under full-suite parallelism a single change from THIS test can be
    /// legitimately evicted by 32 newer changes from other suites before the
    /// fan-in task drains. The property under test is "a matching change
    /// produces an edge", not "one specific publish survives an unrelated
    /// flood". A green run breaks at the first edge, so the deadline costs
    /// nothing.
    private func firstEdge(
        _ stream: AsyncStream<Void>,
        withinSeconds seconds: Double,
        republish: (@Sendable () -> Void)? = nil
    ) async -> Bool {
        let reader = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        let watchdog = Task {
            let deadline = Date().addingTimeInterval(seconds)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                republish?()
            }
            reader.cancel()
        }
        let saw = await reader.value
        watchdog.cancel()
        return saw
    }

    @Test("a matching store publish is one invalidation edge")
    func storeBusFanInFires() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("desk/desk_ops.jsonl")

        let stream = EventDeadlinePhysiology.storeAndFileEvents(
            paths: [feed],
            stores: [.desk]
        )
        let publish: @Sendable () -> Void = { StoreChangeBus.shared.emit(StoreChange(store: .desk, path: feed)) }
        publish()

        #expect(await firstEdge(stream, withinSeconds: 30, republish: publish))
    }

    @Test("a publish on a watched PATH fires even when its store is not subscribed")
    func pathFanInFiresWithoutStoreSubscription() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("github/commands.jsonl")

        // stores: [] — the ONLY thing that can admit this change is the path
        // match. Every consumer that arms on a bare path depends on it.
        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [feed], stores: [])
        let publish: @Sendable () -> Void = { StoreChangeBus.shared.emit(StoreChange(store: .githubCommand, path: feed)) }
        publish()

        #expect(await firstEdge(stream, withinSeconds: 30, republish: publish))
    }

    @Test("an unrelated store on an unrelated path yields NO edge")
    func unrelatedChangeIsFiltered() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("desk/desk_ops.jsonl")
        let unrelated = root.appendingPathComponent("workshop/executions/other.jsonl")

        // Subscribes to NO store, so a concurrently running suite emitting its
        // own desk change cannot leak an edge into this assertion — only a
        // path match could, and this path is UUID-unique to this test.
        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [feed], stores: [])
        StoreChangeBus.shared.emit(StoreChange(store: .desk, path: unrelated))

        #expect(await firstEdge(stream, withinSeconds: 2) == false)
    }

    @Test("a burst coalesces — an edge is an invalidation, never a count")
    func burstCoalescesIntoFewerEdges() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("github/commands-\(UUID().uuidString).jsonl")

        let burst = 50
        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [feed], stores: [])
        let publish: @Sendable () -> Void = {
            StoreChangeBus.shared.emit(StoreChange(store: .githubCommand, path: feed))
        }
        for _ in 0..<burst { publish() }

        let counter = EdgeCounter()
        let reader = Task {
            for await _ in stream { await counter.increment() }
        }
        // Poll until the first observed edge instead of trusting the initial
        // burst to survive: `StoreChangeBus.changes()` buffers
        // `.bufferingNewest(32)`, so under full-suite parallelism ALL fifty of
        // this test's pre-drain emits can be legitimately evicted by foreign
        // changes before the fan-in task ever runs — a fixed wait then times
        // out at zero. The republish keeps the property under test honest
        // ("a burst of matching changes produces an edge"), and every
        // republish only ADDS publishes, so the coalescing assertion below
        // (`observed < burst` while total publishes >= burst) can only get
        // harder to satisfy, never vacuous. The settle window then catches
        // any extra edges the burst could still deliver.
        let deadline = Date().addingTimeInterval(30)
        while await counter.value == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            publish()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        reader.cancel()

        let observed = await counter.value
        #expect(observed >= 1, "the burst must produce at least one invalidation")
        #expect(
            observed < burst,
            "bufferingNewest(1) must coalesce: \(observed) edges for \(burst) publishes means a consumer could read an edge as a count"
        )
    }

    @Test("the feed creates the watched PARENT directory and never the file itself")
    func createsParentDirectoryButNotTheFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root
            .appendingPathComponent("desk", isDirectory: true)
            .appendingPathComponent("desk_ops.jsonl")

        #expect(FileManager.default.fileExists(atPath: feed.deletingLastPathComponent().path) == false)

        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [feed], stores: [.desk])
        _ = stream // retained: the watcher's lifetime is the stream's

        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(
            atPath: feed.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        )
        #expect(parentExists, "the watcher must bind to a directory that exists")
        #expect(isDirectory.boolValue)
        // The FILE is deliberately NOT created — arming must never fabricate a
        // feed. `can never fire` vs `hasn't fired` stays a real distinction and
        // no consumer inherits a phantom empty feed.
        #expect(FileManager.default.fileExists(atPath: feed.path) == false)
    }
}

private actor EdgeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
