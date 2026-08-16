import Foundation
import Testing
@testable import ActivityWatch

private func tempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityPolicyTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let base: Double = 1_700_000_000

// MARK: - Policy defaults

@Test("POLICY: every default is the SAFE one — the feature is off out of the box")
func policyDefaultsAreSafe() {
    let policy = ActivityPolicy()
    #expect(!policy.captureEnabled)
    #expect(!policy.captureTitles)
    #expect(!policy.browserTitlesEnabled)
    #expect(!policy.appNameOnlyMode)
    #expect(!policy.allowModelAccess)
    #expect(policy.retentionDays == 30)
    #expect(!policy.excludedBundleIDs.isEmpty, "the starter exclusion list must not ship empty")
    // Nothing is capturable at all while the master switch is off.
    #expect(!policy.allowsCapture(bundleID: "com.apple.Terminal"))
    #expect(!policy.allowsTitleCapture(bundleID: "com.apple.Terminal"))
}

@Test("POLICY: the starter list covers credential, health and finance surfaces")
func starterExclusionsCoverTheObviousSurfaces() {
    let defaults = ActivityPolicy.defaultExcludedBundleIDs
    for bundle in [
        "com.1password.1password",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "com.apple.Health",
        "com.apple.Wallet",
    ] {
        #expect(defaults.contains(bundle), "starter list is missing \(bundle)")
    }
}

@Test("POLICY: always-excluded ids survive a user emptying the exclusion list")
func alwaysExcludedCannotBeRemoved() {
    var policy = ActivityPolicy(captureEnabled: true, excludedBundleIDs: [])
    // The user removes everything — including, if they could, ourselves.
    policy.excludedBundleIDs = []
    for bundle in ActivityPolicy.alwaysExcludedBundleIDs {
        #expect(policy.isExcluded(bundleID: bundle))
        #expect(!policy.allowsCapture(bundleID: bundle))
    }
    // Self-exclusion is resolved from Bundle.main at runtime, so the host
    // binary — whatever it is called in this build — can never record itself.
    if let host = Bundle.main.bundleIdentifier, !host.isEmpty {
        #expect(policy.isExcluded(bundleID: host))
    }
    #expect(policy.isExcluded(bundleID: ActivityPolicy.selfProcessBundleID))
    #expect(policy.isExcluded(bundleID: ActivityPolicy.selfProcessBundleID))
}

// MARK: - Policy persistence

@Test("POLICY: round-trips through disk unchanged")
func policyRoundTripsThroughDisk() throws {
    let store = ActivityPolicyStore(dataRoot: tempRoot())
    let policy = ActivityPolicy(
        captureEnabled: true,
        captureTitles: true,
        browserTitlesEnabled: true,
        appNameOnlyMode: false,
        allowModelAccess: true,
        excludedBundleIDs: ["com.example.one", "com.example.two"],
        retentionDays: 14
    )
    try store.save(policy)
    #expect(store.load() == policy)
}

@Test("POLICY: a missing or corrupt file loads the SAFE default, never 'on'")
func policyFailsClosed() throws {
    let root = tempRoot()
    let store = ActivityPolicyStore(dataRoot: root)
    // Missing.
    #expect(!store.load().captureEnabled)

    // Corrupt.
    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{ not json at all".utf8).write(to: store.fileURL)
    #expect(!store.load().captureEnabled)
    #expect(store.load() == ActivityPolicy())
}

@Test("POLICY: an older file missing keys decodes them to the SAFE default")
func policyDecodesMissingKeysSafely() throws {
    let store = ActivityPolicyStore(dataRoot: tempRoot())
    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // A file from a build that only knew about captureEnabled.
    try Data(#"{"captureEnabled": true}"#.utf8).write(to: store.fileURL)

    let loaded = store.load()
    #expect(loaded.captureEnabled)
    #expect(!loaded.captureTitles, "a key this build added must not default to ON")
    #expect(!loaded.browserTitlesEnabled)
    #expect(!loaded.allowModelAccess)
    #expect(loaded.retentionDays == 30)
    #expect(loaded.excludedBundleIDs == ActivityPolicy.defaultExcludedBundleIDs)
}

@Test("POLICY: an existing malformed file blocks mutation and preserves its bytes")
func corruptPolicyBlocksMutation() throws {
    let store = ActivityPolicyStore(dataRoot: tempRoot())
    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let original = Data("{ damaged policy".utf8)
    try original.write(to: store.fileURL)

    #expect(throws: ActivityPolicyStore.StoreError.self) {
        try store.save(ActivityPolicy(captureEnabled: true))
    }
    #expect(try Data(contentsOf: store.fileURL) == original)
}

@Test("POLICY: a dangling symlink is unavailable, not a missing bootstrap file")
func symlinkPolicyBlocksMutation() throws {
    let store = ActivityPolicyStore(dataRoot: tempRoot())
    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: store.fileURL,
        withDestinationURL: store.fileURL.deletingLastPathComponent()
            .appendingPathComponent("missing-target.json")
    )
    #expect(throws: ActivityPolicyStore.StoreError.self) {
        _ = try store.loadChecked()
    }
    #expect(throws: ActivityPolicyStore.StoreError.self) {
        try store.save(ActivityPolicy(captureEnabled: true))
    }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path)) != nil)
}

