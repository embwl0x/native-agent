# Automated Systems — architecture map + health probes

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

This map identifies the registered background work, its owners and the
evidence to inspect. It describes code, not the health of a particular running
installation. Checks should be small and tied to the system being diagnosed.

## 0. Ground rule: pin the dataRoot first

Read `app {"action":"agent.introspect"}` and use its `data_root` when
inspecting files. Do not assume the checkout's `data/` is the live root.

`PersistenceCore/PersistenceDataRoot.swift` resolves the process root from
`NATIVE_AGENT_DATA_ROOT`, then a development bundle's `REPO_PATH` stamp,
otherwise Application Support. The root is fixed for that process.

Paths below are relative to that root unless identified as source paths.

## 1. The map — how it all connects

| Owner | Responsibility |
|---|---|
| `EngineRuntime/NativeAgentEngine.swift` | Root-scoped clients, stores and app ports. |
| `ChatTurnRuntime` | Conversation execution and after-turn work. |
| `BackgroundLoops/BackgroundLoopsManager.swift` | Registrations, lifecycle, execution gates and status. |
| `BackgroundLoops/BackgroundLoops.swift` | Scheduler timing, outcomes, durable clocks and failure receipts. |
| `BackgroundWork` | Maintenance, work, heartbeat and connector runner bodies. |
| `EngineRuntime/EngineLaunch.swift` | Constructs the loop registrations and their dependencies through the installed host effects. |
| `SchedulerExecution/SchedulerDueJobRunner.swift` | Execute due persisted scheduler jobs. |
| `DeviceSync/MacSyncEngine*.swift` | Mobile command transport and snapshots. |

Core source paths are under `Modules/NativeAgentCore/Sources/`.
`NativeAgent.app` owns the running system in-process.

## 2. BackgroundLoops scheduler — the engine under §4

The manager serializes execution per registration. Concurrent wake requests
join the active tick rather than running a second copy. Event/deadline runners
can wake on owner changes or their next meaningful deadline; their periodic
interval is an integrity backstop.

Event debounces own their pending delay. A firing debounce transfers its task
into execution ownership; events during that work coalesce into one follow-up
after it exits. A firing deadline likewise transfers its task out of the sleep
slot before execution, so completion projects its successor without cancelling
itself. A deadline joining an active pass retains one follow-up reconciliation
after that pass exits, so age crossings during the pass are assessed. Stop and
replacement cancel pending waits and retained loop tasks.

A tick returns `LoopTickOutcome.completed`, `skipped` or `failed`.
A health-neutral skip preserves an existing failure streak. Durable clocks
survive restart, and timing accounts for time already elapsed rather than
restarting a full period.

Inspect these together:

- `running`: the registration is active.
- `executing` and `executionStartedAt`: its body is currently running.
- `lastRun` and `lastResult`: the latest attempt, which may have skipped or
  failed.
- `lastSuccessfulWorkAt`: the latest completed work.
- `eventListener`: listener health for an event-driven lane.
- `logs/background_loop_state.json` and
  `logs/background_loop_failures.jsonl`: durable clocks and failure evidence.
- `pulses` in that state file: work that runs outside a loop (iCloud drain,
  launch reconcilers) stamps each pass with `OrganPulse.record`.
  Doctor's `live.pulses` row lists them; an organ with a declared cadence is
  overdue once it misses a whole beat since launch. A failed pass leaves no
  pulse; an organ whose clock stopped on purpose records `off: <reason>` and
  is never overdue.

A recent attempt is not proof of successful work. An idle lane's skip reason,
enabled state and next deadline matter more than a blanket freshness threshold.

## 3. Doctor — the health authority

`DoctorChecks/DoctorChecks.swift` defines `SwiftNativeDoctorChecks.defaultChecks`:
17 checks covering storage, runtime JSON, run-ledger and turn-trace integrity,
sessions and identity, prompt-prefix health, subconscious vitals, model
compensations, messages, persona, memory, embeddings, ability files, iCloud,
operation logs and OAuth expiry. The app adds live checks, including
background-loop health; the visible report is not a fixed 17-row checklist.
`Model compensations` (`model.shims`) is a read-only count of `shim.fired`
receipts by census ID in a bounded measurement window, excluded from heartbeat
sweeps.

Saved-provider read failures and failed native provider probes report `fail`;
an unhealthy provider path reports `warn`. A stale probe retains an adverse
registry verdict and otherwise reports `unmeasured`; a readable compensation
scan without a v2 turn is also `unmeasured`. `off` and `not needed` remain
distinct non-fault states, not evidence of healthy work.

`detail` stays evidence prose; remedies and executable calls have their own
fields. Instructions for the Repair button say “Press Repair in Diagnostics →
Health checks to …”; the shared recognizer also accepts legacy cached
“Run Repair Safe Issues” instructions.

