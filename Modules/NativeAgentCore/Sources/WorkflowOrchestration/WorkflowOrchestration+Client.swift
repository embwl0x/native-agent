import Foundation
import CryptoKit
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps
import ToolExecution

// MARK: - SwiftNative impl

public final class SwiftNativeWorkflowOrchestrationClient: WorkflowOrchestrationClient, MotorActionReadModelProviding {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    private let now: @Sendable () -> String
    private let uuid: @Sendable () -> String
    private let useFileLock: Bool
    private let memoryOwner: SwiftNativeMemoryV2

    /// - Parameters:
    ///   - root: the native data root (the dir that contains `workflows/`).
    ///   - now: ISO timestamp factory for default stamps (injectable for tests).
    ///   - uuid: random-id factory for create_workflow's slugify empty-fallback
    ///     and per-step id fallback (injectable for tests). Mirrors Python
    ///     `str(uuid.uuid4())`; default emits a real lowercase UUID string.
    ///   - useFileLock: when true, the registry write-back is wrapped in a
    ///     cross-process flock.
    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        memoryOwner: SwiftNativeMemoryV2? = nil,
        now: @escaping @Sendable () -> String = { WorkflowOrchestrationClock.nowISO() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        useFileLock: Bool = true
    ) {
        self.root = root
        self.persistence = persistence
        self.memoryOwner = memoryOwner ?? Self.makeMemoryOwner(dataRoot: root)
        self.now = now
        self.uuid = uuid
        self.useFileLock = useFileLock
    }

