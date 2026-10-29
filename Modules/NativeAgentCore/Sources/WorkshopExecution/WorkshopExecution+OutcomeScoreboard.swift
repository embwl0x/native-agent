import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `WorkshopExecution+OutcomeScoreboard.swift` | Native canonical receipt/record decoding, verification classification, timestamp interpretation and complete `weeklyOutcomeInput` evidence; missing stores are available empty, unreadable/incomplete sources throw. Editable `Resources/abilities/weekly-outcomes.js` owns local ISO-week grouping, statistics, trend thresholds and digest text; EngineLaunch invokes it through `ToolsFacade.withPartDoor` for maintenance, without activating schedules or a Swift policy substitute |

// Native outcome evidence only. weekly-outcomes.js owns week bucketing,
// statistics, trend thresholds and prompt text. Receipts, verification status,
// timestamp decoding and source availability remain native.

/// One Workshop execution distilled to the fields the scoreboard scores. Dates are
/// pre-parsed natively; only normalized outcome facts cross into the digest part.
public struct WorkshopOutcomeSample: Sendable, Equatable {
    public var id: String
    /// Stable Workshop identity: the Desk handle when present, otherwise the execution id.
    public var deskHandle: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: String
    public var totalSteps: Int
    public var completedSteps: Int
    public var rerunCount: Int
    /// `trigger_source` of the Workshop execution ("manual" / "trigger:<name>" /
    /// another historical source). Lets the scoreboard segment any persisted
    /// cohort without owning a producer for that cohort.
    public var triggerSource: String
    /// Planner failure yielding a stub, evidenced by `planner_fallback`; disabled planning does not count.
    public var wasStub: Bool

    public init(
        id: String, deskHandle: String? = nil, createdAt: Date, updatedAt: Date, status: String,
        totalSteps: Int, completedSteps: Int, rerunCount: Int,
        triggerSource: String = "manual", wasStub: Bool = false
    ) {
        self.id = id
        self.deskHandle = deskHandle ?? id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.totalSteps = totalSteps
        self.completedSteps = completedSteps
        self.rerunCount = rerunCount
        self.triggerSource = triggerSource
        self.wasStub = wasStub
    }

    public var isTerminal: Bool { WorkshopExecutionRecord.isTerminal(status) }
    public var isCompleted: Bool { WorkshopExecutionRecord.isSuccessful(status) }

    /// Nonnegative creation-to-last-write time is an upper bound: record writes can follow completion.
    public var wallSeconds: Double { max(0, updatedAt.timeIntervalSince(createdAt)) }
}

public enum WorkshopOutcomeScoreboard {
    /// Read ISO timestamps with Z or offset zones and optional millisecond or microsecond fractions.
    static func parseTimestamp(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = NativeTimestampFormat.parseISO8601FractionalFirst(trimmed) { return d }
        if let ms = truncateFractionToMillis(trimmed) {
            return NativeTimestampFormat.parseISO8601FractionalFirst(ms)
        }
        return nil
    }

    /// Shorten fractions over three digits to milliseconds, preserving the timezone suffix; otherwise nil.
    static func truncateFractionToMillis(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let firstFrac = s.index(after: dot)
        var i = firstFrac
        var digits = 0
        while i < s.endIndex, s[i].isNumber {
            digits += 1
            i = s.index(after: i)
        }
        guard digits > 3 else { return nil }
        let keepEnd = s.index(firstFrac, offsetBy: 3)  // head + ".###"
        return String(s[..<keepEnd]) + String(s[i...]) // ...### + tz suffix
    }

    /// Build a sample from a persisted record, or nil if its createdAt is
    /// unparseable (a record with no usable creation time can't be bucketed).
    public static func sample(from record: WorkshopExecutionRecord) -> WorkshopOutcomeSample? {
        guard let created = parseTimestamp(record.createdAt) else { return nil }
        let updated = parseTimestamp(record.updatedAt) ?? created
        return WorkshopOutcomeSample(
            id: record.id,
            deskHandle: record.deskHandle,
            createdAt: created,
            updatedAt: updated,
            status: outcomeStatus(status: record.status, verification: record.verification?.status),
            totalSteps: record.plan.count,
            completedSteps: record.stepsCompleted.count,
            rerunCount: record.rerunCount,
            triggerSource: record.triggerSource
        )
    }

    /// Decode canonical directed-task receipts. Executions without such a
    /// receipt are decoded from their canonical record, including live work.
    public static func sample(from receipt: WorkshopDirectedTaskReceipt) -> WorkshopOutcomeSample? {
        guard let created = parseTimestamp(receipt.createdAt) else { return nil }
        let completed = parseTimestamp(receipt.completedAt) ?? created
        return WorkshopOutcomeSample(
            id: receipt.executionId,
            deskHandle: receipt.handle,
            createdAt: created,
            updatedAt: completed,
            status: outcomeStatus(for: receipt),
            totalSteps: receipt.totalSteps,
            completedSteps: receipt.completedSteps,
            rerunCount: receipt.rerunCount,
            triggerSource: receipt.triggerSource,
            wasStub: receipt.wasStub
        )
    }

