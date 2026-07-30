import Foundation
import PersistenceCore

public enum SelfImprovementScoreboardRecommendation: String, Sendable, Codable, Equatable {
    case noBaseline = "no_baseline"
    case healthy
    case needsReview = "needs_review"
    case regressed
}

public struct SelfImprovementScoreboardRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var runId: String
    public var createdAt: String?
    public var completedAt: String?
    public var status: String?
    public var phase: String?
    public var objective: String?
    public var latencyMs: Int?
    public var retryCount: Int
    public var userCorrectionCount: Int
    public var promptBytes: Int?
    public var frozenTurnCount: Int
    public var failedCompletionCount: Int
    public var testFailureCount: Int
    public var rollbackCount: Int
    public var promoted: Bool
    public var reverted: Bool
    public var failed: Bool
    public var interrupted: Bool
    public var promotionPolicy: String
    public var notes: String?

    public init(
        id: String? = nil,
        runId: String,
        createdAt: String? = nil,
        completedAt: String? = nil,
        status: String? = nil,
        phase: String? = nil,
        objective: String? = nil,
        latencyMs: Int? = nil,
        retryCount: Int = 0,
        userCorrectionCount: Int = 0,
        promptBytes: Int? = nil,
        frozenTurnCount: Int = 0,
        failedCompletionCount: Int = 0,
        testFailureCount: Int = 0,
        rollbackCount: Int = 0,
        promoted: Bool = false,
        reverted: Bool = false,
        failed: Bool = false,
        interrupted: Bool = false,
        promotionPolicy: String = "manual_review",
        notes: String? = nil
    ) {
        self.id = id ?? runId
        self.runId = runId
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.phase = phase
        self.objective = objective
        self.latencyMs = latencyMs
        self.retryCount = max(0, retryCount)
        self.userCorrectionCount = max(0, userCorrectionCount)
        self.promptBytes = promptBytes.map { max(0, $0) }
        self.frozenTurnCount = max(0, frozenTurnCount)
        self.failedCompletionCount = max(0, failedCompletionCount)
        self.testFailureCount = max(0, testFailureCount)
        self.rollbackCount = max(0, rollbackCount)
        self.promoted = promoted
        self.reverted = reverted
        self.failed = failed
        self.interrupted = interrupted
        self.promotionPolicy = promotionPolicy.isEmpty ? "manual_review" : promotionPolicy
        self.notes = notes
    }

    public func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "runId": .string(runId),
            "retryCount": .int(Int64(retryCount)),
            "userCorrectionCount": .int(Int64(userCorrectionCount)),
            "frozenTurnCount": .int(Int64(frozenTurnCount)),
            "failedCompletionCount": .int(Int64(failedCompletionCount)),
            "testFailureCount": .int(Int64(testFailureCount)),
            "rollbackCount": .int(Int64(rollbackCount)),
            "promoted": .bool(promoted),
            "reverted": .bool(reverted),
            "failed": .bool(failed),
            "interrupted": .bool(interrupted),
            "promotionPolicy": .string(promotionPolicy),
        ]
        if let createdAt { object["createdAt"] = .string(createdAt) }
        if let completedAt { object["completedAt"] = .string(completedAt) }
        if let status { object["status"] = .string(status) }
        if let phase { object["phase"] = .string(phase) }
        if let objective { object["objective"] = .string(objective) }
        if let latencyMs { object["latencyMs"] = .int(Int64(latencyMs)) }
        if let promptBytes { object["promptBytes"] = .int(Int64(promptBytes)) }
        if let notes { object["notes"] = .string(notes) }
        return .object(object)
    }
}

public struct SelfImprovementScoreboardSummary: Sendable, Codable, Equatable {
    public var recordCount: Int
    public var successfulCount: Int
    public var promotedCount: Int
    public var failedCount: Int
    public var interruptedCount: Int
    public var revertedCount: Int
    public var rollbackCount: Int
    public var retryCount: Int
    public var userCorrectionCount: Int
    public var frozenTurnCount: Int
    public var failedCompletionCount: Int
    public var testFailureCount: Int
    public var totalPromptBytes: Int
    public var averageLatencyMs: Int?
    public var netScore: Int
    public var recommendation: SelfImprovementScoreboardRecommendation