    private static func makeMemoryOwner(dataRoot: URL) -> SwiftNativeMemoryV2 {
        guard dataRoot.standardizedFileURL
            != PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return .shared
        }
        guard let storage = try? MemoryStorage(dataRoot: dataRoot) else {
            return SwiftNativeMemoryV2()
        }
        return SwiftNativeMemoryV2(
            embedder: ManagedEmbeddingProvider(dataRoot: dataRoot),
            storage: MemoryStorageBridge(storage: storage)
        )
    }

    /// Test-only root-confinement seam; exposes only the SQLite location.
    public func _testMemoryStoragePath() async -> URL? {
        guard let bridge = await memoryOwner.underlyingBridge() else { return nil }
        return await bridge.underlyingStorage().path
    }

    private var registryPath: URL { root.appendingPathComponent("workflows/registry.json") }
    private var runsPath: URL { root.appendingPathComponent("workflows/runs.jsonl") }
    private var tracesPath: URL { root.appendingPathComponent("traces/events.jsonl") }
    private var activityPath: URL { root.appendingPathComponent("activity/events.jsonl") }

    /// Mirror of Runtime.workflow_state_path(run_id):
    ///   workflow_run_state_dir / f"{slugify(run_id)}.json"
    private func runStatePath(_ runId: String) -> URL {
        root
            .appendingPathComponent("workflows/run_state")
            .appendingPathComponent("\(WorkflowRunState.slugify(runId)).json")
    }

    /// Mirror of Runtime.workflow_state(run_id): read the state file, raise if
    /// missing / empty / non-object.
    private func loadState(_ runId: String) async throws -> JSONValue {
        let raw = await persistence.readJSON(runStatePath(runId), defaultValue: .object([:]))
        guard case .object(let obj) = raw, !obj.isEmpty else {
            throw WorkflowOrchestrationError.unknownRunState(runId)
        }
        return raw
    }

    /// Read-only shared motor projection over the canonical Workflow run.
    ///
    /// Workflow keeps sole ownership of execution, approval, cancellation,
    /// deadlines, and persistence. This adapter never advances a run and never
    /// interprets `succeeded` as verified real-world success. V2 state files
    /// are authoritative; the bounded run ledger fallback covers v1/dry-run
    /// records, which intentionally have no mutable state file.
    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        let runId = actionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runId.isEmpty, let state = try await motorRunState(runId) else { return nil }
        let domainState = stateString(state, "status")
        let normalized = domainState.lowercased()
        let mode = stateString(state, "mode").lowercased()

        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let expectedEvidence: String?
        switch normalized {
        case "queued", "ready":
            phase = .ready
            verification = .notStarted
            expectedEvidence = "execution_start"
        case "running":
            phase = .running
            verification = .notStarted
            expectedEvidence = "step_or_terminal_outcome"
        case "waiting_approval", "awaiting_approval":
            phase = .awaitingApproval
            verification = .notStarted
            expectedEvidence = "approval_resolution"
        case "blocked":
            phase = .blocked
            verification = .notStarted
            expectedEvidence = "dependency_resolution"
        case "succeeded", "completed", "done":
            phase = .succeeded
            if mode == "dry_run" {
                verification = .notRequired
                expectedEvidence = nil
            } else {
                verification = .unverified
                expectedEvidence = "domain_verification"
            }
        case "failed":
            phase = .failed
            verification = .failed
            expectedEvidence = nil
        case "canceled", "cancelled", "rolled_back":
            phase = .cancelled
            verification = .notRequired
            expectedEvidence = nil
        case "expired":
            phase = .expired
            verification = .notRequired
            expectedEvidence = nil
        default:
            phase = .unknown
            verification = .unknown
            expectedEvidence = "domain_recovery"
        }

        let deadline: MotorActionDeadlineReadModel?
        if phase == .running, let seconds = activeAttemptTimeoutSeconds(state), seconds > 0 {
            deadline = MotorActionDeadlineReadModel(scope: .stepAttempt, timeoutSeconds: seconds)
        } else {
            deadline = nil
        }
        let opaqueRunId = CausalTransitionEvidence.opaqueIdentity(runId)
        return MotorActionReadModel(
            domain: "workflow_orchestration",
            actionIdentity: opaqueRunId,
            phase: phase,
            domainState: domainState,
            verification: verification,
            expectedNextEvidence: expectedEvidence,
            updatedAt: motorTimestamp(state),
            cancellationIdentity: opaqueRunId,
            deadline: deadline
        )
    }

    /// V2 runs have one canonical state file. V1/dry-run workflows only append
    /// to `runs.jsonl`, so consult a bounded recent window without writing or
    /// merging the workflow registry.
    private func motorRunState(_ runId: String) async throws -> JSONValue? {
        let statePath = runStatePath(runId)
        if FileManager.default.fileExists(atPath: statePath.path) {
            // V2 state is authoritative when present. A corrupt/unreadable
            // owner file must fail loud rather than falling through to a stale
            // derived ledger row that could manufacture terminality.
            return try await loadState(runId)
        }
        let recent = try await persistence.tailJSONL(
            runsPath,
            limit: 512,
            maxBytes: 4 * 1_048_576
        )
        return recent.reversed().first { stateString($0, "id") == runId }
    }

    /// Returns the timeout snapshot persisted immediately before the current
    /// attempt dispatched. Reading the mutable workflow registry here would be
    /// dishonest because a definition edit could differ from the in-flight
    /// step's already-selected policy.
    private func activeAttemptTimeoutSeconds(_ state: JSONValue) -> Int? {
        let seconds = Int(WorkflowCreate.pyInt(
            objectField(state, "activeStepTimeoutSeconds") ?? .int(0)
        ))
        return seconds > 0 ? seconds : nil
    }

    private func normalizedStepTimeoutSeconds(_ step: JSONValue) -> Int {
        max(0, Int(WorkflowCreate.pyInt(objectField(step, "timeoutSeconds") ?? .int(0))))
    }

    private func motorTimestamp(_ state: JSONValue) -> String? {
        for key in ["updatedAt", "completedAt", "createdAt"] {
            let value = stateString(state, key)
            if !value.isEmpty, value != "None" { return value }
        }
        return nil
    }

    /// Mirror of Runtime.record_trace for the workflow.* events emitted by
    /// cancel/rollback. The top-level event status matches the retired runtime's
    /// `str(_payload.get("status") or "ok")` — cancel
    /// passes payload.status="canceled" and rollback "rolled_back", so the event
    /// status is NOT "ok" for these (gpt-5.5 review finding #1, 2026-06-01).
    /// The error-normalisation branch (8636) is a no-op here: these payloads
    /// carry no `error` key, so `raw_err is None` short-circuits it.
    ///
    /// Wave 33 W01 (CUTOVER_PLAN §6.96): the append is wrapped in the SAME
    /// cross-process `withFileLock(<path>)` the daemon now also takes around its
    /// `record_trace` append + the traces prune. `traces/events.jsonl` is
    /// co-written by Python and >=5 Swift emitters; O_APPEND atomicity alone is
    /// NOT enough (payloads can exceed PIPE_BUF, and it does not serialize
    /// against the daemon's read-modify-replace prune), so this writer must take
    /// the lock like DispatchLedger.append / Research.appendResearchTrace /
    /// SwiftNativeCatalogWrites.emitCatalogTrace. Errors already propagate (this
    /// is `async throws` and the caller `try`s it), matching unwrapped Python
    /// `append_jsonl`.
    private func appendTrace(kind: String, title: String, payload: [String: JSONValue]) async throws {
        // str(payload.get("status") or "ok"): falsey ("" / missing / null) -> "ok".
        let status: String
        switch payload["status"] {
        case .some(.string(let s)) where !s.isEmpty: status = s
        case .some(.bool(let b)) where b: status = "True"
        case .some(.int(let i)) where i != 0: status = String(i)
        case .some(.double(let d)) where d != 0: status = String(d)
        default: status = "ok"
        }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(status),
            "payload": .object(payload),
            "createdAt": .string(now()),
        ])
        let tracesURL = tracesPath
        try await persistence.withFileLock(tracesURL) {
            try await persistence.appendJSONL(event, to: tracesURL)
        }
    }

    private func setField(_ state: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var obj) = state else { return state }
        obj[key] = value
        return .object(obj)
    }

    private func stateString(_ state: JSONValue, _ key: String) -> String {
        guard case .object(let obj) = state, let v = obj[key] else { return "None" }
        switch v {
        case .string(let s): return s
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return ""
        }
    }

    private func objectField(_ value: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let obj) = value else { return nil }
        return obj[key]
    }

    private func objectString(_ value: JSONValue, _ key: String, fallback: String = "") -> String {
        WorkflowCreate.pyStr(objectField(value, key) ?? .string(fallback))
    }

    private func objectBool(_ value: JSONValue, _ key: String) -> Bool {
        guard let raw = objectField(value, key) else { return false }
        return pyBool(raw)
    }

    private func pyBool(_ raw: JSONValue) -> Bool {
        switch raw {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let arr): return !arr.isEmpty
        case .object(let obj): return !obj.isEmpty
        }
    }

    private func truthyString(_ value: JSONValue?, fallback: @autoclosure () -> String) -> String {
        guard let value, pyBool(value) else { return fallback() }
        return WorkflowCreate.pyStr(value)
    }

    private func pyDouble(_ value: JSONValue?) -> Double {
        switch value {
        case .some(.double(let d)): return d
        case .some(.int(let i)): return Double(i)
        case .some(.bool(let b)): return b ? 1.0 : 0.0
        case .some(.string(let s)): return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default: return 0
        }
    }

    private func objectMap(_ value: JSONValue, _ key: String) -> [String: JSONValue] {
        guard case .object(let obj) = value,
              case .object(let nested)? = obj[key] else {
            return [:]
        }
        return nested
    }

    private func objectArray(_ value: JSONValue, _ key: String) -> [JSONValue] {
        guard case .object(let obj) = value,
              case .array(let array)? = obj[key] else {
            return []
        }
        return array
    }

    private func appendRun(_ run: JSONValue) async throws {
        let path = runsPath
        // M6 (2026-07-09): workflows/runs.jsonl appended forever while its
        // sibling runs.json was capped — the intent existed, the sweep missed
        // this feed. Cap under the same flock as the append (takeLock: false
        // when we already hold it).
        let work: @Sendable () async throws -> Void = { [persistence] in
            try await appendJSONLCapped(
                run, to: path, using: persistence,
                maxLines: JSONLLineCaps.workflowRuns,
                logLabel: "WorkflowOrchestration.runs",
                takeLock: false
            )
        }
        if useFileLock {
            try await persistence.withFileLock(path, work)
        } else {
            try await work()
        }
    }

    private func appendWorkflowRunActivity(workflow: JSONValue, run: JSONValue, status: String) async throws {
        let workflowID = objectString(workflow, "id")
        let name = objectString(workflow, "name", fallback: workflowID)
        let runID = objectString(run, "id")
        try await appendActivity(
            kind: "workflow",
            title: "Workflow run recorded",
            detail: name.isEmpty ? workflowID : name,
            status: status == "succeeded" ? "ok" : "warn",
            payload: ["workflowRunId": .string(runID)]
        )
    }

    private func saveWorkflowState(_ state: JSONValue) async throws -> Bool {
        let runId = stateString(state, "id")
        if runId.isEmpty || runId == "None" {
            throw WorkflowOrchestrationError.unknownRunState(runId)
        }
        let path = runStatePath(runId)
        let work: @Sendable () async throws -> Bool = { [self] in
            let newStatus = stateString(state, "status")
            if !["canceled", "rolled_back"].contains(newStatus) {
                let current = await persistence.readJSON(path, defaultValue: .object([:]))
                let currentStatus = stateString(current, "status")
                if ["canceled", "rolled_back"].contains(currentStatus) {
                    return false
                }
            }
            try await persistence.writeJSON(state, to: path)
            return true
        }
        if useFileLock {
            return try await persistence.withFileLock(path, work)
        }
        return try await work()
    }

    private func committedTerminalStatus(runId: String) async throws -> String {
        let path = runStatePath(runId)
        let work: @Sendable () async throws -> String = { [self] in
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            let status = stateString(current, "status")
            return ["canceled", "rolled_back"].contains(status) ? status : ""
        }
        if useFileLock {
            return try await persistence.withFileLock(path, work)
        }
        return try await work()
    }

    private func workflowTerminalTakeover(_ state: JSONValue) async throws -> JSONValue {
        let runId = stateString(state, "id")
        var committed = await persistence.readJSON(runStatePath(runId), defaultValue: .object([:]))
        if case .object(let obj) = committed, obj.isEmpty {
            committed = setField(state, "status", .string("canceled"))
            committed = setField(committed, "updatedAt", .string(now()))
        }
        try await appendTrace(
            kind: "workflow.v2.write_dropped",
            title: stateString(committed, "workflowName") == "None" ? runId : stateString(committed, "workflowName"),
            payload: [
                "workflowRunId": .string(runId),
                "committedStatus": .string(stateString(committed, "status")),
            ]
        )
        return WorkflowRunState.publicRun(committed)
    }

    public func listWorkflows() async throws -> [JSONValue] {
        // The ENTIRE read -> merge -> write-back must be atomic under the
        // cross-process lock, otherwise a Python writer that commits between
        // our read and our locked write would be silently clobbered by our
        // stale-data write-back (gpt-5.5 review finding #1, 2026-06-01).
        let body: @Sendable () async throws -> [JSONValue] = { [persistence, registryPath, now] in
            let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
            let saved: [JSONValue]
            if case .array(let arr) = raw { saved = arr } else { saved = [] }
            let defaults = WorkflowDefaults.defaults(now: now())
            let (mergedUnsorted, sorted) = WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved)
            // Write back the merged (unsorted) registry, preserving retired semantics.
            try await persistence.writeJSON(.array(mergedUnsorted), to: registryPath)
            return sorted
        }
        if useFileLock {
            return try await persistence.withFileLock(registryPath, body)
        }
        return try await body()
    }

    public func listWorkflowRuns() async throws -> [JSONValue] {
        // Python: list(reversed(tail_jsonl(runs_path, 50)))
        let tail = try await persistence.tailJSONL(runsPath, limit: 50, maxBytes: 1_048_576)
        return tail.reversed()
    }

    /// Mirror of Runtime.record_activity for the workflow.save side-effect:
    /// record_activity("workflow", "Workflow saved", name, "ok",
    ///   payload={"workflowId": workflow_id}).
    /// Envelope = {id, kind, title, detail, status, missionId, payload, createdAt}.
    /// title/detail/payload are redacted (Python redact_secret_text /
    /// redact_secret_value at the retired daemon). missionId is null
    /// here (create_workflow passes no mission_id). The append is flock-wrapped
    /// because activity/events.jsonl is co-written by the daemon and any Swift
    /// activity emitter (mirrors Research.recordActivity), and Python's
    /// append_jsonl has no inner try/except so a write failure propagates — we
    /// keep that (this is `async throws`, caller `try`s it).
    private func appendActivity(kind: String, title: String, detail: String, status: String, payload: [String: JSONValue]) async throws {
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "title": .string(WorkflowRedaction.redactText(title)),
            "detail": .string(WorkflowRedaction.redactText(detail)),
            "status": .string(status),
            "executionId": .null,
            "payload": WorkflowRedaction.redactValue(.object(payload)),
            "createdAt": .string(now()),
        ])
        let activityURL = activityPath
        try await persistence.withFileLock(activityURL) {
            try await appendJSONLCapped(
                event,
                to: activityURL,
                using: persistence,
                maxLines: JSONLLineCaps.activityEvents,
                logLabel: "WorkflowOrchestration.activity",
                takeLock: false
            )
        }
    }

    public func createWorkflow(_ body: JSONValue) async throws -> JSONValue {
        // 1. Build the record (pure). Python stamps ONE now_iso() at the top of
        //    create_workflow and uses it for createdAt/updatedAt.
        let stampNow = now()
        let uuidFactory = uuid
        let built = try WorkflowCreate.buildRecord(body: body, now: stampNow, uuid: { uuidFactory() })
        let workflowId = built.id
        let workflow = built.record
        // Python's record_trace uses len(normalized_steps) — the UNCAPPED count.
        let uncappedStepCount = built.stepCount

        // 2. Persist into the registry. Python:
        //      with file_lock(self.workflows_path):
        //        workflows = [w for w in self._list_workflows_locked()
        //                       if str(w["id"]) != workflow_id]
        //        workflows.append(workflow)
        //        write_json(self.workflows_path, workflows)
        //    _list_workflows_locked() does the read+merge+WRITE-BACK of the
        //    defaults-merged registry (same as listWorkflows' inner body), THEN
        //    we filter+append+overwrite. The ENTIRE sequence runs inside ONE
        //    flock acquisition so a concurrent Python writer can't interleave.
        //    We call the lock-free merge here (NOT listWorkflows, which would
        //    re-acquire the SAME <path>.lock and deadlock — flock(2) is not
        //    recursive across fds; see Python's _list_workflows_locked note).
        let regPath = registryPath
        let nowFn = now
        let body2: @Sendable () async throws -> Void = { [persistence] in
            // _list_workflows_locked: read -> merge -> write-back merged (unsorted)
            // -> RETURN sorted. Python's workflow_defaults() takes a FRESH now_iso()
            // each call (not create's stampNow), so the default rows written back
            // carry their own timestamp (gpt-5.5 review finding #6, 2026-06-02).
            let raw = await persistence.readJSON(regPath, defaultValue: .array([]))
            let saved: [JSONValue]
            if case .array(let arr) = raw { saved = arr } else { saved = [] }
            let defaults = WorkflowDefaults.defaults(now: nowFn())
            let (mergedUnsorted, mergedSorted) = WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved)
            // _list_workflows_locked WRITES BACK the merged UNSORTED list...
            try await persistence.writeJSON(.array(mergedUnsorted), to: regPath)
            // ...then RETURNS the SORTED list. create_workflow filters THAT sorted
            // return, appends the new workflow, and overwrites. So the final
            // on-disk order = sorted(minus same-id) + new-at-end — NOT the unsorted
            // merge order (gpt-5.5 review finding #3, 2026-06-02).
            let kept = mergedSorted.filter { WorkflowMerge.idKey($0) != workflowId }
            let finalList = kept + [workflow]
            try await persistence.writeJSON(.array(finalList), to: regPath)
        }
        if useFileLock {
            try await persistence.withFileLock(regPath, body2)
        } else {
            try await body2()
        }

        // 3. Side-effects (outside the registry lock — different files):
        //    record_activity("workflow", "Workflow saved", name, "ok",
        //      payload={"workflowId": workflow_id})
        let name = WorkflowCreate.pyStr(WorkflowCreate.objField(workflow, "name"))
        try await appendActivity(
            kind: "workflow",
            title: "Workflow saved",
            detail: name,
            status: "ok",
            payload: ["workflowId": .string(workflowId)]
        )
        //    record_trace("workflow.save", name,
        //      {"workflowId": workflow_id, "stepCount": len(normalized_steps)})
        // stepCount = the UNCAPPED normalized count (Python uses len(normalized_
        // steps), NOT len(workflow["steps"]) which is the [:24]-capped list).
        try await appendTrace(
            kind: "workflow.save",
            title: name,
            payload: ["workflowId": .string(workflowId), "stepCount": .int(Int64(uncappedStepCount))]
        )
        return workflow
    }

    public func cancelWorkflowRun(id: String) async throws -> JSONValue {
        // Mirror of Runtime.cancel_workflow_run(body):
        //   state = workflow_state(run_id)
        //   state["status"] = "canceled"
        //   state["completedAt"] = now_iso()
        //   state["updatedAt"]   = now_iso()
        //   save_workflow_state(state)            # write run_state/<slug>.json
        //   record_trace("workflow.v2.cancel", ...)
        //   return workflow_public_run(state)
        //
        // The read -> mutate -> write of the per-run state file is wrapped in the
        // cross-process flock so a concurrent Python engine writer (which now also
        // takes file_lock on save_workflow_state — see W12 daemon patch) cannot
        // interleave between our read and our write and lose state.
        let statePath = runStatePath(id)
        let body: @Sendable () async throws -> JSONValue = { [self] in
            var state = try await loadState(id)
            // Python sets status/completedAt/updatedAt with TWO separate now_iso()
            // calls (completedAt then updatedAt). They can differ by microseconds;
            // mirror that by stamping each independently.
            state = setField(state, "status", .string("canceled"))
            state = setField(state, "completedAt", .string(now()))
            state = setField(state, "updatedAt", .string(now()))
            try await persistence.writeJSON(state, to: statePath)
            return state
        }
        let state: JSONValue
        if useFileLock {
            state = try await persistence.withFileLock(statePath, body)
        } else {
            state = try await body()
        }
        // record_trace runs OUTSIDE the run-state lock (different file). title is
        // str(state.get("workflowName") or run_id).
        let wfName = stateString(state, "workflowName")
        let title = (wfName == "None" || wfName.isEmpty) ? id : wfName
        try await appendTrace(
            kind: "workflow.v2.cancel",
            title: title,
            payload: ["workflowRunId": .string(id), "status": .string("canceled")]
        )
        return WorkflowRunState.publicRun(state)
    }

    public func rollbackWorkflowRun(id: String) async throws -> JSONValue {
        // Mirror of Runtime.rollback_workflow_run(body):
        //   state = workflow_state(run_id)
        //   rollback_receipts = [ {id: f"rollback:{r.id}", stepId: r.id,
        //       status:"rolled_back", detail:"...", createdAt: now_iso()}
        //       for r in reversed(state["steps"]) if r.status == "succeeded" ]
        //   state["status"] = "rolled_back"
        //   state["rollbackReceipts"] = rollback_receipts
        //   state["completedAt"] = now_iso(); state["updatedAt"] = now_iso()
        //   save_workflow_state(state)
        //   record_trace("workflow.v2.rollback", ...)
        //   return workflow_public_run(state) | {"rollbackReceipts": rollback_receipts}
        let statePath = runStatePath(id)
        // Returns both the mutated state (for trace title) and the receipts (for
        // the merged response), computed inside the lock from the freshest read.
        let result: (state: JSONValue, receipts: [JSONValue]) = try await {
            let body: @Sendable () async throws -> (JSONValue, [JSONValue]) = { [self] in
                var state = try await loadState(id)
                var receipts: [JSONValue] = []
                if case .object(let obj) = state, case .array(let steps)? = obj["steps"] {
                    for receipt in steps.reversed() {
                        guard case .object(let r) = receipt,
                              case .string(let st)? = r["status"], st == "succeeded" else { continue }
                        let rid: JSONValue = r["id"] ?? .null
                        // Python f"rollback:{receipt.get('id')}" — str() of the id.
                        let ridStr: String
                        switch rid {
                        case .string(let s): ridStr = s
                        case .null: ridStr = "None"
                        case .int(let i): ridStr = String(i)
                        case .double(let d): ridStr = String(d)
                        case .bool(let b): ridStr = b ? "True" : "False"
                        default: ridStr = ""
                        }
                        receipts.append(.object([
                            "id": .string("rollback:\(ridStr)"),
                            "stepId": rid,
                            "status": .string("rolled_back"),
                            "detail": .string("Compensation receipt recorded; no irreversible external action was performed."),
                            "createdAt": .string(now()),
                        ]))
                    }
                }
                state = setField(state, "status", .string("rolled_back"))
                state = setField(state, "rollbackReceipts", .array(receipts))
                state = setField(state, "completedAt", .string(now()))
                state = setField(state, "updatedAt", .string(now()))
                try await persistence.writeJSON(state, to: statePath)
                return (state, receipts)
            }
            if useFileLock {
                return try await persistence.withFileLock(statePath, body)
            }
            return try await body()
        }()
        let wfName = stateString(result.state, "workflowName")
        let title = (wfName == "None" || wfName.isEmpty) ? id : wfName
        try await appendTrace(
            kind: "workflow.v2.rollback",
            title: title,
            payload: [
                "workflowRunId": .string(id),
                "status": .string("rolled_back"),
                "rollbackCount": .int(Int64(result.receipts.count)),
            ]
        )
        // workflow_public_run(state) | {"rollbackReceipts": rollback_receipts}
        var pub = WorkflowRunState.publicRun(result.state)
        pub = setField(pub, "rollbackReceipts", .array(result.receipts))
        return pub
    }

    private func approvalClassRisk(_ step: JSONValue, defaultRisk: String = "medium") -> String {
        let approvalClass = objectString(step, "approvalClass")
        return ["external_send", "calendar_write", "computer_file_write"].contains(approvalClass)
            ? "high"
            : defaultRisk
    }

    private func createWorkflowApproval(
        workflow: JSONValue,
        step: JSONValue,
        stepId: String,
        title: String,
        objective: String,
        waitReason: Bool,
        runId: String? = nil
    ) async throws -> ApprovalRecord {
        let workflowName = objectString(workflow, "name")
        let workflowId = objectString(workflow, "id")
        let action = truthyString(
            objectField(step, "action") ?? objectField(step, "kind"),
            fallback: "workflow_step"
        )
        let reason = waitReason
            ? "Workflow \(workflowName) is waiting before step \(title)."
            : "Workflow \(workflowName) needs approval before step \(title)."
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string(approvalClassRisk(step)),
            "reason": .string(reason),
            // Sweep R4 B2: ApprovalInbox now fails CLOSED on an undeclared
            // `remoteResolvable`. A parked workflow step is the canonical
            // approve-from-your-phone case, so declare it explicitly rather
            // than inherit the old permissive default.
            "remoteResolvable": .bool(true),
            "payload": .object([
                "workflowRunId": .string(runId ?? ""),
                "workflowId": .string(workflowId),
                "stepId": .string(stepId),
                "objective": .string(objective),
            ]),
        ]))
        try await appendTrace(
            kind: "approval.request",
            title: approval.title,
            payload: [
                "approvalId": .string(approval.id),
                "risk": .string(approval.risk),
                "status": .string("pending"),
            ]
        )
        return approval
    }

    private func createWorkflowApproval(
        workflow: JSONValue,
        state: JSONValue,
        step: JSONValue,
        stepId: String,
        title: String
    ) async throws -> ApprovalRecord {
        let workflowName = objectString(workflow, "name")
        let workflowId = objectString(workflow, "id")
        let runId = stateString(state, "id")
        let objective = stateString(state, "objective")
        let action = truthyString(
            objectField(step, "action") ?? objectField(step, "kind"),
            fallback: "workflow_step"
        )
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string(approvalClassRisk(step)),
            "reason": .string("Workflow \(workflowName) is waiting before step \(title)."),
            // Sweep R4 B2: explicit remote-safe declaration (see the sibling
            // create above) now that an undeclared flag fails closed.
            "remoteResolvable": .bool(true),
            "payload": .object([
                "workflowRunId": .string(runId),
                "workflowId": .string(workflowId),
                "stepId": .string(stepId),
                "objective": .string(objective),
            ]),
        ]))
        try await appendTrace(
            kind: "approval.request",
            title: approval.title,
            payload: [
                "approvalId": .string(approval.id),
                "risk": .string(approval.risk),
                "status": .string("pending"),
            ]
        )
        return approval
    }

    /// True only when the resume-supplied resolved approval is EXACTLY the
    /// MCP-risk approval previously filed for THIS run + step + server + tool
    /// (the same five keys `executeMCPToolStep` writes into the approval
    /// payload). Without this, resuming a high-risk mcp_tool step files a
    /// FRESH risk approval on every re-dispatch and the run approve/parks
    /// forever (gpt-5.5 review 2026-06-09, blocker 1). The match is exact by
    /// design: an approval for step A must not clear step B's gate, and the
    /// OUTER workflow-gate approval (whose payload carries no
    /// serverId/toolName) does not clear the MCP risk gate either — the
    /// user still approves the tool-specific request once.
    private func resolvedApprovalSatisfiesMCPGate(
        _ approval: ApprovalRecord?,
        workflowId: String,
        runId: String?,
        stepId: String,
        serverId: String,
        toolName: String
    ) -> Bool {
        guard let approval, approval.decision == "approved" else { return false }
        guard let runId, !runId.isEmpty else { return false }
        let payload = approval.payload
        return objectString(payload, "workflowId") == workflowId
            && objectString(payload, "workflowRunId") == runId
            && objectString(payload, "stepId") == stepId
            && objectString(payload, "serverId") == serverId
            && objectString(payload, "toolName") == toolName
    }

    private func executeMCPToolStep(
        workflow: JSONValue,
        step: JSONValue,
        stepId: String,
        title: String,
        objective: String,
        runId: String?,
        resolvedApproval: ApprovalRecord? = nil
    ) async throws -> JSONValue {
        let serverId = truthyString(
            objectField(step, "serverId") ?? objectField(step, "server_id"),
            fallback: ""
        )
        let toolName = truthyString(
            objectField(step, "toolName") ?? objectField(step, "tool_name"),
            fallback: ""
        )
        if serverId.isEmpty || toolName.isEmpty {
            throw NSError(domain: "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "mcp_tool step requires serverId and toolName"
            ])
        }
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let servers = try await dispatcher.listServers()
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw NSError(domain: "WorkflowOrchestration", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "MCP server not found: \(serverId)"
            ])
        }
        let effectiveRisk = MCPToolBridge.effectiveRiskClass(
            serverId: serverId,
            toolName: toolName,
            serverRiskClass: server.riskClass,
            dataRoot: root
        )
        if MCPToolBridge.riskRequiresApproval(effectiveRisk) {
            let gateSatisfied = resolvedApprovalSatisfiesMCPGate(
                resolvedApproval,
                workflowId: objectString(workflow, "id"),
                runId: runId,
                stepId: stepId,
                serverId: serverId,
                toolName: toolName
            )
            if !gateSatisfied {
                let inbox = SwiftNativeApprovalInbox(root: root)
                let approval = try await inbox.create(.object([
                    "title": .string(title),
                    "action": .string("mcp_tool"),
                    "risk": .string(effectiveRisk),
                    "reason": .string("Workflow \(objectString(workflow, "name")) needs approval before MCP tool \(toolName) (risk=\(effectiveRisk))."),
                    // Sweep R4 B2: explicit remote-safe declaration — a parked
                    // MCP-tool gate is approve-from-your-phone by design.
                    "remoteResolvable": .bool(true),
                    "payload": .object([
                        "workflowId": .string(objectString(workflow, "id")),
                        "workflowRunId": .string(runId ?? ""),
                        "stepId": .string(stepId),
                        "serverId": .string(serverId),
                        "toolName": .string(toolName),
                        "objective": .string(objective),
                    ]),
                ]))
                try await appendTrace(
                    kind: "approval.request",
                    title: approval.title,
                    payload: [
                        "approvalId": .string(approval.id),
                        "risk": .string(approval.risk),
                        "status": .string("pending"),
                    ]
                )
                return .object([
                    "waitingApproval": .bool(true),
                    "approvalId": .string(approval.id),
                ])
            }
            // Gate satisfied by the resume-supplied resolved approval for THIS
            // exact run/step/server/tool: proceed to the live call. The
            // approval covers THIS call only, so deliberately do NOT persist
            // a consent record (a stored high-risk consent would let future
            // calls skip the gate).
        } else {
            let consents = try await dispatcher.listConsents()
            let hasConsent = consents.contains {
                $0.serverId == serverId
                    && $0.toolName == toolName
                    && MCPToolBridge.consent($0, matchesCurrentEffectiveRisk: effectiveRisk)
            }
            if !hasConsent {
                _ = try await dispatcher.grantConsent(MCPConsentGrant(
                    serverId: serverId,
                    toolName: toolName,
                    risk: effectiveRisk,
                    argumentSummary: "Auto-granted low-risk workflow MCP call."
                ))
            }
        }
        let input = objectMap(step, "input").isEmpty
            ? JSONValue.object(["objective": .string(objective)])
            : JSONValue.object(objectMap(step, "input"))
        let result = try await dispatcher.callToolLive(
            forServer: serverId,
            toolName: toolName,
            arguments: input
        )
        let status: String
        if case .object(let obj) = result, case .bool(true)? = obj["isError"] {
            status = "error"
        } else if case .object(let obj) = result, case .string(let s)? = obj["status"], !s.isEmpty {
            status = s
        } else {
            status = "ok"
        }
        return .object([
            "id": .string(uuid()),
            "status": .string(status),
            "result": result,
        ])
    }

    private func executeToolRunStep(step: JSONValue, objective: String) async throws -> JSONValue {
        let toolId = truthyString(
            objectField(step, "toolId") ?? objectField(step, "tool_id") ?? objectField(step, "tool"),
            fallback: ""
        )
        if toolId.isEmpty {
            throw NSError(domain: "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "tool_run step requires toolId"
            ])
        }
        let input = objectMap(step, "input").isEmpty
            ? JSONValue.object(["objective": .string(objective)])
            : JSONValue.object(objectMap(step, "input"))
        let result = try await SwiftNativeToolExecution(root: root).runTool(id: toolId, input: input)
        let status = objectString(result, "status", fallback: "ok")
        return .object([
            "id": .string(uuid()),
            "status": .string(status),
            "toolId": .string(toolId),
            "result": result,
        ])
    }

    private func executeWorkflowStep(
        workflow: JSONValue,
        step: JSONValue,
        objective: String,
        runId: String? = nil,
        approvalAlreadyResolved: Bool = false,
        resolvedApproval: ApprovalRecord? = nil
    ) async -> JSONValue {
        let stepId = truthyString(objectField(step, "id"), fallback: uuid())
        let title = truthyString(objectField(step, "title"), fallback: stepId)
        let kind = truthyString(objectField(step, "kind"), fallback: "manual")
        var receipt: [String: JSONValue] = [
            "id": .string(stepId),
            "title": .string(title),
            "kind": .string(kind),
            "status": .string("succeeded"),
            "requiresApproval": .bool(objectBool(step, "requiresApproval")),
            "detail": .string(""),
            "output": .object([:]),
        ]

        if !approvalAlreadyResolved, objectBool(step, "requiresApproval") || kind == "approval" {
            do {
                let approval = try await createWorkflowApproval(
                    workflow: workflow,
                    step: step,
                    stepId: stepId,
                    title: title,
                    objective: objective,
                    waitReason: false,
                    runId: runId
                )
                receipt["status"] = .string("waiting_approval")
                receipt["detail"] = .string("Approval request created.")
                receipt["approvalId"] = .string(approval.id)
            } catch {
                receipt["status"] = .string("failed")
                receipt["detail"] = .string(error.localizedDescription)
                receipt["error"] = .string(error.localizedDescription)
            }
            return .object(receipt)
        }

        do {
            switch kind {
            case "router":
                let route = try await SwiftNativeRouterPlanClient().planRoute(message: objective)
                receipt["detail"] = .string("Routed as \(route.goalType).")
                receipt["output"] = .object([
                    "routeId": .string(route.id),
                    "goalType": .string(route.goalType),
                    "route": route.toJSON(),
                ])
            case "research":
                let lab = try await SwiftNativeResearchClient(dataRoot: root)
                    .runResearchLab(objective: objective, maxResults: 3)
                receipt["detail"] = .string(lab.brief.isEmpty ? lab.status : lab.brief)
                receipt["output"] = .object([
                    "researchRunId": .string(lab.id),
                    "sourceCount": .int(Int64(lab.sources.count)),
                    "run": lab.toJSON(),
                ])
            case "memory":
                let layer = truthyString(objectField(step, "layer"), fallback: "semantic")
                let memory = try await memoryOwner.store(
                    content: objective,
                    source: "workflow:\(objectString(workflow, "id"))",
                    metadata: .object([
                        "layer": .string(layer),
                        "workflowId": .string(objectString(workflow, "id")),
                        "stepId": .string(stepId),
                    ])
                )
                receipt["detail"] = .string("Semantic memory written.")
                receipt["output"] = .object(["memoryId": .string(memory.id)])
            case "trace":
                let eventId = uuid()
                try await appendTrace(
                    kind: "workflow.step",
                    title: title,
                    payload: [
                        "workflowId": .string(objectString(workflow, "id")),
                        "stepId": .string(stepId),
                        "status": .string("ok"),
                        "traceId": .string(eventId),
                    ]
                )
                receipt["detail"] = .string("Trace receipt recorded.")
                receipt["output"] = .object(["traceId": .string(eventId)])
            case "mcp_tool":
                let output = try await executeMCPToolStep(
                    workflow: workflow,
                    step: step,
                    stepId: stepId,
                    title: title,
                    objective: objective,
                    runId: runId,
                    resolvedApproval: resolvedApproval
                )
                if case .object(let obj) = output,
                   case .bool(true)? = obj["waitingApproval"],
                   case .string(let approvalId)? = obj["approvalId"] {
                    receipt["status"] = .string("waiting_approval")
                    receipt["approvalId"] = .string(approvalId)
                    receipt["detail"] = .string("Approval request created.")
                } else {
                    let status = objectString(output, "status", fallback: "ok")
                    if status == "failed" || status == "error" {
                        receipt["status"] = .string("failed")
                        receipt["detail"] = .string("MCP tool returned \(status).")
                        receipt["error"] = objectField(objectField(output, "result") ?? .null, "error")
                            ?? objectField(objectField(output, "result") ?? .null, "detail")
                            ?? .string("mcp_tool returned \(status)")
                    } else {
                        receipt["detail"] = .string("MCP tool returned \(status).")
                    }
                    receipt["output"] = .object([
                        "mcpCallId": objectField(output, "id") ?? .null,
                        "status": .string(status),
                        "result": objectField(output, "result") ?? .null,
                    ])
                }
            case "tool_run":
                let output = try await executeToolRunStep(step: step, objective: objective)
                let status = objectString(output, "status", fallback: "ok")
                if status == "failed" || status == "error" {
                    receipt["status"] = .string("failed")
                    receipt["detail"] = .string("Tool \(objectString(output, "toolId")) returned \(status).")
                    receipt["error"] = objectField(objectField(output, "result") ?? .null, "error")
                        ?? objectField(objectField(output, "result") ?? .null, "detail")
                        ?? .string("tool_run returned \(status)")
                } else {
                    receipt["detail"] = .string("Tool \(objectString(output, "toolId")) returned \(status).")
                }
                receipt["output"] = .object([
                    "toolCallId": objectField(output, "id") ?? .null,
                    "toolId": objectField(output, "toolId") ?? .null,
                    "status": .string(status),
                    "result": objectField(output, "result") ?? .null,
                ])
            default:
                receipt["status"] = .string("failed")
                receipt["detail"] = .string("Unsupported step kind '\(kind)' — no Swift adapter; step did NOT execute.")
                receipt["error"] = .string("unsupported step kind: \(kind)")
            }
        } catch {
            receipt["status"] = .string("failed")
            receipt["detail"] = .string(error.localizedDescription)
            receipt["error"] = .string(error.localizedDescription)
        }
        return .object(receipt)
    }

    /// The v2 execute-with-retry loop: per-step attempts ledger + capped
    /// backoff between failed attempts. Factored out of continueWorkflowV2's
    /// `.execute` branch so the resume re-dispatch path shares EXACTLY the
    /// same retry semantics and `attempts` shape as normal execution instead
    /// of synthesizing a one-entry attempts array (gpt-5.5 review 2026-06-09,
    /// blocker 3). Returns the final receipt with `attempts` attached.
    /// Internal so the lifecycle tests can inject a suspending operation and
    /// prove the stored timeout is enforced at this exact retry boundary.
    func executeStepWithRetry(
        workflow: JSONValue,
        step: JSONValue,
        objective: String,
        runId: String,
        approvalAlreadyResolved: Bool = false,
        resolvedApproval: ApprovalRecord? = nil,
        operationOverride: (@Sendable () async -> JSONValue)? = nil,
        raceResolutionObserver: (@Sendable (UInt64) -> Void)? = nil,
        raceOverride: WorkflowStepRaceOverride? = nil
    ) async -> JSONValue {
        let maxAttempts = WorkflowRunState.maxAttempts(forStep: step)
        let timeoutSeconds = normalizedStepTimeoutSeconds(step)
        var attempts: [JSONValue] = []
        var receipt: JSONValue = .object([:])
        for attempt in 1...maxAttempts {
            // R2 (blueprint): before any RETRY dispatch (attempt >= 2), bail if
            // the run was canceled/rolled_back during the prior attempt OR its
            // backoff sleep — otherwise the retry loop keeps re-firing this
            // step's side-effecting mcp_tool/tool_run call. Checking at the loop
            // top (after any backoff) closes the cancel-during-backoff window.
            // committedTerminalStatus reads the run-state file fresh (written by
            // cancelWorkflowRun on another task); the run's terminal status is
            // then enforced by saveWorkflowState's canceled/rolled_back guard.
            // Attempt 1 is already gated by the caller's committedTerminalStatus
            // check. In-flight preemption of a single attempt is handled below
            // by raceStepAgainstCancel.
            if attempt > 1,
               let terminal = try? await committedTerminalStatus(runId: runId),
               !terminal.isEmpty {
                break
            }
            // R2 in-flight abort (blueprint follow-up): race the (possibly
            // side-effecting) dispatch against a cancel watcher, so a cancel
            // landing DURING this attempt cooperatively cancels the in-flight
            // mcp_tool/tool_run Task instead of letting it run to completion.
            let operation: @Sendable () async -> JSONValue = operationOverride ?? { [self] in
                await executeWorkflowStep(
                    workflow: workflow,
                    step: step,
                    objective: objective,
                    runId: runId,
                    approvalAlreadyResolved: approvalAlreadyResolved,
                    resolvedApproval: resolvedApproval
                )
            }
            let race: WorkflowStepRace
            if let raceOverride {
                // Deterministic test seam for retry-policy proof. Production
                // always uses the real hard-deadline owner below.
                race = await raceOverride(attempt, timeoutSeconds, operation)
            } else {
                race = await raceStepAgainstCancelOrTimeout(
                    runId: runId,
                    timeoutSeconds: timeoutSeconds,
                    resolutionObserver: raceResolutionObserver,
                    operation
                )
            }
            var suppressFurtherAttempts = false
            switch race {
            case .completed(let stepReceipt):
                receipt = stepReceipt
            case .canceled(let terminal):
                // Cancel landed mid-flight; the in-flight step Task was canceled.
                // Record an aborted attempt and stop — terminal resolution is
                // enforced by saveWorkflowState's canceled/rolled_back guard.
                let cid = truthyString(objectField(step, "id"), fallback: String(attempt))
                let ctitle = truthyString(objectField(step, "title"), fallback: cid)
                let ckind = truthyString(objectField(step, "kind"), fallback: "manual")
                let cterm = terminal.isEmpty ? "canceled" : terminal
                attempts.append(.object([
                    "attempt": .int(Int64(attempt)),
                    "status": .string("failed"),
                    "detail": .string("run \(cterm) during step; in-flight step aborted"),
                    "createdAt": .string(now()),
                ]))
                return .object([
                    "id": .string(cid),
                    "title": .string(ctitle),
                    "kind": .string(ckind),
                    "status": .string("failed"),
                    "detail": .string("Run \(cterm) during step; step aborted."),
                    "attempts": .array(attempts),
                ])
            case .timedOut(let seconds):
                // The deadline owner can stop waiting without proving that an
                // uncooperative side effect has actually terminated. Retrying
                // here could overlap the still-running attempt and duplicate
                // the external action. Treat timeout as terminal for this
                // retry loop until a future dispatcher can provide positive
                // termination acknowledgement.
                suppressFurtherAttempts = true
                let tid = truthyString(objectField(step, "id"), fallback: String(attempt))
                let ttitle = truthyString(objectField(step, "title"), fallback: tid)
                let tkind = truthyString(objectField(step, "kind"), fallback: "manual")
                let unit = seconds == 1 ? "second" : "seconds"
                receipt = .object([
                    "id": .string(tid),
                    "title": .string(ttitle),
                    "kind": .string(tkind),
                    "status": .string("failed"),
                    "detail": .string("Step timed out after \(seconds) \(unit)."),
                    "error": .string("workflow step deadline exceeded"),
                    "timedOut": .bool(true),
                    "timeoutSeconds": .int(Int64(seconds)),
                    "attemptTerminality": .string("unproven"),
                    "retryDisposition": .string("suppressed_unproven_terminality"),
                ])
            }
            var attemptRecord: [String: JSONValue] = [
                "attempt": .int(Int64(attempt)),
                "status": objectField(receipt, "status") ?? .null,
                "detail": objectField(receipt, "detail") ?? .null,
                "createdAt": .string(now()),
            ]
            for key in [
                "timedOut",
                "timeoutSeconds",
                "attemptTerminality",
                "retryDisposition",
            ] {
                if let value = objectField(receipt, key) {
                    attemptRecord[key] = value
                }
            }
            attempts.append(.object(attemptRecord))
            if suppressFurtherAttempts { break }
            if objectString(receipt, "status") != "failed" { break }
            let retry = objectMap(step, "retry")
            let delay = min(2.0, pyDouble(
                retry["backoffSeconds"] ?? retry["backoff_seconds"] ?? .int(0)
            ))
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return setField(receipt, "attempts", .array(attempts))
    }

    /// Result of racing a workflow step's dispatch against a cancel watcher.
    /// `internal` (not private) so the @testable suite can drive it directly.
    enum WorkflowStepRace: Sendable {
        case completed(JSONValue)
        case canceled(String)   // committed terminal status (canceled/rolled_back)
        case timedOut(Int)
    }

    typealias WorkflowStepRaceOverride = @Sendable (
        _ attempt: Int,
        _ timeoutSeconds: Int,
        _ operation: @escaping @Sendable () async -> JSONValue
    ) async -> WorkflowStepRace

    /// R2 in-flight abort (blueprint follow-up): run `op` (a possibly
    /// side-effecting step dispatch) while a sibling task observes the
    /// canonical run-state file for a committed cancel/rollback. The observer
    /// is kqueue/vnode driven, including cross-process atomic replacements; it
    /// performs one initial read to close the registration race and no idle
    /// polling. If cancel lands mid-flight,
    /// the coordinator cooperatively cancels the in-flight op Task (URLSession/
    /// subprocess dispatch observes cancellation) and reports `.canceled`.
    /// A dispatch-backed deadline resumes exactly once without structurally
    /// awaiting an operation that ignores cancellation; any late result is
    /// discarded. State correctness does NOT depend on process preemption:
    /// saveWorkflowState refuses to overwrite a committed canceled/rolled_back
    /// run, so a late-finishing side effect can't clobber canonical state.
    /// SCOPE (gpt-5.5 review): router/research/memory dispatch (URLSession/async)
    /// preempt promptly; tool_run (subprocess via a GCD-semaphore wait) and stdio
    /// mcp_tool (once the request is written) are NOT cooperatively cancellable and
    /// run to their own tool timeout even though the Workflow control path now
    /// resolves promptly. Process preemption there still needs cancellation-aware
    /// dispatch in ToolExecution/MCPDispatcher.
    func raceStepAgainstCancelOrTimeout(
        runId: String,
        timeoutSeconds: Int = 0,
        resolutionObserver: (@Sendable (UInt64) -> Void)? = nil,
        cancellationReadObserver: (@Sendable () -> Void)? = nil,
        _ op: @escaping @Sendable () async -> JSONValue
    ) async -> WorkflowStepRace {
        let watchesCancellation = !runId.isEmpty && runId != "None"
        let boundedTimeout = max(0, timeoutSeconds)
        guard watchesCancellation || boundedTimeout > 0 else {
            return .completed(await op())
        }
        let coordinator = WorkflowStepRaceCoordinator(resolutionObserver: resolutionObserver)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                coordinator.install(continuation)
                if boundedTimeout > 0 {
                    // Arm before launching the operation so queue saturation
                    // created by that operation cannot delay ownership of the
                    // deadline itself.
                    coordinator.armDeadline(timeoutSeconds: boundedTimeout)
                }
                let operationTask = Task {
                    coordinator.resolve(.completed(await op()))
                }
                coordinator.attachOperation(operationTask)
                if watchesCancellation {
                    let changes = FileChangeEvents(paths: [runStatePath(runId)])
                    let watcherTask = Task { [self] in
                        defer { changes.cancel() }
                        for await _ in changes.stream {
                            if Task.isCancelled { return }
                            cancellationReadObserver?()
                            if let terminal = try? await committedTerminalStatus(runId: runId),
                               !terminal.isEmpty {
                                coordinator.resolve(.canceled(terminal))
                                return
                            }
                        }
                    }
                    coordinator.attachWatcher(watcherTask)
                }
            }
        } onCancel: {
            coordinator.resolve(.canceled(""))
        }
    }

    // MARK: - run / resume
    //
    // Swift-owned run/resume engine. The v1 path records dry-run/live step
    // receipts. The v2 path owns condition checks, dependency blocking,
    // retry/backoff, approval pause/resume, output-key wiring, run-state
    // persistence, run ledgers, activity, and traces. Supported side-effecting
    // step kinds route through Swift modules: router, research, memory, trace,
    // tool_run, mcp_tool, and approval.

    private func workflowByID(_ workflowId: String) async throws -> JSONValue {
        let workflows = try await listWorkflows()
        guard let workflow = workflows.first(where: { WorkflowMerge.idKey($0) == workflowId }) else {
            throw NSError(domain: "WorkflowOrchestration", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown workflow: \(workflowId)"
            ])
        }
        return workflow
    }

    private func workflowObjective(_ explicit: String, workflow: JSONValue) -> String {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let desc = objectString(workflow, "description").trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { return desc }
        return objectString(workflow, "name").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runWorkflowV1(workflowId: String, workflow: JSONValue, objective: String, execute: Bool) async throws -> JSONValue {
        let started = now()
        let runId = uuid()
        var receipts: [JSONValue] = []
        for step in objectArray(workflow, "steps") {
            guard case .object = step else { continue }
            let receipt: JSONValue
            if execute {
                receipt = await executeWorkflowStep(
                    workflow: workflow,
                    step: step,
                    objective: objective,
                    runId: runId
                )
            } else {
                let stepId = truthyString(objectField(step, "id"), fallback: uuid())
                let title = truthyString(objectField(step, "title"), fallback: "Step")
                let kind = truthyString(objectField(step, "kind"), fallback: "manual")
                let requiresApproval = objectBool(step, "requiresApproval")
                receipt = .object([
                    "id": .string(stepId),
                    "title": .string(title),
                    "kind": .string(kind),
                    "status": .string(requiresApproval ? "waiting_approval" : "succeeded"),
                    "requiresApproval": .bool(requiresApproval),
                    "detail": .string(requiresApproval ? "Approval gate recorded." : "Dry-run receipt recorded."),
                ])
            }
            receipts.append(receipt)
            let status = objectString(receipt, "status")
            if ["waiting_approval", "failed"].contains(status) { break }
        }
        let status: String
        if receipts.contains(where: { objectString($0, "status") == "failed" }) {
            status = "failed"
        } else if receipts.contains(where: { objectString($0, "status") == "waiting_approval" }) {
            status = "waiting_approval"
        } else {
            status = "succeeded"
        }
        let run: JSONValue = .object([
            "id": .string(runId),
            "workflowId": .string(workflowId),
            "workflowName": objectField(workflow, "name") ?? .null,
            "objective": .string(objective),
            "status": .string(status),
            "mode": .string(execute ? "execute" : "dry_run"),
            "steps": .array(receipts),
            "createdAt": .string(started),
            "completedAt": status == "succeeded" ? .string(now()) : .null,
        ])
        try await appendRun(run)
        try await appendWorkflowRunActivity(workflow: workflow, run: run, status: status)
        try await appendTrace(
            kind: "workflow.run",
            title: objectString(workflow, "name", fallback: workflowId),
            payload: [
                "workflowRunId": .string(objectString(run, "id")),
                "status": .string(status),
            ]
        )
        return run
    }

    private func runWorkflowV2(workflow: JSONValue, objective: String, variables bodyVariables: JSONValue?) async throws -> JSONValue {
        let runId = uuid()
        var variables = objectMap(workflow, "variables")
        if case .object(let incoming)? = bodyVariables {
            for (key, value) in incoming { variables[key] = value }
        }
        let state: JSONValue = .object([
            "id": .string(runId),
            "workflowId": objectField(workflow, "id") ?? .null,
            "workflowName": objectField(workflow, "name") ?? .null,
            "objective": .string(objective),
            "engineVersion": .string("2"),
            "status": .string("running"),
            "mode": .string("execute"),
            "steps": .array([]),
            "variables": .object(variables),
            "outputs": .object([:]),
            "currentStepIndex": .int(0),
            "createdAt": .string(now()),
            "updatedAt": .string(now()),
            "completedAt": .null,
            "approvalId": .null,
            "activeStepTimeoutSeconds": .null,
        ])
        return try await continueWorkflowV2(workflow: workflow, state: state)
    }

    private func continueWorkflowV2(workflow: JSONValue, state initialState: JSONValue) async throws -> JSONValue {
        let steps = objectArray(workflow, "steps").filter {
            if case .object = $0 { return true }
            return false
        }
        var state = initialState
        var index = Int(WorkflowCreate.pyInt(objectField(state, "currentStepIndex") ?? .int(0)))
        var outputs = objectMap(state, "outputs")
        let variables = objectMap(state, "variables")
        var receipts = objectArray(state, "steps")
        var completedIds = Set(receipts.compactMap { receipt -> String? in
            guard objectString(receipt, "status") == "succeeded" else { return nil }
            return objectString(receipt, "id")
        })

        while index < steps.count {
            let step = steps[index]
            let stepId = truthyString(objectField(step, "id"), fallback: String(index))
            let title = truthyString(objectField(step, "title"), fallback: stepId)
            let kind = truthyString(objectField(step, "kind"), fallback: "manual")
            switch WorkflowRunState.decideStep(
                step: step,
                variables: variables,
                outputs: outputs,
                completedIds: completedIds
            ) {
            case .skip:
                receipts.append(.object([
                    "id": .string(stepId),
                    "title": .string(title),
                    "kind": .string(kind),
                    "status": .string("skipped"),
                    "detail": .string("Condition evaluated false."),
                    "attempts": .array([]),
                ]))
                index += 1
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "currentStepIndex", .int(Int64(index)))
                state = setField(state, "updatedAt", .string(now()))
                continue
            case .blocked(let missing):
                receipts.append(.object([
                    "id": .string(stepId),
                    "title": .string(title),
                    "kind": .string(kind),
                    "status": .string("blocked"),
                    "detail": .string("Waiting on dependency: \(missing.joined(separator: ", "))"),
                    "attempts": .array([]),
                ]))
                state = setField(state, "status", .string("blocked"))
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "currentStepIndex", .int(Int64(index)))
                state = setField(state, "updatedAt", .string(now()))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
                let run = WorkflowRunState.publicRun(state)
                try await appendRun(run)
                return run
            case .waitApproval:
                let runId = stateString(state, "id")
                let terminal = try await committedTerminalStatus(runId: runId)
                if !terminal.isEmpty {
                    state = setField(state, "status", .string(terminal))
                    return try await workflowTerminalTakeover(state)
                }
                let approval = try await createWorkflowApproval(
                    workflow: workflow,
                    state: state,
                    step: step,
                    stepId: stepId,
                    title: title
                )
                receipts.append(.object([
                    "id": .string(stepId),
                    "title": .string(title),
                    "kind": .string(kind.isEmpty ? "approval" : kind),
                    "status": .string("waiting_approval"),
                    "requiresApproval": .bool(true),
                    "approvalId": .string(approval.id),
                    "detail": .string("Approval request created."),
                    "attempts": .array([]),
                ]))
                state = setField(state, "status", .string("waiting_approval"))
                state = setField(state, "approvalId", .string(approval.id))
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "currentStepIndex", .int(Int64(index)))
                state = setField(state, "updatedAt", .string(now()))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
                let run = WorkflowRunState.publicRun(state)
                try await appendRun(run)
                try await appendTrace(
                    kind: "workflow.v2.wait",
                    title: objectString(workflow, "name", fallback: objectString(workflow, "id")),
                    payload: [
                        "workflowRunId": .string(runId),
                        "approvalId": .string(approval.id),
                        "status": .string("waiting_approval"),
                    ]
                )
                return run
            case .execute:
                let runId = stateString(state, "id")
                let terminal = try await committedTerminalStatus(runId: runId)
                if !terminal.isEmpty {
                    state = setField(state, "status", .string(terminal))
                    return try await workflowTerminalTakeover(state)
                }
                // Persist the exact policy selected for this attempt before
                // dispatch. The shared motor reader must not infer it later
                // from a workflow definition that may have changed.
                let activeTimeout = normalizedStepTimeoutSeconds(step)
                state = setField(
                    state,
                    "activeStepTimeoutSeconds",
                    activeTimeout > 0 ? .int(Int64(activeTimeout)) : .null
                )
                state = setField(state, "updatedAt", .string(now()))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
                let receipt = await executeStepWithRetry(
                    workflow: workflow,
                    step: step,
                    objective: stateString(state, "objective"),
                    runId: stateString(state, "id")
                )
                receipts.append(receipt)
                state = setField(state, "activeStepTimeoutSeconds", .null)
                if objectString(receipt, "status") == "waiting_approval" {
                    state = setField(state, "status", .string("waiting_approval"))
                    state = setField(state, "approvalId", objectField(receipt, "approvalId") ?? .null)
                    state = setField(state, "steps", .array(receipts))
                    state = setField(state, "currentStepIndex", .int(Int64(index)))
                    state = setField(state, "updatedAt", .string(now()))
                    if try await !saveWorkflowState(state) {
                        return try await workflowTerminalTakeover(state)
                    }
                    let run = WorkflowRunState.publicRun(state)
                    try await appendRun(run)
                    return run
                }
                if objectString(receipt, "status") == "failed" {
                    state = setField(state, "status", .string("failed"))
                    state = setField(state, "steps", .array(receipts))
                    state = setField(state, "currentStepIndex", .int(Int64(index)))
                    state = setField(state, "updatedAt", .string(now()))
                    state = setField(state, "failedStepId", .string(stepId))
                    if try await !saveWorkflowState(state) {
                        return try await workflowTerminalTakeover(state)
                    }
                    let run = WorkflowRunState.publicRun(state)
                    try await appendRun(run)
                    return run
                }
                let outputKey = truthyString(objectField(step, "outputKey"), fallback: "")
                if !outputKey.isEmpty {
                    outputs[outputKey] = objectField(receipt, "output") ?? .null
                }
                completedIds.insert(stepId)
                index += 1
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "outputs", .object(outputs))
                state = setField(state, "currentStepIndex", .int(Int64(index)))
                state = setField(state, "updatedAt", .string(now()))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
            }
        }

        state = setField(state, "status", .string("succeeded"))
        state = setField(state, "currentStepIndex", .int(Int64(index)))
        state = setField(state, "completedAt", .string(now()))
        state = setField(state, "updatedAt", .string(now()))
        if try await !saveWorkflowState(state) {
            return try await workflowTerminalTakeover(state)
        }
        let run = WorkflowRunState.publicRun(state)
        try await appendRun(run)
        try await appendTrace(
            kind: "workflow.v2.run",
            title: objectString(workflow, "name", fallback: objectString(workflow, "id")),
            payload: [
                "workflowRunId": .string(stateString(state, "id")),
                "status": .string("succeeded"),
            ]
        )
        return run
    }

    public func runWorkflow(id: String, objective: String, execute: Bool, engineVersion: String?, variables: JSONValue?) async throws -> JSONValue {
        let workflowId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = try await workflowByID(workflowId)
        let availability = WorkflowExecutionPreflight.evaluate(workflow: workflow)
        guard availability.isRunnable else {
            throw WorkflowOrchestrationError.workflowNotRunnable(
                id: workflowId,
                reasons: availability.reasons
            )
        }
        let resolvedEngine = (
            engineVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? engineVersion!
            : objectString(workflow, "engineVersion", fallback: "1")
        )
        let resolvedObjective = workflowObjective(objective, workflow: workflow)
        if ["2", "v2", "2.0"].contains(resolvedEngine) {
            return try await runWorkflowV2(
                workflow: workflow,
                objective: resolvedObjective,
                variables: variables
            )
        }
        return try await runWorkflowV1(
            workflowId: workflowId,
            workflow: workflow,
            objective: resolvedObjective,
            execute: execute
        )
    }

    public func resumeWorkflowRun(id: String) async throws -> JSONValue {
        let runId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = try await loadState(runId)
        guard stateString(state, "status") == "waiting_approval" else {
            return WorkflowRunState.publicRun(state)
        }
        let approvalId = stateString(state, "approvalId")
        guard !approvalId.isEmpty, approvalId != "None" else {
            throw NSError(domain: "WorkflowOrchestration", code: -403, userInfo: [
                NSLocalizedDescriptionKey: "Workflow approval has not been approved (run carries no approvalId)"
            ])
        }
        let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
        guard let approval = approvals.first(where: { $0.id == approvalId }) else {
            throw NSError(domain: "WorkflowOrchestration", code: -403, userInfo: [
                NSLocalizedDescriptionKey: "Workflow approval has not been approved (approval record missing)"
            ])
        }
        guard approval.decision == "approved" else {
            throw NSError(domain: "WorkflowOrchestration", code: -403, userInfo: [
                NSLocalizedDescriptionKey: "Workflow approval has not been approved"
            ])
        }
        // Claim the run BEFORE dispatching any side-effecting work. Two
        // concurrent resume calls can both pass the waiting_approval read
        // above; the compare-and-swap below — performed under the same
        // cross-process flock saveWorkflowState uses — lets exactly ONE
        // caller flip waiting_approval(approvalId) → running and execute.
        // The loser returns the committed state untouched (gpt-5.5 review
        // 2026-06-09, blocker 2). A crash after the claim parks the run at
        // "running" — the same stuck-state exposure the engine already has
        // once it advances past waiting_approval; the stuck-"running" reaper
        // is a known ledgered gap and out of scope here.
        let statePath = runStatePath(runId)
        let claim: @Sendable () async throws -> JSONValue? = { [self] in
            let current = try await loadState(runId)
            guard stateString(current, "status") == "waiting_approval",
                  stateString(current, "approvalId") == approvalId else {
                return nil
            }
            var claimed = setField(current, "status", .string("running"))
            claimed = setField(claimed, "updatedAt", .string(now()))
            try await persistence.writeJSON(claimed, to: statePath)
            return claimed
        }
        let claimedState: JSONValue?
        if useFileLock {
            claimedState = try await persistence.withFileLock(statePath, claim)
        } else {
            claimedState = try await claim()
        }
        guard let claimed = claimedState else {
            // Lost the race (or the run advanced / was canceled between the
            // unlocked read above and the locked re-read): surface the
            // committed state and execute NOTHING.
            return WorkflowRunState.publicRun(try await loadState(runId))
        }
        state = claimed
        let workflow = try await workflowByID(stateString(state, "workflowId"))
        var receipts = objectArray(state, "steps")
        let currentIndex = Int(WorkflowCreate.pyInt(objectField(state, "currentStepIndex") ?? .int(0)))
        let steps = objectArray(workflow, "steps").filter {
            if case .object = $0 { return true }
            return false
        }
        let gatedStep: JSONValue? = steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
        if let gatedStep,
           truthyString(objectField(gatedStep, "kind"), fallback: "manual") != "approval" {
            // The approval cleared the gate, but the step's real work has not
            // run yet — re-dispatch it through the SAME v2 retry loop as
            // normal execution, with the (already-resolved) gate bypassed and
            // the resolved approval threaded through so an exact-match
            // MCP-risk gate does not re-file (blockers 1 + 3). Record the
            // REAL execution receipt in place of the waiting_approval one.
            let activeTimeout = normalizedStepTimeoutSeconds(gatedStep)
            state = setField(
                state,
                "activeStepTimeoutSeconds",
                activeTimeout > 0 ? .int(Int64(activeTimeout)) : .null
            )
            state = setField(state, "updatedAt", .string(now()))
            if try await !saveWorkflowState(state) {
                return try await workflowTerminalTakeover(state)
            }
            let executed = await executeStepWithRetry(
                workflow: workflow,
                step: gatedStep,
                objective: stateString(state, "objective"),
                runId: runId,
                approvalAlreadyResolved: true,
                resolvedApproval: approval
            )
            state = setField(state, "activeStepTimeoutSeconds", .null)
            if let waitingIdx = receipts.lastIndex(where: { objectString($0, "status") == "waiting_approval" }) {
                receipts[waitingIdx] = executed
            } else {
                receipts.append(executed)
            }
            let executedStatus = objectString(executed, "status")
            if executedStatus == "waiting_approval" {
                // The step's own dispatch raised a NEW approval (e.g. the MCP
                // risk gate). Park the run on that approval, same as the
                // continueWorkflowV2 waiting branch.
                state = setField(state, "status", .string("waiting_approval"))
                state = setField(state, "approvalId", objectField(executed, "approvalId") ?? .null)
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "updatedAt", .string(now()))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
                let run = WorkflowRunState.publicRun(state)
                try await appendRun(run)
                return run
            }
            if executedStatus == "failed" {
                state = setField(state, "status", .string("failed"))
                state = setField(state, "steps", .array(receipts))
                state = setField(state, "updatedAt", .string(now()))
                state = setField(state, "failedStepId", .string(objectString(executed, "id")))
                if try await !saveWorkflowState(state) {
                    return try await workflowTerminalTakeover(state)
                }
                let run = WorkflowRunState.publicRun(state)
                try await appendRun(run)
                return run
            }
            let outputKey = truthyString(objectField(gatedStep, "outputKey"), fallback: "")
            if !outputKey.isEmpty {
                var outputs = objectMap(state, "outputs")
                outputs[outputKey] = objectField(executed, "output") ?? .null
                state = setField(state, "outputs", .object(outputs))
            }
        } else {
            // Pure approval gate (kind == "approval"): no real work behind it,
            // flipping the receipt IS the resolution.
            for idx in receipts.indices.reversed() {
                if objectString(receipts[idx], "status") == "waiting_approval" {
                    receipts[idx] = setField(receipts[idx], "status", .string("succeeded"))
                    receipts[idx] = setField(receipts[idx], "detail", .string("Approval resolved; workflow resumed."))
                    break
                }
            }
        }
        let nextIndex = currentIndex + 1
        state = setField(state, "steps", .array(receipts))
        state = setField(state, "currentStepIndex", .int(Int64(nextIndex)))
        state = setField(state, "status", .string("running"))
        state = setField(state, "approvalId", .null)
        state = setField(state, "updatedAt", .string(now()))
        return try await continueWorkflowV2(workflow: workflow, state: state)
    }
}

