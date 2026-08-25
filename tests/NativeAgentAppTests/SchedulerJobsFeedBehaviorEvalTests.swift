import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: core.workshop
// Ledger row: scheduler.jobs.feed
//
// These exercise the actual NativeClient create/list/cancel boundary and the
// scheduler runner's settlement update against one isolated canonical root.
// The adverse cases intentionally preserve their source bytes: a damaged
// scheduler feed is unavailable or partial, never silently reported as zero.

@Suite("Scheduler jobs feed behavior", .serialized)
struct SchedulerJobsFeedBehaviorEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-jobs-feed-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeRows(_ rows: [Any], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows).write(to: path)
    }

    @Test("isolated create list cancel reload retains row order and the canonical root")
    func createListCancelReload() async throws {
        let dataRoot = try root("roundtrip")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let client = NativeClient(baseURL: "", dataRootOverride: dataRoot)

        let first = try await client.createJob(name: "First reflection", kind: "dream", intervalSeconds: 120)
        let second = try await client.createJob(name: "Second reflection", kind: "dream", intervalSeconds: 180)
        #expect(FileManager.default.fileExists(atPath: client.schedulerJobsPath.path))

        guard case .current(let initial) = await client.schedulerJobsFeed() else {
            Issue.record("writer-produced scheduler feed must be current")
            return
        }
        #expect(initial.map(\.id) == [first.id, second.id])
        let allInitiallyEnabled = initial.allSatisfy { $0.enabled }
        #expect(allInitiallyEnabled)

        let cancelled = try await client.cancelSchedulerJob(id: first.id)
        #expect(cancelled.id == first.id)
        #expect(!cancelled.enabled)

        let reloaded = NativeClient(baseURL: "", dataRootOverride: dataRoot)
        guard case .current(let afterCancel) = await reloaded.schedulerJobsFeed() else {
            Issue.record("a second client must reload the same canonical scheduler feed")
            return
        }
        #expect(afterCancel.map(\.id) == [first.id, second.id])
        #expect(afterCancel.first?.enabled == false)
        #expect(afterCancel.last?.enabled == true)
    }

    @Test("runner settlement updates the same feed instead of producing a stale list")
    func runnerUpdateReloadsThroughFeed() async throws {
        let dataRoot = try root("update")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let path = dataRoot.appendingPathComponent("scheduler/jobs.json")
        try writeRows([[
            "id": "advancing-job",
            "name": "Advancing job",
            "kind": "dream",
            "enabled": true,
            "oneShot": false,
            "intervalSeconds": 120,
            "nextRunAtEpoch": now.timeIntervalSince1970 - 30,
            "schedule": ["type": "every", "seconds": 120],
            "payload": ["objective": "reflection"],
        ]], to: path)

        let runner = SchedulerDueJobRunner(root: dataRoot)
        let claimed = try await runner.claimDueJobs(now: now, maxJobs: 1)
        let job = try #require(claimed.jobs.first)
        try await runner.update(
            job: job,
            result: .init(status: "completed", detail: "settled", output: .object([:])),
            at: now
        )

        guard case .current(let jobs) = await NativeClient(baseURL: "", dataRootOverride: dataRoot).schedulerJobsFeed(),
              let updated = jobs.first else {
            Issue.record("settled job must reload through the canonical feed")
            return
        }
        #expect(updated.id == "advancing-job")
        #expect(updated.enabled)
        #expect(updated.lastRunAt != nil)
        #expect(updated.nextRunAt != nil)
    }

    @Test @MainActor func appModelCreateUsesItsOwnRoot() async throws {
        let dataRoot = try root("app-model")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let app = AppModel(dataRootOverride: dataRoot, startBackgroundTasks: false)

        let outcome = await app.createDreamJob()
        #expect(outcome.succeeded)
        #expect(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("scheduler/jobs.json").path
        ))
        let feed = await app.client.schedulerJobsFeed()
        #expect(feed.failureDetail == nil)
    }

    @Test("feed health separates disabled historical rows from enabled scheduler stalls")
    func enabledJobAdvancementHealthIsBounded() async throws {
        let dataRoot = try root("health")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-181))
        let path = dataRoot.appendingPathComponent("scheduler/jobs.json")
        try writeRows([
            [
                "id": "stalled", "name": "Stalled", "kind": "dream", "enabled": true,
                "intervalSeconds": 60, "nextRunAt": old, "lastRunAt": old,
            ],
            [
                "id": "dormant", "name": "Dormant", "kind": "dream", "enabled": false,
                "intervalSeconds": 60, "nextRunAt": old, "lastRunAt": old,
            ],
        ], to: path)

        guard case .current(let jobs) = await NativeClient(baseURL: "", dataRootOverride: dataRoot).schedulerJobsFeed() else {
            Issue.record("valid scheduler health rows must load")
            return
        }
        let health = SchedulerJobsFeedHealth.assess(jobs, now: now)
        #expect(health.rowCountByKind == ["dream": 2])
        #expect(health.enabledOverdueNextRunIDs == ["stalled"])
        #expect(health.enabledStaleLastRunIDs == ["stalled"])
        #expect(!health.enabledOverdueNextRunIDs.contains("dormant"))
    }

    @Test("absent malformed partial and unavailable stores are not reported as empty")
    func adverseFeedStatesStayHonest() async throws {
        let dataRoot = try root("adverse")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let client = NativeClient(baseURL: "", dataRootOverride: dataRoot)
        let path = client.schedulerJobsPath

        #expect(await client.schedulerJobsFeed() == .sourceAbsent)
        await #expect(throws: SchedulerJobsFeedError.self) {
            _ = try await client.getJobs()
        }

        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data(#"[{"id":"keep"}, BROKEN]"#.utf8)
        try corrupt.write(to: path)
        guard case .unavailable(let detail) = await client.schedulerJobsFeed() else {
            Issue.record("malformed bytes must be unavailable, not an empty feed")
            return
        }
        // JSONSerialization's localized parse text is platform-owned. The
        // production contract is the typed unavailable state and its honest
        // detail, not a brittle spelling supplied by Foundation.
        #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(SchedulerJobsFeedState.unavailable(detail).failureDetail == "Schedule source is unavailable: \(detail)")
        await #expect(throws: (any Error).self) {
            _ = try await client.createJob(name: "Must not overwrite", kind: "dream", intervalSeconds: 120)
        }
        #expect(try Data(contentsOf: path) == corrupt)

        try writeRows([
            ["id": "valid", "name": "Valid", "kind": "dream", "enabled": true],
            "not a scheduler job",
        ], to: path)
        guard case .partial(let validRows, let rejectedRows) = await client.schedulerJobsFeed() else {
            Issue.record("mixed durable rows must report a partial feed")
            return
        }
        #expect(validRows.map(\.id) == ["valid"])
        #expect(rejectedRows == 1)

        let tooManyRows: [Any] = (0...NativeClient.schedulerJobsFeedMaximumRows).map { index in
            ["id": "bounded-\(index)", "name": "Bounded", "kind": "dream", "enabled": true]
        }
        try writeRows(tooManyRows, to: path)
        guard case .unavailable(let boundsDetail) = await client.schedulerJobsFeed() else {
            Issue.record("an oversized scheduler feed must be unavailable, not partially or silently empty")
            return
        }
        #expect(boundsDetail.contains("rows"))

        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        guard case .unavailable(let directoryDetail) = await client.schedulerJobsFeed() else {
            Issue.record("a directory in place of scheduler/jobs.json must be unavailable")
            return
        }
        #expect(directoryDetail.contains("directory"))
    }
}