    public init(
        recordCount: Int = 0,
        successfulCount: Int = 0,
        promotedCount: Int = 0,
        failedCount: Int = 0,
        interruptedCount: Int = 0,
        revertedCount: Int = 0,
        rollbackCount: Int = 0,
        retryCount: Int = 0,
        userCorrectionCount: Int = 0,
        frozenTurnCount: Int = 0,
        failedCompletionCount: Int = 0,
        testFailureCount: Int = 0,
        totalPromptBytes: Int = 0,
        averageLatencyMs: Int? = nil,
        netScore: Int = 0,
        recommendation: SelfImprovementScoreboardRecommendation = .noBaseline
    ) {
        self.recordCount = recordCount
        self.successfulCount = successfulCount
        self.promotedCount = promotedCount
        self.failedCount = failedCount
        self.interruptedCount = interruptedCount
        self.revertedCount = revertedCount
        self.rollbackCount = rollbackCount
        self.retryCount = retryCount
        self.userCorrectionCount = userCorrectionCount
        self.frozenTurnCount = frozenTurnCount
        self.failedCompletionCount = failedCompletionCount
        self.testFailureCount = testFailureCount
        self.totalPromptBytes = totalPromptBytes
        self.averageLatencyMs = averageLatencyMs
        self.netScore = netScore
        self.recommendation = recommendation
    }

    public func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "recordCount": .int(Int64(recordCount)),
            "successfulCount": .int(Int64(successfulCount)),
            "promotedCount": .int(Int64(promotedCount)),
            "failedCount": .int(Int64(failedCount)),
            "interruptedCount": .int(Int64(interruptedCount)),
            "revertedCount": .int(Int64(revertedCount)),
            "rollbackCount": .int(Int64(rollbackCount)),
            "retryCount": .int(Int64(retryCount)),
            "userCorrectionCount": .int(Int64(userCorrectionCount)),
            "frozenTurnCount": .int(Int64(frozenTurnCount)),
            "failedCompletionCount": .int(Int64(failedCompletionCount)),
            "testFailureCount": .int(Int64(testFailureCount)),
            "totalPromptBytes": .int(Int64(totalPromptBytes)),
            "netScore": .int(Int64(netScore)),
            "recommendation": .string(recommendation.rawValue),
        ]
        if let averageLatencyMs {
            object["averageLatencyMs"] = .int(Int64(averageLatencyMs))
        }
        return .object(object)
    }
}

public enum SelfImprovementScoreboard {
    public static func records(from runs: [ImprovementRun]) -> [SelfImprovementScoreboardRecord] {
        runs.map(record)
    }

    public static func summarize(runs: [ImprovementRun]) -> SelfImprovementScoreboardSummary {
        summarize(records(from: runs))
    }

    public static func summarize(_ records: [SelfImprovementScoreboardRecord]) -> SelfImprovementScoreboardSummary {
        guard !records.isEmpty else { return SelfImprovementScoreboardSummary() }

        let successfulCount = records.filter(Self.isSuccessful).count
        let promotedCount = records.filter(\.promoted).count
        let failedCount = records.filter(\.failed).count
        let interruptedCount = records.filter(\.interrupted).count
        let revertedCount = records.filter(\.reverted).count
        let rollbackCount = records.reduce(0) { $0 + $1.rollbackCount }
        let retryCount = records.reduce(0) { $0 + $1.retryCount }
        let userCorrectionCount = records.reduce(0) { $0 + $1.userCorrectionCount }
        let frozenTurnCount = records.reduce(0) { $0 + $1.frozenTurnCount }
        let failedCompletionCount = records.reduce(0) { $0 + $1.failedCompletionCount }
        let testFailureCount = records.reduce(0) { $0 + $1.testFailureCount }
        let totalPromptBytes = records.compactMap(\.promptBytes).reduce(0, +)
        let latencies = records.compactMap(\.latencyMs)
        let averageLatencyMs = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        let netScore =
            successfulCount * 2
            + promotedCount
            - failedCount * 3
            - interruptedCount * 2
            - revertedCount * 5
            - rollbackCount * 4
            - retryCount
            - userCorrectionCount
            - frozenTurnCount
            - failedCompletionCount * 2
            - testFailureCount * 3

        let recommendation: SelfImprovementScoreboardRecommendation
        if netScore < 0 || revertedCount > 0 || rollbackCount > 0 {
            recommendation = .regressed
        } else if failedCount > 0 || interruptedCount > 0 || failedCompletionCount > 0 || testFailureCount > 0 {
            recommendation = .needsReview
        } else {
            recommendation = .healthy
        }

        return SelfImprovementScoreboardSummary(
            recordCount: records.count,
            successfulCount: successfulCount,
            promotedCount: promotedCount,
            failedCount: failedCount,
            interruptedCount: interruptedCount,
            revertedCount: revertedCount,
            rollbackCount: rollbackCount,
            retryCount: retryCount,
            userCorrectionCount: userCorrectionCount,
            frozenTurnCount: frozenTurnCount,
            failedCompletionCount: failedCompletionCount,
            testFailureCount: testFailureCount,
            totalPromptBytes: totalPromptBytes,
            averageLatencyMs: averageLatencyMs,
            netScore: netScore,
            recommendation: recommendation
        )
    }

