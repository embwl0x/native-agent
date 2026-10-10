import Foundation
import NativeAgentCore
import PersistenceCore

public struct HeartbeatNoticeAction: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct HeartbeatAssessment: Sendable, Equatable {
    public let signals: String
    public let deterministicOK: Bool
    public let conditionId: String
    public let fallbackAlert: String
    public let actions: [HeartbeatNoticeAction]

    public init(
        signals: String,
        deterministicOK: Bool,
        conditionId: String,
        fallbackAlert: String,
        actions: [HeartbeatNoticeAction] = []
    ) {
        self.signals = signals
        self.deterministicOK = deterministicOK
        self.conditionId = conditionId
        self.fallbackAlert = fallbackAlert
        self.actions = actions
    }

    public static func clean(signals: String) -> HeartbeatAssessment {
        HeartbeatAssessment(
            signals: signals,
            deterministicOK: true,
            conditionId: "ok",
            fallbackAlert: ""
        )
    }
}

public struct HeartbeatNotice: Sendable, Equatable {
    public let conditionId: String
    public let body: String
    public let actions: [HeartbeatNoticeAction]

    public init(conditionId: String, body: String, actions: [HeartbeatNoticeAction] = []) {
        self.conditionId = conditionId
        self.body = body
        self.actions = actions
    }
}

/// Reads the `HEARTBEAT.md` checklist and surfaces the assessment's
/// per-condition alert. Healthy assessments make no notice.
///
/// Design notes:
/// - Dependency-clean: the checklist read, the assessment gather, and the notice
///   surface are all injected closures, so this module gains no new deps.
///   BackgroundLoopsAssembly wires the real persona path + signal reads + inbox.
/// - Honest missing-checklist contract: no `HEARTBEAT.md` is NOT "healthy" —
///   it's a no-op that logs and returns, never a fabricated all-clear (the
///   loop has nothing to check against, so it asserts nothing).
/// - tick() is non-throwing by LoopRunner contract — every error is caught
///   and surfaced via stderr.
public struct HeartbeatLoop: LoopRunner {
    public let loopId: String = "heartbeat"
    public let interval: TimeInterval
    /// Default production cadence: twice daily. The loop is a low-noise
    /// sentinel, not a near-real-time monitor; urgent faults are covered by
    /// Doctor.
    public static let defaultInterval: TimeInterval = 12 * 60 * 60

    /// Reads the `HEARTBEAT.md` checklist (persona dir). Returns nil when the
    /// file is absent — the honest no-op trigger.
    private let loadChecklist: @Sendable () -> String?
    /// Gathers the compact live signal assessment (stuck
    /// Workshop executions / Full-Mac expiry / Doctor / error bursts). Injected so the
    /// module needs no Workshop / SelfImprovement dep and tests can feed canned
    /// signals.
    private let gatherAssessment: @Sendable () async -> HeartbeatAssessment
    /// Surfaces a non-OK heartbeat notice to the user (notice / inbox card).
    /// Injected; the assembly wires it to an inbox.jsonl append.
    ///
    /// 2026-07-23 FIX 3 (A4.5): `throws` so a failed inbox write is OBSERVABLE.
    /// Previously this was `async -> Void`, so a staging-write failure was
    /// swallowed and the tick still returned `.completed("heartbeat notice
    /// surfaced")` — a lie, and it bypassed the manager's `.failed` →
    /// background_loop_failures.jsonl receipt net entirely.
    private let surfaceNotice: @Sendable (HeartbeatNotice) async throws -> Void

    public init(
        interval: TimeInterval = Self.defaultInterval,
        loadChecklist: @escaping @Sendable () -> String?,
        gatherAssessment: @escaping @Sendable () async -> HeartbeatAssessment,
        surfaceNotice: @escaping @Sendable (HeartbeatNotice) async throws -> Void
    ) {
        self.interval = interval
        self.loadChecklist = loadChecklist
        self.gatherAssessment = gatherAssessment
        self.surfaceNotice = surfaceNotice
    }

    public func tickOutcome() async -> LoopTickOutcome {
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

    // MARK: - Helpers

    static func fallbackBody(for assessment: HeartbeatAssessment) -> String {
        let trimmed = assessment.fallbackAlert.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "(heartbeat found condition \(assessment.conditionId), but no alert text was supplied)"
    }

}
