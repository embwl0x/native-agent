import Foundation
import NativeAgentCore
import PersistenceCore
import WorkshopExecution

// MARK: - Subsystem #17 WAVE 33 W18 (2026-06-01): scheduler-job create write port
//                       WAVE 35 W14 (2026-06-02): cancel write port (+ update audit)
//                       WAVE 36 W18 (2026-06-02): fire_now audit (§6.138 — nothing to port)
//                       WAVE 38 W15 (2026-06-02): list READ port (+ pause/resume audit, §6.180)
//
// Ports the WRITE side of `/v1/scheduler/jobs` (POST → create_job) into the
// SwiftNative TriggerScheduler. The daemon path is:
//
//   POST /v1/scheduler/jobs  → Daemon.create_job(body)
//                              → normalize_scheduler_job_payload   (L43524)
//                              → flock'd append to scheduler/jobs.json
//                              → record_activity("scheduler", ...) (L5260 → activity/events.jsonl)
//
// WAVE 35 W14 — cancel + update audit (cluster `/v1/scheduler/jobs/<id>/{cancel,update}`):
//   The cluster name describes HTTP routes that DO NOT EXIST. Re-verified this
//   wave against the retired daemon + a full-repo grep:
//     * There is NO `/v1/scheduler/jobs/<id>/cancel` HTTP route. `cancel_job`
// is reachable ONLY through the connector-action
//       dispatch `scheduler.cancel_job` (L21348). It IS a real, portable daemon
//       method, so this wave ports it natively as `cancelJob(jobId:)` for parity
//       with the create write — the SwiftNative write surface now owns the same
//       jobs.json mutations the daemon's connector path performs.
//     * There is NO `/v1/scheduler/jobs/<id>/update` route AND no `update_job`
//       method, connector action, reschedule/edit/modify/toggle, or any other
//       update surface anywhere in the daemon (grep-confirmed). The only
//       mutations of an existing job are `cancel_job` (above) and the internal
//       `scheduler_loop` advancing nextRunAt/lastRunAt each tick. Per AUDIT-FIRST
//       there is NOTHING to port for "update" — inventing an updateJob would
//       create a Swift behavior with no daemon parity reference. KEPT_NO_NATIVE_IMPL;
//       retirement_path documented in CUTOVER_PLAN §6.117.
// The audit (script/audit_v1_routes.py) lists `/v1/scheduler/jobs` GET as
// LEGACY and POST at L52993.
//
// WAVE 36 W18 — fire_now audit (cluster `/v1/scheduler/triggers/<name>/fire_now`):
//   Same AUDIT-FIRST result as the W14 cancel/update audit — re-verified this
//   wave against the retired daemon + a full-repo grep:
//     * There is NO `/v1/scheduler/triggers/<name>/fire_now` HTTP route. The
//       cluster name describes a route that does not exist.
//     * The job-level "fire now" semantic IS `Daemon.run_job` (the retired daemon
//       L44116) — run a scheduled job's action on demand. But `run_job` is
//       reachable ONLY from the in-process `scheduler_loop` (the SOLE
//       `self.run_job(` call site, L44054): NO HTTP route, NO connector action,
//       no `scheduler.run_job` / `scheduler.fire_*` / `scheduler.trigger_*`
//       dispatch id (the scheduler dispatch surface is exactly the four ids
//       create/schedule, list, cancel — L21337-L21355). It is a daemon-internal
//       BACKGROUND-LOOP method. Disposition: KEPT_DAEMON_INTERNAL — porting it
//       would create a Swift write surface with no daemon parity reference
//       (the same anti-pattern W14 avoided for "update"). RETIREMENT PATH:
//       migrates with the scheduler_loop in the broader BackgroundLoops cutover
//       (subsystem #15), post-daemon-HTTP-deprecation.
//     * The ACTUAL fire_now surfaces are the TRIGGER fire_now routes, already
//       ported/retired in prior waves and NOT a scheduler-jobs concern:
//         - `/v1/inbox/triggers/<name>/fire_now`  — Swift-native for stub=true
//           canonical kinds (wave 12); stub=false returns an explicit
//           unsupported envelope unless a test injects a compatibility fallback.
//         - `/v1/missions/triggers/<name>/fire_now` — Swift-native (wave 21);
//           daemon route retired wave 28; Swift-native is the only path.
//   Pinned by SchedulerFireNowAuditTests so a future wave does not re-open this
//   by inventing a Swift `runJob`/`fireJob`. retirement_path documented in
//   CUTOVER_PLAN §6.138.
//
// WAVE 39 W17 — `/v1/scheduler/jobs/<id>/run` audit (cluster
// `/v1/scheduler/jobs/<id>/run port`, §6.201):
//   The "run = trigger-on-demand" framing is the JOB-LEVEL restatement of the
//   wave-36 W18 finding above. Re-verified against the retired daemon in THIS
//   checkout: there is NO `/v1/scheduler/jobs/<id>/run` HTTP route (never has
//   been — `GET`/`POST /v1/scheduler/jobs` are the ENTIRE scheduler-jobs HTTP
//   surface), NO `scheduler.run_*` / `fire_*` / `trigger_*` connector action,
//   and `Daemon.run_job` is still defined once and called from exactly one site
//   (the in-process `scheduler_loop`). On-demand "run this job now" therefore
//   has no HTTP/connector parity reference to port against. Disposition:
//   KEPT_DAEMON_INTERNAL (unchanged from W18). Porting `run_job` standalone
//   would invent a Swift write surface with no daemon parity (the W14 "update"
//   anti-pattern). RETIREMENT PATH unchanged: migrates with `scheduler_loop` in
//   the BackgroundLoops cutover (subsystem #15), post-daemon-HTTP-deprecation.
//   Now pinned BY THE `/run` LITERAL in SchedulerFireNowAuditTests
//   (`runJob_hasNoOnDemandSurface`) so the run-cluster name itself can't be
//   re-opened.
//
// WAVE 38 W15 — list READ port + pause/resume audit (cluster
// `/v1/scheduler/jobs list+pause+resume`):
//   * list IS real and portable. `Daemon.list_jobs`
//     backs BOTH the GET `/v1/scheduler/jobs` route (L52221, audit=LEGACY,
//     live Mac-UI callers via NativeClient.getJobs) AND the `scheduler.list_jobs`
//     connector action (L21402). It reads the SAME scheduler/jobs.json the
//     native createJob/cancelJob already mutate, under the SAME
//     `self.jobs_lock, self._jobs_file_lock()` guard, then decorates each row's
//     `nextRunAt`: parse the stored float-string epoch → ISO-8601 UTC, set
//     `nextRunAtEpoch` (float), `nextRunAt`=ISO, `nextRunAtISO`=ISO. This wave
//     ports it natively as `listJobs()`, completing read/write parity on the
//     native scheduler-jobs surface. The decoration ISO is produced by
//     `epochToDecorationISO` — a FAITHFUL `datetime.fromtimestamp(e, UTC)
//     .isoformat()` mirror (integral epochs omit fractional seconds; fractional
//     epochs render microsecond precision) — DISTINCT from `isoTimestamp`
//     (always millisecond), because the daemon's decoration matches Python
//     isoformat, not now_iso().
//   * pause / resume DO NOT EXIST. Re-verified this wave against
//     the retired daemon + a full-repo grep:
//       - There is NO `/v1/scheduler/jobs/<id>/pause` or `/resume` HTTP route.
//       - There is NO `pause_job` / `resume_job` / `enable_job` / `disable_job`
//         / `toggle_job` method, and NO `scheduler.pause` / `scheduler.resume`
//         / `scheduler.enable` / `scheduler.disable` / `scheduler.toggle`
//         connector action. The ENTIRE scheduler dispatch surface is exactly
//         the four ids create/schedule, list, cancel (L21176-L21179). The only
//         `resume` in the daemon is `resume_workflow_run` (L7343) — a
//         WORKFLOWS concern, not scheduler-jobs.
//       - The closest semantic is `enabled=False` (set by cancel_job) — there
//         is no inverse "re-enable" surface; a cancelled job stays disabled.
//     Per AUDIT-FIRST there is NOTHING to port for pause/resume — inventing a
//     pauseJob/resumeJob would create a Swift write surface with no daemon
//     parity reference (the exact anti-pattern W14 avoided for "update").
//     Disposition: KEPT_NO_NATIVE_IMPL. Pinned by SchedulerJobListTests +
//     SchedulerFireNowAuditTests so a future wave does not re-open this.
//     retirement_path documented in CUTOVER_PLAN §6.180.
//
// SCOPE / BOUNDARY:
//   - FULLY native for all eight job kinds: notify, connector_action, dream,
//     improve, harness_benchmark, proactive_scan, rem, and workshop. Schedule computation is ported
//     byte-for-byte across all seven schedule types (once / every / hourly /
//     daily / weekly / monthly / cron) including the cron field parser.
//   - `connector_action` validates `payload.actionId` against the Swift
//     ConnectorActionsRegistry and persists `payload.input` as the action input.
//   - The scheduler job store is Swift-native. Swift periodic loops and trigger
//     evaluation are app-owned; arbitrary due-job execution uses the same
//     connector/action runners that own those effects.
//
// The production Swift caller is NativeClient.createJob(name:kind:intervalSeconds:)
// (→ AppModel.createDreamJob). The connector-action create path is reachable
// ONLY through the daemon's own dispatcher (scheduler.create_job), never the
// Swift HTTP seam, so delegating that one branch costs the native path nothing
// the Swift surface actually exercises.
//
// PARITY DIVERGENCES (documented, accepted — same class as Connectors W20):
//   - createdAt / activity createdAt: millisecond precision vs Python's
//     microsecond now_iso(). Informational, sortable, never byte-compared.
//   - notify title/name default uses `displayNameFallback` ("NativeAgent" =
//     APP) rather than the live personality profile name from
//     agent_display_name(). The production caller always supplies an explicit
//     name + title, so this only differs for a name-less notify job.
//
// See CUTOVER_PLAN.md §6.96.

