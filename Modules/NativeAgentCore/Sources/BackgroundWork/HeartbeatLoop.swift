import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatLoop.swift` | Event/deadline heartbeat checklist lifetime and per-condition notice settlement; missing checklist claims no health |
/// Missing checklist proves no health; a healthy assessment needs no notice.
/// The nonthrowing LoopRunner contract requires errors to surface as outcomes.
public struct HeartbeatLoop: EventDeadlineLoopRunner {
    public let loopId: String = "heartbeat"
    public let wake: OrganWake
    /// Its checklist is the agent's own HEARTBEAT.md.
    public var needsAgent: Bool { true }
    private let configurationError: String?
    /// Twice-daily health rhythm. Additional assessments follow
    /// input invalidations and their age deadlines; urgent faults also reach Doctor.
    public static let defaultInterval: TimeInterval = 12 * 60 * 60

    private let events: @Sendable () -> AsyncStream<Void>
    private let nextDeadline: @Sendable (Date) async -> Date?

    /// Absence supplies no checklist and therefore authorizes no health verdict.
    private let loadChecklist: @Sendable () throws -> String?
    private let gatherAssessment: @Sendable () async -> HeartbeatAssessment
    /// Inbox write errors must propagate so the tick cannot claim a notice landed.
    private let surfaceNotice: @Sendable (HeartbeatNotice) async throws -> Void

    public init(
        interval: TimeInterval = Self.defaultInterval,
        configurationError: String? = nil,
        events: @escaping @Sendable () -> AsyncStream<Void> = {
            EventDeadlinePhysiology.storeAndFileEvents(paths: [])
        },
        nextDeadline: @escaping @Sendable (Date) async -> Date? = { _ in nil },
        loadChecklist: @escaping @Sendable () throws -> String?,
        gatherAssessment: @escaping @Sendable () async -> HeartbeatAssessment,
        surfaceNotice: @escaping @Sendable (HeartbeatNotice) async throws -> Void
    ) {
        self.wake = .every(interval)
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
        let loaded: String?
        do { loaded = try loadChecklist() }
        catch { return .failed(error: "Heartbeat checklist unavailable: \(error.localizedDescription). Repair HEARTBEAT.md before retrying.") }
        guard let checklist = loaded?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checklist.isEmpty else {
            // No checklist means nothing was checked; never manufacture an all-clear.
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: no HEARTBEAT.md checklist — skipping (no-op, not healthy)\n".utf8))
            return .off("HEARTBEAT.md missing or empty")
        }
        let assessment = await gatherAssessment()
        if assessment.deterministicOK {
            return .completed(result: "deterministic heartbeat healthy")
        }
        // Timed-out ticks may still be unwinding; cancellation must prevent a post-restart card.
        if Task.isCancelled { return .skipped(reason: "canceled") }
        do {
            try await surfaceNotice(HeartbeatNotice(
                conditionId: assessment.conditionId,
                body: Self.fallbackBody(for: assessment),
                actions: assessment.actions
            ))
        } catch {
            // A failed outcome records the dropped card; never claim failed inbox delivery surfaced.
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
