import Testing
import Foundation
@testable import SelfImprovement
import PersistenceCore

@Test func scoreboard_record_round_trips_defaults_and_json_shape() throws {
    let record = SelfImprovementScoreboardRecord(runId: "run-1")

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(SelfImprovementScoreboardRecord.self, from: data)

    #expect(decoded.id == "run-1")
    #expect(decoded.retryCount == 0)
    #expect(decoded.userCorrectionCount == 0)
    #expect(decoded.promotionPolicy == "manual_review")
    #expect(decoded.promoted == false)
    #expect(decoded.reverted == false)

    guard case .object(let object) = decoded.toJSONValue() else {
        Issue.record("scoreboard record should serialize as object")
        return
    }
    #expect(object["runId"] == .string("run-1"))
    #expect(object["retryCount"] == .int(0))
    #expect(object["promotionPolicy"] == .string("manual_review"))
}

@Test func scoreboard_summary_penalizes_failed_and_reverted_runs() {
    let records = [
        SelfImprovementScoreboardRecord(
            runId: "good",
            status: "succeeded",
            latencyMs: 1000,
            promoted: true
        ),
        SelfImprovementScoreboardRecord(
            runId: "bad",
            status: "failed",
            latencyMs: 5000,
            retryCount: 2,
            failedCompletionCount: 1,
            testFailureCount: 1,
            failed: true
        ),
        SelfImprovementScoreboardRecord(
            runId: "rollback",
            status: "reverted",
            latencyMs: 2000,
            rollbackCount: 1,
            reverted: true
        ),
    ]

    let summary = SelfImprovementScoreboard.summarize(records)

    #expect(summary.recordCount == 3)
    #expect(summary.successfulCount == 1)
    #expect(summary.promotedCount == 1)
    #expect(summary.failedCount == 1)
    #expect(summary.revertedCount == 1)
    #expect(summary.rollbackCount == 1)
    #expect(summary.averageLatencyMs == 2666)
    #expect(summary.netScore < 0)
    #expect(summary.recommendation == .regressed)
}

@Test func scoreboard_derives_records_from_improvement_runs_and_extras() {
    let run = ImprovementRun(
        id: "run-extra",
        status: "succeeded",
        phase: "promoted",
        createdAt: "2026-06-20T10:00:00Z",
        completedAt: "2026-06-20T10:00:02Z",
        objective: "tighten evals",
        promotedCommitSha: "abc1234",
        extras: .object([
            "retry_count": .int(2),
            "userCorrectionCount": .int(1),
            "promptBytes": .int(4096),
            "promotion_policy": .string("manual_review"),
        ])
    )

    let record = SelfImprovementScoreboard.record(from: run)

    #expect(record.runId == "run-extra")
    #expect(record.latencyMs == 2000)
    #expect(record.retryCount == 2)
    #expect(record.userCorrectionCount == 1)
    #expect(record.promptBytes == 4096)
    #expect(record.promoted == true)
    #expect(record.failed == false)
    #expect(record.promotionPolicy == "manual_review")
}

@Test func local_summary_exposes_compact_scoreboard() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("si-scoreboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let improvements = root.appendingPathComponent("improvements", isDirectory: true)
    try FileManager.default.createDirectory(at: improvements, withIntermediateDirectories: true)
    let runsPath = improvements.appendingPathComponent("runs.json")
    let runs = """
    [
      {"id":"run-1","status":"succeeded","phase":"promoted","createdAt":"2026-06-20T10:00:00Z","completedAt":"2026-06-20T10:00:02Z","promotedCommitSha":"abc"},
      {"id":"run-2","status":"failed","phase":"failed","createdAt":"2026-06-20T11:00:00Z","completedAt":"2026-06-20T11:00:03Z"}
    ]
    """
    try runs.write(to: runsPath, atomically: true, encoding: .utf8)

    let client = SwiftNativeSelfImprovement(dataRoot: root)
    let summary = try await client.improvementSummaryLocal()

    guard case .object(let raw) = summary.rawResponse,
          case .object(let scoreboard)? = raw["scoreboard"] else {
        Issue.record("local improvement summary should include scoreboard object")
        return
    }
    #expect(scoreboard["recordCount"] == .int(2))
    #expect(scoreboard["successfulCount"] == .int(1))
    #expect(scoreboard["failedCount"] == .int(1))
    #expect(scoreboard["recommendation"] == .string("needs_review"))
}