// MARK: - Errors (scheduler-job specific)

extension TriggerSchedulerError {
    /// ValueError raised by normalize_scheduler_job_payload — surfaced as a
    /// 400-equivalent invalidRequest with the daemon's exact message text.
    static func schedulerInvalid(_ msg: String) -> TriggerSchedulerError {
        .invalidRequest(msg)
    }
}

// MARK: - Protocol extension

/// The job-create surface. Kept on its own protocol so compatibility fallbacks
/// and the SwiftNative impl share one contract.
public protocol SchedulerJobWriter: Sendable {
    /// Mirrors POST /v1/scheduler/jobs → create_job(body). `body` is the raw
    /// request dict (name/kind/interval_seconds/schedule/payload/run_at/...).
    /// Returns the persisted job dict (the daemon returns `job` verbatim).
    func createJob(body: JSONValue) async throws -> JSONValue

    /// Mirrors `Daemon.cancel_job(job_id)` — the
    /// connector-action `scheduler.cancel_job` backing call. Disables the job
    /// (`enabled=False`) and stamps `cancelledAt`, then appends a "warn"
    /// scheduler activity event. Returns `{"ok": true, "job": <updated job>}`.
    /// Throws `.invalidRequest` for a blank id (Python `ValueError("jobId is
    /// required")`) or an unknown id (`ValueError("Unknown scheduled job: …")`).
    func cancelJob(jobId: String) async throws -> JSONValue

    /// Mirrors `Daemon.list_jobs` — the READ side of
    /// `/v1/scheduler/jobs` (GET) and the `scheduler.list_jobs` connector action.
    /// Reads scheduler/jobs.json under the cross-process flock, coerces a
    /// non-list to `[]`, and decorates each row's `nextRunAt` (float-string
    /// epoch → ISO-8601 UTC; adds `nextRunAtEpoch` + `nextRunAtISO`). Returns the
    /// decorated array verbatim (`[JSONValue]`).
    func listJobs() async throws -> [JSONValue]

    /// Idempotently install a user-selected blueprint as one canonical job.
    /// An active row with the same blueprint id/version is retained exactly;
    /// a cancelled or older row is replaced in place. No passive/background
    /// path calls this mutation.
    func installBlueprintJob(body: JSONValue) async throws -> JSONValue
}

public extension SchedulerJobWriter {
    func installBlueprintJob(body: JSONValue) async throws -> JSONValue {
        throw TriggerSchedulerError.schedulerInvalid("blueprint installation is unavailable")
    }
}

// MARK: - SwiftNative create-job impl

