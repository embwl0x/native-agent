# Automated Systems — architecture map + health probes

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
| `Sources/NativeAgentApp/BackgroundLoopsAssembly*.swift` | Construct dependencies and supply the registered manifest. |
| `SchedulerExecution/SchedulerDueJobRunner.swift` | Execute due persisted scheduler jobs. |
| `DeviceSync/MacSyncEngine*.swift` | Mobile command transport and snapshots. |

Core source paths are under `Modules/NativeAgentCore/Sources/`.
`NativeAgent.app` owns the running system in-process.

## 2. BackgroundLoops scheduler — the engine under §4

The manager serializes execution per registration. Concurrent wake requests
join the active tick rather than running a second copy. Event/deadline runners
can wake on owner changes or their next meaningful deadline; their periodic
interval is an integrity backstop.

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

A recent attempt is not proof of successful work. An idle lane's skip reason,
enabled state and next deadline matter more than a blanket freshness threshold.

## 3. Doctor — the health authority

`DoctorChecks/DoctorChecks.swift` defines `SwiftNativeDoctorChecks.defaultChecks`:
15 checks covering storage, runtime JSON, run-ledger and turn-trace integrity,
sessions and identity, prompt-prefix health, subconscious vitals, messages,
persona, memory, embeddings, iCloud, operation logs and OAuth expiry.
The app adds live checks, including background-loop health; the visible report
is not a fixed 15-row checklist.

`app {"page":"diagnostics","item":"doctor"}` runs diagnostics without repair
and returns the health rows. `Sources/NativeAgentApp/AppToolHealthHost.swift`
binds this read to `runDoctor(repair:false)` and the live checks.
`doctor.repair` is a separate action, not a read-only probe.

The configured `doctor_auto_run` lane runs at launch, when a health row turns
from ok to adverse, and weekly; it runs every safe repair and files one inbox
ask for the sign-ins and permissions it cannot do itself. Its
`doctor/latest.json` contains:

- `measuredAt`: when measurement began;
- `runAt`: when the snapshot was published;
- `checks`: the findings.

An empty set is not persisted as a clean bill of health. Some behavioral
checks memoize, so publication time alone does not establish freshness.

`Sources/NativeAgentApp/DoctorFirstTurnRefresh.swift` observes the first
durably persisted turn terminal after launch, drains the trace bus and requests
one fresh auto-doctor measurement. The configured enable switch still governs.

## 4. The loop manifest — every registered lane

`Sources/NativeAgentApp/BackgroundLoopsAssembly.swift:assembleAllLoops()`
registers **21 lanes**. The table gives production defaults; enabled state,
event deadlines, backoff and saved configuration determine actual work.

| loopId | Default wake or backstop | Work |
|---|---|---|
| `doctor_auto_run` | Launch, ok→adverse health reading, weekly; configured intervals at least 1h | Repair, publish Doctor snapshot, file one sign-in/permission ask. |
| `turn_trace_retention` | 6h | Prune expired trace data, lock sidecars and excess transcript backups. |
| `offdisk_backup` | Daily | Create an off-disk backup when due or identity changed; skip alternate roots and unavailable iCloud Drive. |
| `evolution_proposal_retention` | Weekly | Remove expired terminal evolution proposals. |
| `data_root_disk_hygiene` | Hourly, with daily reservation | Detect oversized state and file a notice; the scan does not delete it. |
| `memory_consolidation` | Weekly | Run MemoryV2 consolidation and hygiene. |
| `self_improvement_sweep` | Weekly | Stage improvement proposals; requires its switch and unattended-work authority. |
| `trigger_scheduler_due_work` | Events/deadlines; 6h repair | Run due scheduler jobs. |
| `mission_executor` | Events/deadlines; daily repair | Drain Workshop executions; this is the registered wire name. |
| `workshop_pump` | Events/deadlines; daily repair | Admit bounded Workshop work through its policy and posture gates. |
| `cognition_maintenance` | Daily | Substrate maintenance. |
| `cognition_replay` | Daily | Episodic replay. |
| `cognition_reflection` | Daily | Budgeted cognitive reflection. |
| `heartbeat` | 12h | Assess health; surface stable anomaly cards. Clean assessments skip the model. |
| `autonomy_promotion_proposals` | Events/deadlines; daily repair | Propose promotions and reconcile approved decisions. |
| `desk_notify` | Events/deadlines; daily repair | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Events/deadlines; 6h repair | Reconcile terminal delegation jobs and their notifications. |
| `github_tracking` | Events/deadlines; 6h repair | Refresh configured tracking and reconcile its consumers. |
| `telegram_poll` | Long-poll transport | Admit configured Telegram messages. |
| `slack_socket_mode` | Socket transport | Admit configured Slack messages. |

Telegram and Slack remain registered when unconfigured, using a placeholder
that reports a skip and performs no remote work. A registration is therefore
not proof that the connector is configured.

### Scheduled Dream and REM

The calendar jobs `nativeagent-nightly-dream` and
`nativeagent-weekly-rem` run through `SchedulerDueJobRunner`; there are no
separate periodic Dream or REM wrappers in the loop manifest.

`DreamREMCycle/DreamREMCycle.swift` owns the default schedule: Dream at
03:30 daily and REM at 04:30 Sunday, in the Mac's current time zone.
Read the persisted jobs and their enabled state to establish what will run
on an installation.

The nightly diary entry uses the previous local calendar day's key. Inspect
the job outcome and file modification time; absence of a file named for today
is not evidence of failure. REM stages growth proposals through the approval
path rather than directly treating a dream as permission to rewrite persona.

## 5. MacSync / iCloud bridge (Mac ⇄ iPhone)

`DeviceSync/MacSyncEngine` receives signed commands, checks their identity,
dispatches through the Mac and publishes responses and snapshots.

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

Full Mac does not remove macOS privacy-reset approval or the peer-origin
floors for deletes and irreversible acts, sends in User's name, persona writes
and protected approvals. Authenticated turns from agents enabled in Trust →
Connected agents carry User's authority and skip extra peer approvals; ordinary
Trust and domain checks still apply. Work lanes such as Workshop and self-healing
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
4. For a scheduled job, inspect its persisted enabled state, next run and last
   outcome in `scheduler/jobs.json`.
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