// MARK: - Retention

@Test("RETENTION: prunes past the configured window and leaves the rest")
func retentionPrunesConfiguredWindow() async throws {
    let root = tempRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = base + 100 * 86_400

    for age in [1.0, 5.0, 13.0, 20.0, 40.0] {
        let start = now - age * 86_400
        try await store.openSpan(ActivitySpan(
            startedAt: start, endedAt: start + 60, lastSeenAt: start + 60,
            bundleId: "com.age.\(Int(age))", appName: "Age \(Int(age))",
            eventCount: 1, closeReason: .idle
        ))
    }

    let runner = ActivityRetentionRunner(dataRoot: root)
    let policy = ActivityPolicy(captureEnabled: true, retentionDays: 14)
    #expect(runner.isDue(now: now), "a runner that has never run is due")

    let outcome = try await runner.runIfDue(store: store, policy: policy, now: now)
    #expect(outcome.ran)
    #expect(outcome.deleted == 2, "the 20 d and 40 d rows are past a 14 d window")

    let rows = try await store.querySpans(from: 0, to: now)
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { now - $0.startedAt <= 14 * 86_400 })
}

@Test("RETENTION: the schedule is durable across processes and not re-run early")
func retentionScheduleIsDurable() async throws {
    let root = tempRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = base + 100 * 86_400
    let policy = ActivityPolicy(captureEnabled: true, retentionDays: 30)

    let first = ActivityRetentionRunner(dataRoot: root)
    _ = try await first.runIfDue(store: store, policy: policy, now: now)

    // A FRESH runner — i.e. the next process — must see the stamp on disk.
    let second = ActivityRetentionRunner(dataRoot: root)
    #expect(!second.isDue(now: now + 60), "re-ran within the interval")
    let skipped = try await second.runIfDue(store: store, policy: policy, now: now + 60)
    #expect(!skipped.ran)

    #expect(second.isDue(now: now + ActivityRetentionRunner.defaultInterval + 1))
}

@Test("RETENTION: a backwards clock makes it due, not indefinitely skipped")
func retentionSurvivesBackwardsClock() async throws {
    let root = tempRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = base + 100 * 86_400
    let runner = ActivityRetentionRunner(dataRoot: root)
    _ = try await runner.runIfDue(
        store: store, policy: ActivityPolicy(captureEnabled: true), now: now
    )
    // The clock jumps back a year. A naive `now - last >= interval` would go
    // negative and skip pruning until the clock caught up.
    #expect(runner.isDue(now: now - 365 * 86_400))
}

@Test("RETENTION: pruning leaves nothing in the WAL sidecar")
func retentionCheckpointsTheWAL() async throws {
    let root = tempRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let now = base + 100 * 86_400
    for index in 0..<50 {
        let start = now - 40.0 * 86_400 + Double(index)
        try await store.openSpan(ActivitySpan(
            startedAt: start, endedAt: start + 30, lastSeenAt: start + 30,
            bundleId: "com.old.\(index)", appName: "Old", eventCount: 2, closeReason: .idle
        ))
    }
    let deleted = try await store.prune(olderThan: 30 * 86_400, now: now)
    #expect(deleted == 50)

    let dbPath = await store.databaseURL.path
    let attributes = try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")
    let walSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    #expect(walSize == 0, "prune left \(walSize) bytes of pruned rows in the WAL")
}

// MARK: - Title redaction adapter

@Test("REDACTION: an ordinary title survives; a secret-shaped one does not")
func titleRedactionAdapterBehaviour() {
    #expect(ActivityTitleRedaction.redact(nil) == nil)
    #expect(ActivityTitleRedaction.redact("   ") == nil)
    #expect(ActivityTitleRedaction.redact("notes.md — Terminal") == "notes.md — Terminal")
    #expect(ActivityTitleRedaction.redact("Inbox (3) — Mail") == "Inbox (3) — Mail")

    // Shaped secrets, caught by the SHARED MacControl redactor.
    for secret in [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789AB",
        "4111 1111 1111 1111",
    ] {
        #expect(
            ActivityTitleRedaction.redact(secret) == ActivityTitleRedaction.redactedPlaceholder,
            Comment(rawValue: "not redacted: \(secret)")
        )
    }

    // The placeholder carries NO digest of the secret — a sha256 of an OTP is
    // still a fingerprint of an OTP.
    let redacted = ActivityTitleRedaction.redact("sk-ant-api03-abcdefghijklmnopqrstuvwxyz01234567")
    #expect(redacted == "[redacted]")
    #expect(!(redacted ?? "").contains("sha"))

    // Long titles are truncated rather than stored whole.
    let long = String(repeating: "a", count: 5000)
    #expect((ActivityTitleRedaction.redact(long)?.count ?? 0) <= ActivityTitleRedaction.maxTitleChars)
}