`app {"page":"diagnostics","item":"doctor"}` reads the saved report
(`Sources/NativeAgentApp/AppToolPlatform.swift`) and names the run it shows;
`doctor.run` measures afresh, and `doctor.repair` is a separate action, not a
read-only probe. Runtime JSON, persona and transcript checks only inspect;
Doctor never creates or resets runtime stores, seeds identity or rewrites
transcripts. Missing runtime stores begin through their canonical owners;
malformed saved bytes remain available for the owning repair.

The configured `doctor_auto_run` lane runs once at launch, off their turn's path
(`EngineLaunch` ticks it once), then on its configured interval (at least an
hour); it runs every safe repair and files one inbox ask for the sign-ins and
permissions it cannot do itself. Its `doctor/latest.json` contains:

- `measuredAt`: when measurement began;
- `runAt`: when the snapshot was published;
- `launchID`: the process launch that measured the snapshot;
- `checks`: the findings. An off or not-needed reading settles an owed repair;
  an unreadable config is a fault with its file, never "off".

The runtime page envelope adds `report_completed_at` and, while a run is active,
`run_in_progress` to identify the report shown and the newer run still in flight.
Health-cache reuse requires the current `launchID` and a `runAt` age from zero
to less than 60 seconds; a fresh core reading never merges rows from an earlier
launch.

An empty set is not persisted as a clean bill of health. Some behavioral
checks memoize, so publication time alone does not establish freshness.

## 4. The loop manifest — every registered lane

`EngineRuntime/EngineLaunch.swift` registers the lanes. The table gives the
lanes and their production defaults as of this writing; the installed set is
`logs/background_loop_state.json` and Doctor's `live.loops` row. Enabled state,
event deadlines, backoff and saved configuration determine actual work.

| loopId | Default wake or backstop | Work |
|---|---|---|
| `doctor_auto_run` | Launch, ok→adverse health reading, weekly; configured intervals at least 1h | Repair, publish Doctor snapshot, file one sign-in/permission ask. |
| `turn_trace_retention` | 6h | Prune expired trace data, lock sidecars and excess transcript backups. |
| `offdisk_backup` | Identity-file changes + persisted daily deadline; daily integrity | Create an off-disk backup when due or identity changed; skip alternate roots and unavailable iCloud Drive. |
| `data_root_disk_hygiene` | Persisted daily boundary; hourly retry while unreserved; daily integrity | Detect oversized state and file a notice; the scan does not delete it. |
| `memory_consolidation` | Weekly | Run MemoryV2 consolidation and hygiene. |
| `self_improvement_sweep` | Weekly | Stage runtime improvement approval cards; requires its switch and unattended-work authority. |
| `trigger_scheduler_due_work` | Events/deadlines; 6h repair | Run due scheduler jobs. |
| `mission_executor` | Events/deadlines; daily repair | Drain Workshop executions; this is the registered wire name. |
| `workshop_pump` | Events/deadlines; daily repair | Admit bounded Workshop work through its policy and posture gates. |
| `cognition_maintenance` | Daily | Substrate maintenance. |
| `cognition_replay` | Daily | Episodic replay. |
| `cognition_reflection` | Daily | Budgeted cognitive reflection. |
| `heartbeat` | Assessment-input changes + age deadlines; 12h integrity | Assess health; surface stable anomaly cards. Clean assessments skip the model. |
| `desk_notify` | Events/deadlines; daily repair | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Events/deadlines; 6h repair | Reconcile terminal delegation jobs and their notifications. |
| `telegram_poll` | Long-poll transport | Admit configured Telegram messages. |
| `slack_socket_mode` | Socket transport | Admit configured Slack messages. |

Telegram and Slack remain registered when unconfigured, using a placeholder
that reports a skip and performs no remote work. A registration is therefore
not proof that the connector is configured.

Heartbeat retains its 12-hour integrity sweep for nested records outside its
initial nonrecursive file subscriptions and error rows whose bounded evidence
is too short to project an expiry.

Stopping background scheduling closes bot admission. A helper's seconds limit
cancels its work and joins settlement, retaining its output and crossing report
before releasing the claim. Explicit session cancellation remains separate.

### Scheduled Dream and REM

The calendar jobs `nativeagent-nightly-dream` and
`nativeagent-weekly-rem` run through `SchedulerDueJobRunner`; there are no
separate periodic Dream or REM wrappers in the loop manifest.
Recognized legacy jobs retain their existing IDs; creation receipts read back
the job resolved by bootstrap rather than assuming the default ID.
Phone and agent creation share recurring-dream admission: a repeating reflection
uses that one nightly job, preserving pauses and reactivating cancellations.

`DreamREMCycle/DreamREMCycle.swift` owns the default schedule: Dream at
03:30 daily and REM at 04:30 Sunday, in the Mac's current time zone.
Read the persisted jobs and their enabled state to establish what will run
on an installation.

