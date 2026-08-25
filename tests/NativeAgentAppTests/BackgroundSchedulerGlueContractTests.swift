// Fence app.background — SchedulerDueJobRunner store glue.
//
// Ledger rows closed here:
//   app.background.scheduler.defaultCycleJobs
//   app.background.scheduler.oneShotPrune
//
// The pure row helpers (`upsertDefaultCycleJob`, `pruneCompletedOneShotRows`)
// already have tests. What had none is the ACTOR-LEVEL round trip: read
// jobs.json under the lock, mutate, write it back, and report a count that
// drives an activity receipt. That is where "repaired 0 / removed 0" and
// "silently rewrote the user's schedule" become indistinguishable.

import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private func schedulerTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundScheduler-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("scheduler", isDirectory: true),
        withIntermediateDirectories: true)
    return root
}

private func writeJobs(_ rows: [[String: Any]], to root: URL) throws {
    let url = root.appendingPathComponent("scheduler/jobs.json")
    try JSONSerialization.data(withJSONObject: rows, options: []).write(to: url)
}

private func readJobs(_ root: URL) throws -> [[String: Any]] {
    let url = root.appendingPathComponent("scheduler/jobs.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]) ?? []
}

@Suite("app.background scheduler glue")
struct BackgroundSchedulerGlueContractTests {

    @Test("default cycle repair writes both canonical jobs and is a no-op on a second pass")
    func ensureDefaultCycleJobsWritesBothJobsIdempotently() async throws {
        let root = try schedulerTempRoot("defaults")
        defer { try? FileManager.default.removeItem(at: root) }

        // A user-authored row that must survive the repair byte-for-byte.
        let userRow: [String: Any] = [
            "id": "user-authored-job",
            "name": "My Own Job",
            "kind": "custom",
            "enabled": true,
            "intervalSeconds": 900,
            "objective": "do not touch me",
        ]
        try writeJobs([userRow], to: root)
        let userBytesBefore = try Data(contentsOf: root.appendingPathComponent("scheduler/jobs.json"))

        let runner = SchedulerDueJobRunner(root: root)
        // Fixed instant so the catch-up branch is deterministic: 04:00 UTC is
        // 22:00/23:00 the previous day in America/Chicago, i.e. BEFORE the
        // 03:30 dream slot — no catch-up arming either way, and the assertions
        // below never depend on which side of the slot "now" lands on.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repaired = try await runner.ensureDefaultCycleJobs(now: now)
        #expect(repaired.count == 2, "a fresh schedule must mint BOTH canonical cycle jobs, got \(repaired)")

        let rows = try readJobs(root)
        let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id, row)
        })
        #expect(byId["nativeagent-nightly-dream"]?["kind"] as? String == "dream")
        #expect((byId["nativeagent-nightly-dream"]?["intervalSeconds"] as? NSNumber)?.doubleValue == 86_400)
        #expect(byId["nativeagent-weekly-rem"]?["kind"] as? String == "rem")
        #expect((byId["nativeagent-weekly-rem"]?["intervalSeconds"] as? NSNumber)?.doubleValue == 604_800)
        // Both must be armed with a real next run, not left at epoch zero.
        for id in ["nativeagent-nightly-dream", "nativeagent-weekly-rem"] {
            let epoch = (byId[id]?["nextRunAtEpoch"] as? NSNumber)?.doubleValue ?? 0
            #expect(epoch > now.timeIntervalSince1970 - 1,
                    "\(id) must be armed at or after now, got \(epoch)")
        }

        // The user's row survives with every field intact.
        let survivor = byId["user-authored-job"]
        #expect(survivor?["objective"] as? String == "do not touch me")
        #expect((survivor?["intervalSeconds"] as? NSNumber)?.doubleValue == 900)
        #expect(survivor?["kind"] as? String == "custom")

        // Second pass: nothing to repair, and the file is left alone.
        let bytesAfterFirst = try Data(contentsOf: root.appendingPathComponent("scheduler/jobs.json"))
        let again = try await runner.ensureDefaultCycleJobs(now: now)
        #expect(again.isEmpty, "a repeat repair must report nothing repaired, got \(again)")
        let bytesAfterSecond = try Data(contentsOf: root.appendingPathComponent("scheduler/jobs.json"))
        #expect(bytesAfterFirst == bytesAfterSecond, "an idempotent pass must not rewrite jobs.json")
        #expect(userBytesBefore != bytesAfterFirst, "sanity: the first pass DID write")
    }

    @Test("a corrupt schedule is never replaced with genesis defaults")
    func ensureDefaultCycleJobsFailsClosedOnDamage() async throws {
        let root = try schedulerTempRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scheduler/jobs.json")
        let damaged = Data("{\"jobs\": [] ".utf8)
        try damaged.write(to: url)

        let runner = SchedulerDueJobRunner(root: root)
        await #expect(throws: (any Error).self) {
            _ = try await runner.ensureDefaultCycleJobs(now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        // The load-bearing part: the damaged bytes are still there. A repair
        // that "recovered" by writing two default jobs would have erased every
        // user job the file held.
        let afterAttempt = try Data(contentsOf: url)
        #expect(afterAttempt == damaged)
    }

    @Test("one-shot prune removes exactly the expired completed rows and reports the count")
    func pruneCompletedOneShotJobsRewritesStoreAndReportsCount() async throws {
        let root = try schedulerTempRoot("oneshot")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let expired = iso.string(from: now.addingTimeInterval(-30 * 86_400))
        let recent = iso.string(from: now.addingTimeInterval(-1 * 86_400))

        try writeJobs([
            ["id": "expired-a", "oneShot": true, "completedAt": expired, "kind": "custom"],
            ["id": "expired-b", "oneShot": true, "completedAt": expired, "kind": "custom"],
            ["id": "recent", "oneShot": true, "completedAt": recent, "kind": "custom"],
            ["id": "never-completed", "oneShot": true, "kind": "custom"],
            ["id": "recurring", "oneShot": false, "completedAt": expired, "kind": "dream",
             "objective": "keep"],
        ], to: root)

        let runner = SchedulerDueJobRunner(root: root)
        let removed = try await runner.pruneCompletedOneShotJobs(now: now)
        // The count is what the activity receipt prints — pin it, or "removed 0"
        // and "removed 2" read the same in the feed.
        #expect(removed == 2)

        let ids = try readJobs(root).compactMap { $0["id"] as? String }
        #expect(Set(ids) == ["recent", "never-completed", "recurring"])
        // A recurring row with an ancient completedAt must be untouched, payload
        // included — oneShot is the discriminator, not completedAt.
        let recurring = try readJobs(root).first { $0["id"] as? String == "recurring" }
        #expect(recurring?["objective"] as? String == "keep")

        // Idempotent: nothing left, count is honestly zero, file unchanged.
        let bytes = try Data(contentsOf: root.appendingPathComponent("scheduler/jobs.json"))
        let second = try await runner.pruneCompletedOneShotJobs(now: now)
        #expect(second == 0)
        let bytesAfter = try Data(contentsOf: root.appendingPathComponent("scheduler/jobs.json"))
        #expect(bytesAfter == bytes)
    }

    @Test("one-shot retention window is a week, and the boundary is strict")
    func oneShotRetentionWindowBoundary() throws {
        #expect(SchedulerDueJobRunner.oneShotRetentionSeconds == 7 * 86_400)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        func row(_ ageSeconds: Double) -> JSONValue {
            .object([
                "id": .string("j"),
                "oneShot": .bool(true),
                "completedAt": .string(iso.string(from: now.addingTimeInterval(-ageSeconds))),
            ])
        }
        // Exactly at the window → kept (strictly-greater comparison).
        #expect(SchedulerDueJobRunner.pruneCompletedOneShotRows([row(7 * 86_400)], now: now).removed == 0)
        // One second past → removed.
        #expect(SchedulerDueJobRunner.pruneCompletedOneShotRows([row(7 * 86_400 + 1)], now: now).removed == 1)
    }
}
