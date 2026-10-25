import Privacy
import SwarmRuns
import Foundation
import os
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

// Blueprint: | `WorkshopExecution+Runner.swift` | `SwiftNativeWorkshopRunner`: canonical execution.json ownership, safe execution IDs, queue admission, planning/cancel transitions and timeline receipts |

// MARK: - SwiftNative impl

public actor SwiftNativeWorkshopRunner {
    private let root: URL
    let persistence: any PersistenceCoreProtocol
    private let planner: any WorkshopPlannerLLM
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> String
    private static let logger = Logger(subsystem: "com.nativeagent.workshop", category: "runner")

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        planner: (any WorkshopPlannerLLM)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.planner = planner ?? StubWorkshopPlannerLLM()
        self.now = now
        self.uuid = uuid
    }

    public nonisolated var executionRecordsRoot: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
    }

    public nonisolated func workshopExecutionDir(_ id: String) -> URL {
        executionRecordsRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The sole live record: execution.json. Legacy files stay untouched.
    public nonisolated func executionRecordPath(_ id: String) -> URL {
        ExecutionRecordFile.canonicalPath(in: workshopExecutionDir(id))
    }

    public nonisolated func timelinePath(_ id: String) -> URL {
        ExecutionRecordFile.timelinePath(in: workshopExecutionDir(id))
    }

    public nonisolated func receiptsDir(_ id: String) -> URL {
        ExecutionRecordFile.receiptsPath(in: workshopExecutionDir(id))
    }

    /// Execution ids are persisted as directory names. Keep every public
    /// lookup/mutation rooted to one canonical directory component.
    /// Record readers also require the stored id to equal that component;
    /// payload identity must never redirect execution or receipt ownership.
    nonisolated static func isSafeExecutionID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("\0")
    }

    // WAVE 41 W01 (REOPEN §6.220-rd2 #1) — write-side parity helpers.
    //
    // Mac native execution writes (submit/create, update) MUST mirror the three
    // daemon submission semantics they previously bypassed:
    //   (a) the missionPolicy.enabled gate (`Runtime._missions_allowed`,
    //       the retired daemon) — the daemon route 403s create when
    //       missionPolicy is off;
    //   (b) the execution-slots capacity gate (`_mission_slots` BoundedSemaphore,
    //       the retired daemon / L734) — submit() raises MissionsBusyError
    //       when no slot is free;
    //   (c) the Activity feed row (`Runtime.record_activity`, the retired daemon
    //       L5288-L5308) the legacy create/update handlers emit so the Mac
    //       Activity view shows execution events.
    // Execution state stays under the same data root. Saved authority is read
    // by TrustCenter's checked owner so corrupt policy cannot bootstrap work.

    /// `Runtime.activity_path`:
    /// `<root>/activity/events.jsonl`.
    nonisolated var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Read checked Trust authority before submission; damaged saved policy
    /// refuses work. A missing store receives the owner's bootstrap defaults.
    private func workshopExecutionsAllowed() async throws -> Bool {
        // Reuse the authority owner's checked read: only a missing file may
        // bootstrap. A damaged saved policy is unavailable, not permission to
        // submit work or fall through to a legacy update path. The checked
        // projection preserves valid saved Workshop/Developer Mode values.
        let trust = SwiftNativeTrustCenter(dataRoot: root, persistence: persistence, clock: now)
        do {
            return Self.workshopPolicyAllows(try await trust.loadTrustPolicyChecked())
        } catch {
            throw WorkshopExecutionError.persistenceFailure(
                "saved trust policy is unavailable: \(error)"
            )
        }
    }

    /// Shared Workshop policy projection for submission and background execution.
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
        if pyTruthy(policy["developerMode"]) { return true }
        // Wave 4 read-both (phase A): accept the FUTURE `workshopPolicy`
        // spelling, falling back to the on-wire `missionPolicy`. Every writer
        // still emits the old key, so on a real policy this resolves to exactly
        // the same value it did before — and a policy that carries ONLY the new
        // key can no longer read as "absent → allow" (a fail-OPEN).
        let mpRaw = WorkshopPolicyBlockVocabulary.block(policy)
        if mpRaw == nil {
            return true   // missionPolicy absent → merged default enabled=true
        }
        guard case .object(let mp)? = mpRaw else {
            return false  // missionPolicy present but malformed → deny (daemon AttributeError-bubble parity)
        }
        guard let enabled = mp["enabled"] else {
            return true   // enabled key absent → merged default enabled=true
        }
        return pyTruthy(enabled)
    }

    /// Retired truthiness for a JSON value (matches `bool(x)` for the scalar
    /// types `body.get(...)` can return): absent/null/false/0/0.0/""/[]/{}
    /// are falsy; everything else is truthy.
    private static func pyTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.int(let i)): return i != 0
        case .some(.double(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let o)): return !o.isEmpty
        }
    }

    /// Mirror of the `_mission_slots` capacity:
    /// `BoundedSemaphore(max_active + max_pending)` where the two counts come
    /// from the SAME env vars (defaults 3 + 32 = 35). The daemon holds one
    /// permit for an execution's whole queued→running lifetime (acquire in
    /// submit() L734, release in _run_mission's finally), so the live count is
    /// the number of executions in a non-terminal state. We can't hold a
    /// cross-process semaphore for the daemon executor's lifetime, so we mirror
    /// the EFFECT: count active (queued/running/blocked_on_approval) queue
    /// executions and refuse a new submit when that count is already at the cap —
    /// the same condition under which the daemon's `acquire(blocking=False)`
    /// would fail.
    private static func workshopExecutionSlotsCap() -> Int {
        // P2-5: canonical names are `..._EXECUTIONS`; the `..._MISSIONS`
        // spellings are the public 0.3.x contract and still win when both are
        // set, so a launch agent that pins the old name is never silently
        // overridden. Reading one logs a single deprecation line.
        let active = WorkshopExecutorLoop.defaultMaxActive()
        let pending = max(0, Int(
            ExecutionEnvVocabulary.value(canonical: "NATIVE_AGENT_MAX_PENDING_EXECUTIONS") ?? ""
        ) ?? 32)
        return active + pending
    }

    /// Refuse if the queue is at capacity. Mirrors the
    /// `if not self._mission_slots.acquire(blocking=False): raise MissionsBusyError()`
    /// guard at the TOP of submit().
    private func assertSlotAvailable() async throws {
        let cap = Self.workshopExecutionSlotsCap()
        let active = Self.activeRecords(try await scanAllQueueWorkshopExecutionsChecked().map(\.record))
        if let corrupt = active.first(where: { $0.status == "corrupt" }) {
            throw WorkshopExecutionError.persistenceFailure(String(describing: corrupt.result))
        }
        let activeCount = active.count + (try liveReservationCount())
        if activeCount >= cap {
            // Same message MissionsBusyError ships by default.
            throw WorkshopExecutionError.workshopExecutionsBusy("missions_busy: too many active or pending Workshop executions")
        }
    }

    /// In-flight submit reservations: queue subdirs holding `.reserved` with
    /// no execution.json yet. Each occupies a slot so concurrent submitters
    /// can't overshoot the cap between admission and the durable write.
    /// Age-out: a reservation older than 10 minutes is a crashed submit
    /// (planning happens BEFORE reservation; only file IO remains) — ignore
    /// it rather than leak the slot forever.
    private nonisolated func liveReservationCount() throws -> Int {
        let fm = FileManager.default
        let subdirs = try fm.contentsOfDirectory(
            at: executionRecordsRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var count = 0
        for dir in subdirs {
            let marker = dir.appendingPathComponent(".reserved")
            guard fm.fileExists(atPath: marker.path),
                  !ExecutionRecordFile.exists(in: dir, fileManager: fm) else {
                continue
            }
            let mtime = (try marker.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if Date().timeIntervalSince(mtime) < 600 { count += 1 }
        }
        return count
    }

    /// Append one Activity event mirroring `Runtime.record_activity`
    ///: the daemon writes
    ///   {id, kind, title, detail, status, executionId, payload, createdAt}
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
    /// redaction as a real parity/security gap (user-entered execution text could
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
        let event = SwiftNativePersistenceCore.activityEvent(
            id: uuid(),
            kind: kind,
            title: NativeAgentSecretRedactor.redactText(title),
            detail: NativeAgentSecretRedactor.redactText(detail),
            status: status,
            executionId: executionId,
            payload: NativeAgentSecretRedactor.redactValue(payload),
            createdAt: Self.isoTimestamp(now())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
                event, to: activityPath, using: persistence,
                logLabel: "Workshop"
            )
        } catch {
            // An activity-feed write must NEVER unwind the execution write that
            // already landed durably (parity with the daemon, where
            // record_activity is fire-and-forget after the state change).
            Self.logger.info("record_activity append failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: planWorkshopExecution

    private func planWorkshopExecution(spec: WorkshopExecutionSpec) async throws -> [WorkshopExecutionStep] {
        try Task.checkCancellation()
        let workspaceDirectory = NativeAgentWorkspaceRoot.resolve(dataRoot: root).path

        // Build tools_summary. Always include chat.synthesize.
        let connectorActions = await planner.availableConnectorActions()
        try Task.checkCancellation()
        var availableTools: [(id: String, description: String)] = []
        var schemas: [String: JSONValue] = [:]
        for action in connectorActions {
            guard case .object(let obj) = action,
                  case .string(let aid) = obj["id"] ?? .null,
                  !aid.isEmpty else { continue }
            let desc: String = {
                if case .string(let s) = obj["description"] ?? .null { return s }
                return aid
            }()
            if case .object? = obj["parameters"] { schemas[aid] = obj["parameters"] }
            availableTools.append((id: aid, description: desc))
        }
        if !availableTools.contains(where: { $0.id == "chat.synthesize" }) {
            availableTools.append((
                id: "chat.synthesize",
                description: "Use the AI to synthesize, draft, analyze, or reason over text"
            ))
        }
        // Render the FULL tool menu (was prefix(30) — which silently cut
        // builder/shell tools from the planner's view, so "run a shell command"
        // executions picked the wrong tool and failed; 2026-06-15, the user: executions
        // do everything). Cap high (200) only as a prompt-size backstop.
        let toolsSummary = availableTools.prefix(200).map { t in
            let schema = schemas[t.id].flatMap { try? $0.serialize(pretty: false) }
            return "  - \(t.id): \(t.description)" + (schema.map { " [schema=\($0)]" } ?? "")
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
            Workspace folder: \(workspaceDirectory)
            Required output phrases: \((spec.expectedOutputs ?? []).joined(separator: "\n"))

            Available tools:
            \(toolsSummary)

            Rules:
            - Each step's tool_or_action must be one of the available tool IDs above, OR chat.synthesize.
            - autonomy_hint must be one of: auto, needs_approval
            - Maximum 8 steps.
            - Set working_directory to the first path named in the objective if it denotes a directory, or to its parent if it denotes a file (including a file to create). Use the Workspace folder only when no path is named; a named directory stays the working_directory even if it does not exist.
            - Working-folder arguments (cwd or package_path) use the directory required by that step; use working_directory when the objective does not specify another directory for that step.
            - args must be a JSON object preserving each tool schema's declared types, including booleans, numbers, arrays, and objects. Never quote booleans or numbers.
            - working_directory and args must be FINAL literal values, never placeholders. Do NOT write things like "<today's date>", "<result>", or "<the summary>". For the date, use the Current date/time above directly in the arg.
            - If a step's arg must contain the OUTPUT of an EARLIER step (e.g. write a file whose body is what a prior step produced), put the token {{step:<that earlier step's id>}} in the arg — it is replaced at run time with that step's actual output. This works in tool args only; chat.synthesize steps automatically see all prior step outputs, so to turn raw data into prose first add a chat.synthesize step, then reference ITS id with {{step:<id>}} in the write step.

            Return ONLY valid JSON, no commentary, no markdown fences:
            {"working_directory": "...", "steps": [{"id": "step-1", "description": "...", "tool_or_action": "...", "args": {}, "autonomy_hint": "auto"}]}
            """

        // Call codex.
        let rawOutput: String
        do {
            (_, rawOutput) = try await planner.runCodex(
                prompt: prompt,
                surface: WorkshopSurfaceVocabulary.canonical,
                timeoutSeconds: 60
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolFailureError {
            throw error
        } catch {
            throw planningFailure(error, spec: spec)
        }
        try Task.checkCancellation()

        // Strip markdown fences.
        let raw = Self.stripMarkdownFences(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let directory = try JSONRow(JSONValue.parse(Data(raw.utf8))).string("working_directory")
            if directory.isEmpty { throw JSONRow.Malformed.field("working_directory") }
            let workingDirectory = NativeAgentWorkspaceRoot.resolveFileMutationPath(directory, dataRoot: root).path
            let steps = try Self.parsePlanJSON(raw, validTools: Set(availableTools.map(\.id)), schemas: schemas)
            guard !steps.isEmpty else {
                throw WorkshopExecutionError.plannerFailure("planner returned no steps")
            }
            return steps.map { step in
                var step = step
                if case .object(let schema)? = schemas[step.toolOrAction],
                   case .object(let properties)? = schema["properties"],
                   case .object(var args) = step.args {
                    for key in ["cwd", "package_path"] where properties[key] != nil && args[key] == nil {
                        args[key] = .string(workingDirectory)
                    }
                    step.args = .object(args)
                }
                return step
            }
        } catch {
            throw planningFailure(error, spec: spec)
        }
    }

    private func planningInput(_ spec: WorkshopExecutionSpec) -> JSONValue {
        var input: [String: JSONValue] = ["text": .string(String(spec.objective.prefix(2000))), "context": .string(String(spec.title.prefix(160)))]
        if let handle = spec.deskHandle { input["desk_handle"] = .string(handle) }
        if let outputs = spec.expectedOutputs { input["expected_outputs"] = .array(outputs.map(JSONValue.string)) }
        return .object(input)
    }

    private func planningFailure(_ error: Error, spec: WorkshopExecutionSpec) -> ToolFailureError {
        ToolFailureError("Workshop planner failed; no substitute plan was queued: \(error.localizedDescription)",
            effects: .none, nextCall: ToolFailureError.call("app", ["action": .string("workshop.submit"), "args": planningInput(spec)]))
    }

    // MARK: submit

    public func submit(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionEnqueueResult {
        try Task.checkCancellation()
        let lifeID = try DataRootLife.current(in: root)

        // WAVE 41 W01 (a) missionPolicy gate — FIRST, matching the daemon's
        // POST /v1/missions route ORDER: the route checks `_missions_allowed()`
        // BEFORE the empty-objective validation
        // (L53003) and refuses with HTTP 403 + the exact detail below. gpt-5.5
        // review #1: gating AFTER the objective check diverged — a policy-off
        // request with an empty objective would return `missing_objective` (400)
        // where the daemon returns `forbidden` (403). Default-safe: a fresh root
        // with no saved policy is ALLOWED (default_trust_policy enabled=true).
        guard try await workshopExecutionsAllowed() else {
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
        // already at (max_active + max_pending) active executions.
        let id = uuid()
        guard Self.isSafeExecutionID(id) else {
            throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
        }
        try FileManager.default.createDirectory(at: executionRecordsRoot, withIntermediateDirectories: true)
        let admissionLock = executionRecordsRoot.appendingPathComponent(".admission")
        let prior = try await persistence.withFileLock(admissionLock) { [self] in
            try await getWorkshopExecution(id)
        }
        if let prior {
            return WorkshopExecutionEnqueueResult(status: prior.status, executionId: id, record: prior)
        }
        try await assertSlotAvailable()

        // Build the Workshop execution record.
        let titleTrunc = String(spec.title.prefix(160))
        let objectiveTrunc = String(spec.objective.prefix(2000))
        let nowStr = Self.isoTimestamp(now())

        let plan = try await planWorkshopExecution(
            spec: WorkshopExecutionSpec(
                title: titleTrunc,
                objective: objectiveTrunc,
                triggerSource: spec.triggerSource,
                trustRequired: spec.trustRequired,
                deskHandle: spec.deskHandle,
                projectSpaceId: spec.projectSpaceId,
                expectedOutputs: spec.expectedOutputs
            )
        )
        let exactPlanningProviderCallCount = planner.directProviderCallCountPerInvocation

        // Check cancellation AFTER planning, BEFORE file IO. Without this gate
        // a cancel that lands between the planner returning and the directory
        // create would still write execution.json and fire the detached
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
        let existing = try await persistence.withFileLock(admissionLock) { [self] () async throws -> WorkshopExecutionRecord? in
            let raw = try await ExecutionRecordFile.readJSON(at: executionRecordPath(id), using: persistence)
            if case .object(let object) = raw {
                guard object["id"] == .string(id) else {
                    throw WorkshopExecutionError.persistenceFailure("execution identity mismatch")
                }
                return Self.recordFromJSON(object)
            }
            guard !FileManager.default.fileExists(atPath: workshopExecutionDir(id).path) else {
                throw WorkshopExecutionError.invalidRequest("execution admission is already in progress")
            }
            try await assertSlotAvailable()
            // COUNTED reservation (delta review: an empty dir is invisible
            // to the slot count, so racers serializing through this lock
            // each saw the same count). `.reserved` occupies a slot until
            // execution.json lands; removed on success, dir deleted on
            // failure, age-out guards a crash between the two.
            try FileManager.default.createDirectory(
                at: workshopExecutionDir(id), withIntermediateDirectories: true)
            do {
                try Data("reserved \(nowStr)".utf8)
                    .write(to: workshopExecutionDir(id).appendingPathComponent(".reserved"))
            } catch {
                try? FileManager.default.removeItem(at: workshopExecutionDir(id))
                throw error
            }
            return nil
        }
        if let existing {
            return WorkshopExecutionEnqueueResult(status: existing.status, executionId: id, record: existing)
        }

        let dir = workshopExecutionDir(id)
        let receipts = receiptsDir(id)
        let timeline = timelinePath(id)
        let executionRecordJSON = executionRecordPath(id)
        // Delta review: ONE cleanup scope for every throw between the counted
        // reservation and the durable execution.json write (receipt directory,
        // both timeline appends, cancellation, execution.json itself) — any
        // failure frees the reservation by deleting the dir, instead of
        // falsely occupying a slot until the 600s age-out.
        func freeReservationAndRethrow(_ error: Error) throws -> Never {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        var record = WorkshopExecutionRecord(
            id: id,
            lifeID: lifeID,
            deskHandle: spec.deskHandle,
            projectSpaceId: spec.projectSpaceId,
            title: titleTrunc,
            objective: objectiveTrunc,
            createdAt: nowStr,
            status: "queued",
            plan: plan,
            stepsCompleted: [],
            receiptsDir: receipts.path,
            triggerSource: spec.triggerSource,
            trustRequired: spec.trustRequired,
            expectedOutputs: (spec.expectedOutputs ?? []).map(JSONValue.string),
            currentStepId: "",
            updatedAt: nowStr,
            result: .null,
            rerunCount: 0,
            planningProviderCallCount: exactPlanningProviderCallCount,
            planningRemovableOrchestrationProviderCallCount: exactPlanningProviderCallCount
        )
        do {
        if let compiled = planner as? WorkshopCompiledLocalFileCopyPlanner {
            record.compiledOperationBinding = try JSONValue.parse(JSONEncoder().encode(compiled.binding))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)


        // Write the timeline first, so an interrupted enqueue has no execution record.
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
        // cancel between timeline append and execution.json write should NOT
        // land execution.json — and must free the admission reservation.
        if Task.isCancelled { throw CancellationError() }

        do {
            try await ExecutionRecordFile.write(record, to: executionRecordJSON, using: persistence)
        } catch {
            throw WorkshopExecutionError.persistenceFailure("execution.json write failed: \(error)")
        }
        // Reservation fulfilled — execution.json is the counted artifact now.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".reserved"))
        } catch {
            try freeReservationAndRethrow(error)
        }

        // WAVE 41 W01 (c) Activity row — mirror the daemon legacy create_mission's
        // record_activity:
        //   record_activity("mission", "Workshop task created", title, "ok",
        //                   execution["id"], {"executionId": execution["id"]})
        // emitted right after the durable write (the daemon records once the
        // execution is persisted, with NO cancellation point between).
        //
        // gpt-5.5 review #5: this MUST sit BEFORE the post-write
        // checkCancellation() below. A landed execution.json write is durable; if a
        // cancel were checked first, the execution would exist on disk with NO
        // Activity row — the exact gap the reopen flags. Emitting here guarantees
        // every durably-created execution gets its row. recordActivity is
        // non-fatal (logs on IO failure) so it never unwinds the landed write.
        await recordActivity(
            kind: "mission",
            title: "Workshop task created",
            detail: titleTrunc,
            status: "ok",
            executionId: id,
            payload: .object(["executionId": .string(id)])
        )

        try Task.checkCancellation() // cancel after the write+activity should NOT fire the detached auto-start

        // Daemon retired (fac-F1): no fire-and-forget auto-start. The execution
        // lands durably on disk in `queued`; WorkshopExecutorLoop's next drain
        // pass (BackgroundLoops-registered, gated on enableAutonomy +
        // missionPolicy) claims and runs it.
        return WorkshopExecutionEnqueueResult(status: "queued", executionId: id, record: record)
    }

    // MARK: cancel (WAVE 33 W07 — execution-lifecycle WRITE)
    //
    // Hold the execution-file lock across read, mutation and write so cancel
    // cannot race another execution mutation.
    public func cancel(executionId: String) async throws -> WorkshopExecutionRecord {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("empty missionId")
        }
        // Execution ids become a single directory component below the
        // selected Workshop root. Refuse path syntax at the canonical owner,
        // not only at a CLI wrapper, so every cancel caller stays root-bound.
        guard Self.isSafeExecutionID(trimmed) else {
            throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
        }
        let executionRecordJSON = executionRecordPath(trimmed)
        let timeline = timelinePath(trimmed)
        let nowStr = Self.isoTimestamp(now())

        // Reject a missing execution before acquiring its lock. File-lock
        // acquisition creates the lock's parent directory on some backends;
        // without this preflight, a typo in a cancel command could leave an
        // empty Workshop execution directory and lock artifact behind.
        guard FileManager.default.fileExists(atPath: executionRecordJSON.path) else {
            throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)")
        }

        let record: WorkshopExecutionRecord
        let didCancel: Bool
        do {
            let update = try await ExecutionRecordFile.update(at: executionRecordJSON, id: trimmed, using: persistence) { record in
                guard !["completed", "failed", "cancelled", "stopped"].contains(record.status) else { return false }
                record.status = "cancelled"
                record.updatedAt = nowStr
                return true
            }
            guard let saved = update.record else {
                throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)")
            }
            record = saved
            didCancel = update.applied
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("cancel execution.json write failed: \(error)")
        }

        // Append the event only after the durable transition and lock release.
        if didCancel {
            let event: JSONValue = .object([
                "event": .string("cancelled"),
                "ts": .string(nowStr),
            ])
            do {
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

    private func appendTimelineLocked(_ event: JSONValue, to timeline: URL) async throws {
        try await ExecutionRecordFile.appendTimeline(event, to: timeline, using: persistence)
    }

    // Reads use the same on-disk layout submit() writes:
    //     <root>/workshop/executions/<id>/execution.json
    //     <root>/workshop/executions/<id>/timeline.jsonl
    // The compatibility record shape is preserved under Workshop ownership.
    // Reads remain lock-free, matching the prior behavior.

    /// `TaskQueue.get`. Reads
    /// <queue>/<id>/execution.json, returns nil when absent, malformed, or
    /// carrying an id that does not match its containing directory.
    public func getWorkshopExecution(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        guard Self.isSafeExecutionID(executionId) else { return nil }
        let raw = try await ExecutionRecordFile.readJSON(at: executionRecordPath(executionId), using: persistence)
        guard case .object(let obj) = raw,
              case .string(let gotId)? = obj["id"], gotId == executionId else {
            return nil
        }
        return Self.recordFromJSON(obj)
    }

    /// Byte-faithful single-execution read for the GET /v1/missions/<id> seam
    ///. Returns the asdict-equivalent object
    /// WITHOUT the `timeline` key (the caller attaches it); nil when absent.
    /// gpt-5.5 finding #1: use this (not getMission(...)?.toJSON()) so `plan`
    /// is emitted verbatim.
    public func getWorkshopExecutionWireJSON(_ executionId: String) async throws -> JSONValue? {
        guard Self.isSafeExecutionID(executionId) else { return nil }
        let raw = try await ExecutionRecordFile.readJSON(at: executionRecordPath(executionId), using: persistence)
        guard case .object(let obj) = raw,
              case .string(let gotId)? = obj["id"], gotId == executionId else {
            return nil
        }
        return Self.readJSONForWorkshopExecution(obj)
    }

    /// `TaskQueue.read_timeline`. Returns the raw event
    /// dicts in file order; missing file -> []; malformed lines skipped. The
    /// `readJSONL` impl matches Python's semantics exactly.
    public func readTimeline(_ executionId: String) async throws -> [JSONValue] {
        guard Self.isSafeExecutionID(executionId) else {
            throw WorkshopExecutionError.invalidRequest(
                "executionId must be a single path component"
            )
        }
        return try await ExecutionRecordFile.readTimeline(at: timelinePath(executionId), using: persistence)
    }

    /// Queue members have execution.json; retired-only directories are excluded.
    /// Failed reads and invalid canonical records remain visible as corrupt and block admission.
    private func scanAllQueueWorkshopExecutions() async -> [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] {
        do {
            return try await scanAllQueueWorkshopExecutionsChecked()
        } catch {
            let raw: [String: JSONValue] = [
                "id": .string("queue-unavailable"),
                "title": .string("Workshop queue unavailable"),
                "status": .string("unavailable"),
                "result": .object(["error": .string(error.localizedDescription)]),
            ]
            return [(Self.recordFromJSON(raw), raw)]
        }
    }

    /// Absent canonical records are not queue members; failed reads cannot prove inactivity.
    private func scanAllQueueWorkshopExecutionsChecked() async throws -> [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] {
        try await Self.readQueueRecords(dataRoot: root, persistence: persistence).compactMap { id, raw in
            guard case .object(let obj) = raw,
                  case .string(let gotId)? = obj["id"], gotId == id else { return nil }
            return (Self.recordFromJSON(obj), obj)
        }
    }

    static func readQueueRecords(dataRoot: URL, persistence: any PersistenceCoreProtocol) async throws -> [(id: String, raw: JSONValue)] {
        let fm = FileManager.default
        let queueRoot = dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: queueRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var out: [(id: String, raw: JSONValue)] = []
        for sub in entries {
            let isDir = try sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            guard isDir else { continue }
            let mp = ExecutionRecordFile.canonicalPath(in: sub)
            let raw = await Self.readQueueRecord(mp, id: sub.lastPathComponent, persistence: persistence)
            if raw != .null { out.append((sub.lastPathComponent, raw)) }
        }
        return out
    }

    /// A read-only projection: never persist invented execution state over bad bytes.
    static func readQueueRecord(
        _ path: URL, id: String, persistence: any PersistenceCoreProtocol
    ) async -> JSONValue {
        do {
            let raw = try await ExecutionRecordFile.readJSON(at: path, using: persistence)
            if raw == .null, !FileManager.default.fileExists(atPath: path.path) { return raw }
            guard case .object(let obj) = raw else {
                throw WorkshopExecutionError.persistenceFailure("Execution record must be an object")
            }
            guard case .string(let gotId)? = obj["id"], gotId == id else {
                throw WorkshopExecutionError.persistenceFailure("Execution record id must match its directory: \(id)")
            }
            return raw
        } catch {
            return .object([
                "id": .string(id),
                "title": .string(id),
                "status": .string("corrupt"),
                "result": .object(["error": .string(error.localizedDescription)]),
            ])
        }
    }

    /// `TaskQueue.list_all`: all queue Workshop executions sorted
    /// by created_at DESC.
    public func listAll() async -> [WorkshopExecutionRecord] {
        await scanAllQueueWorkshopExecutions().sorted { $0.record.createdAt > $1.record.createdAt }.map(\.record)
    }

    /// One observed set for the status tool's active/recent sections. Each
    /// record is read once, so a transition cannot put that record in both
    /// sections. This is not an atomic cross-record snapshot: independent
    /// executions can still change while the directory scan is in progress.
    public func listStatusSnapshot() async -> (active: [WorkshopExecutionRecord], recent: [WorkshopExecutionRecord]) {
        let records = await scanAllQueueWorkshopExecutions().map(\.record)
        return (Self.activeRecords(records), Self.recentRecords(records))
    }

    private nonisolated static func activeRecords(_ records: [WorkshopExecutionRecord]) -> [WorkshopExecutionRecord] {
        let live: Set<String> = ["queued", "running", "blocked_on_approval", "blocked_on_reconciliation", "corrupt", "unavailable"]
        return records.filter { live.contains($0.status) }
    }

    private nonisolated static func recentRecords(_ records: [WorkshopExecutionRecord]) -> [WorkshopExecutionRecord] {
        let done: Set<String> = ["completed", "failed", "cancelled", "stopped"]
        let filtered = records.filter { done.contains($0.status) }
        return Array(filtered.sorted { $0.updatedAt > $1.updatedAt }.prefix(20))
    }

    /// Canonical queue records, sorted by creation time; retired flat history is untouched.
    public func listWorkshopExecutions() async throws -> [JSONValue] {
        // Preserve raw plan bytes from the sole canonical execution store.
        let queue = try await scanAllQueueWorkshopExecutionsChecked()
            .sorted { $0.record.createdAt > $1.record.createdAt }
            .map { Self.readJSONForWorkshopExecution($0.raw) }
        return queue
    }

    /// Build a WorkshopExecutionRecord from a persisted execution.json object, mirroring
    /// Byte-faithful read serialization mirroring the daemon's HTTP wire output
    /// for a single execution: `asdict(TaskQueue._from_dict(data))` (missions.py
    /// L432-L450 + dataclasses.asdict). gpt-5.5 review (wave 32 W07) finding #1:
    /// Python preserves `plan` / `steps_completed` / `expected_outputs` /
    /// `result` VERBATIM (`list(data.get(k) or [])` — raw dicts unchanged) and
    /// only `str()`-coerces the scalar string fields. Round-tripping `plan`
    /// through `WorkshopExecutionRecord`/`WorkshopExecutionStep` would NORMALIZE it (default a
    /// missing tool_or_action, drop unknown keys), altering the wire bytes vs
    /// the daemon. So the wire paths (listWorkshopExecutions, getWorkshopExecutionWireJSON) use
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
            case .double(let d): return .int(Int64(exactly: d.rounded(.towardZero)) ?? 0)
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
            "receipts_dir": .string(s("receipts_dir", "")),
            "steps_completed": rawArr("steps_completed"),
            "trigger_source": .string(s("trigger_source", "manual")),
            "trust_required": .string(s("trust_required", "none")),
            "expected_outputs": rawArr("expected_outputs"),
            "current_step_id": .string(s("current_step_id", "")),
            "updated_at": .string(s("updated_at", "")),
            "result": obj["result"] ?? .null,
            "rerun_count": rerun(),
        ]
        normalized["lifeID"] = obj["lifeID"]
        normalized["terminal_reason"] = obj["terminal_reason"]
        if let deskHandle = obj["desk_handle"], case .string = deskHandle {
            normalized["desk_handle"] = deskHandle
        }
        if let projectSpaceId = obj["project_space_id"], case .string = projectSpaceId {
            normalized["project_space_id"] = projectSpaceId
        }
        if let movement = obj["last_movement_at"], case .string = movement {
            normalized["last_movement_at"] = movement
        }
        if let binding = obj["compiled_operation_binding"] {
            normalized["compiled_operation_binding"] = binding
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
    /// (defaults included) so a partial / older-schema execution.json decodes the
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
            case .double(let d): return Int(exactly: d.rounded(.towardZero)) ?? 0
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
            lifeID: { if case .string(let id)? = obj["lifeID"] { id } else { nil } }(),
            deskHandle: {
                let value = s("desk_handle", "").trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }(),
            projectSpaceId: {
                let value = s("project_space_id", "").trimmingCharacters(in: .whitespacesAndNewlines)
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
            verification: WorkshopVerificationRecord.fromJSON(obj["verification"]),
            lastMovementAt: {
                if case .string(let value)? = obj["last_movement_at"] { return value }
                return nil
            }(),
            compiledOperationBinding: obj["compiled_operation_binding"],
            terminalReason: {
                if case .string(let value)? = obj["terminal_reason"] { return value }
                return nil
            }()
        )
    }

    /// Plan-array parser for persisted execution.json `plan` fields.
    static func parsePlanSteps(_ v: JSONValue?) -> [WorkshopExecutionStep] {
        guard let v, case .array(let arr) = v else { return [] }
        var out: [WorkshopExecutionStep] = []
        for item in arr {
            guard case .object(let o) = item else { continue }
            let id: String = { if case .string(let s) = o["id"] ?? .null { return s }; return "" }()
            let desc: String = { if case .string(let s) = o["description"] ?? .null { return s }; return "" }()
            let tool: String = { if case .string(let s) = o["tool_or_action"] ?? .null { return s }; return "" }()
            let auto: String = { if case .string(let s) = o["autonomy"] ?? .null { return s }; return "auto" }()
            let args: JSONValue = { if case .object = o["args"] ?? .null { return o["args"]! }; return .object([:]) }()
            out.append(WorkshopExecutionStep(id: id, description: desc, toolOrAction: tool, args: args, autonomy: auto, argumentSchema: o["argument_schema"]))
        }
        return out
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
    /// Autonomy hints not in {auto, needs_approval} clamp to "auto" per
    /// L1683-L1684. Max 8 steps per L1675.
    static func parsePlanJSON(_ raw: String, validTools: Set<String>, schemas: [String: JSONValue] = [:]) throws -> [WorkshopExecutionStep] {
        let data = Data(raw.utf8)
        guard let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed,
              case .array(let stepsRaw) = obj["steps"] ?? .null else {
            throw WorkshopExecutionError.plannerFailure("plan missing 'steps' list")
        }
        var out: [WorkshopExecutionStep] = []
        for (i, s) in stepsRaw.prefix(8).enumerated() {
            guard case .object(let sobj) = s else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1) must be a JSON object")
            }
            guard case .string(let tool)? = sobj["tool_or_action"], !tool.isEmpty else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1).tool_or_action is missing")
            }
            guard validTools.contains(tool) || tool == "chat.synthesize" else {
                throw WorkshopExecutionError.plannerFailure("step \(i + 1).tool_or_action '\(tool)' is unavailable; the intended action was not replaced")
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
            // which refuses the plan before enqueue.
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
                autonomy: hint,
                argumentSchema: schemas[tool]
            ))
        }
        try validateStepIDs(out)
        return out
    }

    static func validateStepIDs(_ steps: [WorkshopExecutionStep]) throws {
        var seen: Set<String> = []
        for step in steps {
            guard seen.insert(step.id).inserted else {
                throw WorkshopExecutionError.invalidRequest("Duplicate Workshop step ID: \(step.id)")
            }
        }
    }

    /// Same shape as TriggerScheduler.isoTimestamp.
    public static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }
}
