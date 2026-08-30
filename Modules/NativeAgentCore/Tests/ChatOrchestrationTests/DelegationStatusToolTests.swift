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

    @Test func paginationRejectsUnrepresentableNumbersWithoutTrapping() {
        for number in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                       -.greatestFiniteMagnitude, Double(Int.max)] {
            #expect(SwiftToolDispatcher.delegationStatusLimit(["limit": .double(number)]) == 8)
            #expect(SwiftToolDispatcher.delegationStatusOffset(["offset": .double(number)]) == 0)
        }
        #expect(SwiftToolDispatcher.delegationStatusLimit(["limit": .double(3.9)]) == 3)
        #expect(SwiftToolDispatcher.delegationStatusOffset(["offset": .double(3.9)]) == 3)
        #expect(SwiftToolDispatcher.delegationStatusLimit(["limit": .int(.max)]) == 12)
        #expect(SwiftToolDispatcher.delegationStatusOffset(["offset": .int(.max)]) == Int.max)
        #expect(SwiftToolDispatcher.delegationStatusOffset(["offset": .double(-3.9)]) == 0)
    }

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

    private func codexDeliveryFile(_ root: URL) -> URL {
        let bridge = root.appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        return bridge.appendingPathComponent("reply-deliveries.jsonl")
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

    private func lookup(_ root: URL, _ input: [String: JSONValue]) async throws -> [String: JSONValue] {
        let dispatcher = SwiftToolDispatcher(dataRoot: root, agentBridgeConfigRoot: root)
        let result = try await dispatcher.dispatch(tool: "delegation_status", input: input, surface: "chat")
        guard case .object(let object) = result else { throw PersistenceCoreError.ioFailure("missing status envelope") }
        return object
    }

    @Test func acceptedMessageLookupFindsRunningBatchBeforePagingWithoutBindingMotorOwner() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = codexDir(root)
        let batch = #"{"id":"internal-batch","phase":"watching_turn","createdAt":"2026-08-05T17:00:00Z","threadId":"thread-exact","turnId":"turn-exact","entries":[{"payload":{"messageId":"accepted-A"}},{"payload":{"messageId":"accepted-B"}}]}"#
        write(batch, to: dir, named: "opaque-job-file.json")
        write(#"{"id":"internal-newer","phase":"watching_turn","createdAt":"2026-08-05T17:30:00Z","threadId":"initial-thread","turnId":"initial-turn","entries":[{"payload":{"messageId":"accepted-B"}}],"completedExecution":{"threadId":"terminal-thread","turnId":"terminal-turn","turnResult":{"status":"completed","completedAt":"2026-08-05T17:30:00Z"}}}"#,
              to: dir, named: "second.json")
        for index in 0..<10 {
            write("{\"id\":\"unrelated-\(index)\",\"phase\":\"watching_turn\",\"createdAt\":\"2026-08-05T18:30:00Z\",\"entries\":[{\"payload\":{\"messageId\":\"other-\(index)\"}}]}",
                  to: dir, named: "unrelated-\(index).json")
        }
        let plain = try await lookup(root, ["agent": .string("codex")])
        #expect(plain["matched_count"] == .int(12))
        #expect(plain["returned_count"] == .int(8))
        #expect(plain["lookup_status"] == nil)
        let input: [String: JSONValue] = ["agent": .string("codex"), "message_id": .string("accepted-B"), "limit": .int(1)]
        let first = try await lookup(root, input)
        #expect(first["lookup_status"] == .string("matched"))
        #expect(first["matched_count"] == .int(2))
        #expect(first["returned_count"] == .int(1))
        #expect(first["has_more"] == .bool(true))
        #expect(first["next_offset"] == .int(1))
        #expect(first["source_availability"] == plain["source_availability"])
        guard case .array(let firstJobs)? = first["jobs"], case .object(let terminal)? = firstJobs.first else {
            Issue.record("missing terminal match"); return
        }
        #expect(terminal["thread_id"] == .string("terminal-thread"))
        #expect(terminal["turn_id"] == .string("terminal-turn"))
        let second = try await lookup(root, input.merging(["offset": .int(1), "detail": .string("full")]) { _, new in new })
        guard case .array(let jobs)? = second["jobs"], case .object(let row)? = jobs.first else {
            Issue.record("missing exact batch match"); return
        }
        #expect(row["id"] == .string("internal-batch"))
        #expect(row["matched_message_id"] == .string("accepted-B"))
        #expect(row["thread_id"] == .string("thread-exact"))
        #expect(row["turn_id"] == .string("turn-exact"))
        #expect(row["motor_owner_id"] == nil)
        #expect(row["message_ids"] == nil)
        #expect(row["conversation_id"] == nil)
        #expect(second["has_more"] == .bool(false))
        #expect(second["next_offset"] == nil)
        let end = try await lookup(root, input.merging(["offset": .int(2)]) { _, new in new })
        #expect(end["returned_count"] == .int(0))
        #expect(end["lookup_status"] == .string("matched"))
        let missing = try await lookup(root, ["agent": .string("codex"), "message_id": .string("unobserved")])
        #expect(missing["status"] == .string("ok"))
        #expect(missing["lookup_status"] == .string("not_observed"))
        #expect(missing["matched_count"] == .int(0))
        #expect(try String(contentsOf: dir.appendingPathComponent("opaque-job-file.json"), encoding: .utf8) == batch)
    }

    @Test func acceptedMessageLookupUsesOnlyCanonicalIDsAndKeepsLegacyListing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = codexDir(root)
        write(#"{"id":"accepted","phase":"watching_turn","entries":[{"payload":{"messageId":false}},{"messageId":"accepted"}]}"#,
              to: codex, named: "accepted.json")
        write(#"{"state":"claimed","payload":{"topic":"accepted"}}"#, to: claudeDir(root), named: "accepted.json")
        write(#"{"messageId":"accepted","state":"claimed"}"#, to: ompDir(root), named: "other-filename.json")
        let delivered = #"{"createdAt":"2026-08-05T18:59:00Z","messageIds":["delivered-exact"],"threadId":"recorded-thread","turnId":"recorded-turn","turnResult":{"status":"completed"},"bridge":{"status":"delivered"}}"#
        try Data((delivered + "\n").utf8).write(to: codexDeliveryFile(root))
        let result = try await lookup(root, ["message_id": .string("accepted")])
        #expect(result["matched_count"] == .int(1))
        guard case .array(let jobs)? = result["jobs"], case .object(let row)? = jobs.first else {
            Issue.record("missing canonical OMP match"); return
        }
        #expect(row["agent"] == .string("omp"))
        let receipt = try await lookup(root, ["agent": .string("codex"), "message_id": .string("delivered-exact")])
        guard case .array(let deliveries)? = receipt["jobs"], case .object(let delivery)? = deliveries.first else {
            Issue.record("missing canonical delivery match"); return
        }
        #expect(delivery["thread_id"] == .string("recorded-thread"))
        #expect(delivery["turn_id"] == .string("recorded-turn"))
        for absent in [JSONValue.null, .string(""), .string("  ")] {
            let listing = try await lookup(root, ["message_id": absent])
            #expect(listing["matched_count"] == .int(4))
            #expect(listing["lookup_status"] == nil)
        }
        for invalid in [JSONValue.bool(false), .int(1), .array([]), .object([:]), .string(String(repeating: "x", count: 161))] {
            let response = try await lookup(root, ["message_id": invalid])
            #expect(response["reason"] == .string("delegation_message_id_invalid"))
        }
        let swarm = try await lookup(root, ["agent": .string("swarm"), "message_id": .bool(false)])
        #expect(swarm["reason"] == .string("swarm_run_id_required"))
        #expect(try String(contentsOf: codexDeliveryFile(root), encoding: .utf8) == delivered + "\n")
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
         "entries":[{"id":"e2","key":null,"payload":{"messageId":"m2","topic":"gh command","deskHandle":"desk_bound"}}],
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

    @Test func blockedDeliveryPreservesExecutionAndOnlyExposesKnownReason() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in ["claude", "omp"] {
            for status in ["completed", "failed"] {
                for reason in ["missing_origin_session", "PRIVATE arbitrary helper diagnostic"] {
                    let id = "\(agent)-\(status)-\(reason == "missing_origin_session" ? "known" : "unknown")"
                    var record: [String: JSONValue] = [
                        "messageId": .string(id), "state": .string("settled"), "status": .string(status),
                        "createdAt": .string("2026-08-05T18:00:00Z"), "completedAt": .string("2026-08-05T18:10:00Z"),
                        "completionText": .string("retained terminal evidence"), "idleSeconds": .int(1),
                    ]
                    if agent == "claude" {
                        record["runStatus"] = .string(status)
                        record["bridgeStatus"] = .string("blocked")
                        record["bridgeReason"] = .string(reason)
                        record["deliveryLost"] = .bool(false)
                    } else {
                        record["bridge"] = .object(["status": .string("blocked"), "reason": .string(reason), "deliveryAttempted": .bool(false)])
                    }
                    let dir = agent == "claude" ? claudeDir(root) : ompDir(root)
                    try JSONValue.object(record).serializedData(pretty: false).write(to: dir.appendingPathComponent("\(id).json"))
                }
            }
        }
        let rows = projector(root).allJobs(now: Self.now)
        #expect(rows.count == 8)
        for row in rows {
            #expect(row.deliveryOutcome == "blocked")
            #expect(row.deliveryLost != true)
            #expect(!row.stalled)
            #expect(row.stallBasis == .terminal)
            #expect(row.status == (row.id.contains("-completed-") ? "completed" : "failed"))
            #expect(row.completionTextHead == "retained terminal evidence")
            for representation in [row.toJSON(), row.toCompactJSON()] {
                guard case .object(let object) = representation else { Issue.record("missing projection"); continue }
                #expect(object["delivery_outcome"] == .string("blocked"))
                #expect(object["delivery_reason"] == (row.id.hasSuffix("-known") ? .string("missing_origin_session") : nil))
                let rendered = String(decoding: try representation.serializedData(pretty: false), as: UTF8.self)
                #expect(!rendered.contains("PRIVATE"))
            }
        }
        #expect(projector(root).nextStallDeadline(after: Self.now) == nil)
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

    @Test func nextStallDeadlineUsesTheExistingLivenessRulesWithoutPolling() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeRunningJob(claudeDir(root)) // recorded deadline: 19:50:00.900Z
        write("""
        {"messageId":"OMP-DEADLINE","state":"running","status":"running",
         "createdAt":"2026-08-05T18:50:00.000Z","updatedAt":"2026-08-05T18:59:00.000Z",
         "idleSeconds":120,"payload":{"topic":"reviewer-step"}}
        """, to: ompDir(root), named: "OMP-DEADLINE.json")
        writeCodexInFlightJob(codexDir(root)) // no computable stall rule

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = try #require(projector(root).nextStallDeadline(after: Self.now))
        #expect(formatter.string(from: first) == "2026-08-05T19:01:00.000Z")

        // Once OMP's crossing is in the past, the next exact crossing is the
        // Claude record's own deadline. No synthetic cadence is introduced.
        let afterOMP = Self.now.addingTimeInterval(121)
        let second = try #require(projector(root).nextStallDeadline(after: afterOMP))
        #expect(formatter.string(from: second) == "2026-08-05T19:50:00.900Z")
    }

    @Test func persistedOMPOutputKeepsMovingTheExactStallCrossingUntilOutputStops() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = ompDir(root)
        let file = dir.appendingPathComponent("OMP-LIVE.json")

        write("""
        {"messageId":"OMP-LIVE","state":"running","status":"running",
         "createdAt":"2026-08-05T18:50:00.000Z","startedAt":"2026-08-05T18:50:00.000Z",
         "updatedAt":"2026-08-05T18:50:00.000Z","lastActivityAt":"2026-08-05T18:59:50.000Z",
         "idleSeconds":30,"payload":{"topic":"builder-step"}}
        """, to: dir, named: file.lastPathComponent)

        let first = try #require(job(projector(root).recentJobs(now: Self.now), "OMP-LIVE"))
        #expect(first.stalled == false)
        #expect(first.lastLiveness == "2026-08-05T18:59:50.000Z")

        // Another stdout/stderr observation lands before the prior 30-second
        // crossing. The persisted timestamp, not process-local knowledge,
        // moves the projector's exact deadline while the job remains running.
        write("""
        {"messageId":"OMP-LIVE","state":"running","status":"running",
         "createdAt":"2026-08-05T18:50:00.000Z","startedAt":"2026-08-05T18:50:00.000Z",
         "updatedAt":"2026-08-05T18:50:00.000Z","lastActivityAt":"2026-08-05T19:00:15.000Z",
         "idleSeconds":30,"payload":{"topic":"builder-step"}}
        """, to: dir, named: file.lastPathComponent)
        let whileActive = Self.now.addingTimeInterval(25)
        let active = try #require(job(projector(root).recentJobs(now: whileActive), "OMP-LIVE"))
        #expect(active.stalled == false)
        #expect(projector(root).nextStallDeadline(after: whileActive)
            == Self.now.addingTimeInterval(45))

        // Once output truly stops, the same recorded threshold crosses. This
        // keeps the true-stall verdict; only the false active-run verdict moves.
        let afterSilence = Self.now.addingTimeInterval(45)
        let stalled = try #require(job(projector(root).recentJobs(now: afterSilence), "OMP-LIVE"))
        #expect(stalled.stalled == true)
        #expect(stalled.stallBasis == .stallSeconds)
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

    @Test func producerIdentityProjectsAcrossAllBridgeRecordShapes() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = "1234567890abcdef1234567890abcdef12345678"
        write("""
        {"messageId":"CLAUDE-STAMPED","createdAt":"2026-08-05T18:59:00.000Z","state":"claimed",
         "payload":{"producerSchemaVersion":1,"producerSourceRevision":"\(revision)"}}
        """, to: claudeDir(root), named: "CLAUDE-STAMPED.json")
        write("""
        {"id":"CODEX-STAMPED","phase":"watching_turn","createdAt":"2026-08-05T18:58:00.000Z",
         "entries":[{"payload":{"messageId":"m1","producerSchemaVersion":1,
         "producerSourceRevision":"\(revision)"}}]}
        """, to: codexDir(root), named: "CODEX-STAMPED.json")
        write("""
        {"messageId":"OMP-STAMPED","createdAt":"2026-08-05T18:57:00.000Z","state":"claimed",
         "payload":{"producerSchemaVersion":1,"producerSourceRevision":"\(revision)"}}
        """, to: ompDir(root), named: "OMP-STAMPED.json")

        let rows = projector(root).recentJobs(now: Self.now)
        for id in ["CLAUDE-STAMPED", "CODEX-STAMPED", "OMP-STAMPED"] {
            let projected = try! #require(job(rows, id))
            #expect(projected.producerSchemaVersion == 1)
            #expect(projected.producerSourceRevision == revision)
            guard case .object(let json) = projected.toJSON() else {
                Issue.record("not an object: \(id)")
                continue
            }
            #expect(json["producer_schema_version"] == .int(1))
            #expect(json["producer_source_revision"] == .string(revision))
        }
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
        #expect(lost.state == "delivery_unknown")
        #expect(lost.deskHandle == "desk_bound")
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
        #expect(lost.motorOwnerID == "m2")
        // Completion text is capped at 200 chars.
        #expect(lost.completionTextHead?.count == 200)
    }

    @Test func deliveredCodexLedgerClosesTheDispatchIdentityAfterReplyJobRemoval() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let delivery = #"{"id":"delivery-1","createdAt":"2026-08-05T18:59:50.000Z","messageIds":["MESSAGE-1","MESSAGE-2"],"turnResult":{"status":"completed","completedAt":"2026-08-05T18:59:45.000Z","messagePreview":"Codex completed the requested architecture audit."},"bridge":{"status":"delivered","replyStatus":"ok","nativeAgentReplyPreview":"The result reached its bound NativeAgent session."}}"#
        try Data((delivery + "\n").utf8).write(to: codexDeliveryFile(root))

        // Successful delivery intentionally leaves reply-jobs empty. The
        // sibling ledger must still carry the terminal state for each exact
        // message identity returned by codex_message.
        _ = codexDir(root)
        let rows = projector(root).allJobs(now: Self.now)
        for id in ["MESSAGE-1", "MESSAGE-2"] {
            let row = try #require(job(rows, id))
            #expect(row.source == "codex")
            #expect(row.state == "settled")
            #expect(row.status == "delivered")
            #expect(row.runStatus == "completed")
            #expect(row.completedAt == "2026-08-05T18:59:45.000Z")
            #expect(row.deliveryOutcome == "delivered")
            #expect(row.motorOwnerID == id)
            #expect(row.stallBasis == .terminal)
            #expect(row.completionTextHead == "The result reached its bound NativeAgent session.")
        }
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

    @Test func availabilityDistinguishesAbsentEmptyAndUnreadableWithoutInventingNoWork() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root.appendingPathComponent("data"), agentBridgeConfigRoot: root)
        let absent = try await dispatcher.dispatch(tool: "delegation_status", input: [:], surface: "chat")
        guard case .object(let absentObject) = absent,
              case .array(let absentSources)? = absentObject["source_availability"] else {
            Issue.record("missing source availability"); return
        }
        #expect(absentObject["status"] == .string("no_evidence"))
        #expect(absentObject["count"] == .int(0))
        #expect(absentSources.count == 5)
        #expect(absentSources.allSatisfy { source in
            guard case .object(let object) = source else { return false }
            return object["status"] == .string("absent")
        })
        _ = claudeDir(root)
        let empty = try await dispatcher.dispatch(tool: "delegation_status", input: ["agent": .string("claude")], surface: "chat")
        guard case .object(let emptyObject) = empty else { Issue.record("missing empty projection"); return }
        #expect(emptyObject["status"] == .string("ok"))
        #expect(emptyObject["count"] == .int(0))
        let ompPath = root.appendingPathComponent("omp-bridge/wake-jobs")
        try FileManager.default.createDirectory(at: ompPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: ompPath)
        let unavailable = try await dispatcher.dispatch(tool: "delegation_status", input: ["agent": .string("omp")], surface: "chat")
        guard case .object(let unavailableObject) = unavailable else { Issue.record("missing unavailable projection"); return }
        #expect(unavailableObject["status"] == .string("unavailable"))
        #expect(unavailableObject["count"] == .int(0))
        let stillEmpty = try await dispatcher.dispatch(tool: "delegation_status", input: ["agent": .string("claude")], surface: "chat")
        #expect(stillEmpty == empty, "unrelated unavailable bridge must not contaminate selected source")
    }

    @Test func partialAvailabilityRetainsReadableJobsAndCountsSkippedEvidence() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = claudeDir(root)
        writeRunningJob(directory)
        write("{invalid", to: directory, named: "PRIVATE-BROKEN.json")
        write("[]", to: directory, named: "PRIVATE-ARRAY.json")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("PRIVATE-DIRECTORY.json"), withIntermediateDirectories: true)
        let ledger = codexDeliveryFile(root)
        let ledgerText = """
        {"messageIds":["DELIVERED-1"],"createdAt":"2026-08-05T18:30:00Z","turnResult":{"status":"completed"},"bridge":{"status":"delivered"}}
        {broken
        []
        {"unprojectable":"no originating identity"}

        """
        try Data(ledgerText.utf8).write(to: ledger)
        let dispatcher = SwiftToolDispatcher(dataRoot: root.appendingPathComponent("data"), agentBridgeConfigRoot: root)
        let result = try await dispatcher.dispatch(tool: "delegation_status", input: [:], surface: "chat")
        guard case .object(let object) = result,
              case .array(let sources)? = object["source_availability"] else { Issue.record("missing availability"); return }
        #expect(object["status"] == .string("partial"))
        #expect(object["count"] == .int(2))
        let sourceObjects = sources.compactMap { value -> [String: JSONValue]? in
            if case .object(let object) = value { return object }; return nil
        }
        let claude = try #require(sourceObjects.first { $0["source"] == .string("claude_jobs") })
        #expect(claude["status"] == .string("partial"))
        #expect(claude["readable_records"] == .int(1))
        #expect(claude["malformed_records"] == .int(2))
        #expect(claude["unreadable_files"] == .int(1))
        let deliveries = try #require(sourceObjects.first { $0["source"] == .string("codex_deliveries") })
        #expect(deliveries["status"] == .string("partial"))
        #expect(deliveries["readable_records"] == .int(1))
        #expect(deliveries["malformed_records"] == .int(3))
        let retainedIDs = Set(projector(root).allJobs(now: Self.now).map(\.id))
        #expect(retainedIDs == Set(["RUNNING-1", "DELIVERED-1"]))
        let filtered = try await dispatcher.dispatch(tool: "delegation_status", input: ["agent": .string("codex")], surface: "chat")
        guard case .object(let filteredObject) = filtered,
              case .array(let filteredSources)? = filteredObject["source_availability"] else { Issue.record("missing filtered sources"); return }
        #expect(filteredObject["status"] == .string("partial"))
        #expect(filteredObject["count"] == .int(1))
        #expect(filteredSources.count == 3)
        let metadata = String(decoding: try JSONValue.array(sources).serializedData(pretty: false), as: UTF8.self)
        #expect(!metadata.contains("PRIVATE"))
        #expect(!metadata.contains(root.path))
        #expect(try String(contentsOf: ledger, encoding: .utf8) == ledgerText)
        #expect(try String(contentsOf: directory.appendingPathComponent("PRIVATE-BROKEN.json"), encoding: .utf8) == "{invalid")
    }

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
        #expect(obj["projection_schema_version"] == .int(2))
        #expect(obj["current_build_count"] == .int(0))
        #expect(obj["current_build_delivery_unknown_count"] == .int(0))
        #expect(obj["legacy_or_other_build_count"] == .int(4))
        #expect(obj["legacy_or_other_build_delivery_unknown_count"] == .int(1))
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

    @Test func dispatcherFiltersBeforeCompactPagination() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        writeCodexInFlightJob(codexDir(root))
        for index in 0..<15 {
            write("""
            {"messageId":"OMP-NEW-\(index)","state":"settled","status":"completed",
             "createdAt":"2026-08-06T18:00:00.000Z","completedAt":"2026-08-06T18:30:00.000Z",
             "payload":{"topic":"newer-omp-work"}}
            """, to: ompDir(root), named: "OMP-NEW-\(index).json")
        }

        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot, agentBridgeConfigRoot: root)
        let filtered = try await dispatcher.dispatch(
            tool: "delegation_status",
            input: ["agent": .string("codex"), "limit": .int(20)],
            surface: "chat")
        guard case .object(let filteredObj) = filtered,
              case .array(let filteredJobs)? = filteredObj["jobs"],
              case .object(let codex)? = filteredJobs.first else {
            Issue.record("expected filtered codex page"); return
        }
        #expect(filteredObj["matched_count"] == .int(1))
        #expect(filteredObj["returned_count"] == .int(1))
        #expect(codex["id"] == .string("CODEX-1"))
        #expect(codex["created_at"] == nil)
        #expect(filteredObj["detail"] == .string("compact"))

        let firstPage = try await dispatcher.dispatch(
            tool: "delegation_status",
            input: ["limit": .int(20)], surface: "chat")
        guard case .object(let firstObj) = firstPage else {
            Issue.record("expected first page"); return
        }
        #expect(firstObj["returned_count"] == .int(12))
        #expect(firstObj["matched_count"] == .int(16))
        #expect(firstObj["has_more"] == .bool(true))
        #expect(firstObj["next_offset"] == .int(12))

        let secondPage = try await dispatcher.dispatch(
            tool: "delegation_status",
            input: ["limit": .int(20), "offset": .int(12), "detail": .string("full")],
            surface: "chat")
        guard case .object(let secondObj) = secondPage,
              case .array(let secondJobs)? = secondObj["jobs"],
              case .object(let fullRow)? = secondJobs.first else {
            Issue.record("expected full second page"); return
        }
        #expect(secondObj["returned_count"] == .int(4))
        #expect(secondObj["has_more"] == .bool(false))
        #expect(secondObj["detail"] == .string("full"))
        #expect(fullRow["created_at"] != nil)
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
        #expect(props["offset"] != nil)
        #expect(props["agent"] != nil)
        #expect(props["detail"] != nil)
        guard case .object(let messageID)? = props["message_id"] else {
            Issue.record("missing exact accepted-message selector"); return
        }
        #expect(messageID["type"] == .array([.string("string"), .string("null")]))
    }
}