extension SwiftNativeTriggerScheduler: SchedulerJobWriter {
    public nonisolated var jobsPath: URL {
        root
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    public nonisolated var activityPath: URL {
        root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Faithful port of Daemon.create_job:
    ///   job = normalize_scheduler_job_payload(body)
    ///   with jobs_lock, _jobs_file_lock(): append + write jobs.json
    ///   record_activity("scheduler", "Scheduled job created", ...)
    ///   return job
    ///
    /// connector_action kind validates against the Swift registry before write.
    public func createJob(body: JSONValue) async throws -> JSONValue {
        guard case .object(let obj) = body else {
            throw TriggerSchedulerError.schedulerInvalid("request body must be a JSON object")
        }

        let job = try SchedulerJobNormalizer.normalize(
            body: obj,
            now: now,
            uuid: uuid,
            displayNameFallback: Self.displayNameFallback,
            connectorActionIDs: connectorActionIDs
        )

        // Serialize Swift-side writes, and hold the cross-process flock on
        // <jobs.json>.lock so the daemon's scheduler_loop / save_jobs can't
        // race a torn write (wave 31 W16 symmetry).
        _ = try await runSerialized { [persistence, jobsPath, activityPath, now, uuid] () async throws -> Int in
            let work: @Sendable () async throws -> Void = {
                // read-modify-write: append the new job (matches daemon).
                let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
                var jobs: [JSONValue]
                if case .array(let arr) = raw { jobs = arr } else { jobs = [] }
                jobs.append(job)
                do {
                    try await persistence.writeJSON(.array(jobs), to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(jobsPath, work)

            // record_activity("scheduler", "Scheduled job created", ...) →
            // activity/events.jsonl. Swift-owned append (mirror Connectors W20):
            // one-sided flock serializes concurrent Swift writers; the daemon's
            // append_jsonl is unlocked and unaffected.
            let jobObj: [String: JSONValue]
            if case .object(let o) = job { jobObj = o } else { jobObj = [:] }
            let jobName = SchedulerJobNormalizer.string(jobObj["name"]) ?? ""
            let jobKind = SchedulerJobNormalizer.string(jobObj["kind"]) ?? ""
            let event: JSONValue = .object([
                "id": .string(uuid()),
                "kind": .string("scheduler"),
                "title": .string(SchedulerSecretRedactor.redactText("Scheduled job created")),
                "detail": .string(SchedulerSecretRedactor.redactText("\(jobName) · \(jobKind)")),
                "status": .string("ok"),
                "executionId": .null,
                "payload": SchedulerSecretRedactor.redactValue(.object([
                    "jobId": jobObj["id"] ?? .null,
                    "kind": jobObj["kind"] ?? .null,
                    "intervalSeconds": jobObj["intervalSeconds"] ?? .null,
                    "oneShot": jobObj["oneShot"] ?? .null,
                ])),
                "createdAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(now())),
            ])
            let activityWork: @Sendable () async throws -> Void = {
                try await appendJSONLCapped(
                    event,
                    to: activityPath,
                    using: persistence,
                    maxLines: JSONLLineCaps.activityEvents,
                    logLabel: "SchedulerJobs.create.activity",
                    takeLock: false
                )
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(activityPath, activityWork)
            return 0
        }

        return job
    }

    public func installBlueprintJob(body: JSONValue) async throws -> JSONValue {
        guard case .object(let requested) = body,
              case .string(let requestedID)? = requested["id"],
              !requestedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .object(let requestedPayload)? = requested["payload"],
              case .string(let blueprintID)? = requestedPayload["blueprintId"],
              case .int(let blueprintVersion)? = requestedPayload["blueprintVersion"],
              blueprintVersion > 0 else {
            throw TriggerSchedulerError.schedulerInvalid(
                "blueprint jobs require id, payload.blueprintId, and payload.blueprintVersion"
            )
        }
        let normalized = try SchedulerJobNormalizer.normalize(
            body: requested,
            now: now,
            uuid: uuid,
            displayNameFallback: Self.displayNameFallback,
            connectorActionIDs: connectorActionIDs
        )
        let result: (status: String, job: JSONValue) = try await runSerialized {
            [persistence, jobsPath] () async throws -> (String, JSONValue) in
            try await persistence.withFileLock(jobsPath) {
                let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
                var jobs: [JSONValue]
                if case .array(let rows) = raw { jobs = rows } else { jobs = [] }

                let index = jobs.firstIndex { row in
                    guard case .object(let object) = row,
                          case .string(let id)? = object["id"] else { return false }
                    return id == requestedID
                }
                if let index,
                   case .object(let existing) = jobs[index],
                   case .bool(true)? = existing["enabled"],
                   case .object(let existingPayload)? = existing["payload"],
                   case .string(let existingBlueprintID)? = existingPayload["blueprintId"],
                   existingBlueprintID == blueprintID,
                   case .int(let existingBlueprintVersion)? = existingPayload["blueprintVersion"],
                   existingBlueprintVersion == blueprintVersion {
                    return ("already_present", jobs[index])
                }

                let status: String
                if let index {
                    jobs[index] = normalized
                    status = "repaired"
                } else {
                    jobs.append(normalized)
                    status = "installed"
                }
                do {
                    try await persistence.writeJSON(.array(jobs), to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return (status, normalized)
            }
        }
        if result.status != "already_present" {
            let event: JSONValue = .object([
                "id": .string(uuid()),
                "kind": .string("scheduler"),
                "title": .string(SchedulerSecretRedactor.redactText("Automation blueprint \(result.status)")),
                "detail": .string(SchedulerSecretRedactor.redactText(blueprintID)),
                "status": .string("ok"),
                "executionId": .null,
                "payload": SchedulerSecretRedactor.redactValue(.object([
                    "jobId": .string(requestedID),
                    "blueprintId": .string(blueprintID),
                    "blueprintVersion": .int(blueprintVersion),
                    "installStatus": .string(result.status),
                ])),
                "createdAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(now())),
            ])
            let eventPath = activityPath
            let eventPersistence = persistence
            try await eventPersistence.withFileLock(eventPath) {
                try await appendJSONLCapped(
                    event,
                    to: eventPath,
                    using: eventPersistence,
                    maxLines: JSONLLineCaps.activityEvents,
                    logLabel: "SchedulerJobs.blueprint.activity",
                    takeLock: false
                )
            }
        }
        return .object([
            "status": .string(result.status),
            "job": result.job,
        ])
    }

    /// Faithful port of Daemon.cancel_job:
    ///   if not job_id: raise ValueError("jobId is required")
    ///   with jobs_lock, _jobs_file_lock():
    ///       jobs = read_json(...) (coerce non-list → [])
    ///       target = first job where str(job["id"]) == job_id
    ///           job["enabled"] = False; job["cancelledAt"] = now_iso()
    ///       if target is None: raise ValueError("Unknown scheduled job: …")
    ///       write_json(jobs)
    ///   record_activity("scheduler", "Scheduled job cancelled",
    ///                    str(target.name or job_id), "warn", payload={"jobId": …})
    ///   return {"ok": True, "job": dict(target)}
    ///
    /// Note: unlike `create_job`, the daemon's `cancel_job` was NOT exposed on an
    /// HTTP route — it is the backing call for the `scheduler.cancel_job`
    /// connector action. This SwiftNative impl gives
    /// the native write surface parity with that mutation. No connector-registry
    /// validation is involved for cancel because it takes only a job id.
    public func cancelJob(jobId: String) async throws -> JSONValue {
        // Python: `if not job_id:` — empty string is falsey. (The daemon receives
        // an already-`.strip()`ed id from the connector dispatch; we mirror the
        // method's own guard, which is the raw-emptiness check.)
        if jobId.isEmpty {
            throw TriggerSchedulerError.schedulerInvalid("jobId is required")
        }

        // Hold the cross-process flock on <jobs.json>.lock across the whole
        // read-modify-write so the daemon's scheduler_loop / save_jobs can't race
        // a torn write (wave 31 W16 symmetry; daemon `_jobs_file_lock`). Serialize
        // Swift-side writers via runSerialized exactly like createJob.
        let updatedTarget: JSONValue = try await runSerialized {
            [persistence, jobsPath, now] () async throws -> JSONValue in
            // The R-M-W returns the updated target job. Throws on the not-found
            // path so no write happens (mirrors the daemon raising before write_json).
            let work: @Sendable () async throws -> JSONValue = {
                let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
                var jobs: [JSONValue]
                if case .array(let arr) = raw { jobs = arr } else { jobs = [] }

                var matched: JSONValue? = nil
                for (idx, job) in jobs.enumerated() {
                    guard case .object(var obj) = job else { continue }
                    // Python: `str(job.get("id")) == job_id`. `pyStrForId`
                    // reproduces Python `str()` EXACTLY for the comparison —
                    // crucially `str(None) == "None"` (a malformed job with an
                    // absent/null id matches a literal `jobId == "None"`, same as
                    // the daemon). Legitimately-created jobs always carry a
                    // non-empty UUID id (`create_job` stamps `str(... or uuid4())`),
                    // so this only affects the pathological None-id case — but it
                    // keeps the match set byte-identical to the daemon.
                    if SchedulerJobNormalizer.pyStrForId(obj["id"]) == jobId {
                        obj["enabled"] = .bool(false)
                        obj["cancelledAt"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(now()))
                        jobs[idx] = .object(obj)
                        matched = .object(obj)
                        break
                    }
                }

                guard let target = matched else {
                    // Matches `raise ValueError(f"Unknown scheduled job: {job_id}")`.
                    // Thrown INSIDE the lock so no write happens on the miss path
                    // (the daemon raises before its `write_json`).
                    throw TriggerSchedulerError.schedulerInvalid("Unknown scheduled job: \(jobId)")
                }

                do {
                    try await persistence.writeJSON(.array(jobs), to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return target
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(jobsPath, work)
        }

        // record_activity("scheduler", "Scheduled job cancelled",
        //                  str(target.get("name") or job_id), "warn", payload={"jobId": job_id})
        // → activity/events.jsonl. Swift-owned flock (mirror createJob / Connectors W20).
        let targetObj: [String: JSONValue]
        if case .object(let o) = updatedTarget { targetObj = o } else { targetObj = [:] }
        // Python `str(target.get("name") or job_id)`: a falsey/absent name falls
        // back to the id (pyOr truthiness — empty string is falsey).
        let detailRaw = SchedulerJobNormalizer.string(
            SchedulerJobNormalizer.pyOr(targetObj["name"], .string(jobId))
        ) ?? jobId
        _ = try await runSerialized { [persistence, activityPath, uuid, now] () async throws -> Int in
            let event: JSONValue = .object([
                "id": .string(uuid()),
                "kind": .string("scheduler"),
                "title": .string(SchedulerSecretRedactor.redactText("Scheduled job cancelled")),
                "detail": .string(SchedulerSecretRedactor.redactText(detailRaw)),
                "status": .string("warn"),
                "executionId": .null,
                "payload": SchedulerSecretRedactor.redactValue(.object(["jobId": .string(jobId)])),
                "createdAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(now())),
            ])
            let activityWork: @Sendable () async throws -> Void = {
                try await appendJSONLCapped(
                    event,
                    to: activityPath,
                    using: persistence,
                    maxLines: JSONLLineCaps.activityEvents,
                    logLabel: "SchedulerJobs.cancel.activity",
                    takeLock: false
                )
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(activityPath, activityWork)
            return 0
        }

        // Daemon returns `{"ok": True, "job": dict(target)}`.
        return .object(["ok": .bool(true), "job": updatedTarget])
    }

    /// Faithful port of Daemon.list_jobs:
    ///   with self.jobs_lock, self._jobs_file_lock():
    ///       jobs = read_json(self.jobs_path, [])
    ///   if not isinstance(jobs, list): return []
    ///   for j in jobs:
    ///       d = dict(j)
    ///       raw = d.get("nextRunAt")
    ///       try: epoch = float(raw) if raw not in (None, "") else None
    ///       except (TypeError, ValueError): epoch = None
    ///       if epoch is not None:
    ///           iso = datetime.fromtimestamp(epoch, tz=UTC).isoformat()
    ///           d["nextRunAtEpoch"] = epoch
    ///           d["nextRunAt"] = iso
    ///           d["nextRunAtISO"] = iso
    ///       decorated.append(d)
    ///   return decorated
    ///
    /// READ-ONLY: no write happens, but the read is held under the SAME
    /// `<jobs.json>.lock` cross-process flock that createJob/cancelJob take
    /// (wave 31 W16 symmetry; daemon `self.jobs_lock, self._jobs_file_lock()`),
    /// so a Swift reader can't observe a torn write mid-flight from the daemon's
    /// scheduler_loop / save_jobs. Serialized Swift-side via runSerialized for
    /// the same per-actor ordering as the writes. The decoration is a pure
    /// transform of what was read; non-list disk content coerces to `[]`.
    public func listJobs() async throws -> [JSONValue] {
        return try await runSerialized { [persistence, jobsPath] () async throws -> [JSONValue] in
            let work: @Sendable () async throws -> [JSONValue] = {
                let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
                // Python: `if not isinstance(jobs, list): return []`.
                guard case .array(let jobs) = raw else { return [] }
                return jobs.map { SchedulerJobNormalizer.decorateNextRunAt($0) }
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(jobsPath, work)
        }
    }

    /// APP constant from the daemon. Used as the
    /// notify-title / name fallback. See PARITY DIVERGENCES in the header.
    nonisolated static var displayNameFallback: String { "NativeAgent" }
}

// MARK: - SchedulerJobNormalizer
//
// Pure, dependency-free port of Daemon.normalize_scheduler_job_payload and its
// helper cluster (_scheduler_* methods, the retired daemon). Kept
// as a stateless enum with injected `now`/`uuid` so it is trivially testable
// against the daemon's behavior without booting an actor.

enum SchedulerJobNormalizer {
    static let allowedKinds: Set<String> = [
        "notify", "connector_action", "dream", "rem", "improve", "harness_benchmark", "proactive_scan", "workshop",
    ]

    /// DEFAULT_IMPROVEMENT_OBJECTIVE — EXACT copy so a
    /// defaulted `improve` job runs with the same instructions as the daemon.
    /// The em-dash (—) and wording are byte-for-byte the Python constant.
    static let defaultImprovementObjective =
        "Make NativeAgent meaningfully better. Survey the ENTIRE system end to "
        + "end and decide for yourself what is most worth improving — do not "
        + "restrict yourself to any predefined list. Consider, among anything "
        + "else you notice: your own recent runs, evals, Doctor reports, error "
        + "and crash logs, telemetry, test results and gaps, prior staged and "
        + "failed self-improvement attempts, user feedback, the bug ledger, and "
        + "the codebase itself (daemon, providers, iOS app, scripts, "
        + "architecture, performance, reliability, security, UX, missing "
        + "capabilities, and tech debt). Identify the single highest-value "
        + "concrete improvement you can FULLY implement and verify right now, "
        + "then implement exactly that one improvement, tested and "
        + "receipt-backed."

    // MARK: top-level normalize

    static func normalize(
        body: [String: JSONValue],
        now: @Sendable () -> Date,
        uuid: @Sendable () -> String,
        displayNameFallback: String,
        connectorActionIDs: Set<String>? = nil
    ) throws -> JSONValue {
        let payload: [String: JSONValue]
        if case .object(let p)? = body["payload"] { payload = p } else { payload = [:] }

        // kind = str(body.get("kind") or "notify").strip().lower()
        let kind = (string(pyOr(body["kind"], .string("notify"))) ?? "notify")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedKinds.contains(kind) else {
            throw TriggerSchedulerError.schedulerInvalid("Unsupported scheduled job kind: \(kind)")
        }

        // interval = max(60, int(body.interval_seconds or intervalSeconds or payload.interval_seconds or 3600))
        var interval = try max(60, pyIntOr(
            body["interval_seconds"], body["intervalSeconds"], payload["interval_seconds"],
            default: 3600
        ))

        // schedule resolution.
        var schedule: [String: JSONValue]
        if case .object(let raw)? = body["schedule"] {
            schedule = raw
        } else {
            // _scheduler_schedule_from_legacy_body({**body, one_shot from payload if present}, interval)
            var legacyBody = body
            if let os = payload["one_shot"] { legacyBody["one_shot"] = os }
            schedule = scheduleFromLegacyBody(legacyBody, interval: interval)
        }

        if string(schedule["type"]) == "every" {
            // max(60, int(schedule.interval_seconds or intervalSeconds or seconds or interval))
            interval = try max(60, pyIntOr(
                schedule["interval_seconds"], schedule["intervalSeconds"], schedule["seconds"],
                default: interval
            ))
            schedule["seconds"] = .int(Int64(interval))
        }

        // one_shot = str(schedule.type or "").lower() == "once"
        //            OR bool(body.get("one_shot", body.get("oneShot", payload.get("one_shot", False))))
        let typeLower = (string(schedule["type"]) ?? "").lowercased()
        let oneShotFallback = body["one_shot"]
            ?? body["oneShot"]
            ?? payload["one_shot"]
        let oneShot = typeLower == "once" || boolValue(oneShotFallback, default: false)

        // first_run = schedule.firstRunAt or body.run_at or body.runAt  (Python `or`)
        let firstRun = pyOr(schedule["firstRunAt"], body["run_at"], body["runAt"])
        let nextRun: Double
        if let fr = firstRun, truthy(fr) {
            nextRun = try epochFromValue(fr, now: now)
        } else {
            nextRun = try nextFromSchedule(schedule, afterEpoch: nil, now: now)
        }

        // name = str(body.name or payload.name or kind.replace("_"," ").title() or "Scheduled Job")[:160]
        let nameRaw = string(pyOr(
            body["name"], payload["name"],
            .string(titleCased(kind.replacingOccurrences(of: "_", with: " "))),
            .string("Scheduled Job")
        )) ?? "Scheduled Job"
        let name = nameRaw.prefixString(160)

        // per-kind payload normalization.
        var outPayload: [String: JSONValue]
        switch kind {
        case "notify":
            // title = str(payload.title or body.title or name or display)[:120]
            let title = (string(pyOr(
                payload["title"], body["title"],
                .string(name), .string(displayNameFallback)
            )) ?? displayNameFallback).prefixString(120)
            // message = str(payload.message or payload.body or body.message or "").strip()
            let message = (string(pyOr(
                payload["message"], payload["body"], body["message"], .string("")
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw TriggerSchedulerError.schedulerInvalid("notify jobs require payload.message")
            }
            let delivery = deliveryChannels(payload)
            outPayload = [
                "title": .string(title),
                "message": .string(message.prefixString(1000)),
                "source": .string(string(pyOr(payload["source"], .string("scheduled_job"))) ?? "scheduled_job"),
                "delivery": .array(delivery.map { .string($0) }),
            ]
            if case .string(let projectSpaceId)? = payload["projectSpaceId"], !projectSpaceId.isEmpty {
                outPayload["projectSpaceId"] = .string(projectSpaceId.prefixString(160))
            }
            // delivery_options = payload.deliveryOptions or payload.delivery_options or {}
            let rawOpts = pyOr(payload["deliveryOptions"], payload["delivery_options"], .object([:]))
            if case .object(let opts)? = rawOpts {
                outPayload["deliveryOptions"] = .object(opts)
            }
        case "dream", "rem", "improve":
            // objective = str(payload.objective or body.objective or "").strip()
            var objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if objective.isEmpty {
                objective = kind == "improve"
                    ? defaultImprovementObjective
                    : (kind == "rem" ? "Scheduled REM consolidation" : "Scheduled reflection")
            }
            outPayload = ["objective": .string(objective.prefixString(2000))]
        case "workshop":
            let objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("workshop jobs require payload.objective")
            }
            let title = (string(pyOr(payload["title"], body["title"], .string(name))) ?? name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedEvidence = (string(pyOr(
                payload["expectedEvidence"], payload["expected_evidence"], .string("canonical Workshop completion receipt")
            )) ?? "canonical Workshop completion receipt")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let delivery = deliveryChannels(payload)
            outPayload = [
                "title": .string((title.isEmpty ? name : title).prefixString(160)),
                "objective": .string(objective.prefixString(2000)),
                "expectedEvidence": .string(expectedEvidence.prefixString(500)),
                "delivery": .array(delivery.map { .string($0) }),
            ]
        case "proactive_scan":
            // reason = str(orig.reason or body.reason or "scheduled_proactive_scan")[:120]
            let reason = (string(pyOr(
                payload["reason"], body["reason"], .string("scheduled_proactive_scan")
            )) ?? "scheduled_proactive_scan").prefixString(120)
            // limit = max(1, min(int(orig.limit or body.limit or 10), 50))
            let limit = try max(1, min(pyIntOr(payload["limit"], body["limit"], default: 10), 50))
            // surfaceLimit = max(0, min(int(orig.surfaceLimit or surface_limit or body.surfaceLimit or 4), 12))
            let surfaceLimit = try max(0, min(pyIntOr(
                payload["surfaceLimit"], payload["surface_limit"], body["surfaceLimit"],
                default: 4
            ), 12))
            outPayload = [
                "reason": .string(reason),
                "limit": .int(Int64(limit)),
                "surfaceLimit": .int(Int64(surfaceLimit)),
            ]
            // sources = orig.sources or body.sources or []  (Python `or`)
            let rawSources = pyOr(payload["sources"], body["sources"], .array([]))
            if case .array(let arr)? = rawSources {
                // [str(item)[:80] for item in sources[:8] if str(item).strip()]
                let sources = arr.prefix(8).compactMap { v -> JSONValue? in
                    let s = string(v) ?? ""
                    guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return .string(s.prefixString(80))
                }
                outPayload["sources"] = .array(sources)
            }
            let watchTemplateId = (string(pyOr(
                payload["watchTemplateId"], payload["watch_template_id"], body["watchTemplateId"], .string("")
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !watchTemplateId.isEmpty {
                outPayload["watchTemplateId"] = .string(watchTemplateId.prefixString(120))
            }
        case "connector_action":
            let actionId = (string(pyOr(
                payload["actionId"], payload["action_id"], payload["id"],
                body["actionId"], body["action_id"], body["action"]
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actionId.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action jobs require payload.actionId")
            }
            guard let connectorActionIDs else {
                throw TriggerSchedulerError.schedulerInvalid(
                    "connector_action scheduled jobs require Swift connector registry validation"
                )
            }
            guard connectorActionIDs.contains(actionId) else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown connector action: \(actionId)")
            }
            let rawInput = pyOr(payload["input"], body["input"], .object([:]))
            let input: [String: JSONValue]
            if case .object(let obj)? = rawInput {
                input = obj
            } else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action jobs require payload.input to be an object when provided")
            }
            outPayload = [
                "actionId": .string(actionId),
                "input": .object(input),
            ]
        default:
            // harness_benchmark (and any other allowed-but-unhandled kind):
            // payload = {**payload, manualAllowed: true, lightweight: true}
            outPayload = payload
            outPayload["manualAllowed"] = .bool(true)
            outPayload["lightweight"] = .bool(true)
        }

        // Native Experience blueprints compile into ordinary canonical jobs.
        // Preserve only their bounded identity/version markers so an explicit
        // reinstall can be idempotent or repair a cancelled/older row without
        // creating a parallel blueprint store.
        if case .string(let blueprintId)? = payload["blueprintId"], !blueprintId.isEmpty {
            outPayload["blueprintId"] = .string(blueprintId.prefixString(120))
        }
        if case .int(let blueprintVersion)? = payload["blueprintVersion"], blueprintVersion > 0 {
            outPayload["blueprintVersion"] = .int(min(blueprintVersion, 10_000))
        }

        // id = str(body.get("id") or uuid.uuid4())
        let id = string(pyOr(body["id"], .string(uuid()))) ?? uuid()
        // enabled = bool(body.get("enabled", True)) — explicit null is FALSEY.
        let enabled = boolValue(body["enabled"], default: true)
        // createdBy = str(body.get("createdBy") or "agent")
        let createdBy = string(pyOr(body["createdBy"], .string("agent"))) ?? "agent"

        let job: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "kind": .string(kind),
            "intervalSeconds": .int(Int64(interval)),
            "enabled": .bool(enabled),
            "oneShot": .bool(oneShot),
            "nextRunAt": .string(pyFloatString(nextRun)),
            "nextRunAtEpoch": .int(Int64(nextRun)),
            "lastRunAt": .null,
            "schedule": .object(schedule),
            "payload": .object(outPayload),
            "createdBy": .string(createdBy),
            "createdAt": .string(nowIso(now())),
        ]
        return .object(job)
    }

    // MARK: schedule helpers (port of _scheduler_* methods)

    /// _scheduler_schedule_from_legacy_body (L43217)
    ///   raw_run_at = body.run_at or body.runAt or body.nextRunAt    (Python `or`)
    ///   one_shot   = bool(body.get("one_shot", body.get("oneShot", False)))
    static func scheduleFromLegacyBody(_ body: [String: JSONValue], interval: Int) -> [String: JSONValue] {
        let rawRunAt = pyOr(body["run_at"], body["runAt"], body["nextRunAt"])
        // nested get-defaults: one_shot present? else oneShot present? else False.
        let oneShotRaw = body["one_shot"] ?? body["oneShot"]
        let oneShot = boolValue(oneShotRaw, default: false)
        if let r = rawRunAt, truthy(r), oneShot {
            return ["type": .string("once"), "run_at": r]
        }
        if let r = rawRunAt, truthy(r) {
            return ["type": .string("every"), "seconds": .int(Int64(interval)), "firstRunAt": r]
        }
        return ["type": .string("every"), "seconds": .int(Int64(interval))]
    }

    /// _scheduler_delivery_channels (L43226)
    ///   raw = payload.delivery or deliveries or channels or notifyVia  (Python `or`)
    static func deliveryChannels(_ payload: [String: JSONValue]) -> [String] {
        let raw = pyOr(payload["delivery"], payload["deliveries"], payload["channels"], payload["notifyVia"])
        let values: [String]
        switch raw {
        case .some(.array(let arr)):
            if arr.isEmpty { return ["push"] }
            values = arr.map { string($0) ?? "" }
        case .some(.string(let s)):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return ["push"] }
            values = s.replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        default:
            return ["push"]
        }
        let aliases: [String: String] = [
            "iphone": "push", "ios": "push", "apns": "push", "mobile": "push", "phone": "push",
            "telegram": "telegram", "tg": "telegram",
            "macos": "mac", "desktop": "mac", "mac": "mac",
            "chat": "chat", "session": "chat",
            "inbox": "inbox",
            "activity": "activity", "log": "activity",
        ]
        let canonical: Set<String> = ["push", "telegram", "mac", "chat", "inbox", "activity"]
        var channels: [String] = []
        for value in values {
            let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
            let channel = aliases[lower] ?? lower
            if canonical.contains(channel), !channels.contains(channel) {
                channels.append(channel)
            }
        }
        return channels.isEmpty ? ["push"] : channels
    }

    /// _scheduler_epoch_from_value (L43076)
    static func epochFromValue(_ raw: JSONValue, now: @Sendable () -> Date) throws -> Double {
        let nowEpoch = now().timeIntervalSince1970
        switch raw {
        case .int(let i):
            return max(nowEpoch, Double(i))
        case .double(let d):
            return max(nowEpoch, d)
        case .string(let s):
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw TriggerSchedulerError.schedulerInvalid("run_at is required") }
            if let d = Double(text) { return max(nowEpoch, d) }
            if let parsed = parseISO(text) { return max(nowEpoch, parsed) }
            throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime")
        case .null:
            throw TriggerSchedulerError.schedulerInvalid("run_at is required")
        default:
            throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime")
        }
    }

    /// _scheduler_next_from_schedule (L43176). `tz` handling: the daemon resolves
    /// IANA tz or local; we use local tz (matching the daemon's local-default)
    /// and honor an explicit IANA timezone string via TimeZone(identifier:).
    static func nextFromSchedule(_ schedule: [String: JSONValue], afterEpoch: Double?, now: @Sendable () -> Date) throws -> Double {
        let typ = (string(schedule["type"]) ?? string(schedule["kind"]) ?? "every")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tz = resolveTimezone(schedule["timezone"] ?? schedule["tz"])
        let nowEpoch = afterEpoch ?? now().timeIntervalSince1970

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // after = floor-to-minute(now in tz) + 1 minute
        let base = Date(timeIntervalSince1970: nowEpoch)
        let afterMinute = floorToMinute(base, cal: cal).addingTimeInterval(60)

        switch typ {
        case "once":
            // run_at or runAt or at  (Python `or`)
            return try epochFromValue(pyOr(schedule["run_at"], schedule["runAt"], schedule["at"]) ?? .null, now: now)
        case "every":
            // seconds = int(seconds or 0) + int(minutes or 0)*60 + …
            var seconds = try pyIntOr(schedule["seconds"], default: 0)
            seconds += try pyIntOr(schedule["minutes"], default: 0) * 60
            seconds += try pyIntOr(schedule["hours"], default: 0) * 3600
            seconds += try pyIntOr(schedule["days"], default: 0) * 86400
            // max(60, int(interval_seconds or intervalSeconds or seconds or 3600))
            let resolved = try max(60, pyIntOr(
                schedule["interval_seconds"], schedule["intervalSeconds"],
                seconds != 0 ? .int(Int64(seconds)) : nil,
                default: 3600
            ))
            // datetime.fromtimestamp(after_epoch or now, UTC) + seconds → epoch.
            return nowEpoch + Double(resolved)
        case "hourly":
            // minute = int(spec.get("minute", 0)) — present-default get, then int().
            let minute = try schedule["minute"].map { try pyInt($0) } ?? 0
            guard (0...59).contains(minute) else {
                throw TriggerSchedulerError.schedulerInvalid("hourly schedule minute out of range")
            }
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: afterMinute)
            comps.minute = minute
            comps.second = 0
            guard var candidate = cal.date(from: comps) else {
                throw TriggerSchedulerError.schedulerInvalid("could not compute hourly candidate")
            }
            if candidate <= afterMinute { candidate = candidate.addingTimeInterval(3600) }
            return candidate.timeIntervalSince1970
        case "daily", "weekly", "monthly", "cron":
            let (hour, minute) = typ == "cron" ? (0, 0) : try timeParts(schedule)
            // weekdays = _scheduler_weekdays(spec.weekdays or spec.weekday)  (Python `or`)
            let weekdays = typ == "weekly" ? try weekdaySet(pyOr(schedule["weekdays"], schedule["weekday"])) : Set(0...6)
            // month_day = max(1, min(31, int(spec.day or monthday or monthDay or 1)))
            let monthDay = try max(1, min(31, pyIntOr(
                schedule["day"], schedule["monthday"], schedule["monthDay"],
                default: 1
            )))
            // expression = str(spec.expression or spec.cron or "")  (Python `or`)
            let expression = (string(pyOr(schedule["expression"], schedule["cron"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Advance candidate by ONE WALL-CLOCK MINUTE per iteration (mirrors
            // Python's `candidate += timedelta(minutes=1)` on a tz-aware
            // datetime — correct across DST, unlike adding raw 60s).
            var candidate = afterMinute
            for _ in 0..<(370 * 24 * 60) {
                let c = cal.dateComponents([.hour, .minute, .day, .weekday], from: candidate)
                let cHour = c.hour ?? -1
                let cMinute = c.minute ?? -1
                let cDay = c.day ?? -1
                // Calendar.weekday: 1=Sunday..7=Saturday → Python weekday(): 0=Mon..6=Sun
                let pyWeekday = ((c.weekday ?? 1) + 5) % 7
                if typ == "daily", cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if typ == "weekly", weekdays.contains(pyWeekday), cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if typ == "monthly", cDay == monthDay, cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if typ == "cron", try cronMatches(candidate, expression: expression, cal: cal) {
                    return candidate.timeIntervalSince1970
                }
                guard let nextCandidate = cal.date(byAdding: .minute, value: 1, to: candidate) else {
                    throw TriggerSchedulerError.schedulerInvalid("could not advance \(typ) candidate")
                }
                candidate = nextCandidate
            }
            throw TriggerSchedulerError.schedulerInvalid("Could not find next run for \(typ) schedule within one year")
        default:
            throw TriggerSchedulerError.schedulerInvalid("Unsupported schedule type: \(typ)")
        }
    }

    /// _scheduler_time_parts (L43094)
    ///   raw = spec.get("at") or spec.get("time")   (Python `or`)
    ///   if raw not in (None, ""): regex ^\s*(\d{1,2})(?::(\d{1,2}))?\s*$
    ///   else: hour = int(spec.get("hour", default)); minute = int(spec.get("minute", default))
    static func timeParts(_ spec: [String: JSONValue], defaultHour: Int = 9, defaultMinute: Int = 0) throws -> (Int, Int) {
        let raw = pyOr(spec["at"], spec["time"])
        let hour: Int
        let minute: Int
        if let r = raw, truthy(r) {
            // str(raw) then exact regex match over the WHOLE string.
            let text = string(r) ?? jsonScalarString(r)
            guard let (h, m) = parseHHMM(text) else {
                throw TriggerSchedulerError.schedulerInvalid("schedule.at must be HH:MM")
            }
            hour = h
            minute = m
        } else {
            // present-default get → strict int().
            hour = try spec["hour"].map { try pyInt($0) } ?? defaultHour
            minute = try spec["minute"].map { try pyInt($0) } ?? defaultMinute
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TriggerSchedulerError.schedulerInvalid("scheduled hour/minute out of range")
        }
        return (hour, minute)
    }

    /// Match Python regex `^\s*(\d{1,2})(?::(\d{1,2}))?\s*$`: 1-2 digit hour,
    /// optional `:` + 1-2 digit minute, surrounded only by whitespace. Returns
    /// (hour, minute) — minute defaults to 0 when the `:MM` group is absent.
    static func parseHHMM(_ raw: String) -> (Int, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return nil }
        let hStr = parts[0]
        guard (1...2).contains(hStr.count), hStr.allSatisfy({ $0.isASCII && $0.isNumber }), let h = Int(hStr) else {
            return nil
        }
        if parts.count == 2 {
            let mStr = parts[1]
            guard (1...2).contains(mStr.count), mStr.allSatisfy({ $0.isASCII && $0.isNumber }), let m = Int(mStr) else {
                return nil
            }
            return (h, m)
        }
        return (h, 0)
    }

    /// _scheduler_weekdays (L43109) → Python weekday ints (0=Mon..6=Sun)
    static func weekdaySet(_ raw: JSONValue?) throws -> Set<Int> {
        let names: [String: Int] = [
            "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1,
            "wed": 2, "wednesday": 2, "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
            "fri": 4, "friday": 4, "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
        ]
        guard let raw, !isEmptyForWeekdays(raw) else { return Set(0...6) }
        let values: [String]
        if case .array(let arr) = raw {
            values = arr.map { string($0) ?? jsonScalarString($0) }
        } else {
            values = (string(raw) ?? jsonScalarString(raw))
                .replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        }
        var result: Set<Int> = []
        for item in values {
            let text = item.trimmingCharacters(in: .whitespaces).lowercased()
            if text == "weekday" || text == "weekdays" {
                result.formUnion([0, 1, 2, 3, 4])
            } else if text == "weekend" || text == "weekends" {
                result.formUnion([5, 6])
            } else if let n = names[text] {
                result.insert(n)
            } else if let value = Int(text) {
                // (value - 1) % 7 if value >= 1 else value
                result.insert(value >= 1 ? ((value - 1) % 7) : value)
            } else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown weekday: \(item)")
            }
        }
        return result.isEmpty ? Set(0...6) : result
    }

    /// _scheduler_cron_values (L43131)
    static func cronValues(_ field: String, minimum: Int, maximum: Int, names: [String: Int] = [:]) throws -> Set<Int> {
        var allowed: Set<Int> = []
        for partRaw in field.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            var part = String(partRaw).trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            func namedOrInt(_ token: String, _ fallback: Int) -> Int {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let n = names[t] { return n }
                if t.allSatisfy({ $0.isNumber }), !t.isEmpty, let v = Int(t) { return v }
                return fallback
            }
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                let stepText = String(part[part.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                part = String(part[..<slash])
                // Python: step = max(1, int(step_text)) — int() raises on non-numeric.
                guard let parsedStep = Int(stepText), stepText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
                    throw TriggerSchedulerError.schedulerInvalid("invalid cron step: \(stepText)")
                }
                step = max(1, parsedStep)
            }
            let start: Int
            let end: Int
            if part == "*" || part == "?" {
                start = minimum; end = maximum
            } else if let dash = part.firstIndex(of: "-") {
                let left = String(part[..<dash])
                let right = String(part[part.index(after: dash)...])
                start = namedOrInt(left, minimum)
                end = namedOrInt(right, maximum)
            } else {
                let value = namedOrInt(part, minimum)
                start = value; end = value
            }
            if start <= end {
                var value = start
                while value <= end {
                    if value >= minimum && value <= maximum { allowed.insert(value) }
                    value += step
                }
            }
        }
        return allowed
    }

    /// _scheduler_cron_matches (L43163)
    static func cronMatches(_ date: Date, expression: String, cal: Calendar) throws -> Bool {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else {
            throw TriggerSchedulerError.schedulerInvalid("cron expression must have 5 fields: minute hour day month weekday")
        }
        let weekdayNames: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        let minute = try cronValues(fields[0], minimum: 0, maximum: 59)
        let hour = try cronValues(fields[1], minimum: 0, maximum: 23)
        let day = try cronValues(fields[2], minimum: 1, maximum: 31)
        let month = try cronValues(fields[3], minimum: 1, maximum: 12)
        let dow = try cronValues(fields[4], minimum: 0, maximum: 7, names: weekdayNames)
        let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        // cron_dow = (dt.weekday() + 1) % 7; dt.weekday(): 0=Mon..6=Sun.
        let pyWeekday = ((c.weekday ?? 1) + 5) % 7   // Calendar 1=Sun → py 6; 2=Mon → py 0
        let cronDow = (pyWeekday + 1) % 7
        let dowMatch = dow.contains(cronDow) || (cronDow == 0 && dow.contains(7))
        return minute.contains(c.minute ?? -1)
            && hour.contains(c.hour ?? -1)
            && day.contains(c.day ?? -1)
            && month.contains(c.month ?? -1)
            && dowMatch
    }

    // MARK: scalar helpers
    //
    // The daemon's normalize path leans on Python semantics that do NOT map to
    // Swift's `??` / numeric inits:
    //   * `a or b or c`            → first TRUTHY value (0 / "" / [] / {} / None
    //                                are falsey), not first non-nil.
    //   * `int(x)`                 → raises on non-numeric / decimal strings.
    //   * `str(x)`                 → coerces any scalar to text.
    //   * `bool(d.get(k, True))`   → explicit JSON null is FALSEY.
    // These helpers reproduce that so a value of 0 / "" / wrong-type does not
    // silently change the persisted job (gpt-5.5 review wave 33 W18).

    /// Python `str(x)` for the scalar JSON cases the daemon coerces. Objects /
    /// arrays never reach a `str(...)` site in normalize, so they map to nil
    /// (caller treats as absent) rather than Python's "[...]"/"{...}" repr.
    static func string(_ v: JSONValue?) -> String? {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return pyFloatString(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        default: return nil
        }
    }

    /// Python `str(x)` for the `cancel_job` id COMPARISON specifically
    /// (`str(job.get("id")) == job_id`). Differs from `string` in one way that
    /// matters there: an ABSENT or `null` id → Python `str(None) == "None"`, so
    /// a malformed job with no id matches a literal `jobId == "None"`. Arrays /
    /// objects can't appear as a real job id and Python's list/dict repr never
    /// equals a UUID-shaped id, so they map to a non-matching sentinel.
    static func pyStrForId(_ v: JSONValue?) -> String {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return pyFloatString(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        case .some(.null), .none: return "None"   // Python str(None)
        case .some(.array), .some(.object):
            // Python would produce a list/dict repr; it can never equal a real
            // job id, so return a value that won't match any caller-supplied id.
            return "\u{0}__nonscalar_id__"
        }
    }

    /// Retired truthiness: 0 / 0.0 / "" / [] / {} / null / absent are falsey.
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .some(.bool(let b)): return b
        case .some(.int(let i)): return i != 0
        case .some(.double(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let o)): return !o.isEmpty
        case .some(.null), .none: return false
        }
    }

    /// Python `a or b or c …` — returns the first TRUTHY argument, else the
    /// last argument (retired semantics returned the final operand when all are
    /// falsey, e.g. `x or 3600` → 3600).
    static func pyOr(_ values: JSONValue?...) -> JSONValue? {
        for v in values where truthy(v) { return v }
        return values.last ?? nil
    }

    /// Python `int(x)` with the daemon's strictness: ints pass through; floats
    /// truncate toward zero; numeric strings (no decimal point) parse; bools →
    /// 0/1; everything else THROWS (matching ValueError → 400). Empty string and
    /// null also throw. Used where the daemon would surface a 400 on bad input.
    static func pyInt(_ v: JSONValue?) throws -> Int {
        switch v {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)   // Python int(float) truncates toward zero
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.string(let s)):
            // Python int("  12 ") strips surrounding whitespace; int("1.5") raises.
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            throw TriggerSchedulerError.schedulerInvalid("invalid integer literal: \(s)")
        case .some(.array), .some(.object), .some(.null), .none:
            throw TriggerSchedulerError.schedulerInvalid("expected an integer")
        }
    }

    /// `int(a or b or c or default)` — the daemon's recurring pattern: pick the
    /// first truthy operand, fall back to `default`, then `int()` it (strict).
    static func pyIntOr(_ values: JSONValue?..., default def: Int) throws -> Int {
        for v in values where truthy(v) { return try pyInt(v) }
        return def
    }

    /// `bool(d.get(k, default))` — present-with-null is FALSEY; absent uses the
    /// stored default. `def` is the Python `d.get(k, def)` default applied when
    /// the key is ABSENT (nil); a present null/scalar follows retired truthiness.
    static func boolValue(_ v: JSONValue?, default def: Bool) -> Bool {
        guard let v else { return def }   // key absent → Python default
        return truthy(v)                  // present (incl. null) → truthiness
    }

    /// _scheduler_weekdays empty-guard: raw in (None, "", []).
    static func isEmptyForWeekdays(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    static func jsonScalarString(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return pyFloatString(d)
        case .bool(let b): return b ? "True" : "False"
        default: return ""
        }
    }

    /// Python `str.title()` — capitalize first letter of each word.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Python `str(float)` — integral floats render as "N.0".
    static func pyFloatString(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    /// now_iso() — ISO-8601 UTC with offset (millisecond precision; see header).
    static func nowIso(_ date: Date) -> String {
        SwiftNativeTriggerScheduler.isoTimestamp(date)
    }

    // MARK: list_jobs nextRunAt decoration

    /// Port of the per-row `nextRunAt` decoration inside `Daemon.list_jobs`.
    /// `d = dict(j)` then, IF the stored `nextRunAt` coerces to a float epoch
    /// (Python `float(raw) if raw not in (None, "") else None`, swallowing
    /// TypeError/ValueError → None), overwrite `nextRunAt` with the ISO form and
    /// add `nextRunAtEpoch` (the float) + `nextRunAtISO` (the same ISO). A
    /// non-object row is returned unchanged (Python `dict(j)` would raise on a
    /// non-mapping, but jobs.json only ever holds objects; we pass scalars
    /// through rather than crash, which is strictly safer and never reached in
    /// practice). All OTHER keys (lastRunAt/createdAt/etc.) pass through untouched.
    static func decorateNextRunAt(_ row: JSONValue) -> JSONValue {
        guard case .object(var d) = row else { return row }
        // raw = d.get("nextRunAt"); epoch = float(raw) if raw not in (None,"") else None
        let epoch = floatEpochForDecoration(d["nextRunAt"])
        if let epoch {
            let iso = epochToDecorationISO(epoch)
            // Python stores the FLOAT under nextRunAtEpoch (json → number). Use
            // .double so the wire shape matches (e.g. 1893456000.0, not "…").
            d["nextRunAtEpoch"] = .double(epoch)
            d["nextRunAt"] = .string(iso)
            d["nextRunAtISO"] = .string(iso)
        }
        return .object(d)
    }

    /// `epoch = float(raw) if raw not in (None, "") else None`, catching
    /// TypeError/ValueError → None. Mirrors Python `float()` coercion EXACTLY for
    /// the stored-row cases: the daemon writes `nextRunAt` as `pyFloatString`
    /// (a float-string like "1893456000.0"), but a row may also carry a numeric
    /// JSON value (older shells) or garbage. Crucially, `raw not in (None, "")`
    /// means a literal `0` / `0.0` / `"0"` is NOT skipped — it coerces to 0.0 and
    /// decorates to the epoch (1970-01-01T00:00:00+00:00), same as the daemon.
    static func floatEpochForDecoration(_ raw: JSONValue?) -> Double? {
        switch raw {
        case .none, .some(.null):
            // Python: raw is None → skipped (in the (None, "") set).
            return nil
        case .some(.string(let s)):
            // Python: "" → skipped; otherwise float(s). float() strips
            // surrounding whitespace and accepts int/decimal/exponent forms.
            if s.isEmpty { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Double(_:) rejects empty / non-numeric → Python float() ValueError.
            guard let v = Double(trimmed), v.isFinite else { return nil }
            return v
        case .some(.int(let i)):
            return Double(i)
        case .some(.double(let d)):
            return d.isFinite ? d : nil
        case .some(.bool):
            // Python float(True/False) == 1.0/0.0, BUT a bool nextRunAt can't be
            // produced by the daemon and `float(bool)` is a degenerate path the
            // real data never hits; treat as garbage → None (TypeError-equivalent
            // is the safe call here since it can never appear in jobs.json).
            return nil
        case .some(.array), .some(.object):
            // Python float([...]) / float({...}) raises TypeError → None.
            return nil
        }
    }

    /// Faithful mirror of `datetime.fromtimestamp(epoch, tz=timezone.utc)
    /// .isoformat()` — the EXACT call the daemon's list_jobs decoration uses.
    /// Python's isoformat:
    ///   * omits the fractional-seconds component entirely when the microsecond
    ///     field is 0 (integral epoch → "2030-01-01T00:00:00+00:00"),
    ///   * renders SIX fractional digits (microseconds) otherwise
    ///     ("…T00:00:00.500000+00:00"),
    ///   * always uses the "+00:00" offset (never "Z") for a UTC-aware datetime.
    /// This DIFFERS from `SwiftNativeTriggerScheduler.isoTimestamp` (which always
    /// emits millisecond ".SSS"), so we cannot reuse it for the decoration.
    static func epochToDecorationISO(_ epoch: Double) -> String {
        // Split into whole seconds + microseconds, rounding microseconds the way
        // CPython's fromtimestamp does (round-half-to-even at microsecond
        // resolution). Compute the fractional part against the floored second.
        let floored = epoch.rounded(.down)
        // CPython's datetime.fromtimestamp rounds the sub-second remainder to
        // microseconds with round-HALF-to-EVEN (banker's rounding), NOT
        // round-half-away-from-zero. Exact half-microsecond ties differ between
        // the two (0.0000005 → 0 even; 0.0000025 → 2 even, not 3). Use
        // .toNearestOrEven so the rare tie case stays byte-identical to Python
        // (gpt-5.5 review, wave 38 W15). Real daemon-written epochs are integral
        // or clean fractions and never hit a tie, but this keeps the mirror exact.
        var micros = Int(((epoch - floored) * 1_000_000.0).rounded(.toNearestOrEven))
        var wholeSeconds = floored
        // Guard the boundary where rounding pushes micros to 1_000_000.
        if micros >= 1_000_000 {
            micros -= 1_000_000
            wholeSeconds += 1
        }
        if micros < 0 { micros = 0 }

        let date = Date(timeIntervalSince1970: wholeSeconds)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 1970, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        if micros == 0 {
            return base + "+00:00"
        }
        return base + String(format: ".%06d", micros) + "+00:00"
    }

    /// Mirror `datetime.fromisoformat(text.replace("Z","+00:00"))` with the
    /// daemon's `if parsed.tzinfo is None: parsed = parsed.replace(tzinfo=UTC)`.
    /// Python's fromisoformat accepts both `T` and space separators and naive
    /// (offset-less) forms, including date-only. We try, in order:
    ///   1. offset-bearing forms (with/without fractional seconds)
    ///   2. naive datetime forms → interpreted as UTC (Python's tzinfo=UTC rule)
    ///   3. date-only `YYYY-MM-DD` → midnight UTC
    static func parseISO(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: "Z", with: "+00:00")

        // 1. Offset-bearing (Internet date-time).
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: normalized) { return d.timeIntervalSince1970 }
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        if let d = noFrac.date(from: normalized) { return d.timeIntervalSince1970 }

        // 2 & 3. Naive forms (no offset) → UTC. Accept both `T` and space.
        let utc = TimeZone(identifier: "UTC")!
        let candidates = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd'T'HH:mm:ss.SSS",
                          "yyyy-MM-dd'T'HH:mm:ss",
                          "yyyy-MM-dd'T'HH:mm",
                          "yyyy-MM-dd HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd HH:mm:ss.SSS",
                          "yyyy-MM-dd HH:mm:ss",
                          "yyyy-MM-dd HH:mm",
                          "yyyy-MM-dd"]
        for fmt in candidates {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = utc
            df.dateFormat = fmt
            if let d = df.date(from: normalized) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    static func resolveTimezone(_ v: JSONValue?) -> TimeZone {
        if case .string(let name)? = v {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if !trimmed.isEmpty, lower != "local", lower != "system", let tz = TimeZone(identifier: trimmed) {
                return tz
            }
        }
        return TimeZone.current
    }

    static func floorToMinute(_ date: Date, cal: Calendar) -> Date {
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return cal.date(from: comps) ?? date
    }
}

private extension String {
    /// Python `s[:n]` slices by Unicode code points (scalars), NOT by Swift
    /// extended grapheme clusters. Slice on `unicodeScalars` so a combining
    /// sequence / flag emoji counts the same number of positions Python would.
    func prefixString(_ n: Int) -> String {
        let scalars = unicodeScalars
        if scalars.count <= n { return self }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }
}

// MARK: - Factory (scheduler-job writer)

/// Returns the SwiftNative create-job writer when `.triggerScheduler` is ON,
/// Returns SwiftNative. Mirrors `makeTriggerScheduler`'s Workshop execution-runner wiring
/// (SwiftNativeWorkshopPlannerLLM via `makeWorkshopRunner`) so the
/// SwiftNative instance is identical to the one serving the rest of the
/// trigger-scheduler surface — the create path never needs the runner, but
/// sharing one construction keeps the two factories from drifting.
public func makeSchedulerJobWriter(
    connectorActionIDs: Set<String>? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any SchedulerJobWriter {
    let runner = makeWorkshopRunner(dataRoot: dataRoot)
    return SwiftNativeTriggerScheduler(
        root: dataRoot,
        workshopRunner: runner,
        connectorActionIDs: connectorActionIDs
    )
}

typealias SchedulerSecretRedactor = NativeAgentSecretRedactor
