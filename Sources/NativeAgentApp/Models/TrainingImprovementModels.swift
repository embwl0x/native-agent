import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
import SelfImprovement

struct TrainingArtifact: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String?
    var sourceId: String?
    var sensitivity: String?
    var status: String?
    var createdAt: String?
    var summary: String?
}

extension SelfImprovement.ImprovementSummary {
    var trustEnabled: Bool? {
        guard case .object(let row) = rawResponse, case .bool(let enabled)? = row["trustEnabled"] else { return nil }
        return enabled
    }
}

struct HarnessBenchmarkRun: Identifiable, Codable, Hashable {
    var id: String
    var name: String?
    var status: String?
    var checks: [HarnessBenchmarkCheck]?
    var durationSeconds: Double?
    var schedule: String?
    var manualRunnable: Bool?
    var chatPathImpact: String?
    var createdAt: String?
}

struct HarnessBenchmarkCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var passed: Bool?
    var detail: String?
}

// PATCH-2026-05-08: no-terminal-moments — rebuild result
struct SystemRebuildResult: Codable, Hashable {
    var ok: Bool
    var message: String?
    var error: String?
}

extension SelfImprovement.ImprovementSummary {
    /// The persisted UI summary is a flat record; the core summary keeps its
    /// long-tail fields in rawResponse instead of duplicating them in app state.
    init(persistedRow value: JSONValue) throws {
        guard case .object(let row) = value,
              let enabled = improvementBool(row["enabled"]),
              let status = improvementString(row["status"]) else {
            throw CocoaError(.coderReadCorrupt)
        }
        func count(_ key: String) throws -> Int {
            guard case .int(let value)? = row[key], let result = Int(exactly: value) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return result
        }
        func run(_ key: String) throws -> SelfImprovement.ImprovementRun? {
            guard let value = row[key], value != .null else { return nil }
            return try SelfImprovement.ImprovementRun(persistedRow: value)
        }
        let staged: [SelfImprovement.ImprovementRun]?
        if case .array(let values)? = row["stagedRuns"] {
            staged = try values.map { try SelfImprovement.ImprovementRun(persistedRow: $0) }
        } else {
            staged = nil
        }
        self.init(
            enabled: enabled, status: status,
            disabledReason: improvementString(row["disabledReason"]),
            runningCount: try count("runningCount"), succeededCount: try count("succeededCount"),
            failedCount: try count("failedCount"), interruptedCount: try count("interruptedCount"),
            stagedCount: try count("stagedCount"), totalCount: try count("totalCount"),
            latestRun: try run("latestRun"), latestFailure: try run("latestFailure"),
            stagedRuns: staged, rawResponse: value
        )
    }
}

private extension SelfImprovement.ImprovementRun {
    init(persistedRow value: JSONValue) throws {
        guard case .object(let row) = value,
              let id = improvementString(row["id"]),
              let status = improvementString(row["status"]),
              let phase = improvementString(row["phase"]),
              let createdAt = improvementString(row["createdAt"]),
              let objective = improvementString(row["objective"]) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let known: Set<String> = ["id", "status", "phase", "createdAt", "completedAt", "objective", "summary", "model", "worktree", "exitReason", "promotedCommitSha", "revertCommitSha"]
        let extras = row.filter { !known.contains($0.key) }
        self.init(
            id: id, status: status, phase: phase, createdAt: createdAt,
            completedAt: improvementString(row["completedAt"]), objective: objective,
            summary: improvementString(row["summary"]), model: improvementString(row["model"]),
            worktree: improvementString(row["worktree"]), exitReason: improvementString(row["exitReason"]),
            promotedCommitSha: improvementString(row["promotedCommitSha"]),
            revertCommitSha: improvementString(row["revertCommitSha"]),
            extras: extras.isEmpty ? nil : .object(extras)
        )
    }
}

private func improvementString(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
}

private func improvementBool(_ value: JSONValue?) -> Bool? {
    guard case .bool(let bool)? = value else { return nil }
    return bool
}