    public static func record(from run: ImprovementRun) -> SelfImprovementScoreboardRecord {
        let extras = object(run.extras)
        let status = run.status?.lowercased()
        let phase = run.phase?.lowercased()
        let latency = firstInt(extras, ["latencyMs", "latency_ms", "durationMs", "duration_ms"])
            ?? latencyMs(createdAt: run.createdAt, completedAt: run.completedAt)
        let retryCount = firstInt(extras, ["retryCount", "retry_count", "retries"]) ?? 0
        let correctionCount = firstInt(extras, [
            "userCorrectionCount", "user_correction_count", "correctionCount", "correction_count",
        ]) ?? 0
        let promptBytes = firstInt(extras, ["promptBytes", "prompt_bytes"])
        let frozenTurnCount = firstInt(extras, ["frozenTurnCount", "frozen_turn_count"]) ?? 0
        let failedCompletionCount = firstInt(extras, [
            "failedCompletionCount", "failed_completion_count", "completionFailures",
        ]) ?? 0
        let testFailureCount = firstInt(extras, ["testFailureCount", "test_failure_count"]) ?? 0
        let rollbackCount = firstInt(extras, ["rollbackCount", "rollback_count"]) ?? 0
        let promoted = run.promotedCommitSha?.isEmpty == false
            || status == "promoted" || phase == "promoted"
        let reverted = (run.revertCommitSha?.isEmpty == false)
            || status == "reverted" || phase == "reverted"
            || firstBool(extras, ["reverted"]) == true
        let failed = status == "failed" || phase == "failed" || status == "candidate_failed"
        let interrupted = status == "interrupted" || phase == "interrupted"
        let promotionPolicy = firstString(extras, ["promotionPolicy", "promotion_policy"])
            ?? "manual_review"
        let notes = firstString(extras, ["scoreboardNotes", "notes"])

        return SelfImprovementScoreboardRecord(
            runId: run.id,
            createdAt: run.createdAt,
            completedAt: run.completedAt,
            status: run.status,
            phase: run.phase,
            objective: run.objective,
            latencyMs: latency,
            retryCount: retryCount,
            userCorrectionCount: correctionCount,
            promptBytes: promptBytes,
            frozenTurnCount: frozenTurnCount,
            failedCompletionCount: failedCompletionCount,
            testFailureCount: testFailureCount,
            rollbackCount: rollbackCount,
            promoted: promoted,
            reverted: reverted,
            failed: failed,
            interrupted: interrupted,
            promotionPolicy: promotionPolicy,
            notes: notes
        )
    }

    private static func isSuccessful(_ record: SelfImprovementScoreboardRecord) -> Bool {
        guard !record.failed, !record.reverted, !record.interrupted else { return false }
        let status = record.status?.lowercased()
        let phase = record.phase?.lowercased()
        return record.promoted
            || status == "succeeded"
            || status == "verified"
            || phase == "verified"
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private static func firstString(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            guard case .string(let value)? = object[key], !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func firstBool(_ object: [String: JSONValue], _ keys: [String]) -> Bool? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .bool(let bool): return bool
            case .string(let string):
                if string.lowercased() == "true" { return true }
                if string.lowercased() == "false" { return false }
            default:
                continue
            }
        }
        return nil
    }

    private static func firstInt(_ object: [String: JSONValue], _ keys: [String]) -> Int? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .int(let int): return max(0, Int(int))
            case .double(let double): return max(0, Int(double))
            case .string(let string):
                if let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return max(0, int)
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func latencyMs(createdAt: String?, completedAt: String?) -> Int? {
        guard let start = parseISO(createdAt), let end = parseISO(completedAt) else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    private static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

public extension SwiftNativeSelfImprovement {
    func improvementScoreboardLocal() async throws -> SelfImprovementScoreboardSummary {
        let runs = try await listImprovementsLocal()
        return SelfImprovementScoreboard.summarize(runs: runs)
    }
}
