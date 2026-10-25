import Foundation
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
    /// Stable Workshop identity. New directed-task samples are keyed by their
    /// Desk handle; daemon-era history falls back to the execution id.
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
    /// The planner FAILED for this execution (threw / returned non-JSON / 0 valid
    /// steps) and fell back to a deterministic stub plan — a PLAN-QUALITY signal.
    /// Derived from the `planner_fallback` timeline event (`fromStub` isn't on
    /// WorkshopExecutionRecord). NOTE (gpt-5.5): this is the planner-FAILURE rate, NOT
    /// every stub plan — the autonomy-disabled path also stubs but emits no
    /// `planner_fallback` event, and that's a deliberate disable, not a quality
    /// failure, so excluding it is correct. A rising rate = the planner is
    /// degrading (multi-step jobs quietly collapsing to trivial stubs).
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

    public var isTerminal: Bool { WorkshopOutcomeScoreboard.terminalStatuses.contains(status.lowercased()) }
    public var isCompleted: Bool { WorkshopOutcomeScoreboard.completedStatuses.contains(status.lowercased()) }

    /// Wall time from creation to the LAST execution.json write (createdAt →
    /// updatedAt). For the common case (an execution not edited after it finishes)
    /// the last write IS the terminal transition, so this ≈ end-to-end
    /// execution time. CAVEAT (gpt-5.5 review): later edits can bump
    /// `updatedAt`, so an execution edited post-terminal would overstate
    /// this — it's an UPPER BOUND
    /// on execution time, a useful trend signal, not an exact duration. Exact
    /// terminal duration needs a dedicated terminal timestamp / timeline parse
    /// (v2). Clamped at 0 (a clock skew / out-of-order write can't go negative).
    public var wallSeconds: Double { max(0, updatedAt.timeIntervalSince(createdAt)) }
}

public enum WorkshopOutcomeScoreboard {
    // Status sets mirror the runner's terminal set (WorkshopExecution.swift ~L1379).
    public static let completedStatuses: Set<String> = ["completed", "done", "succeeded"]
    public static let failedStatuses: Set<String> = ["failed"]
    public static let cancelledStatuses: Set<String> = ["cancelled", "canceled"]
    public static let unverifiedStatuses: Set<String> = ["unverified"]
    public static let terminalStatuses: Set<String> =
        completedStatuses.union(failedStatuses).union(cancelledStatuses).union(unverifiedStatuses)

    /// Parse an execution ISO timestamp. Swift-written records use
    /// `[.withInternetDateTime, .withFractionalSeconds]` with a `+00:00`
    /// offset (WorkshopExecution.isoTimestamp). But DAEMON-ERA records on disk carry
    /// MICROSECOND fractions (`2026-05-07T10:12:54.380610+00:00`), and
    /// `ISO8601DateFormatter.withFractionalSeconds` only accepts 3-digit
    /// fractions — so those fail the first two attempts and, without the
    /// microsecond fallback below, would be silently dropped by the scanner's
    /// compactMap (the scoreboard would then ignore most of the real history —
    /// gpt-5.5 review caught this; 19/21 live queue records are microsecond).
    /// Truncate an over-long fraction to milliseconds and retry. Mirrors
    /// DreamCycleRunner.parseDaemonISO; kept local to avoid a DreamREMCycle
    /// module dependency from WorkshopExecution.
    static func parseTimestamp(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = NativeTimestampFormat.parseISO8601FractionalFirst(trimmed) { return d }
        if let ms = truncateFractionToMillis(trimmed) {
            return NativeTimestampFormat.parseISO8601FractionalFirst(ms)
        }
        return nil
    }

    /// Shorten a fractional-seconds component longer than 3 digits to exactly
    /// 3, preserving the timezone suffix (`.380610+00:00` → `.380+00:00`).
    /// Returns nil when there is no over-long fraction to shorten (the caller
    /// already tried the raw string).
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
        guard completedStatuses.contains(status.lowercased()) else {
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
        let feed = try await persistence.readJSONLReporting(root.appendingPathComponent("workshop/receipts.jsonl"))
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
        for (id, raw) in try await Self.readQueueRecords(dataRoot: root, persistence: persistence) {
            try Task.checkCancellation()
            guard Self.isSafeExecutionID(id) else {
                throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
            }
            guard case .object(let object) = raw else {
                throw WorkshopExecutionError.persistenceFailure("Workshop outcome record is unavailable: " + id)
            }
            let record = Self.recordFromJSON(object)
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
                let timeline = try await persistence.readJSONLReporting(timelinePath(record.id))
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
