import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatLoop.swift` | Event/deadline heartbeat checklist lifetime and per-condition notice settlement; missing checklist claims no health |
/// Reads the `HEARTBEAT.md` checklist and surfaces the assessment's
/// per-condition alert. Healthy assessments make no notice.
///
/// Design notes:
/// - Honest missing-checklist contract: no `HEARTBEAT.md` is NOT "healthy" —
///   it's a no-op that logs and returns, never a fabricated all-clear (the
///   loop has nothing to check against, so it asserts nothing).
/// - tick() is non-throwing by LoopRunner contract — every error is caught
///   and surfaced via stderr.
public struct HeartbeatLoop: EventDeadlineLoopRunner {
    public let loopId: String = "heartbeat"
    public let interval: TimeInterval
    private let configurationError: String?
    /// Twice-daily missed-event integrity sweep. Normal assessments follow
    /// input invalidations and their age deadlines; urgent faults also reach Doctor.
    public static let defaultInterval: TimeInterval = 12 * 60 * 60

    private let events: @Sendable () -> AsyncStream<Void>
    private let nextDeadline: @Sendable (Date) async -> Date?

    /// Reads the `HEARTBEAT.md` checklist (persona dir). Returns nil when the
    /// file is absent — the honest no-op trigger.
    private let loadChecklist: @Sendable () -> String?
    /// Gathers the compact live signal assessment (stuck
    /// Workshop executions / Full-Mac expiry / Doctor / error bursts).
    private let gatherAssessment: @Sendable () async -> HeartbeatAssessment
    /// Surfaces a non-OK heartbeat notice to the user (notice / inbox card).
    /// The owning factory wires it to the durable inbox.
    /// Inbox write errors propagate so the tick records a failed outcome.
    private let surfaceNotice: @Sendable (HeartbeatNotice) async throws -> Void

    public init(
        interval: TimeInterval = Self.defaultInterval,
        configurationError: String? = nil,
        events: @escaping @Sendable () -> AsyncStream<Void> = {
            EventDeadlinePhysiology.storeAndFileEvents(paths: [])
        },
        nextDeadline: @escaping @Sendable (Date) async -> Date? = { _ in nil },
        loadChecklist: @escaping @Sendable () -> String?,
        gatherAssessment: @escaping @Sendable () async -> HeartbeatAssessment,
        surfaceNotice: @escaping @Sendable (HeartbeatNotice) async throws -> Void
    ) {
        self.interval = interval
        self.configurationError = configurationError
        self.events = events
        self.nextDeadline = nextDeadline
        self.loadChecklist = loadChecklist
        self.gatherAssessment = gatherAssessment
        self.surfaceNotice = surfaceNotice
    }
    public func physiologyEvents() -> AsyncStream<Void> { events() }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? { await nextDeadline(now) }

    public func tickOutcome() async -> LoopTickOutcome {
        if let configurationError { return .failed(error: configurationError) }
        guard let checklist = loadChecklist()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checklist.isEmpty else {
            // Missing (or empty) HEARTBEAT.md = honest no-op. We have nothing
            // to check against; asserting "healthy" here would be a fabricated
            // all-clear (the exact failure mode the silent-OK contract exists
            // to prevent). Log and return — never surface, never claim health.
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: no HEARTBEAT.md checklist — skipping (no-op, not healthy)\n".utf8))
            return .off("HEARTBEAT.md missing or empty")
        }
        let assessment = await gatherAssessment()
        if assessment.deterministicOK {
            return .completed(result: "deterministic heartbeat healthy")
        }
        // Scheduler allows timed-out ticks to keep running until they observe
        // cancellation — never emit a user-visible card after cancel/restart.
        if Task.isCancelled { return .skipped(reason: "canceled") }
        do {
            try await surfaceNotice(HeartbeatNotice(
                conditionId: assessment.conditionId,
                body: Self.fallbackBody(for: assessment),
                actions: assessment.actions
            ))
        } catch {
            // The inbox write did not land — do NOT claim the notice surfaced.
            // Returning .failed trips the manager's failure-receipt net so the
            // dropped card is recorded instead of silently lost.
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: notice staging failed: \(error)\n".utf8))
            return .failed(error: "heartbeat notice staging: \(SwiftNativeLoopScheduler.describeLoopError(error))")
        }
        return .completed(result: "heartbeat notice surfaced")
    }

    static func fallbackBody(for assessment: HeartbeatAssessment) -> String {
        let trimmed = assessment.fallbackAlert.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "(heartbeat found condition \(assessment.conditionId), but no alert text was supplied)"
    }
}