The nightly diary entry uses the previous local calendar day's key. Inspect
the job outcome and file modification time; absence of a file named for today
is not evidence of failure. REM stages growth proposals through the approval
path rather than directly treating a dream as permission to rewrite persona.
Each saved dream section carries its consumed-message cutoff. Under the run
reservation, the next pass reconciles `.dream_state.json` from the diary,
including archived entries, before gathering new material. A crash between
saving a section and advancing the mark therefore does not dream it again.
Archival removes an identical top-level duplicate only after comparing its
bytes; differing same-name entries are both retained, with a unique suffix
on the incoming copy. Existing archived writing is never replaced.

## 5. MacSync / iCloud bridge (Mac ⇄ iPhone)

`DeviceSync/MacSyncEngine` receives signed commands, checks their identity,
dispatches through the Mac and publishes responses and snapshots.
The Mac stamps `mac_time_zone`, its current time zone identifier, into the scheduler snapshot so the phone can show job times in the Mac's zone.

The local bookkeeping under `icloud/` is distinct from the transport's
container. `DeviceSync/State/ICloudSyncStatePaths.swift` defines:

| Evidence | Meaning |
|---|---|
| `processed_ids.json` | Executed message IDs used to prevent redispatch. |
| `processed_ids.corrupt.json` | Preserved evidence of an unreadable ID window. |
| `completed-unarchived/` | Commands whose effect/response landed but completion bookkeeping could not finish; do not replay them. |
| `snapshot_skips.json` | Groups with unresolved snapshot failures, including groups not attempted in the latest pass. Absence means no skips were recorded. |
| `account_failure.json` | The last account rejection, retained until a successful pull. |

The snapshot bundle publishes `snapshot_staleness.json` (group → reason)
for the mobile app's stale-state badges. A healthy pass with no unresolved
groups publishes `{}` (never deletes the file): the phone's CloudKit cache
only gains files, and a missing marker leaves its previous stale verdict intact.

Doctor's iCloud check consumes the shared state paths and live bridge health.
Read the actual error and transaction state before interpreting queue age or
attempting a retry. A transport write is not Mac-owned completion.

## 6. MemoryV2 → USER.md generation (the identity doc)

`MemoryV2/MemoryV2+UserMDGen.swift` regenerates `USER.md` in the active
persona root from eligible active memories. It respects onboarding and
preserves a damaged existing document rather than silently replacing it.
The generator owns the 30-second trailing deadline through regeneration;
termination cancels a sleeping deadline and flushes accepted requests after
draining storage-owned pokes. Accepted canonical writes are not cancelled;
writes after projection closure are reconciled on the next launch.

Workshop execution records are excluded by their `workshop:` source prefix.
Repair the canonical memory or generator when the projection is wrong; a manual
edit to the generated document is not a durable fix.

For after-turn promotion, proposal review and recall, see
[Internal Workings](INTERNAL_WORKINGS.md#2-anatomy-of-a-memory).

## 7. Approvals & trust gating

`ApprovalInbox/ApprovalInbox.swift` owns
`workflows/approvals/requests.json`. A pending request is a decision waiting
to be made, not automatically an automation failure. Read its origin, bound
action, decision and execution outcome.

Full Mac does not remove macOS privacy-reset approval. A turn an untrusted
agent started with its message gets one card on its first effect, and the
answer covers the rest of that turn; a read steers nothing. Agents enabled in
Trust → Connected agents carry the owner's authority on authenticated turns;
ordinary Trust and domain checks still apply. Work lanes such as Workshop and self-healing
check unattended-work admission; per-lane enable switches remain separate. A scheduler
wake does not grant authority.

See [Tool loading](TOOL_LOADING.md#authority-and-receipts) for the action
boundary and [Approval schema](approval-schema.md) for stored records.

## 8. Bounded inspection

Start with the smallest evidence relevant to the reported problem:

1. Establish the running root with `agent.introspect`.
2. Read the relevant app page or Doctor's non-repair report.
3. For a loop, compare its result, successful-work clock, listener health and
   failure receipts with its configuration and deadline.
4. For a scheduled job, inspect enabled state and last outcome, and use
   `SchedulerJobRuntime.scheduledEpoch`: unclaimed wall-clock work follows its
   civil occurrence in the current zone; claims and retry floors keep their instant.
5. For a turn, inspect its terminal trace; for a mobile command or approval,
   inspect that transaction's outcome.

`activity/events.jsonl` provides scheduler activity, while
`turn_traces/` holds turn evidence. Neither feed substitutes for the owning
store's result. Do not infer that a system is healthy from an old successful
run, a recently rewritten timestamp, or a quiet failure log alone.

Context preparation, after-turn promotion, cognition and builder conversation
allocation also do work at their existing event boundaries. They do not need
invented loop IDs or separate periodic health campaigns. Their owners are mapped
in [Anatomy of a Turn](ANATOMY_OF_A_TURN.md),
[Internal Workings](INTERNAL_WORKINGS.md) and
[Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md).
