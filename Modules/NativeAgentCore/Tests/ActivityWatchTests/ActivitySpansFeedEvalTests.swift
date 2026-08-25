import Foundation
import Testing
@testable import ActivityWatch

private func activitySpansFeedRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivitySpansFeed-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("ACTIVITY SPANS FEED: due retention checkpoints an in-window WAL and names stopped capture")
func activitySpansFeedStaysFreshAndCheckpointed() async throws {
    let root = activitySpansFeedRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = 1_700_000_000.0
    let enabled = ActivityPolicy(captureEnabled: true)

    // A current span is the positive control. Its payload is intentionally
    // uninteresting: the health surface may inspect only liveness metadata.
    try await store.openSpan(
        id: "fresh", bundleId: "com.example.editor", appName: "Editor", at: now - 60
    )
    for index in 0..<300 {
        let timestamp = now - 600 - Double(index)
        try await store.openSpan(
            id: "in-window-\(index)",
            bundleId: "com.example.\(index)", appName: String(repeating: "A", count: 512),
            at: timestamp
        )
    }

    let beforeMaintenance = try await store.activitySpansFeedHealth(policy: enabled, now: now)
    #expect(beforeMaintenance.captureIsFresh, "precondition: capture never produced a fresh span")

    // No row is eligible for deletion. The due pass must still checkpoint;
    // otherwise a live, in-window feed accumulates a capped WAL forever.
    let runner = ActivityRetentionRunner(dataRoot: root)
    let outcome = try await runner.runIfDue(store: store, policy: enabled, now: now)
    #expect(outcome.ran)
    #expect(outcome.deleted == 0, "precondition: this exercise is the no-delete maintenance path")

    let healthy = try await store.activitySpansFeedHealth(policy: enabled, now: now)
    #expect(healthy.status == .healthy)
    #expect(healthy.newestSpanAt == now - 60)
    #expect(
        healthy.walBytes <= healthy.databaseBytes * ActivitySpanStore.maximumWALToDatabaseMultiplier,
        "WAL is \(healthy.walBytes) B against \(healthy.databaseBytes) B DB after due maintenance"
    )

    let staleRoot = activitySpansFeedRoot()
    let staleStore = try ActivitySpanStore(dataRoot: staleRoot)
    try await staleStore.openSpan(
        id: "stale", bundleId: "com.example.stale", appName: "Stale", at: now - 3_600
    )
    let stale = try await staleStore.activitySpansFeedHealth(policy: enabled, now: now)
    #expect(
        stale.status == .captureSilentlyStoppedAndCheckpointOverdue,
        "capture enabled with no span in the named freshness window must not look healthy"
    )
}
