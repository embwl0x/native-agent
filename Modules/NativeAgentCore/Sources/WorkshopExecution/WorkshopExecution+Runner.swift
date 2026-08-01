import Foundation
import os
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - SwiftNative impl

public actor SwiftNativeWorkshopRunner: WorkshopRunnerClient {
    private let root: URL
    private let persistence: any PersistenceCoreProtocol
    private let planner: any WorkshopPlannerLLM
    private let enableAutonomy: Bool
    private let executorAvailable: Bool
    private let workshopExecutionSlotsCapOverride: Int?
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> String
    private static let logger = Logger(subsystem: "com.nativeagent.workshop", category: "runner")

    /// `executorAvailable` is declared FIRST so test call sites can opt in
    /// uniformly regardless of which other params they pass. Default TRUE
    /// since the executor port landed (2026-06-10,
    /// docs/build_plans/missions-executor-port.md): WorkshopExecutorLoop
    /// (WorkshopExecution+Executor.swift) drains queued missions, so submit() is
    /// honest again. Pass `false` explicitly to restore the honest-refusal
    /// gate (e.g. an embedding that registers no executor loop).
    public init(
        executorAvailable: Bool = true,
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        planner: (any WorkshopPlannerLLM)? = nil,
        enableAutonomy: Bool = true,
        workshopExecutionSlotsCapOverride: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.planner = planner ?? StubWorkshopPlannerLLM()
        self.enableAutonomy = enableAutonomy
        self.executorAvailable = executorAvailable
        self.workshopExecutionSlotsCapOverride = workshopExecutionSlotsCapOverride
        self.now = now
        self.uuid = uuid
    }

    /// Test-only seam: returns the runtime planner's type name so factory-level
    /// tests can assert that the PRODUCTION factory path wires the real
/// `SwiftNativeWorkshopPlannerLLM` and NOT the `StubWorkshopPlannerLLM`
    /// default. Without this seam, the planner field is private and the only
    /// observable difference at the factory level (in a test, with no provider
    /// credentials) is the failure reason string — too brittle to test on.
    /// See BLOCKING #1 of the wave-24-amendment.
    public nonisolated var _testPlannerTypeName: String {
        return String(describing: type(of: planner))
    }

    /// Confirms factory root threading reaches the planner's RunLedger owner,
    /// not only the runner's execution directory.
    public nonisolated var _testPlannerRunLedgerDataRoot: URL? {
        (planner as? SwiftNativeWorkshopPlannerLLM)?._testRunLedgerDataRoot
    }

    public nonisolated var executionRecordsRoot: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
    }

    public nonisolated func workshopExecutionDir(_ id: String) -> URL {
        executionRecordsRoot.appendingPathComponent(id, isDirectory: true)
    }

    public nonisolated func executionRecordPath(_ id: String) -> URL {
        workshopExecutionDir(id).appendingPathComponent("mission.json")
    }

    public nonisolated func timelinePath(_ id: String) -> URL {
        workshopExecutionDir(id).appendingPathComponent("timeline.jsonl")
    }

    public nonisolated func receiptsDir(_ id: String) -> URL {
        workshopExecutionDir(id).appendingPathComponent("receipts", isDirectory: true)
    }

    // WAVE 41 W01 (REOPEN §6.220-rd2 #1) — write-side parity helpers.
    //
    // Mac native mission writes (submit/create, update) MUST mirror the three
    // daemon submission semantics they previously bypassed:
    //   (a) the missionPolicy.enabled gate (`Runtime._missions_allowed`,
    //       the retired daemon) — the daemon route 403s create when
    //       missionPolicy is off;
    //   (b) the mission-slots capacity gate (`_mission_slots` BoundedSemaphore,
    //       the retired daemon / L734) — submit() raises MissionsBusyError
    //       when no slot is free;
    //   (c) the Activity feed row (`Runtime.record_activity`, the retired daemon
    //       L5288-L5308) the legacy create/update handlers emit so the Mac
    //       Activity view shows mission events.
    // These read/append plain JSON files co-located with the daemon under the
    // SAME data root, so the WorkshopExecution module stays self-contained (no new
    // TrustCenter inter-module dependency — same in-module-trust-gate pattern
    // MultimodalTTS uses, Package.swift comment L79-L86).

    /// `Runtime.trust_path`: `<root>/trust/policy.json`.
    nonisolated var trustPolicyPath: URL {
        root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// `Runtime.activity_path`:
    /// `<root>/activity/events.jsonl`.
    nonisolated var activityPath: URL {
        root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Mirror of `Runtime._missions_allowed`:
    ///   `bool(policy.get("developerMode")) or
    ///    bool(policy.get("missionPolicy", {}).get("enabled", False))`
    /// against the MERGED trust policy. We only need these two keys, so rather
    /// than port the whole `trust_policy()` merge+normalize, read the saved
    /// `trust/policy.json` and apply the SAME default the daemon's
    /// `default_trust_policy()` ships:
    /// `missionPolicy.enabled` defaults to TRUE. So a fresh root with no saved
    /// policy is ALLOWED — matching the daemon and keeping the default-OFF
    /// `.missionsWrites` seam's behavior identical to the daemon route it
    /// falls through to. The gate only ever REFUSES when a saved policy
    /// explicitly sets `missionPolicy.enabled = false` (and developerMode is
    /// not set) — exactly the daemon's 403 condition.
    private func workshopExecutionsAllowed() async -> Bool {
        let raw = await persistence.readJSON(trustPolicyPath, defaultValue: .null)
        guard case .object(let policy) = raw else {
            // No saved policy → default_trust_policy(): missionPolicy.enabled = true.
            return true
        }
        return Self.workshopPolicyAllows(policy)
    }

    /// SINGLE SOURCE OF TRUTH for the missionPolicy half of
    /// `Runtime._missions_allowed`:
    ///   `bool(policy.get("developerMode")) or
    ///    bool(policy.get("missionPolicy", {}).get("enabled", False))`
    /// evaluated with merged-default semantics. Public + static so the
    /// app-layer EXECUTOR gate (BackgroundLoopsAssembly.missionExecutorGate)
    /// evaluates the EXACT same rules as this submit-side gate — gpt-5.5
    /// executor-port blocker #7 flagged the two gates diverging (the
    /// executor gate treated a present-but-malformed missionPolicy as ALLOW
    /// while submit denies it).
    ///
    /// Rules:
    ///   - developerMode truthy (retired truthiness) -> allow. Swift-native
    ///     policy keeps Developer Mode as the explicit operator-only
    ///     escalation, independent of the selected access preset.
    ///   - missionPolicy ABSENT → allow (merged default enabled=true).
    ///   - missionPolicy present but NOT an object → DENY. §6.240-rd2 #1
    ///     PARITY-FIX (gpt-5.5 W41 W01 finding): the daemon's
    ///     `policy.get("missionPolicy", {}).get("enabled", False)` raises
    ///     AttributeError if missionPolicy is a string/array/scalar — the
    ///     route bubbles a 500 → effective DENY. Conflating that with
    ///     "absent → allow" is a fail-open on malformed policies.
    ///   - `enabled` key absent → allow (merged default enabled=true).
    ///   - otherwise -> retired truthiness of `enabled`.
    public static func workshopPolicyAllows(_ policy: [String: JSONValue]) -> Bool {
        if WorkshopExecutionUpdate.pyTruthy(policy["developerMode"]) { return true }
        let mpRaw = policy["missionPolicy"]
        if mpRaw == nil {
            return true   // missionPolicy absent → merged default enabled=true
        }
        guard case .object(let mp)? = mpRaw else {
            return false  // missionPolicy present but malformed → deny (daemon AttributeError-bubble parity)
        }
        guard let enabled = mp["enabled"] else {
            return true   // enabled key absent → merged default enabled=true
        }
        return WorkshopExecutionUpdate.pyTruthy(enabled)
    }

    /// Mirror of the `_mission_slots` capacity:
    /// `BoundedSemaphore(max_active + max_pending)` where the two counts come
    /// from the SAME env vars (defaults 3 + 32 = 35). The daemon holds one
    /// permit for a mission's whole queued→running lifetime (acquire in
    /// submit() L734, release in _run_mission's finally), so the live count is
    /// the number of missions in a non-terminal state. We can't hold a
    /// cross-process semaphore for the daemon executor's lifetime, so we mirror
    /// the EFFECT: count active (queued/running/blocked_on_approval) queue
    /// missions and refuse a new submit when that count is already at the cap —
    /// the same condition under which the daemon's `acquire(blocking=False)`
    /// would fail.
    private static func workshopExecutionSlotsCap() -> Int {
        let env = ProcessInfo.processInfo.environment
        // Python: max(1, int(...)) for active; max(0, int(...)) for pending.
        let active = max(1, Int(env["NATIVE_AGENT_MAX_ACTIVE_MISSIONS"] ?? "") ?? 3)
        let pending = max(0, Int(env["NATIVE_AGENT_MAX_PENDING_MISSIONS"] ?? "") ?? 32)
        return active + pending
    }

    private func effectiveWorkshopExecutionSlotsCap() -> Int {
        if let workshopExecutionSlotsCapOverride {
            return max(1, workshopExecutionSlotsCapOverride)
        }
        return Self.workshopExecutionSlotsCap()
    }

    /// Refuse if the queue is at capacity. Mirrors the
    /// `if not self._mission_slots.acquire(blocking=False): raise MissionsBusyError()`
    /// guard at the TOP of submit().
    private func assertSlotAvailable() async throws {
        let cap = effectiveWorkshopExecutionSlotsCap()
        let activeCount = await listActive().count + liveReservationCount()
        if activeCount >= cap {
            // Same message MissionsBusyError ships by default.
            throw WorkshopExecutionError.workshopExecutionsBusy("missions_busy: too many active or pending Workshop executions")
        }
    }

    /// In-flight submit reservations: queue subdirs holding `.reserved` with
    /// no mission.json yet. Each occupies a slot so concurrent submitters
    /// can't overshoot the cap between admission and the durable write.
    /// Age-out: a reservation older than 10 minutes is a crashed submit
    /// (planning happens BEFORE reservation; only file IO remains) — ignore
    /// it rather than leak the slot forever.
    private nonisolated func liveReservationCount() -> Int {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: executionRecordsRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var count = 0
        for dir in subdirs {
            let marker = dir.appendingPathComponent(".reserved")
            guard fm.fileExists(atPath: marker.path),
                  !fm.fileExists(atPath: dir.appendingPathComponent("mission.json").path) else {
                continue
            }
            let mtime = (try? marker.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if Date().timeIntervalSince(mtime) < 600 { count += 1 }
        }
        return count
    }

    /// Append one Activity event mirroring `Runtime.record_activity`
    ///: the daemon writes
    ///   {id, kind, title, detail, status, missionId, payload, createdAt}
    /// to `activity/events.jsonl` (sorted-keys JSON line). The legacy
    /// create_mission (L5432) and update_mission (L5490) handlers emit these
    /// rows; the QUEUE path the native writer mirrors emits NONE (neither
    /// missions.py nor the queue route call record_activity), so without this
    /// a `.missionsWrites`-ON create/update leaves the Activity feed empty
    /// where the daemon's legacy path would have a row — the regression the
    /// reopen flags.
    ///
    /// FLOCK: the retired daemon's append_jsonl did
    /// not take a file lock for activity. We still wrap our append in
    /// withFileLock(activityPath) to serialize concurrent Swift appends.
    ///
    /// REDACTION: the daemon runs title/detail through `redact_secret_text` and
    /// payload through `redact_secret_value`
    /// before writing. gpt-5.5 review #4 flagged the prior native path's missing
    /// redaction as a real parity/security gap (user-entered mission text could
    /// land an OAuth token / API key verbatim in the Activity feed). This path
    /// now mirrors the retired daemon through the NativeAgentCore-owned
    /// `NativeAgentSecretRedactor`: title/detail use `redactText`, while payload
    /// uses the recursive `redactValue` contract.
    private func recordActivity(
        kind: String,
        title: String,
        detail: String = "",
        status: String,
        executionId: String?,
        payload: JSONValue
    ) async {
        let event: JSONValue = .object([
            "id": .string(uuid()),
            "kind": .string(kind),
            "title": .string(NativeAgentSecretRedactor.redactText(title)),
            "detail": .string(NativeAgentSecretRedactor.redactText(detail)),
            "status": .string(status),
            "missionId": executionId.map { JSONValue.string($0) } ?? .null,
            "payload": NativeAgentSecretRedactor.redactValue(payload),
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        do {
            try? FileManager.default.createDirectory(
                at: activityPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // U5 fix-round (2026-06-11, gpt-5.5 review): routed through the
            // shared capped append (PersistenceCore.appendJSONLCapped) — same
            // flock-when-SwiftNative behavior as before, plus the shared
            // activity-feed line cap with rotation logging.
            try await appendJSONLCapped(
                event, to: activityPath, using: persistence,
                logLabel: "Workshop"
            )
        } catch {
            // An activity-feed write must NEVER unwind the mission write that
            // already landed durably (parity with the daemon, where
            // record_activity is fire-and-forget after the state change).
            Self.logger.info("record_activity append failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: planWorkshopExecution

    public func planWorkshopExecution(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionPlan {
        try Task.checkCancellation()
        let (plan, _) = try await _planWorkshopExecutionWithReason(spec: spec)
        return plan
    }

    /// Same as planMission, but also returns the failure reason (or nil)
    /// when the LLM path falls back to the deterministic stub for any reason
    /// OTHER than the clean autonomy-disabled / autonomy-not-applicable case.
    /// submit() uses this to emit the Python `planner_fallback` timeline
    /// event before `enqueued`.
    func _planWorkshopExecutionWithReason(spec: WorkshopExecutionSpec) async throws -> (WorkshopExecutionPlan, String?) {
        try Task.checkCancellation()
        let stub = Self.stubFallback(spec: spec)

        // Autonomy gate — the retired daemon. Not a "failure";
        // no planner_fallback event is emitted here (Python only emits the
        // event on the codex exception path).
        if !enableAutonomy {
            return (WorkshopExecutionPlan(steps: stub, fromStub: true), nil)
        }

        // Build tools_summary. Always include chat.synthesize.
        let connectorActions = await planner.availableConnectorActions()
        try Task.checkCancellation()
        var availableTools: [(id: String, description: String, autonomy: String)] = []
        for action in connectorActions {
            guard case .object(let obj) = action,
                  case .string(let aid) = obj["id"] ?? .null,
                  !aid.isEmpty else { continue }
            let desc: String = {
                if case .string(let s) = obj["description"] ?? .null { return s }
                return aid
            }()
            let autonomy = DefaultToolAutonomy.resolve(toolId: aid)
            availableTools.append((id: aid, description: desc, autonomy: autonomy))
        }
        if !availableTools.contains(where: { $0.id == "chat.synthesize" }) {
            availableTools.append((
                id: "chat.synthesize",
                description: "Use the AI to synthesize, draft, analyze, or reason over text",
                autonomy: "auto"
            ))
        }
        // Render the FULL tool menu (was prefix(30) — which silently cut
        // builder/shell tools from the planner's view, so "run a shell command"
        // missions picked the wrong tool and failed; 2026-06-15, the user: missions
        // do everything). Cap high (200) only as a prompt-size backstop.
        let toolsSummary = availableTools.prefix(200).map { t in
            "  - \(t.id): \(t.description) [autonomy=\(t.autonomy)]"
        }.joined(separator: "\n")

        // Current date/time for the plan. The planner had NO clock, so a
        // "morning brief"-style objective couldn't know today's date and baked a
        // literal "<today's date>" placeholder into a write step (2026-06-15,
        // found live). Inject it (local timezone — "today" is the user's today)
        // so date-stamped content is correct AT PLAN TIME, no time_now step or
        // placeholder needed.
        // Use the injected clock (now()) — deterministic under test/golden-eval,
        // not a raw Date(). BOTH renderings use the LOCAL timezone (no UTC ISO
        // timestamp): a UTC stamp beside a local human date disagree by a day
        // near local midnight, confusing the planner (gpt-5.5 review,
        // 2026-06-15).
        let nowDate = now()
        let humanDateFmt = DateFormatter()
        humanDateFmt.locale = Locale(identifier: "en_US_POSIX")
        humanDateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        let humanDate = humanDateFmt.string(from: nowDate)
        let isoDateFmt = DateFormatter()
        isoDateFmt.locale = Locale(identifier: "en_US_POSIX")
        isoDateFmt.dateFormat = "yyyy-MM-dd"
        let isoDate = isoDateFmt.string(from: nowDate)

        // Prompt — diverged from the retired daemon (date + step-output
        // threading rules added 2026-06-15; daemon is dead, no parity to keep).
        let prompt = """
            You are a Workshop planner for an AI assistant. Given a task objective and available tools, produce a JSON execution plan with 1–8 steps.

            Current date: \(humanDate) (\(isoDate))

            Workshop task title: \(spec.title)
            Workshop task objective: \(spec.objective)

            Available tools:
            \(toolsSummary)

            Rules:
            - Each step's tool_or_action must be one of the available tool IDs above, OR chat.synthesize.
            - autonomy_hint must be one of: auto, needs_approval
            - Maximum 8 steps. Prefer fewer, focused steps.
            - args should be a flat JSON object with string values.
            - args must be FINAL literal values, never placeholders. Do NOT write things like "<today's date>", "<result>", or "<the summary>". For the date, use the Current date/time above directly in the arg.
            - If a step's arg must contain the OUTPUT of an EARLIER step (e.g. write a file whose body is what a prior step produced), put the token {{step:<that earlier step's id>}} in the arg — it is replaced at run time with that step's actual output. This works in tool args only; chat.synthesize steps automatically see all prior step outputs, so to turn raw data into prose first add a chat.synthesize step, then reference ITS id with {{step:<id>}} in the write step.

            Return ONLY valid JSON, no commentary, no markdown fences:
            {"steps": [{"id": "step-1", "description": "...", "tool_or_action": "...", "args": {}, "autonomy_hint": "auto"}]}
            """

        // Call codex.
        let rawOutput: String
        do {
            (_, rawOutput) = try await planner.runCodex(prompt: prompt, surface: "missions", timeoutSeconds: 60)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (WorkshopExecutionPlan(steps: stub, fromStub: true), String(describing: error))
        }
        try Task.checkCancellation()

        // Strip markdown fences.
        let raw = Self.stripMarkdownFences(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse + validate.
        do {
            let steps = try Self.parsePlanJSON(raw, validTools: Set(availableTools.map(\.id)))
            if steps.isEmpty {
                return (WorkshopExecutionPlan(steps: stub, fromStub: true), "codex returned 0 valid steps")
            }
            return (WorkshopExecutionPlan(steps: steps, fromStub: false), nil)
        } catch {
            return (WorkshopExecutionPlan(steps: stub, fromStub: true), String(describing: error))
        }
    }

    // MARK: submit

    public func submit(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionEnqueueResult {
        try Task.checkCancellation()

        // EXECUTOR GATE (2026-06-10, overnight-audit Tier-1 disposition;
        // default flipped to TRUE the same day when the executor port
        // landed): WorkshopExecutorLoop (WorkshopExecution+Executor.swift, registered
        // via BackgroundLoopsAssembly) now transitions queued→running, so a
        // default-constructed runner accepts submits. The gate stays for
        // callers that explicitly construct with `executorAvailable: false`
        // (no executor loop registered) — accepting a submit there would
        // queue a mission that can never run while burning a planner LLM
        // call, the "fabricated success" shape the audit closed everywhere
        // else.
        guard executorAvailable else {
            throw WorkshopExecutionError.executorUnavailable(
                "Workshop executor unavailable; submission is disabled"
            )
        }

        // WAVE 41 W01 (a) missionPolicy gate — FIRST, matching the daemon's
        // POST /v1/missions route ORDER: the route checks `_missions_allowed()`
        // BEFORE the empty-objective validation
        // (L53003) and refuses with HTTP 403 + the exact detail below. gpt-5.5
        // review #1: gating AFTER the objective check diverged — a policy-off
        // request with an empty objective would return `missing_objective` (400)
        // where the daemon returns `forbidden` (403). Default-safe: a fresh root
        // with no saved policy is ALLOWED (default_trust_policy enabled=true).
        guard await workshopExecutionsAllowed() else {
            throw WorkshopExecutionError.forbidden("Workshop execution is disabled by trust policy")
        }

        // Validation mirror — the route's empty-objective check
        //, which runs AFTER the policy gate and
        // mirrors MissionRunner.submit's own check.
        let trimmed = spec.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("missing_objective")
        }

        // WAVE 41 W01 (b) slots gate — mirror the `_mission_slots.acquire`
        // capacity guard at the TOP of MissionRunner.submit,
        // which the runner checks AFTER its objective validation (L728) and
        // BEFORE planning + file IO. Refuse a new submit when the queue is
        // already at (max_active + max_pending) active missions.
        try await assertSlotAvailable()

        // Build the Workshop execution record.
        let id = uuid()
        let titleTrunc = String(spec.title.prefix(160))
        let objectiveTrunc = String(spec.objective.prefix(2000))
        let nowStr = Self.isoTimestamp(now())

        // Plan it (stub or real). Capture the planner failure reason so we
        // can emit Python's `planner_fallback` timeline event before
        // `enqueued` when the LLM path bailed to the stub.
        let (plan, plannerFailureReason) = try await _planWorkshopExecutionWithReason(
            spec: WorkshopExecutionSpec(
                title: titleTrunc,
                objective: objectiveTrunc,
                triggerSource: spec.triggerSource,
                trustRequired: spec.trustRequired,
                deskHandle: spec.deskHandle
            )
        )
        let exactPlanningProviderCallCount: Int? = enableAutonomy
            ? planner.directProviderCallCountPerInvocation
            : 0

        // Check cancellation AFTER planning, BEFORE file IO. Without this gate
        // a cancel that lands between the planner returning and the directory
        // create would still write mission.json and fire the detached
        // auto-start — silent landing of a cancelled Workshop execution.
        try Task.checkCancellation()

        // W-I review fix (gpt-5.5, 2026-06-11): RE-assert the slot cap under
        // the queue ADMISSION flock immediately before enqueue. The early
        // assertSlotAvailable() is a fast-fail courtesy only — with multiple
        // runner instances (chat tool + executor assembly each construct
        // their own), concurrent submits could all pass the unlocked count
        // and overshoot the cap. Planning happens OUTSIDE the lock (LLM
        // latency must not serialize the queue); only count+create is
        // critical. The executor's claim path takes its own flock — this
        // lock is admission-only.
        // Uniform locking (L7, 2026-08-01): admission used to run ONLY when
        // `persistence` downcast to SwiftNativePersistenceCore — every other
        // conformer skipped the slot-cap re-check and the counted reservation
        // outright, so the cap was silently unenforced. `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4),
        // so the downcast was gratuitous; admission now always runs, locked.
        let admissionLock = executionRecordsRoot.appendingPathComponent(".admission")
        try await persistence.withFileLock(admissionLock) { [self] in
            try await assertSlotAvailable()
            // COUNTED reservation (delta review: an empty dir is invisible
            // to the slot count, so racers serializing through this lock
            // each saw the same count). `.reserved` occupies a slot until
            // mission.json lands; removed on success, dir deleted on
            // failure, age-out guards a crash between the two.
            try FileManager.default.createDirectory(
                at: workshopExecutionDir(id), withIntermediateDirectories: true)
            try Data("reserved \(nowStr)".utf8)
                .write(to: workshopExecutionDir(id).appendingPathComponent(".reserved"))
        }

        // Ensure mission dir + receipts/ exist (daemon does this in
        // TaskQueue.enqueue at L350-L352). receipts_dir is the absolute
        // path string the Python side writes.
        let dir = workshopExecutionDir(id)
        let receipts = receiptsDir(id)
        let timeline = timelinePath(id)
        let executionRecordJSON = executionRecordPath(id)
        // Delta review: ONE cleanup scope for every throw between the counted
        // reservation and the durable mission.json write (receipts create,
        // both timeline appends, cancellation, mission.json itself) — any
        // failure frees the reservation by deleting the dir, instead of
        // falsely occupying a slot until the 600s age-out.
        func freeReservationAndRethrow(_ error: Error) throws -> Never {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let record = WorkshopExecutionRecord(
            id: id,
            deskHandle: spec.deskHandle,
            title: titleTrunc,
            objective: objectiveTrunc,
            createdAt: nowStr,
            status: "queued",
            plan: plan.steps,
            stepsCompleted: [],
            receiptsDir: receipts.path,
            triggerSource: spec.triggerSource,
            trustRequired: spec.trustRequired,
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: nowStr,
            result: .null,
            rerunCount: 0,
            planningProviderCallCount: exactPlanningProviderCallCount,
            planningRemovableOrchestrationProviderCallCount: exactPlanningProviderCallCount
        )
        do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)


        // ORDER MATTERS — wave-12 gpt-5.5 finding #4.
        // Write timeline.jsonl FIRST so a crash between the two writes leaves
        // a mission with no mission.json (cleanly absent, scanner skips it)
        // rather than a mission.json with no enqueued event in the timeline
        // (poisoned audit trail). The Python side writes mission.json first
        // (L353-L359), which has the inverse failure mode; wave 21 fixes
        // both sides.
        // Mirror Python's planner_fallback event:
        // emitted BEFORE the enqueued event when the codex path bailed.
        //
        // Each timeline append is wrapped in withFileLock(timeline).
        // timeline.jsonl can be appended concurrently by Swift mission
        // planning/execution paths and the trigger scheduler;
        // O_APPEND alone does not keep a record contiguous across the
        // appendBytes short-write loop, so an unlocked concurrent append can
        // tear the JSON line. Each append takes the lock independently,
        // preserving the wave-12 ordering (planner_fallback BEFORE enqueued)
        // and the cancel checkpoints between them.
        //
        // WAVE 35 W10 (CUTOVER §6.117): the wave-34 W03/W07 merge had left BOTH
        // the W03 inline `appendTimeline(_:)` closure AND the W07
        // appendTimelineLocked() call live for each event, double-writing every
        // planner_fallback + enqueued line to timeline.jsonl. appendTimelineLocked
        // is the canonical single append; the redundant W03 closure is removed.
        if let reason = plannerFailureReason {
            let fallbackEvent: JSONValue = .object([
                "event": .string("planner_fallback"),
                "reason": .string(reason),
                "ts": .string(nowStr),
            ])
            do {
                // WAVE 34 W07 (§6.96 round-2 #3): cross-process flock on
                // timeline.jsonl — see appendTimelineLocked + the Python
                // file_lock(_append_jsonl) symmetry.
                try await appendTimelineLocked(fallbackEvent, to: timeline)
            } catch {
                throw WorkshopExecutionError.persistenceFailure("timeline append failed: \(error)")
            }
            try Task.checkCancellation() // cancel between planner_fallback append and enqueued append should NOT continue
        }
        let timelineEvent: JSONValue = .object([
            "event": .string("enqueued"),
            "title": .string(titleTrunc),
            "trigger_source": .string(spec.triggerSource),
            "ts": .string(nowStr),
        ])
        do {
            // WAVE 34 W07 (§6.96 round-2 #3): cross-process flock on
            // timeline.jsonl — see appendTimelineLocked.
            try await appendTimelineLocked(timelineEvent, to: timeline)
        } catch {
            throw WorkshopExecutionError.persistenceFailure("timeline append failed: \(error)")
        }
        // cancel between timeline append and mission.json write should NOT
        // land mission.json — and must free the admission reservation.
        if Task.isCancelled { throw CancellationError() }

        // Then mission.json under the cross-process flock so the daemon
        // can't tear our write. The Python side already wraps _write_json
        // in file_lock per wave-4 + wave-21 daemon symmetry.
        let work: @Sendable () async throws -> Void = { [persistence, record, executionRecordJSON] in
            try await persistence.writeJSON(record.toJSON(), to: executionRecordJSON)
        }
        do {
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(executionRecordJSON, work)
        } catch {
            throw WorkshopExecutionError.persistenceFailure("mission.json write failed: \(error)")
        }
        // Reservation fulfilled — mission.json is the counted artifact now.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".reserved"))
        } catch {
            try freeReservationAndRethrow(error)
        }

        // WAVE 41 W01 (c) Activity row — mirror the daemon legacy create_mission's
        // record_activity:
        //   record_activity("mission", "Workshop task created", title, "ok",
        //                   mission["id"], {"missionId": mission["id"]})
        // emitted right after the durable write (the daemon records once the
        // mission is persisted, with NO cancellation point between).
        //
        // gpt-5.5 review #5: this MUST sit BEFORE the post-write
        // checkCancellation() below. A landed mission.json write is durable; if a
        // cancel were checked first, the mission would exist on disk with NO
        // Activity row — the exact gap the reopen flags. Emitting here guarantees
        // every durably-created mission gets its row. recordActivity is
        // non-fatal (logs on IO failure) so it never unwinds the landed write.
        await recordActivity(
            kind: "mission",
            title: "Workshop task created",
            detail: titleTrunc,
            status: "ok",
            executionId: id,
            payload: .object(["missionId": .string(id)])
        )

        try Task.checkCancellation() // cancel after the write+activity should NOT fire the detached auto-start

        // Daemon retired (fac-F1): no fire-and-forget auto-start. The mission
        // lands durably on disk in `queued`; WorkshopExecutorLoop's next drain
        // pass (BackgroundLoops-registered, gated on enableAutonomy +
        // missionPolicy) claims and runs it.
        return WorkshopExecutionEnqueueResult(status: "queued", executionId: id, record: record)
    }

    // MARK: start

    public func start(executionId: String) async throws -> WorkshopExecutionStartResult {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("empty missionId")
        }
        // Execution lives on WorkshopExecutorLoop (WorkshopExecution+Executor.swift),
        // which carries the injected LLM/tool/approval closures this runner
        // deliberately doesn't hold (module stays dependency-clean). Callers
        // that want an explicit start should call
        // WorkshopExecutorLoop.start(missionId:); the background loop drains
        // queued missions on its own. This protocol stub keeps surfacing a
        // typed error rather than silently no-op (W6).
        throw WorkshopExecutionError.unavailable
    }

    // MARK: cancel (WAVE 33 W07 — mission-lifecycle WRITE)
    //
    // Port of MissionRunner.cancel. The WHOLE
    // read-mutate-write runs inside one withFileLock(mission.json) critical
    // section. This is intentionally STRONGER than the Python side: Python's
    // TaskQueue.get reads mission.json OUTSIDE file_lock (only the subsequent
    // _write_json is locked), so the daemon executor could in principle mutate
    // the file between Python's read and write. With `.missions` ON in
    // production the Swift daemon-bridge and the Python executor BOTH touch
    // this file, so we hold the cross-process flock across the full
    // read→mutate→write to make the cancel atomic against the executor and
    // against a concurrent updateMission(). The flock is the SAME advisory
    // lock the Python file_lock(path) uses (the retired daemon <->
    // PersistenceCore+FileLock.swift), so mutual exclusion holds across both
    // processes.
    public func cancel(executionId: String) async throws -> WorkshopExecutionRecord {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("empty missionId")
        }
        let executionRecordJSON = executionRecordPath(trimmed)
        let timeline = timelinePath(trimmed)
        let nowStr = Self.isoTimestamp(now())

        // Mutate-under-flock. Returns the post-cancel record AND whether a
        // timeline event needs appending (skip the append on the idempotent
        // already-cancelled no-op, matching Python's early `return mission`).
        let work: @Sendable () async throws -> (record: WorkshopExecutionRecord, didCancel: Bool) = { [persistence] in
            let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                // Mirror Python's `if mission is None: raise ValueError(...)`.
                throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)")
            }
            var record = SwiftNativeWorkshopRunner.recordFromJSON(obj)
            // Idempotency: already-cancelled → silent
            // no-op, return the unchanged record, NO new timeline event.
            if record.status == "cancelled" {
                return (record, false)
            }
            record.status = "cancelled"
            // TaskQueue.save_mission bumps updated_at — match.
            record.updatedAt = nowStr
            try await persistence.writeJSON(record.toJSON(), to: executionRecordJSON)
            return (record, true)
        }

        let (record, didCancel): (WorkshopExecutionRecord, Bool)
        do {
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            (record, didCancel) = try await persistence.withFileLock(executionRecordJSON, work)
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("cancel mission.json write failed: \(error)")
        }

        // Append the `cancelled` timeline event AFTER the mission.json write
        // (Python order: save_mission then append_timeline, L1569-L1570). Only
        // on a real transition — never on the idempotent no-op.
        //
        // The append takes withFileLock(timeline) — its OWN lock, NOT the
        // mission.json lock (already released above). WAVE 34 W03 correction:
        // the daemon's TaskQueue.append_timeline -> _append_jsonl now wraps the
        // write in file_lock(timeline); the prior comment here
        // mis-cited the retired daemon (that is _write_json's lock — _append_jsonl
        // historically took NONE). Holding the mission.json lock across the
        // timeline write would buy nothing and widen the window, but the
        // timeline DOES need its own cross-process lock so the appendBytes
        // short-write loop can't tear a concurrent daemon/scheduler append.
        // WAVE 34 W07 (CUTOVER §6.96 round-2 #3): the append now runs inside
        // withFileLock(timeline) — its OWN lock on timeline.jsonl, NOT the
        // mission.json lock. The mission.json withFileLock BODY (the `work`
        // closure) has fully completed by here; its unlock is scheduled in a
        // detached Task (PersistenceCore+FileLock.swift defer), so the actual
        // flock release may lag a beat — but that is a DIFFERENT path's lock, so
        // there is no deadlock and no lock-ordering hazard with the timeline
        // lock acquired below. The Python side now wraps _append_jsonl in
        // file_lock(path), taking the SAME advisory lock on
        // `<timeline>.lock`. Without this, a `.missions`-ON Swift cancel and a
        // concurrent Python executor timeline append (e.g. a `failed`/`step`
        // event mid-cancel) could interleave into a torn JSONL line and break
        // the strict reader. timeline.jsonl's lock is distinct from
        // mission.json's lock, so there is no nesting/contention with the
        // read-mutate-write critical section that just completed.
        if didCancel {
            let event: JSONValue = .object([
                "event": .string("cancelled"),
                "ts": .string(nowStr),
            ])
            do {
                // WAVE 35 W10 (CUTOVER §6.117): single flock-wrapped append via
                // the shared appendTimelineLocked helper. The wave-34 W03/W07
                // merge had left BOTH the W03 inline withFileLock(timeline) block
                // AND the W07 appendTimelineLocked call live here, double-writing
                // the `cancelled` event to timeline.jsonl. appendTimelineLocked is
                // the canonical single-source-of-truth append (same `<timeline>.lock`
                // flock, identical to the daemon's _append_jsonl→file_lock).
                try await appendTimelineLocked(event, to: timeline)
            } catch {
                // The durable state transition already landed; a failed
                // timeline append must not unwind the cancel. Log + proceed.
                Self.logger.info("cancel timeline append failed: \(String(describing: error), privacy: .public)")
            }
        }
        // NOTE: _purge_mission_scratchpad + _notify_mission are not part of this
        // Swift cancel yet (see protocol doc).
        return record
    }

    // MARK: updateMission (WAVE 33 W07 — queue-bridge field patch)
    //
    // Port of the `_missions_allowed()` queue-bridge branch of
    // Runtime.update_mission. Applies the
    // field patches to the queue mission's mission.json under flock and
    // returns the post-patch record. Returns nil when the id is NOT a queue
    // mission. Historical missions.jsonl rows are a different file shape and
    // are not handled by this queue bridge. Whole read-mutate-write held under
    // the flock, same rationale as cancel().
    public func updateWorkshopExecution(_ patch: WorkshopExecutionUpdate) async throws -> WorkshopExecutionRecord? {
        let id = patch.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            // Empty id never matches a queue mission; return nil so callers
            // surface Unknown/unsupported through the Swift path.
            return nil
        }
        // WAVE 41 W01 (a) missionPolicy gate: when missionPolicy is off, skip
        // the queue bridge so the native writer never runs against a disabled
        // policy. Default-safe (fresh root -> allowed).
        guard await workshopExecutionsAllowed() else {
            return nil
        }
        let executionRecordJSON = executionRecordPath(id)
        let nowStr = Self.isoTimestamp(now())

        // Terminal statuses that clear current_step_id.
        // NOTE: Python's queue-bridge terminal set INCLUDES "canceled" AND
        // "cancelled" (L5393) — broader than the legacy-path set at L5415.
        let terminalStatuses: Set<String> = [
            "done", "completed", "succeeded", "canceled", "cancelled", "failed",
        ]

        // The work closure returns (record?, changed) so the caller can emit the
        // Activity row only when a real patch landed (matching the daemon's
        // `if changed:` save gate). nil record == not a queue mission.
        let work: @Sendable () async throws -> (record: WorkshopExecutionRecord, changed: Bool)? = { [persistence] in
            let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                // Not a queue mission → nil, daemon falls through to legacy.
                return nil
            }
            var record = SwiftNativeWorkshopRunner.recordFromJSON(obj)
            var changed = false
            // Presence-gated patches, mirroring L5385-L5398. Empty title/objective
            // falls back to the existing value (Python `str(... or qm.title)`).
            if let t = patch.title {
                record.title = String((t.isEmpty ? record.title : t).prefix(160))
                changed = true
            }
            if let o = patch.objective {
                record.objective = String((o.isEmpty ? record.objective : o).prefix(2000))
                changed = true
            }
            if let s = patch.status {
                // Python `str(body.get("status") or qm.status)` — empty falls
                // back to existing.
                record.status = s.isEmpty ? record.status : s
                if terminalStatuses.contains(record.status) {
                    record.currentStepId = ""
                }
                changed = true
            }
            if let r = patch.result {
                // Python: `str(body.get("summary") or body.get("result") or qm.result or "")`.
                // The body contribution (`r`) already had `summary or result`
                // resolved with retired truthiness in fromBody. Here we apply the
                // remaining `... or qm.result or ""` falsy-fallback chain:
                //   - non-empty body result  → use it verbatim.
                //   - empty body result + TRUTHY existing result → KEEP existing
                //     (gpt-5.5 finding #2: do NOT clobber an existing
                //     .object/.array/non-empty-.string result to ""). The Python
                //     `qm.result` here is the queue dataclass's `str|None`, but
                //     the reads port widened `record.result` to JSONValue, so we
                //     preserve any truthy value rather than lossily str()-ing it.
                //   - empty body result + falsy existing result → "".
                if !r.isEmpty {
                    record.result = .string(r)
                } else if WorkshopExecutionUpdate.pyTruthy(record.result) {
                    // keep existing truthy result unchanged
                } else {
                    record.result = .string("")
                }
                changed = true
            }
            // Only persist + bump updated_at when something actually changed
            // (Python: `if changed ... qm.updated_at = now_iso(); save_mission`).
            if changed {
                record.updatedAt = nowStr
                try await persistence.writeJSON(record.toJSON(), to: executionRecordJSON)
            }
            return (record, changed)
        }

        let outcome: (record: WorkshopExecutionRecord, changed: Bool)?
        do {
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            outcome = try await persistence.withFileLock(executionRecordJSON, work)
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("updateMission mission.json write failed: \(error)")
        }

        // Not a queue mission → nil; daemon falls through to its legacy path.
        guard let outcome else { return nil }

        // WAVE 41 W01 (c) Activity row — mirror the daemon legacy update_mission's
        // record_activity:
        //   record_activity("mission", "Workshop task updated", title,
        //                   "ok" if status not in {failed, blocked} else "warn",
        //                   mission_id, {"status": ..., "phase": ...})
        // Emit ONLY when a real change landed (the daemon writes — and so emits —
        // only inside `if changed`). The queue Mission has no `phase` field
        // (documented §6.220), so payload.phase mirrors that as null, exactly
        // like the daemon's queue-bridge would if it recorded.
        //
        // DELIBERATE DAEMON-QUEUE-PATH DIVERGENCE (documented §6.240): the daemon's
        // queue-bridge update branch (L5448-L5468) returns BEFORE record_activity —
        // only its LEGACY path (L5490) emits the row. This native bridge emits the
        // SAME-shape row so the Mac Activity feed shows queue-mission updates the
        // legacy path would show; a daemon queue-bridge update emits none. This is
        // the intent of the reopen ("native writes emit no record_activity rows")
        // and is gated behind default-OFF .missionsWrites.
        if outcome.changed {
            let status = outcome.record.status
            await recordActivity(
                kind: "mission",
                title: "Workshop task updated",
                detail: outcome.record.title.isEmpty ? id : outcome.record.title,
                status: (status == "failed" || status == "blocked") ? "warn" : "ok",
                executionId: id,
                payload: .object(["status": .string(status), "phase": .null])
            )
        }
        return outcome.record
    }

    // MARK: appendTimelineLocked (WAVE 34 W07 — cross-process timeline flock)
    //
    // Appends one event to <id>/timeline.jsonl while holding the advisory flock
    // for that timeline file.
    //
    // WHY: a Swift submit()/cancel() and Workshop execution can both append to
    // the SAME timeline.jsonl
    // concurrently. O_APPEND moves to EOF atomically per write(), but a single
    // logical JSONL row can span MULTIPLE underlying write()s. Holding the
    // shared `<timeline>.lock` serializes the whole append.
    //
    // The lock is on timeline.jsonl's OWN `.lock` sibling — distinct from
    // mission.json's lock — so it never nests inside or contends with the
    // read-mutate-write critical section that submit()/cancel()/updateMission()
    // hold on mission.json. Uniform locking (2026-08-01): EVERY persistence
    // conformer takes this lock — mock persistence included — pinned by
    // UniformFileLockTests; do not restore an unlocked mock path.
    private func appendTimelineLocked(_ event: JSONValue, to timeline: URL) async throws {
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        let core = persistence
        try await core.withFileLock(timeline) {
            try await core.appendJSONL(event, to: timeline)
        }
    }

    // MARK: reads (WAVE 32 W07 — mission listing / detail / timeline)
    //
    // Read-side port of the daemon's GET /v1/missions, GET /v1/missions/<id>,
    // and GET /v1/missions/<id>/timeline handlers (the retired daemon
    // L51353-L51437) plus their TaskQueue backers.
    // All three are PURE file reads against the same on-disk layout the
    // SwiftNative submit() already writes:
    //     <root>/workshop/executions/<id>/mission.json
    //     <root>/workshop/executions/<id>/timeline.jsonl
    // The compatibility record shape is preserved under Workshop ownership.
    // Reads remain lock-free, matching the prior behavior.

    /// Path to the LEGACY flat mission store (the retired daemon:
    /// `self.missions_path = root / "missions" / "missions.json"`). This is a
    /// SEPARATE store from the queue dir — a flat JSON list of camelCase
    /// mission dicts created by `create_mission`. GET /v1/missions MERGES
    /// queue + legacy (L51363-L51365: `new_missions + old_missions`), so the
    /// SwiftNative list-read must read BOTH or it silently drops every legacy
    /// mission.
    public nonisolated var legacyWorkshopExecutionsPath: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("legacy_executions.json")
    }

    /// `TaskQueue.get`. Reads
    /// <queue>/<id>/mission.json, returns nil when absent or malformed.
    public func getWorkshopExecution(_ executionId: String) async -> WorkshopExecutionRecord? {
        let raw = await persistence.readJSON(executionRecordPath(executionId), defaultValue: .null)
        guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
            return nil
        }
        return Self.recordFromJSON(obj)
    }

    /// Byte-faithful single-mission read for the GET /v1/missions/<id> seam
    ///. Returns the asdict-equivalent object
    /// WITHOUT the `timeline` key (the caller attaches it); nil when absent.
    /// gpt-5.5 finding #1: use this (not getMission(...)?.toJSON()) so `plan`
    /// is emitted verbatim.
    public func getWorkshopExecutionWireJSON(_ executionId: String) async -> JSONValue? {
        let raw = await persistence.readJSON(executionRecordPath(executionId), defaultValue: .null)
        guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
            return nil
        }
        return Self.readJSONForWorkshopExecution(obj)
    }

    /// `TaskQueue.read_timeline`. Returns the raw event
    /// dicts in file order; missing file -> []; malformed lines skipped. The
    /// `readJSONL` impl matches Python's semantics exactly.
    public func readTimeline(_ executionId: String) async throws -> [JSONValue] {
        try await persistence.readJSONL(timelinePath(executionId))
    }

    /// `TaskQueue._scan_all`: every <queue>/<id>/
    /// subdir with a parseable mission.json carrying a non-empty `id`.
    /// Malformed / id-less mission.json entries are skipped (Python's broad
    /// `except` at L428).
    private func scanAllQueueWorkshopExecutions() async -> [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] {
        let fm = FileManager.default
        let queueRoot = executionRecordsRoot
        guard let entries = try? fm.contentsOfDirectory(
            at: queueRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            return []  // execution root absent -> no Workshop executions
        }
        var out: [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] = []
        for sub in entries {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let mp = sub.appendingPathComponent("mission.json")
            let raw = await persistence.readJSON(mp, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                continue
            }
            out.append((Self.recordFromJSON(obj), obj))
        }
        return out
    }

    /// `TaskQueue.list_all`: all queue Workshop executions sorted
    /// by created_at DESC.
    public func listAll() async -> [WorkshopExecutionRecord] {
        await scanAllQueueWorkshopExecutions().sorted { $0.record.createdAt > $1.record.createdAt }.map(\.record)
    }

    /// `TaskQueue.list_active`: queued / running /
    /// blocked_on_approval. Python does NOT re-sort list_active (returns
    /// _scan_all order); we preserve _scan_all (directory) order to match —
    /// the `active=true` query branch of GET /v1/missions.
    public func listActive() async -> [WorkshopExecutionRecord] {
        let live: Set<String> = ["queued", "running", "blocked_on_approval"]
        return await scanAllQueueWorkshopExecutions().filter { live.contains($0.record.status) }.map(\.record)
    }

    /// `TaskQueue.list_history`: terminal missions,
    /// sorted by updated_at DESC, capped at 20 — the `active=false` query
    /// branch of GET /v1/missions.
    public func listHistory() async -> [WorkshopExecutionRecord] {
        let done: Set<String> = ["completed", "failed", "cancelled"]
        let filtered = await scanAllQueueWorkshopExecutions().filter { done.contains($0.record.status) }
        return Array(filtered.sorted { $0.record.updatedAt > $1.record.updatedAt }.prefix(20).map(\.record))
    }

    /// Legacy flat store: the
    /// raw camelCase dict list, sorted by updatedAt|createdAt DESC. Returned as
    /// opaque JSONValue dicts (NOT WorkshopExecutionRecord — the legacy schema has
    /// `phase`/`priority`/`receiptCount` and camelCase keys the queue record
    /// type doesn't model). The Mac decode models accept either casing, so
    /// passing these through verbatim is byte-faithful.
    public func listLegacyWorkshopExecutions() async -> [JSONValue] {
        let raw = await persistence.readJSON(legacyWorkshopExecutionsPath, defaultValue: .array([]))
        guard case .array(let items) = raw else { return [] }
        let dicts = items.compactMap { item -> [String: JSONValue]? in
            if case .object(let o) = item { return o }
            return nil
        }
        // Sort key mirrors L5329: updatedAt or createdAt, missing -> "".
        let sortKey: ([String: JSONValue]) -> String = { o in
            if case .string(let u)? = o["updatedAt"], !u.isEmpty { return u }
            if case .string(let c)? = o["createdAt"] { return c }
            return ""
        }
        return dicts.sorted { sortKey($0) > sortKey($1) }.map { .object($0) }
    }

    /// Merged GET /v1/missions list (default branch, no `active` param —
    /// the retired daemon): queue `list_all()` records FIRST, then
    /// the legacy flat list, preserving the daemon's `new_missions +
    /// old_missions` order. Returns a JSONValue array so the NativeClient seam
    /// can decode it into whichever Mac model the caller asked for.
    public func listWorkshopExecutionsMerged() async -> [JSONValue] {
        // Queue first (created_at DESC), faithful asdict bytes; then legacy
        // verbatim. Matches the retired daemon `new_missions +
        // old_missions`. gpt-5.5 finding #1: emit via readJSONForMission so the
        // raw `plan` survives instead of being normalized by WorkshopExecutionRecord.
        let queue = await scanAllQueueWorkshopExecutions()
            .sorted { $0.record.createdAt > $1.record.createdAt }
            .map { Self.readJSONForWorkshopExecution($0.raw) }
        let legacy = await listLegacyWorkshopExecutions()
        return queue + legacy
    }

    /// Build a WorkshopExecutionRecord from a persisted mission.json object, mirroring
    /// Byte-faithful read serialization mirroring the daemon's HTTP wire output
    /// for a single mission: `asdict(TaskQueue._from_dict(data))` (missions.py
    /// L432-L450 + dataclasses.asdict). gpt-5.5 review (wave 32 W07) finding #1:
    /// Python preserves `plan` / `steps_completed` / `expected_outputs` /
    /// `result` VERBATIM (`list(data.get(k) or [])` — raw dicts unchanged) and
    /// only `str()`-coerces the scalar string fields. Round-tripping `plan`
    /// through `WorkshopExecutionRecord`/`WorkshopExecutionStep` would NORMALIZE it (default a
    /// missing tool_or_action, drop unknown keys), altering the wire bytes vs
    /// the daemon. So the wire paths (listMissionsMerged, getMissionDetail) use
    /// THIS, not `recordFromJSON(...).toJSON()`. Defaults match _from_dict:
    /// status->"queued", trigger_source->"manual", trust_required->"none",
    /// rerun_count->0 (graceful coerce; the daemon never writes a non-int).
    static func readJSONForWorkshopExecution(_ obj: [String: JSONValue]) -> JSONValue {
        func s(_ key: String, _ dflt: String) -> String {
            if case .string(let v)? = obj[key] { return v }
            return dflt
        }
        // Verbatim list passthrough (Python `list(... or [])`): preserve the raw
        // array (and its inner dicts) exactly; non-array / missing -> [].
        func rawArr(_ key: String) -> JSONValue {
            if case .array(let v)? = obj[key] { return .array(v) }
            return .array([])
        }
        func rerun() -> JSONValue {
            switch obj["rerun_count"] ?? .null {
            case .int(let n): return .int(n)
            case .double(let d): return .int(Int64(d))
            case .string(let str): return .int(Int64(Int(str) ?? 0))
            default: return .int(0)
            }
        }
        var normalized: [String: JSONValue] = [
            "id": .string(s("id", "")),
            "title": .string(s("title", "")),
            "objective": .string(s("objective", "")),
            "created_at": .string(s("created_at", "")),
            "status": .string(s("status", "queued")),
            "plan": rawArr("plan"),
            "steps_completed": rawArr("steps_completed"),
            "receipts_dir": .string(s("receipts_dir", "")),
            "trigger_source": .string(s("trigger_source", "manual")),
            "trust_required": .string(s("trust_required", "none")),
            "expected_outputs": rawArr("expected_outputs"),
            "current_step_id": .string(s("current_step_id", "")),
            "updated_at": .string(s("updated_at", "")),
            "result": obj["result"] ?? .null,
            "rerun_count": rerun(),
        ]
        if let deskHandle = obj["desk_handle"], case .string = deskHandle {
            normalized["desk_handle"] = deskHandle
        }
        if let verification = obj["verification"], case .object = verification {
            normalized["verification"] = verification
        }
        for key in [
            "planning_provider_call_count",
            "planning_removable_orchestration_provider_call_count",
        ] {
            if let value = obj[key], case .int = value {
                normalized[key] = value
            }
        }
        return .object(normalized)
    }

    /// `TaskQueue._from_dict` field-for-field
    /// (defaults included) so a partial / older-schema mission.json decodes the
    /// same way Python would.
    static func recordFromJSON(_ obj: [String: JSONValue]) -> WorkshopExecutionRecord {
        func s(_ key: String, _ dflt: String) -> String {
            if case .string(let v)? = obj[key] { return v }
            return dflt
        }
        func arr(_ key: String) -> [JSONValue] {
            if case .array(let v)? = obj[key] { return v }
            return []
        }
        func i(_ key: String) -> Int {
            switch obj[key] ?? .null {
            case .int(let n): return Int(n)
            case .double(let d): return Int(d)
            case .string(let str): return Int(str) ?? 0
            default: return 0
            }
        }
        func optionalInt(_ key: String) -> Int? {
            guard obj[key] != nil else { return nil }
            return i(key)
        }
        return WorkshopExecutionRecord(
            id: s("id", ""),
            deskHandle: {
                let value = s("desk_handle", "").trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }(),
            title: s("title", ""),
            objective: s("objective", ""),
            createdAt: s("created_at", ""),
            status: s("status", "queued"),
            plan: parsePlanSteps(obj["plan"]),
            stepsCompleted: arr("steps_completed"),
            receiptsDir: s("receipts_dir", ""),
            triggerSource: s("trigger_source", "manual"),
            trustRequired: s("trust_required", "none"),
            expectedOutputs: arr("expected_outputs"),
            currentStepId: s("current_step_id", ""),
            updatedAt: s("updated_at", ""),
            result: obj["result"] ?? .null,
            rerunCount: i("rerun_count"),
            planningProviderCallCount: optionalInt("planning_provider_call_count"),
            planningRemovableOrchestrationProviderCallCount:
                optionalInt("planning_removable_orchestration_provider_call_count"),
            verification: WorkshopVerificationRecord.fromJSON(obj["verification"])
        )
    }

    /// Plan-array parser for persisted mission.json `plan` fields.
    static func parsePlanSteps(_ v: JSONValue?) -> [WorkshopExecutionStep] {
        guard let v, case .array(let arr) = v else { return [] }
        var out: [WorkshopExecutionStep] = []
        for item in arr {
            guard case .object(let o) = item else { continue }
            let id: String = { if case .string(let s) = o["id"] ?? .null { return s }; return "" }()
            let desc: String = { if case .string(let s) = o["description"] ?? .null { return s }; return "" }()
            let tool: String = { if case .string(let s) = o["tool_or_action"] ?? .null { return s }; return "chat.synthesize" }()
            let auto: String = { if case .string(let s) = o["autonomy"] ?? .null { return s }; return "auto" }()
            let args: JSONValue = { if case .object = o["args"] ?? .null { return o["args"]! }; return .object([:]) }()
            out.append(WorkshopExecutionStep(id: id, description: desc, toolOrAction: tool, args: args, autonomy: auto))
        }
        return out
    }

    // MARK: stub fallback (PUBLIC FOR TESTS)

    /// 2-step stub plan — byte-for-byte against the retired daemon.
    public static func stubFallback(spec: WorkshopExecutionSpec) -> [WorkshopExecutionStep] {
        return [
            WorkshopExecutionStep(
                id: "step-plan",
                description: "Analyze objective and gather context",
                toolOrAction: "chat.synthesize",
                args: .object([
                    "prompt": .string("Given this objective: \(spec.objective)\n\nProduce a brief action plan."),
                ]),
                autonomy: "auto"
            ),
            WorkshopExecutionStep(
                id: "step-report",
                description: "Summarize findings",
                toolOrAction: "chat.synthesize",
                args: .object([
                    "prompt": .string("Summarize the outcome for: \(spec.objective)"),
                ]),
                autonomy: "auto"
            ),
        ]
    }

    // MARK: parse helpers

    /// Strip leading + trailing ```...``` fences, matching missions.py
    /// L1665-L1669 (`"\n".join(line for line in raw.splitlines() if not
    /// line.strip().startswith("```")).strip()`).
    static func stripMarkdownFences(_ s: String) -> String {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.hasPrefix("```") { return stripped }
        let lines = stripped.components(separatedBy: "\n")
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirror of the Python parse loop.
    /// Returns the validated steps; raises if the top-level shape is wrong.
    /// Unknown step tools fall back to chat.synthesize per L1679-L1681.
    /// Autonomy hints not in {auto, needs_approval} clamp to "auto" per
    /// L1683-L1684. Max 8 steps per L1675.
    static func parsePlanJSON(_ raw: String, validTools: Set<String>) throws -> [WorkshopExecutionStep] {
        let data = Data(raw.utf8)
        guard let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed,
              case .array(let stepsRaw) = obj["steps"] ?? .null else {
            throw WorkshopExecutionError.plannerFailure("plan missing 'steps' list")
        }
        var out: [WorkshopExecutionStep] = []
        for (i, s) in stepsRaw.prefix(8).enumerated() {
            guard case .object(let sobj) = s else { continue }
            var tool: String = {
                if case .string(let v) = sobj["tool_or_action"] ?? .null { return v }
                return "chat.synthesize"
            }()
            if !validTools.contains(tool) && tool != "chat.synthesize" {
                tool = "chat.synthesize"
            }
            var hint: String = {
                if case .string(let v) = sobj["autonomy_hint"] ?? .null { return v }
                return "auto"
            }()
            if hint != "auto" && hint != "needs_approval" {
                hint = "auto"
            }
            // Python: str(s.get("id") or f"step-{i+1}") — empty string is falsy.
            let id: String = {
                if case .string(let v) = sobj["id"] ?? .null, !v.isEmpty { return v }
                return "step-\(i + 1)"
            }()
            let desc: String = {
                if case .string(let v) = sobj["description"] ?? .null, !v.isEmpty { return v }
                return "Step \(i + 1)"
            }()
            // Python: dict(s.get("args") or {}) — None/missing/empty-dict → {};
            // a non-dict truthy value (string/array/number) raises TypeError,
            // which cascades to the outer planMission stub-fallback path.
            let args: JSONValue
            switch sobj["args"] ?? .null {
            case .null:
                args = .object([:])
            case .object(let o):
                args = .object(o)
            default:
                throw WorkshopExecutionError.plannerFailure("step args must be a JSON object")
            }
            out.append(WorkshopExecutionStep(
                id: id,
                description: desc,
                toolOrAction: tool,
                args: args,
                autonomy: hint
            ))
        }
        return out
    }

    /// Same shape as MCPDispatcher.isoTimestamp and TriggerScheduler.isoTimestamp.
    public static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}
