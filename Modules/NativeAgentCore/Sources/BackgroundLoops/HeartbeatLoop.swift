import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

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

/// Small, separate "is anything quietly on fire?" heartbeat (U2b wave 3,
/// plan design #6). Distinct from the weekly self-improvement pass and the
/// self-healing hook: this reads a `HEARTBEAT.md` checklist from the persona
/// dir and an app-supplied deterministic assessment. Clean assessments skip
/// the LLM entirely. Only anomalous assessments ask the app's OWN configured
/// LLM (routed by the `heartbeat` surface picker — the user's HARD RULE: every LLM
/// call site resolves via the picker, never a hardcoded provider/model) to
/// phrase the alert. The LLM can improve wording, but it cannot suppress a
/// deterministic anomaly by returning `HEARTBEAT_OK`.
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
    /// A heartbeat is ONE cheap LLM turn over a small checklist + signal
    /// block; it should never approach the long-pass overrides the weekly /
    /// Workshop execution loops need. 120s is a generous ceiling for a small turn (and
    /// well under the scheduler's 300s default — kept explicit so a slow
    /// provider can't wedge the heartbeat cadence).
    public var tickTimeoutOverride: TimeInterval? { 120 }

    /// The EXACT reply (after trimming) that means "all clear." Anything else
    /// — including an empty reply or a near-miss like "heartbeat ok" — is
    /// surfaced. Exact-match is deliberate: a model that's unsure must not be
    /// able to fall into silence by paraphrasing the OK token.
    public static let okToken = "HEARTBEAT_OK"

    /// The surface name; its own MODEL_SURFACES entry (added in this wave) so
    /// the user can pin a cheap model for heartbeats independently of chat.
    public static let surface = "heartbeat"
    /// Default production cadence: twice daily. The loop is a low-noise
    /// sentinel, not a near-real-time monitor; urgent faults are covered by
    /// Doctor and SelfHealingHook.
    public static let defaultInterval: TimeInterval = 12 * 60 * 60

    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let clock: @Sendable () -> Date
    /// Reads the `HEARTBEAT.md` checklist (persona dir). Returns nil when the
    /// file is absent — the honest no-op trigger.
    private let loadChecklist: @Sendable () -> String?
    /// Gathers the compact live signal assessment (pending evolution / stuck
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
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        clock: @escaping @Sendable () -> Date = { Date() },
        loadChecklist: @escaping @Sendable () -> String?,
        gatherAssessment: @escaping @Sendable () async -> HeartbeatAssessment,
        surfaceNotice: @escaping @Sendable (HeartbeatNotice) async throws -> Void
    ) {
        self.interval = interval
        self.llm = llm
        self.router = router
        self.clock = clock
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
            return .skipped(reason: "HEARTBEAT.md missing or empty")
        }
        let assessment = await gatherAssessment()
        if assessment.deterministicOK {
            return .completed(result: "deterministic heartbeat healthy")
        }

        let body: String
        do {
            let model = await router.modelStringForSurface(Self.surface)
            let raw = try await llm.complete(
                prompt: Self.heartbeatPrompt(
                    checklist: checklist,
                    assessment: assessment,
                    now: clock()
                ),
                system: Self.systemPrompt,
                model: model,
                surface: Self.surface
            )
            // CONTRACT (documented in the u2b plan, design #6): exact match
            // after a whitespace-ONLY trim. LLMs near-universally append a
            // trailing newline; raw-exact would surface a noise card on every
            // healthy tick (alert fatigue). The safety property is preserved:
            // any NON-whitespace addition ("HEARTBEAT_OK.", "HEARTBEAT_OK but
            // note…", lowercase) fails the match and SURFACES.
            let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            body = reply == Self.okToken || reply.isEmpty
                ? Self.fallbackBody(for: assessment)
                : reply
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: alert wording failed, surfacing deterministic fallback: \(error)\n".utf8))
            body = Self.fallbackBody(for: assessment)
        }

        // Scheduler allows timed-out ticks to keep running until they observe
        // cancellation — never emit a user-visible card after cancel/restart.
        if Task.isCancelled { return .skipped(reason: "canceled") }
        do {
            try await surfaceNotice(HeartbeatNotice(
                conditionId: assessment.conditionId,
                body: body,
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

    // MARK: - Prompt

    static let systemPrompt = """
    You are the heartbeat monitor for NativeAgent, a native Mac + iOS AI \
    assistant app. You are given a short HEARTBEAT.md checklist of things to \
    verify and a compact block of the app's CURRENT live signals. Check the \
    checklist against the signals.

    CONTRACT — follow it EXACTLY:
    • If, and ONLY if, every checklist item is satisfied and nothing in the \
      signals looks wrong, reply with the single token:
          HEARTBEAT_OK
      and NOTHING else — no punctuation, no explanation, no surrounding text.
    • Otherwise, reply with a short (1-4 sentence) plain-text alert naming \
      ONLY the concrete problem(s) you found and, where useful, what to look \
      at. Do NOT include the token HEARTBEAT_OK anywhere in an alert.

    Do not invent problems. The Swift deterministic assessment has already \
    found an anomaly when you are called; your job is to phrase it clearly \
    from the supplied facts, not to override it.
    """

    static func heartbeatPrompt(
        checklist: String,
        assessment: HeartbeatAssessment,
        now: Date
    ) -> String {
        """
        Heartbeat at \(isoString(now)).

        ## HEARTBEAT.md checklist
        \(checklist)

        ## Deterministic alert
        condition_id: \(assessment.conditionId)
        fallback_alert: \(fallbackBody(for: assessment))

        ## Live signals
        \(assessment.signals.isEmpty ? "(no signals gathered)" : assessment.signals)

        Reply with a short user-facing alert for this concrete condition.
        """
    }

    // MARK: - Helpers

    static func fallbackBody(for assessment: HeartbeatAssessment) -> String {
        let trimmed = assessment.fallbackAlert.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "(heartbeat found condition \(assessment.conditionId), but no alert text was supplied)"
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
