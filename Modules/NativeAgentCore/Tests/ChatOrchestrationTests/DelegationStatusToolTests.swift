import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - delegation_status projection + dispatcher-surface tests (W2)
//
// Hermetic by construction: every store path is rooted at a per-test temp
// directory injected through `agentBridgeConfigRoot` (the same seam
// claude_message uses), and the clock is passed explicitly to
// `recentJobs(now:)`. Nothing here reads the live ~/.config, and nothing
// here can pass because of the wall clock.
//
// Fixtures mirror the RECORD SHAPES READ OFF THE JS WRITERS, not the shapes a
// prompt described: the claude record (script/claude_thread_wakeup.js) and
// the codex reply-job record (script/codex_thread_wakeup.js) do not share a
// field set, and the tests pin that asymmetry deliberately.

@Suite("DelegationStatusTool")
struct DelegationStatusToolTests {

    // 2026-08-05T19:00:00Z — a fixed instant every fixture is written against.
    private static let now = Date(timeIntervalSince1970: 1_785_956_400)

    /// The clock constant is itself load-bearing: every elapsed and stall
    /// expectation below is arithmetic against it, so an off-by-N epoch would
    /// silently retune all of them at once. Pin it against the ISO string.
    @Test func fixedClockIsTheInstantTheFixturesAssume() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.string(from: Self.now) == "2026-08-05T19:00:00Z")
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelegationStatus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func claudeDir(_ root: URL) -> URL {
        let dir = root.appendingPathComponent("claude-bridge/wake-jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func codexDir(_ root: URL, undelivered: Bool = false) -> URL {
        var dir = root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs", isDirectory: true)
        if undelivered { dir = dir.appendingPathComponent("undelivered", isDirectory: true) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ompDir(_ root: URL) -> URL {
        let dir = root.appendingPathComponent("omp-bridge/wake-jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: String, to directory: URL, named name: String) {
        try? Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func projector(_ root: URL) -> DelegationStatusProjector {
        DelegationStatusProjector(configRoot: root)
    }

    private func job(_ rows: [DelegationJobProjection], _ id: String) -> DelegationJobProjection? {
        rows.first { $0.id == id }
    }

    // MARK: - Fixtures (relative to `now` = 19:00:00Z)

    /// Enqueued but never claimed: createdAt only, no runner fields at all.
    private func writeFreshJob(_ dir: URL) {
        write("""
        {"messageId":"FRESH-1","createdAt":"2026-08-05T18:59:30.000Z","state":"queued","topicSlug":"w2-delegation"}
        """, to: dir, named: "FRESH-1.json")
    }

    /// Claimed 60s ago; the runner has not stamped startedAt/deadlineAt yet.
    private func writeClaimedJob(_ dir: URL) {
        write("""
        {"messageId":"CLAIMED-1","createdAt":"2026-08-05T18:58:00.000Z",
         "claimedAt":"2026-08-05T18:59:00.000Z","state":"claimed",
         "claimId":"c-1","pid":1234,"topicSlug":"w2-delegation"}
        """, to: dir, named: "CLAIMED-1.json")
    }

    /// Running and healthy: started 10 min ago, deadline an hour out, and
    /// progressAt (child liveness) is NEWER than heartbeatAt (runner liveness).
    private func writeRunningJob(_ dir: URL) {
        write("""
        {"messageId":"RUNNING-1","createdAt":"2026-08-05T18:50:00.000Z",
         "claimedAt":"2026-08-05T18:50:00.500Z","startedAt":"2026-08-05T18:50:00.900Z",
         "deadlineAt":"2026-08-05T19:50:00.900Z","state":"running",
         "heartbeatAt":"2026-08-05T18:58:00.000Z","progressAt":"2026-08-05T18:59:00.000Z",
         "progressCpuMs":247110,"stallSeconds":600,"timeoutSeconds":3600,
         "topicSlug":"w2-delegation"}
        """, to: dir, named: "RUNNING-1.json")
    }

    /// Settled: completed 12 min after start, delivered.
    private func writeCompletedJob(_ dir: URL) {
        write("""
        {"messageId":"DONE-1","createdAt":"2026-08-05T18:30:00.000Z",
         "claimedAt":"2026-08-05T18:30:00.100Z","startedAt":"2026-08-05T18:30:00.500Z",
         "deadlineAt":"2026-08-05T19:30:00.500Z","state":"settled",
         "heartbeatAt":"2026-08-05T18:42:00.000Z","progressAt":"2026-08-05T18:41:00.000Z",
         "stallSeconds":600,"runStatus":"completed","status":"completed",
         "completedAt":"2026-08-05T18:42:00.500Z","deliveryLost":false,
         "completionText":null,"topicSlug":"w2-delegation"}
        """, to: dir, named: "DONE-1.json")
    }

    /// Genuinely stalled: deadline passed 30 minutes ago, still not settled.
    private func writeStalledJob(_ dir: URL) {
        write("""
        {"messageId":"STALLED-1","createdAt":"2026-08-05T17:00:00.000Z",
         "claimedAt":"2026-08-05T17:00:00.100Z","startedAt":"2026-08-05T17:00:00.500Z",
         "deadlineAt":"2026-08-05T18:30:00.500Z","state":"running",
         "heartbeatAt":"2026-08-05T18:29:00.000Z","progressAt":"2026-08-05T18:05:00.000Z",
         "stallSeconds":600,"topicSlug":"w2-delegation"}
        """, to: dir, named: "STALLED-1.json")
    }

    /// Legacy: predates startedAt/deadlineAt/stallSeconds/topicSlug entirely.
    private func writeLegacyJob(_ dir: URL) {
        write("""
        {"messageId":"LEGACY-1","createdAt":"2026-08-05T18:40:00.000Z","state":"running"}
        """, to: dir, named: "LEGACY-1.json")
    }

    private func writeCodexInFlightJob(_ dir: URL) {
        write("""
        {"id":"CODEX-1","phase":"watching_turn","createdAt":"2026-08-05T18:55:00.000Z",
         "threadId":"t-1","turnId":"u-1","clientUserMessageId":"nativeagent-codex-abc",
         "boundAt":"2026-08-05T18:55:00.300Z",
         "entries":[{"id":"e1","key":null,"payload":{"messageId":"m1","topic":"Codex Bridge / Stalled Turns!"}}],
         "lastWait":{"observedAt":"2026-08-05T18:58:30.000Z","status":"pending",
                     "waitSource":"exact_timeout","threadId":"t-1","turnId":"u-1"}}
        """, to: dir, named: "CODEX-1.json")
    }

    private func writeCodexUndeliveredJob(_ dir: URL) {
        write("""
        {"id":"CODEX-UNDELIVERED","phase":"watching_turn","createdAt":"2026-08-05T18:45:00.000Z",
         "threadId":"t-2","turnId":"u-2","clientUserMessageId":"nativeagent-codex-xyz",
         "boundAt":"2026-08-05T18:45:00.200Z",
         "entries":[{"id":"e2","key":null,"payload":{"messageId":"m2","topic":"gh command"}}],
         "completedExecution":{"threadId":"t-2","turnId":"u-2","attempts":[],
           "turnResult":{"status":"completed","completedAt":"2026-08-05T18:46:00.000Z",
                         "durationMs":57772,"message":"\(String(repeating: "A", count: 260))",
                         "waitSource":"rollout_file_event"}}}
        """, to: dir, named: "CODEX-UNDELIVERED.outcome_unknown.json")
    }

    // MARK: - Projection correctness

    @Test func projectsClaudeLifecycleFieldsAndElapsed() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        writeFreshJob(dir); writeClaimedJob(dir); writeRunningJob(dir); writeCompletedJob(dir)

        let rows = projector(root).recentJobs(now: Self.now)

        let fresh = try! #require(job(rows, "FRESH-1"))
        #expect(fresh.source == "claude")
        #expect(fresh.agent == "claude")
        #expect(fresh.topicSlug == "w2-delegation")
        #expect(fresh.state == "queued")
        #expect(fresh.claimedAt == nil)
        #expect(fresh.startedAt == nil)
        #expect(fresh.lastLiveness == nil)
        // Elapsed falls back to createdAt when nothing later exists: 30s.
        #expect(fresh.elapsedSeconds == 30)

        let claimed = try! #require(job(rows, "CLAIMED-1"))
        #expect(claimed.claimedAt == "2026-08-05T18:59:00.000Z")
        #expect(claimed.startedAt == nil)
        // claimedAt wins over createdAt as the elapsed anchor: 60s, not 120s.
        #expect(claimed.elapsedSeconds == 60)

        let running = try! #require(job(rows, "RUNNING-1"))
        #expect(running.startedAt == "2026-08-05T18:50:00.900Z")
        // lastLiveness is max(heartbeatAt, progressAt) — progressAt is newer.
        #expect(running.lastLiveness == "2026-08-05T18:59:00.000Z")
        #expect(running.completedAt == nil)
        // startedAt anchors elapsed: 18:50:00.9 → 19:00:00 ≈ 599s.
        #expect(running.elapsedSeconds == 599)

        let done = try! #require(job(rows, "DONE-1"))
        #expect(done.runStatus == "completed")
        #expect(done.status == "completed")
        #expect(done.deliveryLost == false)
        // A settled job's elapsed stops at completedAt and does NOT keep
        // growing with the clock: 18:30:00.5 → 18:42:00.5 = 720s exactly.
        #expect(done.elapsedSeconds == 720)
    }

    @Test func heartbeatWinsWhenItIsNewerThanProgress() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        // Inverted vs writeRunningJob: heartbeatAt is the LATER of the two.
        write("""
        {"messageId":"HB-1","createdAt":"2026-08-05T18:50:00.000Z","startedAt":"2026-08-05T18:50:00.000Z",
         "deadlineAt":"2026-08-05T19:50:00.000Z","state":"running",
         "heartbeatAt":"2026-08-05T18:59:30.000Z","progressAt":"2026-08-05T18:55:00.000Z"}
        """, to: dir, named: "HB-1.json")

        let row = try! #require(job(projector(root).recentJobs(now: Self.now), "HB-1"))
        #expect(row.lastLiveness == "2026-08-05T18:59:30.000Z")
    }

    @Test func stalledIsDeadlineDrivenAndTerminalJobsAreNeverStalled() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        writeRunningJob(dir); writeStalledJob(dir); writeCompletedJob(dir)

        let rows = projector(root).recentJobs(now: Self.now)

        let running = try! #require(job(rows, "RUNNING-1"))
        #expect(running.stalled == false)
        #expect(running.stallBasis == .deadline)

        let stalled = try! #require(job(rows, "STALLED-1"))
        #expect(stalled.stalled == true)
        #expect(stalled.stallBasis == .deadline)

        // Settled 18 minutes ago with a deadline that has ALSO passed — the
        // terminal check must run first or every completed job reads stalled.
        let done = try! #require(job(rows, "DONE-1"))
        #expect(done.stalled == false)
        #expect(done.stallBasis == .terminal)
    }

    /// The regression this whole tool exists to prevent: a job whose RUN
    /// finished but which has not yet settled must never read as stalled just
    /// because its run deadline has since passed. claude_thread_wakeup.js
    /// writes state "delivering" (L1457, alongside runStatus) and
    /// "spawn_failed" (L2222) in exactly that position — both carry a
    /// deadlineAt and neither carries completedAt.
    @Test func postRunStatesAreTerminalEvenWithAPassedDeadline() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        // Ran, finished, deadline has passed, still posting to the bridge.
        write("""
        {"messageId":"DELIVERING-1","createdAt":"2026-08-05T17:00:00.000Z","startedAt":"2026-08-05T17:00:00.000Z",
         "deadlineAt":"2026-08-05T18:00:00.000Z","state":"delivering","runStatus":"completed",
         "heartbeatAt":"2026-08-05T17:50:00.000Z","stallSeconds":600}
        """, to: dir, named: "DELIVERING-1.json")
        // Never got off the ground; deadline long past.
        write("""
        {"messageId":"SPAWNFAIL-1","createdAt":"2026-08-05T17:00:00.000Z","startedAt":"2026-08-05T17:00:00.000Z",
         "deadlineAt":"2026-08-05T18:00:00.000Z","state":"spawn_failed","error":"ENOENT",
         "stallSeconds":600}
        """, to: dir, named: "SPAWNFAIL-1.json")

        let rows = projector(root).recentJobs(now: Self.now)

        let delivering = try! #require(job(rows, "DELIVERING-1"))
        #expect(delivering.stalled == false)
        #expect(delivering.stallBasis == .terminal)

        let spawnFailed = try! #require(job(rows, "SPAWNFAIL-1"))
        #expect(spawnFailed.stalled == false)
        #expect(spawnFailed.stallBasis == .terminal)
    }

    @Test func deliveryOutcomeIsReadOffTheRecordNeverInferred() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        write("""
        {"messageId":"DELIVERED-1","createdAt":"2026-08-05T18:00:00.000Z","state":"settled",
         "completedAt":"2026-08-05T18:10:00.000Z","deliveryLost":false,"bridgeStatus":"delivered"}
        """, to: dir, named: "DELIVERED-1.json")
        write("""
        {"messageId":"LOST-1","createdAt":"2026-08-05T18:00:00.000Z","state":"settled",
         "completedAt":"2026-08-05T18:10:00.000Z","deliveryLost":true,"bridgeStatus":"failed",
         "completionText":"the reply that never landed"}
        """, to: dir, named: "LOST-1.json")
        write("""
        {"messageId":"UNKNOWN-1","createdAt":"2026-08-05T18:00:00.000Z","state":"settled",
         "completedAt":"2026-08-05T18:10:00.000Z","deliveryLost":false,"bridgeStatus":"unknown"}
        """, to: dir, named: "UNKNOWN-1.json")
        // A record that says nothing about delivery must yield nothing.
        write("""
        {"messageId":"SILENT-1","createdAt":"2026-08-05T18:00:00.000Z","state":"settled",
         "completedAt":"2026-08-05T18:10:00.000Z"}
        """, to: dir, named: "SILENT-1.json")

        let rows = projector(root).recentJobs(now: Self.now)
        #expect(try! #require(job(rows, "DELIVERED-1")).deliveryOutcome == "delivered")
        #expect(try! #require(job(rows, "LOST-1")).deliveryOutcome == "lost")
        #expect(try! #require(job(rows, "LOST-1")).completionTextHead == "the reply that never landed")
        #expect(try! #require(job(rows, "UNKNOWN-1")).deliveryOutcome == "unknown")
        #expect(try! #require(job(rows, "SILENT-1")).deliveryOutcome == nil)
        #expect(try! #require(job(rows, "SILENT-1")).deliveryLost == nil)
    }

    @Test func stallSecondsDrivesTheVerdictWhenNoDeadlineExists() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        // Liveness went quiet 15 min ago against a 600s threshold.
        write("""
        {"messageId":"QUIET-1","createdAt":"2026-08-05T18:00:00.000Z","startedAt":"2026-08-05T18:00:00.000Z",
         "state":"running","heartbeatAt":"2026-08-05T18:45:00.000Z","stallSeconds":600}
        """, to: dir, named: "QUIET-1.json")
        // Same threshold, but liveness 60s ago — healthy.
        write("""
        {"messageId":"LIVE-1","createdAt":"2026-08-05T18:00:00.000Z","startedAt":"2026-08-05T18:00:00.000Z",
         "state":"running","heartbeatAt":"2026-08-05T18:59:00.000Z","stallSeconds":600}
        """, to: dir, named: "LIVE-1.json")

        let rows = projector(root).recentJobs(now: Self.now)
        let quiet = try! #require(job(rows, "QUIET-1"))
        #expect(quiet.stalled == true)
        #expect(quiet.stallBasis == .stallSeconds)

        let live = try! #require(job(rows, "LIVE-1"))
        #expect(live.stalled == false)
        #expect(live.stallBasis == .stallSeconds)
    }

    @Test func legacyRecordEmitsWhatExistsAndFabricatesNothing() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeLegacyJob(claudeDir(root))

        let row = try! #require(job(projector(root).recentJobs(now: Self.now), "LEGACY-1"))
        #expect(row.topicSlug == nil)
        #expect(row.claimedAt == nil)
        #expect(row.startedAt == nil)
        #expect(row.lastLiveness == nil)
        #expect(row.completedAt == nil)
        #expect(row.deliveryLost == nil)
        #expect(row.completionTextHead == nil)
        // Elapsed still computes from createdAt — 20 minutes.
        #expect(row.elapsedSeconds == 1200)
        // No deadline and no stall threshold: not stalled, and the basis says
        // so out loud rather than implying a healthy verdict.
        #expect(row.stalled == false)
        #expect(row.stallBasis == DelegationJobProjection.StallBasis.none)

        // Absent fields must be OMITTED from the envelope, not emitted as null.
        guard case .object(let obj) = row.toJSON() else { Issue.record("not an object"); return }
        #expect(obj["topic_slug"] == nil)
        #expect(obj["completed_at"] == nil)
        #expect(obj["delivery_lost"] == nil)
        #expect(obj["stall_basis"] == .string("none"))
    }

    @Test func projectsCodexRecordsAcrossItsDifferentShape() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeCodexInFlightJob(codexDir(root))
        writeCodexUndeliveredJob(codexDir(root, undelivered: true))

        let rows = projector(root).recentJobs(now: Self.now)

        let inFlight = try! #require(job(rows, "CODEX-1"))
        #expect(inFlight.source == "codex")
        #expect(inFlight.agent == "codex")
        #expect(inFlight.state == "watching_turn")
        // boundAt is the codex analogue of claimedAt; there is no startedAt.
        #expect(inFlight.claimedAt == "2026-08-05T18:55:00.300Z")
        #expect(inFlight.startedAt == nil)
        // lastWait.observedAt is the codex liveness beacon.
        #expect(inFlight.lastLiveness == "2026-08-05T18:58:30.000Z")
        #expect(inFlight.completedAt == nil)
        #expect(inFlight.elapsedSeconds == 300)  // boundAt → now
        // Topic slugs by the same rules as the JS writer's topicSlug().
        #expect(inFlight.topicSlug == "codex-bridge-stalled-turns")
        // No deadline and no stall threshold EXIST on a codex record, so the
        // verdict must be unmeasurable rather than a confident false.
        #expect(inFlight.stalled == false)
        #expect(inFlight.stallBasis == DelegationJobProjection.StallBasis.none)
        #expect(inFlight.deliveryLost == nil)
        #expect(inFlight.deliveryOutcome == nil)

        let lost = try! #require(job(rows, "CODEX-UNDELIVERED"))
        #expect(lost.runStatus == "completed")
        #expect(lost.status == nil)  // codex writes no delivery status onto the job
        #expect(lost.completedAt == "2026-08-05T18:46:00.000Z")
        #expect(lost.elapsedSeconds == 60)
        #expect(lost.stallBasis == .terminal)
        // Living under undelivered/ means the bridge could NOT CONFIRM the
        // handoff (replyJobDisposition preserves there on outcome_unknown /
        // conflict). It is NOT proof of loss, and the projection must not
        // upgrade it to one — that would be exactly the fabricated verdict
        // this tool exists to replace.
        #expect(lost.deliveryLost == nil)
        #expect(lost.deliveryOutcome == "unknown")
        // Completion text is capped at 200 chars.
        #expect(lost.completionTextHead?.count == 200)
    }

    @Test func projectsOMPRecordAndNestedBridgeDelivery() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        write("""
        {"messageId":"OMP-1","state":"settled","status":"completed",
         "createdAt":"2026-08-05T18:40:00.000Z","startedAt":"2026-08-05T18:41:00.000Z",
         "completedAt":"2026-08-05T18:45:00.000Z","lastActivityAt":"2026-08-05T18:44:59.000Z",
         "payload":{"topic":"NativeAgent Cleanup"},"bridge":{"status":"delivered"},
         "reply":"Tightened the Desk bridge."}
        """, to: ompDir(root), named: "OMP-1.json")
        let row = try #require(job(projector(root).recentJobs(now: Self.now), "OMP-1"))
        #expect(row.source == "omp")
        #expect(row.agent == "omp")
        #expect(row.topicSlug == "nativeagent-cleanup")
        #expect(row.deliveryOutcome == "delivered")
        #expect(row.runStatus == "completed")
        #expect(row.completionTextHead == "Tightened the Desk bridge.")
        #expect(row.stallBasis == .terminal)
    }

    // MARK: - Bounding, ordering, missing stores

    @Test func returnsNewestFirstAndHonoursTheBound() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        // Ten jobs, each one minute older than the last.
        for i in 0..<10 {
            let minute = String(format: "%02d", 50 - i)
            write("""
            {"messageId":"SEQ-\(i)","createdAt":"2026-08-05T18:\(minute):00.000Z","state":"queued"}
            """, to: dir, named: "SEQ-\(i).json")
        }

        let all = projector(root).recentJobs(now: Self.now)
        #expect(all.count == 10)
        #expect(all.first?.id == "SEQ-0")   // 18:50 — newest
        #expect(all.last?.id == "SEQ-9")    // 18:41 — oldest

        let bounded = projector(root).recentJobs(now: Self.now, limit: 3)
        #expect(bounded.map(\.id) == ["SEQ-0", "SEQ-1", "SEQ-2"])

        // Out-of-range limits clamp instead of throwing or returning nothing.
        #expect(projector(root).recentJobs(now: Self.now, limit: 0).count == 1)
        #expect(projector(root).recentJobs(now: Self.now, limit: 10_000).count == 10)
    }

    @Test func reconciliationProjectionIsNotLimitedByChatDisplayBudget() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        for index in 0..<150 {
            write("""
            {"messageId":"BURST-\(index)","createdAt":"2026-08-05T18:00:00.000Z",
             "completedAt":"2026-08-05T18:30:00.000Z","status":"completed","state":"settled"}
            """, to: dir, named: "BURST-\(index).json")
        }
        #expect(projector(root).recentJobs(now: Self.now, limit: 10_000).count == 100)
        #expect(projector(root).allJobs(now: Self.now).count == 150)
    }

    @Test func missingOrGarbageRecordsDoNotSinkTheCall() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        writeRunningJob(dir)
        write("{ this is not json", to: dir, named: "BROKEN.json")
        write("[1,2,3]", to: dir, named: "NOTANOBJECT.json")
        write("{\"messageId\":\"IGNORED\"}", to: dir, named: "ignored.txt")  // wrong extension
        // The codex store does not exist at all on this machine.

        let rows = projector(root).recentJobs(now: Self.now)
        #expect(rows.map(\.id) == ["RUNNING-1"])
    }

    @Test func absentStoresYieldAnEmptyListNotAFailure() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(projector(root).recentJobs(now: Self.now).isEmpty)
    }

    // MARK: - Dispatcher surface

    @Test func dispatcherReturnsProjectionWithStorePathsAndCounts() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = claudeDir(root)
        writeRunningJob(dir); writeCompletedJob(dir); writeStalledJob(dir)
        writeCodexUndeliveredJob(codexDir(root, undelivered: true))

        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let d = SwiftToolDispatcher(dataRoot: dataRoot, agentBridgeConfigRoot: root)

        let result = try await d.dispatch(tool: "delegation_status", input: [:], surface: "chat")
        guard case .object(let obj) = result else { Issue.record("not an object: \(result)"); return }
        #expect(obj["status"] == .string("ok"))
        #expect(obj["count"] == .int(4))
        // RUNNING-1, STALLED-1, and the codex job (whose turnResult carries
        // completedAt) → 2 open.
        #expect(obj["open_count"] == .int(2))
        // The dispatcher reads the WALL clock (injection lives on the
        // projector), so stall expectations here must be clock-independent.
        // Both open claude fixtures carry deadlines in 2026-08-05, so they are
        // past-deadline for any real `now` at or after that date — which is
        // every run of this test. The stall arithmetic itself is pinned against
        // the fixed clock in the projector tests above.
        #expect(obj["stalled_count"] == .int(2))
        // The codex fixture sits under undelivered/ — outcome UNKNOWN, not
        // proven lost. The two counts must stay separate.
        #expect(obj["delivery_lost_count"] == .int(0))
        #expect(obj["delivery_unknown_count"] == .int(1))
        guard case .object(let stores)? = obj["stores"] else { Issue.record("no stores"); return }
        // Model-visible store labels are REDACTED (gpt-5.5 BLOCKING: absolute
        // paths leak the account name on public installs): home-relative for
        // stores under ~, last-two-components otherwise. The injected temp
        // root is outside home, so the fallback form is expected here — and
        // asserting the absolute path NEVER appears is the leak fence AND the
        // hermeticity assertion in one (a live ~/.config path would carry the
        // real home prefix, which the redaction forbids).
        #expect(stores["claude"] == .string("claude-bridge/wake-jobs"))
        guard case .string(let codexPath)? = stores["codex"] else { Issue.record("no codex path"); return }
        #expect(codexPath == "codex-nativeagent-bridge/reply-jobs")
        #expect(!codexPath.contains(root.path))
    }

    @Test func dispatcherHonoursLimitAndAgentFilter() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeRunningJob(claudeDir(root))
        writeCompletedJob(claudeDir(root))
        writeCodexInFlightJob(codexDir(root))

        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let d = SwiftToolDispatcher(dataRoot: dataRoot, agentBridgeConfigRoot: root)

        func ids(_ input: [String: JSONValue]) async throws -> [String] {
            let result = try await d.dispatch(tool: "delegation_status", input: input, surface: "chat")
            guard case .object(let obj) = result, case .array(let jobs)? = obj["jobs"] else { return [] }
            return jobs.compactMap { row in
                guard case .object(let r) = row, case .string(let id)? = r["id"] else { return nil }
                return id
            }
        }

        #expect(try await ids([:]).count == 3)
        #expect(try await ids(["agent": .string("codex")]) == ["CODEX-1"])
        #expect(try await ids(["agent": .string("claude")]).sorted() == ["DONE-1", "RUNNING-1"])
        // "claude" is an accepted alias for the claude bridge.
        #expect(try await ids(["agent": .string("claude")]).sorted() == ["DONE-1", "RUNNING-1"])
        // An unrecognized agent must NOT silently return zero rows — that
        // reads as "nothing is running" when it means "you typo'd".
        #expect(try await ids(["agent": .string("nonsense")]).count == 3)
        #expect(try await ids(["limit": .int(1)]).count == 1)
        // String limits arrive from some providers; they must still bound.
        #expect(try await ids(["limit": .string("2")]).count == 2)
    }

    // MARK: - Wiring canon

    @Test func delegationStatusIsALazyLoadedBuiltIn() {
        #expect(SwiftToolDispatcher.builtInToolNames.contains("delegation_status"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("delegation_status"))
    }

    @Test func schemaIsAdvertisedWithOptionalParameters() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = SwiftToolDispatcher(dataRoot: root)
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)

        let schema = try #require(schemas.first { $0.name == "delegation_status" })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let o) = parsed,
              case .object(let props)? = o["properties"],
              case .array(let required)? = o["required"] else {
            Issue.record("delegation_status schema malformed"); return
        }
        #expect(required == [])
        #expect(props["limit"] != nil)
        #expect(props["agent"] != nil)
    }
}