    /// New receipts distinguish a process ending from its promised outcome
    /// being proven. Legacy receipts omit verificationStatus and retain their
    /// historical interpretation instead of being rewritten speculatively.
    private static func outcomeStatus(for receipt: WorkshopDirectedTaskReceipt) -> String {
        outcomeStatus(status: receipt.status, verification: receipt.verificationStatus)
    }

    private static func outcomeStatus(status: String, verification: WorkshopVerificationStatus?) -> String {
        guard WorkshopExecutionRecord.isSuccessful(status) else {
            return status
        }
        switch verification {
        case .satisfied, .none:
            return status
        case .failed:
            return "failed"
        case .unverified:
            return "unverified"
        }
    }
}

extension SwiftNativeWorkshopRunner {
    /// Complete normalized evidence for the digest part. Missing stores mean
    /// available empty history; unreadable sources throw, never become [].
    /// L0 rejects a packet over its 4 MiB bound without truncating the history.
    public func weeklyOutcomeInput() async throws -> JSONValue {
        let root = executionRecordsRoot.deletingLastPathComponent().deletingLastPathComponent()
        let feed = try await SwiftNativePersistenceCore.readJSONLReporting(root.appendingPathComponent("workshop/receipts.jsonl"))
        guard feed.report.isClean else {
            throw WorkshopExecutionError.persistenceFailure("Workshop outcome receipts are incomplete")
        }
        var receiptByExecution: [String: WorkshopDirectedTaskReceipt] = [:]
        for row in feed.rows {
            guard case .object(let object) = row else {
                throw WorkshopExecutionError.persistenceFailure("Workshop outcome receipt is not an object")
            }
            // Session receipts are a different canonical variant, not directed
            // task samples. A damaged directed-task row is never empty history.
            guard object["kind"] == .string("directed_task") else { continue }
            guard let receipt = WorkshopReceiptLog.directedReceipt(from: row) else {
                throw WorkshopExecutionError.persistenceFailure("Workshop outcome receipt is unavailable")
            }
            receiptByExecution[receipt.executionId] = receipt
        }

        var samples: [JSONValue] = []
        // The checked reader keeps damaged canonical records visible. Such a
        // record cannot supply a dated sample, so the digest is unavailable.
        for (id, _, record) in try await Self.readQueueRecords(dataRoot: root) {
            try Task.checkCancellation()
            guard Self.isSafeExecutionID(id) else {
                throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
            }
            guard record.status != "corrupt", record.status != "unavailable" else {
                throw WorkshopExecutionError.persistenceFailure("Workshop outcome record is unavailable: " + id)
            }
            var sample: WorkshopOutcomeSample
            if var receipt = receiptByExecution[record.id] {
                // Old receipts inherit only the canonical record's actual
                // verification evidence, never speculative verification.
                if receipt.verificationStatus == nil {
                    receipt.verificationStatus = record.verification?.status
                }
                guard let decoded = WorkshopOutcomeScoreboard.sample(from: receipt) else {
                    throw WorkshopExecutionError.persistenceFailure("Workshop outcome receipt timestamp is unavailable: " + id)
                }
                sample = decoded
            } else {
                guard let decoded = WorkshopOutcomeScoreboard.sample(from: record) else {
                    throw WorkshopExecutionError.persistenceFailure("Workshop outcome timestamp is unavailable: " + id)
                }
                sample = decoded
                let timeline = try await SwiftNativePersistenceCore.readJSONLReporting(timelinePath(record.id))
                guard timeline.report.isClean else {
                    throw WorkshopExecutionError.persistenceFailure("Workshop outcome timeline is incomplete: " + id)
                }
                sample.wasStub = timeline.rows.contains { row in
                    if case .object(let o) = row, case .string("planner_fallback")? = o["event"] { return true }
                    return false
                }
            }
            samples.append(.object([
                "createdDay": .string(NativeTimestampFormat.calendarDay(sample.createdAt)),
                "status": .string(sample.status.lowercased()),
                "terminal": .bool(sample.isTerminal),
                "completed": .bool(sample.isCompleted),
                "totalSteps": .int(Int64(sample.totalSteps)),
                "completedSteps": .int(Int64(sample.completedSteps)),
                "wallSeconds": .double(sample.wallSeconds),
                "rerunCount": .int(Int64(sample.rerunCount)),
                "triggerSource": .string(sample.triggerSource),
                "wasStub": .bool(sample.wasStub),
            ]))
        }
        return .object(["availability": .string("available"), "samples": .array(samples)])
    }
}
