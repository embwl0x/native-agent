import Foundation

// MARK: - REMReport

/// Summary the weekly REM run returns to its caller (scheduler / debug menu).
public struct REMReport: Sendable, Codable, Equatable {
    public var proposalsGenerated: Int
    public var evidenceDatesMin: Int
    public var tombstoneSkips: Int
    public var growthMDEvicted: Int
    public var archivedEntries: Int
    /// Proposals the store REFUSED, keyed by persona doc ("SOUL.md": 2).
    /// nil (and omitted on the wire) when nothing was dropped — and optional
    /// so run reports written before this field decode unchanged. The fence
    /// itself is unchanged; this is the fence saying what it stopped.
    public var personaTargetDrops: [String: Int]?
    /// Why this pass did no work, when it did none. 2026-09-06: losing the run
    /// reservation to a concurrent pass returned a report indistinguishable
    /// from a genuine zero-proposal week, so the scheduler recorded the week
    /// "completed" and never came back — the week was silently dropped. nil on
    /// a pass that actually ran, and omitted on the wire so older run reports
    /// decode unchanged.
    public var skipReason: String?

    public init(
        proposalsGenerated: Int,
        evidenceDatesMin: Int,
        tombstoneSkips: Int,
        growthMDEvicted: Int,
        archivedEntries: Int = 0,
        personaTargetDrops: [String: Int]? = nil,
        skipReason: String? = nil
    ) {
        self.proposalsGenerated = proposalsGenerated
        self.evidenceDatesMin = evidenceDatesMin
        self.tombstoneSkips = tombstoneSkips
        self.growthMDEvicted = growthMDEvicted
        self.archivedEntries = archivedEntries
        self.personaTargetDrops = personaTargetDrops
        self.skipReason = skipReason
    }
}

/// Durable, privacy-safe summary of one invocation of `runWeeklyREM`.
///
/// `REMReport` is the successful-run value returned to an immediate caller.
/// This envelope is what survives a scheduler wake, app restart, or manual
/// debug session in the shared run ledger. It deliberately contains counters
/// and a bounded outcome/reason only — never diary, persona, or proposal text.
public struct REMRunReportPayload: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable, Equatable {
        /// The pipeline reached all commit boundaries (a zero-proposal week is
        /// still completed and is distinguishable by its real counters).
        case completed
        /// The weekly reservation was already fresh, so no second LLM pass ran.
        case skipped
        /// Trust policy rejected the run before any REM persistence work began.
        case disabled
        /// A real execution error or cancellation prevented completion.
        case failed
    }

    public static let schema = "rem.run_report.v1"

    public var schemaVersion: String
    public var outcome: Outcome
    public var reason: String?
    public var report: REMReport?

    public init(
        outcome: Outcome,
        reason: String? = nil,
        report: REMReport? = nil
    ) {
        self.schemaVersion = Self.schema
        self.outcome = outcome
        self.reason = reason
        self.report = report
    }
}