/// Resume-once owner for a Workflow step's operation, cancellation watcher,
/// and native-thread hard deadline. Unlike a structured task group, timeout
/// resolution does not await a losing operation that ignored cooperative
/// cancellation. State correctness remains at the caller's canonical CAS
/// boundary; a late operation result is discarded by `resolve`.
private final class WorkflowStepRaceCoordinator: @unchecked Sendable {
    typealias Race = SwiftNativeWorkflowOrchestrationClient.WorkflowStepRace

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Race, Never>?
    private var pending: Race?
    private var resolved = false
    private var operationTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var deadlineSignal: DispatchSemaphore?
    private var deadlineThread: Thread?
    private let resolutionObserver: (@Sendable (UInt64) -> Void)?

    init(resolutionObserver: (@Sendable (UInt64) -> Void)?) {
        self.resolutionObserver = resolutionObserver
    }

    func install(_ continuation: CheckedContinuation<Race, Never>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(returning: pending)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func attachOperation(_ task: Task<Void, Never>) {
        attach(task, to: \Self.operationTask)
    }

    func attachWatcher(_ task: Task<Void, Never>) {
        attach(task, to: \Self.watcherTask)
    }

    private func attach(
        _ task: Task<Void, Never>,
        to keyPath: ReferenceWritableKeyPath<WorkflowStepRaceCoordinator, Task<Void, Never>?>
    ) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
        } else {
            self[keyPath: keyPath] = task
            lock.unlock()
        }
    }

    /// Waits on an absolute monotonic deadline without using the cooperative
    /// executor or a global Dispatch queue. Both were observed resolving many
    /// seconds late under full-suite saturation. Any earlier winner signals
    /// the semaphore so this dedicated waiter exits immediately.
    func armDeadline(timeoutSeconds: Int) {
        let signal = DispatchSemaphore(value: 0)
        let boundedSeconds = max(0, timeoutSeconds)
        let (timeoutNanos, timeoutOverflow) = UInt64(boundedSeconds)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let (deadlineNanos, deadlineOverflow) = nowNanos
            .addingReportingOverflow(timeoutNanos)
        let deadline = DispatchTime(
            uptimeNanoseconds: timeoutOverflow || deadlineOverflow
                ? UInt64.max
                : deadlineNanos
        )
        let thread = Thread { [weak self] in
            guard signal.wait(timeout: deadline) == .timedOut else { return }
            self?.resolve(.timedOut(boundedSeconds))
        }
        thread.name = "NativeAgent.WorkflowDeadline"
        thread.qualityOfService = .userInitiated

        lock.lock()
        if resolved {
            lock.unlock()
            signal.signal()
        } else {
            deadlineSignal = signal
            deadlineThread = thread
            lock.unlock()
            thread.start()
        }
    }

    func resolve(_ result: Race) {
        let continuation: CheckedContinuation<Race, Never>?
        let operationTask: Task<Void, Never>?
        let watcherTask: Task<Void, Never>?
        let deadlineSignal: DispatchSemaphore?
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        operationTask = self.operationTask
        watcherTask = self.watcherTask
        deadlineSignal = self.deadlineSignal
        self.operationTask = nil
        self.watcherTask = nil
        self.deadlineSignal = nil
        self.deadlineThread = nil
        lock.unlock()

        resolutionObserver?(DispatchTime.now().uptimeNanoseconds)
        deadlineSignal?.signal()
        operationTask?.cancel()
        watcherTask?.cancel()
        continuation?.resume(returning: result)
    }
}
