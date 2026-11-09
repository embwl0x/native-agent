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
| `BackgroundLoops/BackgroundLoopsManager.swift`, `ManagedLoopRunner.swift`, `BackgroundLoopWakes.swift` | Registrations, lifecycle, execution gates, event/deadline wakes and status. |
| `BackgroundLoops/BackgroundLoops.swift`, `LoopHistory.swift`, `LoopFailureReceipts.swift` | Scheduler timing, outcome accounting, durable clocks and failure receipts. |
| `BackgroundLoops/LoopContracts.swift`, `LoopStatusEvidence.swift` | Runner contracts, outcomes, backoff, bounded tick execution and status evidence; watchdog wire keys remain unchanged. |
| `BackgroundWork` | Maintenance, work, heartbeat and connector runner bodies. |
| `EngineRuntime/EngineLaunch.swift`, `EngineComposition.swift` | Launch ordering and concrete loop composition; `EngineChatSurfaces.swift`, `EngineDreams.swift` and `EngineScheduledWork.swift` compose chat surfaces, Dream/REM and scheduled work through installed host effects. |
| `TriggerScheduler/OneClock.swift`, `EngineScheduledWork.swift` | The one clock: each declared time (`clock/times.json`), delivered once to its owner. |
| `DeviceSync/MacSyncEngine*.swift` | Mobile command transport and snapshots. |

Core source paths are under `Modules/NativeAgentCore/Sources/`.
`NativeAgent.app` owns the running system in-process.

Built-in Mac integration calls declare their integration and read/write axis
on their tool schema. Dispatch, approval, action discovery and readiness read
that declaration; `MacIntegrationPermissionStore` still owns the switches.

## 2. BackgroundLoops scheduler — the engine under §4

The manager serializes execution per registration. Concurrent wake requests
join the active tick rather than running a second copy. Every runner declares
`wake`: `.every(period)` is a rhythm; `.onChange` has no clock and runs only on
its declared changes, its next meaningful deadline and launch reconciliation.
Event/deadline runners can also receive owner changes and their own deadlines
alongside a declared rhythm. A missing event is repaired where it was lost.

Event debounces own their pending delay. A firing debounce transfers its task
into execution ownership; events during that work coalesce into one follow-up
after it exits. A firing deadline likewise transfers its task out of the sleep
slot before execution, so completion projects its successor without cancelling
itself. A deadline joining an active pass retains one follow-up reconciliation
after that pass exits, so age crossings during the pass are assessed. Stop and
replacement cancel pending waits and retained loop tasks.

A tick returns `LoopTickOutcome.completed`, `skipped` or `failed`.
A skip preserves an existing failure streak and updates live status only. Durable clocks
survive restart, and timing accounts for time already elapsed rather than
restarting a full period.

Inspect these together:

- `running`: the registration is active.
- `executing` and `executionStartedAt`: its body is currently running.
- `lastRun` and `lastResult`: the latest attempt, which may have skipped or
  failed.
- `lastSuccessfulWorkAt`: the latest completed work.
- `eventListener`: listener health for an event-driven lane.
- `wake.period`: a rhythm's period, absent for change-woken organs. Those organs
  have no periodic `nextTickAt` or status `nextRun`, and silence alone makes them
  neither overdue nor dormant. Failures, active-tick timeouts and broken listeners
  remain visible; no period is inferred from an unavailable registration.
- `logs/background_loop_state.json`: durable run, completion and first-seen clocks.
  Ordered flushes compare this complete state with the stored JSON before replacing
  it; an unchanged checkpoint writes nothing. Completed work and failures advance
  the run clock; completed work advances its separate completion clock. Skips
  advance neither durable clock and cannot claim recovery.
  Failure occurrences are `loop.failure` details in `experiences/experiences.sqlite`;
  readers fold incidents without rewriting their original occurrence times.
- `beat` details in that record: work that runs outside a loop (iCloud drain,
  launch reconcilers) records each pass as a beat with `OrganPulse.record`
  (outcome `worked`, `nothing`, `held`, `failed` or `stopped`, a note, an
  optional yield and cadence). The record compares those facts with the organ's
  latest stored beat in the write transaction; an unchanged reading writes nothing,
  including across relaunch. Every beat still feeds the live ring for liveness and
  repeated holds. Each organ retains its last 32 beats in memory, so a busy organ
  never evicts another's. Relaunch restores changed facts from the record. `OrganRecord` reads a ring: its
  latest beat, its profile (median interval, outcome mix, median yield) and
  its deviation (missed, failed, stuck, off record), derived on every read
  and never stored. `OrganBody` is the one body projection over those records:
  each organ's line (latest beat, why, next beat due) and its deviation,
  deviations first. Doctor's `live.pulses` row (titled Body) and the agent's
  `mind.body` read draw the same lines. An organ with a declared cadence is
  missed once it misses a whole beat since launch. A fresh timestamp alone does
  not prove successful work: read outcome, note and cadence together. An organ
  whose clock stopped on purpose records a `held` beat noted `off: <reason>`:
  never overdue, never felt. No beats yet means nothing is known, not a quiet
  body.
- **Felt.** The agent feels only what its body did not predict. A deviation
  not yet told to its turns rides the next turn's facts as one line ("In my
  body: …"), in every turn kind; a quiet body adds nothing. It is said at its
  start and again when its kind, onset or size changes; the
  said-memory (`mind/body_said.json`) is stamped only when the provider accepts
  a context carrying the line. `BodyNerve` re-reads the body on every beat: a
  deviation it has not felt becomes one `organDeviated` somatic signal, and a
  `failed` or `stuck` organ owes repair (operation `organ:<id>`) once, settled
  by that organ's next completed pass (`worked` or `nothing`). Its memory is
  `mind/body_nerve.json`, so a relaunch neither signals an ongoing deviation
  again nor forgets its debt.

A recent attempt is not proof of successful work. An idle lane's skip reason,
enabled state and next deadline matter more than a blanket freshness threshold.

### Pulse-owner index

Every row below is retained pass evidence. Reading `live.pulses` inspects these
records without running the writer or probing its dependency. `launch.*` rows
are launch passes, not registered loop IDs; event-only pulses have no cadence.
After approval reconciliation, `EngineLaunch.swift`'s independent memory branch
archives repair inventory, migrates legacy correction scope and stages kind
backfill; it emits no separate memory-repair or kind-backfill pulse.

| Pulse | Source writer | What its pass records |
|---|---|---|
| `launch.chat_index` | `EngineRuntime/EngineLaunch.swift` | Recovered sessions, repaired index rows and corrupt transcripts found. |
| `launch.browser_stranded` | `EngineRuntime/EngineLaunch.swift` | Successful recovery's stranded browser operations closed as outcome unknown before ingress under the [browser ownership contract](INTERNAL_WORKINGS.md#built-in-browser-operation-ownership). Failed recovery leaves browser starts unavailable while the app starts; it emits no success count. Doctor reads the retained cause. |
| `launch.approval_executions` | `EngineRuntime/EngineLaunch.swift` | Unapplied approval executions settle before independent retained memory and REM catch-up branches. |
| `launch.rem_staging` | `EngineRuntime/EngineDreams.swift` | Previously unstaged REM proposals staged. |
| `abandoned_turns` | `TurnTrace/AbandonedTurnReconciliationHook.swift` | Launch-only resume, recovery obligations and failures. |
| `history_index` | `ChatToolRuntime/ChatHistoryIndex.swift` | Transcripts/new lines absorbed and listing or persistence diagnostics; retained utility launch work independent of session-index repair. |
| `chrome_relay` | `ChromeControl/ChromeControlRuntime.swift` | Relay listening state, transport-authority failure or deliberate off state. |
| `embedding_warmup` | `MemoryV2/MemoryV2+EmbeddingRuntime.swift` | Launch embedder load, an already-loaded model or missing-store skip. |
| `icloud_drain` | `DeviceSync/iCloudBridge.swift` | Incoming drain counts/skips and the transport's current receive cadence or rest/off state. |
| `presence_beat` | `DeviceSync/MacSyncEngine+Lifecycle.swift`; `DeviceSync/iCloudBridge.swift` | Published Mac presence, starting cadence or transport off state. |
| `desk_notify` | `BackgroundWork/DeskNotifyRunner.swift` | Each admitted pass records its actual outcome; no cadence. |
| `snapshot_integrity` | `DeviceSync/MacSyncEngine+Lifecycle.swift`; `DeviceSync/iCloudBridge.swift` | Snapshot integrity findings/skipped groups, starting cadence or unavailable-iCloud off state. |
| `studio_canon` | `Cognition/NativeCognitionRuntime+StudioCanon.swift` | Canon proposals staged and works evaluated on the tending pass. |
| `horizon_expectations` | `Cognition/NativeCognitionRuntime+Expectations.swift` | Open/settled expectations and composed sources, or organism off state. |

Use the [turn recovery map](TURN_RESILIENCE.md#9-process-continuation),
[memory map](MEMORY_SYSTEM_MAP.md), [mobile transport](mobile_companion.md),
[approval records](approval-schema.md) and [organism horizon](ORGANISM.md#the-horizon-family--toward)
for the owning behavior. A pulse count is that pass's observation, not a new
delivery or repair acceptance rule.

## 3. Doctor — the health authority

The admitted morning-brief ability assembles its checked sources for direct
and scheduled calls. Its primary-root worklog path is the external-path
owner's `InstallPaths.current.claudeWorklog`, also read by the Agents view.
Secondary roots leave that source unconfigured. The scheduler supplies only
`operation:"brief"`; it retains consent, occurrence claims and publication.

Activity history rejects negative retained event counts and reports unrepresentable
rollup conversions or merged counts as source errors, leaving stored rows intact.
Clearing history orders the current span's close, deletion and a fresh permitted
span through the capture pump, so later capture never targets a deleted row.
An idle-closed capture resumes on the canonical person-here event through the
normal activation/privacy gates. The sampled idle-resume path remains available
where physical-input observation is unavailable.

`DoctorChecks/DoctorChecks.swift` defines `SwiftNativeDoctorChecks.defaultChecks`:
17 checks covering storage, runtime JSON, run-ledger and turn-trace integrity,
sessions and identity, prompt-prefix health, subconscious vitals, model
compensations, messages, persona, memory, embeddings, ability files, iCloud,
operation logs and OAuth expiry. The app adds live checks, including
background-loop health; the visible report is not a fixed 17-row checklist.
`Model compensations` (`model.shims`) is a read-only count of `shim.fired`
receipts by census ID in a bounded measurement window, excluded from heartbeat
sweeps.
Prompt-prefix token aggregation uses checked sums; an unrepresentable total is
unmeasured with a failed row naming the provider, turn, session and timestamp.
Prefix health, subconscious vitals and model compensations measure only a valid
stamp from this process launch and build. Missing or invalid launch evidence is
unmeasured; it never selects an older 24-hour window. A damaged Doctor snapshot
or iPhone snapshot-skip ledger is a named storage failure. Fresh readings retain
any failed snapshot publication alongside their measurement.
Absent Auto Doctor settings use fresh-install defaults. An existing unreadable
or invalid configuration disables automatic/startup execution and makes its
registered tick fail with the file path and cause; the bytes remain untouched.
Incomplete disk accounting retains unreadable paths and causes in its outcome,
preserves prior notices, and releases the daily reservation. A partial scan
cannot claim disk clean or retire an existing finding.
Weekly analysis distinguishes absent transcripts, error feeds and Doctor reports
from unreadable or malformed evidence. Unavailable sources fail before synthesis
and release the weekly reservation instead of supplying measured zeros. Its
outcome evidence is their jobs that ended this week and last
(`AgentJobs.weeklyOutcomes`); an unreadable job store fails the pass.
Heartbeat also keeps source availability: a missing checklist is off, while an
unreadable checklist fails its tick; job, task and error-log read failures
produce an unavailable assessment. A job whose owner reports `.needsYou` raises `job-needs-you`;
a ledger task whose owner reports `.blocked` raises `tasks-blocked`. Age alone supplies no work-health verdict. Incomplete durable-residue categories are
named as unavailable and cannot clear their review card. Failed child-watch
registration records its path, cause and rearming remedy while retaining the
parent watch. Watchdog snapshots encode the live runtime lifecycle and running
execution counts; retired daemon and LaunchAgent fields are absent.
The weekly response requires a nonempty summary, complete typed findings and
standing rows, including valid runtime operations. Invalid responses stage
nothing, retain their returned bytes in the failed digest and release the week.
Standing lessons require recurrence across two independent conversations,
covering half their observed turns and two thirds of the week's conversations;
eligibility has no fixed lifetime-use or installation-volume floor.

Saved-provider read failures and failed native provider probes report `fail`;
explicit connection checks probe the current saved credential, including OAuth,
instead of reusing historical successful traffic. An unhealthy provider path reports `warn`. A stale probe retains an adverse
registry verdict and otherwise reports `unmeasured`; a readable compensation
scan without a v2 turn is also `unmeasured`. `off` and `not needed` remain
distinct non-fault states, not evidence of healthy work.
Doctor and Support rollups retain `unknown` for empty inventories or unclear
statuses and `unmeasured` for readings without a verdict, after preserving any
failure or warning. A healthy sibling cannot turn an incomplete check healthy.
The autonomy row describes policy only; running improvement counts belong to
the background-loop watchdog. Session and transcript integrity checks use
`ChatSession.init(row:)` on the checked index and `SessionHistoryReader`'s full
checked history, including message identity and provenance damage. Doctor has
no separate, looser message schema.

`detail` stays evidence prose; remedies and executable calls have their own
fields. `repair_available` records handler availability; `repair` describes
that executable repair and never becomes a human step by its wording.
A check declares its human recovery step in `human_action`. Older cached rows with only
`repair` prose need a fresh reading to establish their current human remedy.

`app {"page":"diagnostics","item":"doctor"}` reads the saved report
(`Sources/NativeAgentApp/AppToolPlatform.swift`) and names the run it shows;
`doctor.run` measures afresh, and `doctor.repair` is a separate action, not a
read-only probe. Runtime JSON, persona and transcript checks only inspect; persona health uses
`PersonaCompiler` so an unreadable canonical document reports its filename;
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
- `checks`: the findings; an unreadable config is a fault with its file,
  never "off".

Repair acceptance follows the [repair law](EXPERIENCE.md#repair-is-owed-users-law-10-18).
For a loop's owed repair, a clean tick newer than the obligation proves the loop
runs again, including a legitimate "nothing to do" tick; restarting its
registration alone does not.

The runtime page envelope adds `report_completed_at` and, while a run is active,
`run_in_progress` to identify the report shown and the newer run still in flight.
`report_availability` and `report_issue` retain the latest full run's availability;
running or failed runs leave older checks inspectable under `report_status`,
but `status` and `active_path_status` remain unavailable. The health pill and
Doctor headline also keep that unavailable state, even after live rows refresh.
Shortcuts admits and settles its run through the same live Doctor facade as
the UI and automatic runs. The Diagnostics header reads that latest-run
availability before retained checks and says every check passed only when all
rows were measured and passed; empty, unmeasured or unclear checks stay incomplete.
Only a completed full run clears a failed-run issue. Current route details come
from one checked provider snapshot at the Doctor facade's own root. A failed
read is a structured `current_route_issue` and makes the envelope unavailable;
an absent provider is not a route-read failure.
Health-cache reuse requires the current `launchID` and a `runAt` age from zero
to less than 60 seconds; a fresh core reading never merges rows from an earlier
launch.

Living status subscribes to `ForPerson.changes()` for Inbox matters alongside
cognition changes and its current durable inputs. It does not watch the retired
`notifications/inbox.jsonl`. The runtime owns these subscriptions until quit;
the shared refresh coalescer and `LatestRead` publish their completed reads.

An empty set is not persisted as a clean bill of health. Some behavioral
checks memoize, so publication time alone does not establish freshness.

`script/organism_doctor.sh` reads phone evidence only from
`<dataRoot>/mobile_snapshot_cache/snapshots/organism_living_status.json`, where
`NATIVE_AGENT_DATA_ROOT` selects the root (default: this checkout's `data`).
Missing evidence stays unavailable; there is no machine-wide snapshot search.
The reader checks the bare status object and reports the ISO 8601 `generatedAt`
as its last state-change time. An unchanged snapshot's old time is not a stale
Mac verdict; transport presence owns last-seen.
`NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT` explicitly selects a diagnostic file and
is labeled as such rather than establishing the active phone's health.

### Live and status reading index

These are the owners of fresh health collection, not extra probes launched by
reading the saved Doctor page. In the last column, a probe means exercising a
service or querying a live dependency beyond reading its retained state.
Local file and snapshot reads still can fail. Repair remains a separate action.

| Check | Source owner | What it measures | Does collection probe? |
|---|---|---|---|
| `live.providers` | `EngineRuntime/EngineDoctorMeasurements.swift`; `EngineRuntime/DoctorProviderPathReading.swift` | Saved authentication, active route and native connection-test reading. | No new connection test; reads the provider status feed. Explicit connection tests probe the saved credential. |
| `live.memory` | `EngineRuntime/EngineDoctorMeasurements.swift` | Mounted canonical store attachment, query response, graph reconciliation failure and SQLite integrity. | Yes: queries the running store each time; `quick_check` is cached between integrity readings. |
| `live.bridges` | `EngineRuntime/EngineDoctorMeasurements.swift` | Expected local listeners, bound ports and startup failures. | No; reads listener snapshots. |
| `live.mac_operation_recovery` | `EngineRuntime/EngineDoctorRuntime.swift`; `MacControl/MacControlOperationStore.swift` | Mac owner's launch-recovery admission state, original failure and repair; unavailable refuses Mac effects while looking and other surfaces remain available. | No; reads owner state, never runs recovery. |
| `live.browser_operation_recovery` | `EngineRuntime/EngineDoctorRuntime.swift`; `Browser/Browser+OperationStore.swift` | Browser owner's launch-recovery state and individual damaged run causes. Uncertain damaged runs refuse new effects; valid sibling rows remain readable and damaged row bytes stay intact. | No; reads owner state and canonical runs, never runs recovery. |
| `live.agent_connections` | `EngineRuntime/EngineDoctorMeasurements.swift`; `AgentConversations/AgentContactHealth.swift` | Contact readiness, saved reply-path evidence and open connection repairs. | Refreshes readiness; definite unsent failures remain `not_reached` with current readable prerequisites, without reply-path repair. May schedule bounded connection verification for a possibly delivered failed path, without resending its message. |
| `live.telegram` | `EngineRuntime/EngineDoctorMeasurements.swift` | Configuration, credential availability, poller state and fresh successful-poll evidence. | No new Telegram request; reads the transport's evidence, separately from loop registration. |
| `live.search` | `EngineRuntime/EngineDoctorMeasurements.swift` | Configured SearXNG URL and bounded checked search response, retaining probe failures separately from refused listeners. | Doctor runs probe; ordinary live refresh reads the retained result, valid for that URL for less than ten minutes. Repair checks/starts only that configured server; explicit setup owns discovery and endpoint selection. Only the Repair button may open Docker Desktop; background repair reports unavailable inventory when its daemon is down. |
| `live.tools` | `EngineRuntime/EngineDoctorMeasurements.swift` | Authored tool registry readability and saved admission states. | No tool invoked; execution remains unmeasured. |
| `live.autonomy` | `EngineRuntime/EngineDoctorMeasurements.swift` | Saved enable posture and reported autonomy runtime state. | No unattended work started. |
| `install.data_root` | `EngineRuntime/EngineDoctorMeasurements.swift` | Installation move marker and any recorded backup location. | No; reads local installation evidence. |
| `live.inspector_feed` | `DoctorChecks/DoctorRunsInspectorChecks.swift` (`InspectorFeedHealth`) | Whether an open Inspector observes persisted trace changes. | No; reads observation state. |
| `live.embedding_download` | `EngineRuntime/DoctorEmbeddingDownloadCheck.swift` | Runtime mode, distribution descriptor, installed release/epoch and retained transfer state. | No transfer or model-load check started; reads local owners and saved parts. |
| `live.background_loops` | `BackgroundWork/DoctorLoopHealth.swift` | Aggregate manager execution, cadence and listener health. | No tick started; evaluates manager/receipt evidence. |
| `live.background_loop.<loopId>` | `BackgroundWork/DoctorLoopRecovery.swift` | Each configured registration's health and any repair still awaiting a clean tick. | No tick or restart started. |
| `live.pulses` | `EngineRuntime/EngineDoctorMeasurements.swift` | The Body view: each organ's `OrganBody` line, deviations first (the same lines as `mind.body`). | No organ pass started. |
| `live.cognition.runtime` | `EngineRuntime/EngineDoctor+Cognition.swift` | Mounted cognition readiness. | No; reads the mounted runtime after its bootstrap. |
| `live.cognition.persistence` | `EngineRuntime/EngineDoctor+Cognition.swift` | Persistence state, blocked writes and failure stage. | No restore attempted; reads the cognition snapshot. |
| `live.cognition.receipts` | `EngineRuntime/EngineDoctor+Cognition.swift` | Availability of persisted cognition loop receipts. | Reads receipt evidence; no loop run. |
| `live.cognition.readouts` | `EngineRuntime/EngineDoctor+Cognition.swift` | Enabled mood/body values and body-sample freshness. | No new body sample; validates retained readings. |
| `live.cognition.body` | `EngineRuntime/EngineDoctor+Cognition.swift` | Body dependencies and a due residual repair opportunity. | No residual repair run. |
| `live.cognition.capacity` | `EngineRuntime/EngineDoctor+Cognition.swift` | Node and workspace counts against configured caps. | No; reads snapshot counts. |
| `live.cognition.associations` | `EngineRuntime/EngineDoctor+Cognition.swift` | Whether displayed association endpoints resolve in the current node snapshot. | No graph repair; compares snapshot identifiers. |
| `live.cognition.context_flow` | `EngineRuntime/EngineDoctor+Cognition.swift` | Context Flow registration, source errors and arena pressure. | No reconciliation; reads the owner's health state. |
| `live.cognition.phone_pairing` | `EngineRuntime/EngineDoctor+Cognition.swift` | Checked pairing authority and the bridge's pairing/last-exchange assessment. | No phone message sent. |
| `live.phone_notifications` | `EngineRuntime/EngineDoctor+Cognition.swift` | Checked paired-phone authority; optional APNS credentials and wake outcomes do not gate ordinary notifications. | No push sent; unreadable authority reports unavailable. |
| `status.desk_attention` | `EngineRuntime/EngineDoctor+StatusChecks.swift` | Canonical Desk/approval state, waiting work and parent/descendant contradictions. | Reads stores and calls the diagnostic narration part; parent reconciliation runs only on the repair path. |
| `status.activity` | `EngineRuntime/EngineDoctor+StatusChecks.swift` | Activity readability, malformed rows, recent failures and unresolved effects. | Reads retained activity and calls the diagnostic narration part; no effect replay. |

Domain laws remain in the [memory map](MEMORY_SYSTEM_MAP.md),
[authored-part manifest](skill_manifest_spec.md),
[action authority](TOOL_LOADING.md#authority-and-receipts),
[cross-surface ownership](INTERNAL_WORKINGS.md#6-one-agent-across-every-surface),
[capability map](CAPABILITIES.md), [cognition wiring](COGNITION_WIRING.md)
and [experience/repair law](EXPERIENCE.md). This table identifies measurements;
it does not grant a repair or infer delivery from setup.

## 4. The loop manifest — every registered lane

`EngineRuntime/EngineLaunch.swift` registers the lanes. The table gives the
lanes and their production defaults as of this writing; the installed set is
`logs/background_loop_state.json` and Doctor's aggregate `live.background_loops`
row, with individual readings at `live.background_loop.<loopId>`. Enabled state,
event deadlines, backoff and saved configuration determine actual work.

Senses registration never gates this manifest or its resident observations.
Loops start together, including Telegram/Slack ingress, reply reconciliation
and Desk notifications. A loop's work that actually selects a sense waits at
the shared read door; sense wakes and file subscriptions wait at their own
owners. Doctor retains registration failures and their repair instructions.
An explicit run of a stopped loop follows the same per-read rule. See
[sense readiness and repair](SENSES.md) for bounds and subscription recovery.

| loopId | Declared wake | Work |
|---|---|---|
| `doctor_auto_run` | Launch, ok→adverse health reading, weekly; configured intervals at least 1h | Repair, publish Doctor snapshot, file one sign-in/permission ask. |
| `offdisk_backup` | Daily rhythm, identity changes, daily deadline | Back up when due or identity changes; skip alternate roots and unavailable iCloud. |
| `data_root_disk_hygiene` | Daily rhythm/boundary; hourly retry while unreserved | Detect oversized state and file a notice; never delete it. |
| `cognition_maintenance` | Daily | Substrate maintenance. |
| `cognition_replay` | Daily | Episodic replay. |
| `heartbeat` | 12h rhythm + assessment-input changes + age deadlines | Assess health; surface stable anomaly cards. Clean assessments skip the model. |
| `desk_notify` | Declared changes, next nag or quiet end, launch | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Events/deadlines; 6h repair | Reconcile terminal delegation jobs and their notifications. |
| `heartbeat` | Assessment-input changes + age deadlines; 12h integrity | Assess health; surface stable anomaly cards. Clean assessments skip the model. |
| `desk_notify` | Events/deadlines; daily repair | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Events/deadlines and a 6h integrity rhythm | Reconcile jobs and notifications; failed settlement still needs this rhythm. |
| `delegation_outcome` | Events/deadlines; 6h repair | Delegation outcomes; the contact doors' reply reads and settled Desk waits. |
| `telegram_poll` | Long-poll transport | Admit configured Telegram messages. |
| `slack_socket_mode` | Socket transport | Admit configured Slack messages; socket failure is reported and reconnects that same transport, with no Web API ingress/history polling. |
| `presence_beat` | Mac activity edges + 240s renewal; 300s due-only reconciliation | Publish canonical presence on launch, activation/deactivation, wake, network regain and completed conversations. Renew inside the phone's 300s contact window; never renew unchanged snapshots. Independent transport-owned reads continue at 20s regardless of publication outcome. Ship the phone freshness reader first. |

`desk_notify` offers each admitted outcome as a beat with no cadence, including
repeated failures. It
watches Desk ops/base, nag config, the desk-notify part, live inbox and user
preferences. `ForPerson` emits only changed matters, so an unchanged Desk
question cannot wake this evaluation and its run accounting again; see the
[unchanged experience law](EXPERIENCE.md#delivery-and-face). Its CPU-only proposal
calls no action and changes no notebook, so a successful evaluation writes no
run accounting under the [run evidence contract](skill_manifest_spec.md).
The macOS background activity for the weekly sweep
reads that runner's declared default period and refuses a change-woken entry.

Telegram and Slack remain registered as disabled when unconfigured and perform
no remote work. Saved-configuration or credential read failures register as
unreadable, so unavailable credentials do not appear disconnected. Launch and
restart use the same registration factory. Registration alone is not proof
that a connector is configured.

The Mac's mobile receiver uses push, launch, network/KVS wakes and explicit
refresh. A failed push registration reports its cause without a timed drain.
Snapshot integrity uses exact file/store invalidations and launch reconciliation;
there is no periodic missed-event pass. Unreadable held-notification or proactive
scan inputs fail at their owner and retain owed work rather than count as empty.
Proactive scans use the checked approval, inbox and Desk projections.
Their creation and execution share `ProactiveScanArguments`: `reason`,
`limit` (1–50), `surfaceLimit` (0–12) and `staleDays` (positive integer).
Missing optional arguments use their declared defaults; malformed or unknown
arguments are refused. The retired numeric coercions, `surface_limit`,
`stale_days` and unused `sources` input are removed.
Notification release reads the immutable delivery ledger described in
[Internal Workings](INTERNAL_WORKINGS.md). It does not rewrite its watched
inbox. Channel suppression settles once; only destination acceptance is
delivery, and unknown sends await evidence.

Completed periodic work persists its admitted start for cadence across relaunch;
successful work keeps its separate completion timestamp. A long-running tick
therefore does not add its duration to the next period after a restart.

A Desk continuation whose helper run is still queued or running remains a
live domain wait. Unknown terminal effects stop the continuation for domain
verification.
Requested helper replies follow queue and shelf changes, without a thirty-second
pending-result poll. A helper's cadence is its `helper:<id>` time on the one clock
(`StandingBots/BotRunnerScheduler.swift`); a requested run runs once queued. A
helper's cron cadence declares its rhythm on that clock, including when an old
runner occurrence is carried over and after each delivery, so a live time-zone
change preserves its pending local date and minute. Existing declarations missing
that rhythm gain it without moving their pending occurrence. Interval cadences
stay absolute and retain the helper's minimum spacing. The retired
`runner-tick.json` pass ledger is neither read nor written; a quiet
interval between source changes cannot prove Mac sleep.
Receipt-only delegation outcomes complete the same idempotent downstream
settlement before their cursor advances; they still suppress redundant cards.
Delegation snapshots carry the contact's declared name into cards and resident
notices; without one they preserve the original identifier and spelling.

The `delegation_outcome` runner reads contact owner changes and the
quiet-hours end; its pass reads contact replies and returns settled Desk waits
(`EngineComposition.reconcileAgentConversations`). Neither decides that the agent
thinks: what comes back is a `returned` happening posted through `Attention.post`.
A return opens at once in the conversation that
started the work (`MindStream.returnTo`) through `TurnAdmission` as a hidden
arrival; a turn open there reads it and answers it, with no second delivery.
Otherwise it runs there and its reply uses that door. A return to an agent
conversation binds its one saved answer as a send, held by `AgentConversationStore`
for that contact's next door call (`AgentContactHeldAnswer`); its `agent-held` route
excludes person-result notifications. Completion records `completed` with
`held_for_contact` at the handoff; actual delivery settles only when the door writes
the held message. A return whose conversation or route is unavailable stays owed
to that conversation with a repair. A helper's own Desk wait returns to the agent's
mind stream, never into the helper's session. Abandoned-turn reconciliation runs
once at launch, with no completed-turn observer or five-minute throttle.

Reply tasks wake on contact push, conversation-store changes or an explicit read.
Silence never expires a reply or schedules a read retry. Launch reconciliation
resumes saved queues. Each contact retains one ordered
reply task, while other contacts can receive their own replies immediately;
there is no shared three-reply or one-turn cap. Completing a contact's work
invalidates its canonical conversation file through the store change bus.
Stop cancels and drains these tasks before closing their transports. A failed
read or write retains attention and repair with its cause. A pending task with no
event remains waiting and can be read or cancelled explicitly.

Heartbeat findings and age deadlines share each source's admission scan,
including bridge delivery and acknowledgment exclusions; deadline reads do not
mutate inbox cards. Its 12-hour rhythm also reads nested records outside its
initial nonrecursive file subscriptions and error rows whose bounded evidence
is too short to project an expiry.
The heartbeat interval override must fit UInt64 nanoseconds and be at least one
second; invalid configured values fail the tick explicitly. Scheduler sleep
conversion checks the rounded floating-point boundary before converting.

Stopping background scheduling closes bot admission and joins the retained
managed tick; one outer timeout selects the caller's verdict, with due and
lifecycle checks after gate admission. The retained child's value owns actual
exit; its gate releases only after body exit and outcome accounting.
managed tick owned solely by `BackgroundLoopLifetimes`; its timeout runs the operation directly, with due and lifecycle
checks after gate admission. The physical worker stays held through settlement.
Helper sessions settle on their actual result, error or explicit Stop. Their live writer claim remains running until that settlement;
no wall-clock overrun marker is produced.
Helper arguments use their declared closed schema after reference and null
normalization; route admission and `BotDefinitionStore.check` retain semantic
validation. A seconds budget is a positive finite number, including fractions.
Helper definitions accept typed cadence, event and budget values; each Mac or
phone form parses its own controls before calling the definition owner. A
failed fresh definition read does not imply an unpaused helper. Event hold
receipt failures report their storage cause through scheduler availability.
Before execution, provider, unattended and daily-ceiling refusals settle the
exact queue request as refused and retire its claim. Admission commits the
exact claim or refusal before removing the queued request. A failed claim
write retains the queue entry; a later interruption retains the claim and
requires its exact settlement evidence before reconciliation can proceed.
Only an execution that lost settlement is reconciled as interrupted. Daily
reservations read and write only that helper's own `bots/<id>/daily-spend.json`;
no fleet-wide allowance is
charged against a new helper.

### Intentions and body rhythms

What the agent means to do later is a MY QUEUE intention, filed through
`queue.add {text, when, until?, say?}`. Each step's next time is a `moment:<handle>`
time on the one clock, and what comes due is posted once as a `moment` happening
([Intentions](INTENTIONS.md)). Every declared time is a `TriggerScheduler/OneClock.swift`
time (`clock/times.json`), its next occurrence saved before delivery, delivered once
to whoever declared it (`EngineScheduledWork.registerClockOwners`): `part:<id>:<cron>` (a part header's `schedule:` wake; the
clock posts its signal and the run is the part's), `watch:<id>` and `scan:<id>`,
`brief:<name>` (inbox briefs), `helper:<id>` and `moment:*`.

`schedule.create` schedules only reads: `connector_action` (a watch) or
`proactive_scan` (`TriggerScheduler/ScheduledReads.swift`). Any other kind is
refused as unsupported before timing normalization; the action's description
points intentions, check-ins and reminders to `queue.add`. `schedule.list` lists the scheduled reads;
`schedule.cancel` requires the canonical ID returned by listing. It and `schedule.delete` share `scheduler_cancel_job`, which
withdraws the read's time and leaves a read already running alone. Creation and
cancellation require Scheduler Write. `clock/times.json` is the declaration
owner. Engine launch reads no retired scheduler rows or migration marker and
attaches helpers without importing their retired runner jobs. Watch and scan
handlers register independently; an item's failure names that item while its
healthy siblings retain their declarations.

### Scheduled Dream and REM

Dream surprise reading preserves source-read causes. An unreadable correction ledger fails dream synthesis before the consumed cutoff
advances; a partial reading cannot stand in for complete correction evidence.

Attention admits the night through `MindStream.night`; its source and policy are owned by
[Subconscious: Attention](SUBCONSCIOUS.md#attention). Launch withdraws `sleep:night` and `rem:weekly`;
there are no sleep or REM clock handlers. Each night offers REM to its existing gate.
Dream and REM failures owe repair on `attention > night`, naming `mind.dream` or `mind.rem`.
A completed dream keeps its result if diary presentation fails and reports that separate failure.
REM consumes the REM owner's typed outcome: a skip keeps its reason in the receipt;
a completed pass with proposals files one card (`ClockWork.surfaceREMResult`).
A scheduled dream report with errors and no written entry files a critical
`dream_cycle` card and routes adverse attention before archiving older dream
cards. It reaches the phone even through quiet hours; a no-work or disabled
pass still produces no interruption.

The same `mind_run` action family supports immediate owner passes:
`app {action:"mind.dream"}`, `mind.rem`, `mind.think_now` and `mind.reflect`
retain their existing manual gates; `mind.night` reads the night's reading of
their parts (verdicts and candidates, numbers and ids), changing nothing.
`mind.sleep` requests a night through the same owner; one night runs at a time.
It awaits the owner's [admission outcome](SUBCONSCIOUS.md#attention) before reporting
started, already running or failed with its cause; the accepted night continues in the stream.
Clock times have no run-now verb: running one early would consume its real
occurrence. `mind.dream` runs a real dream and
changes their; `app {action:"mind.dream", preview:true}` instead generates and
decodes on current lived material, reporting care judgments through the same
apply checks on a copy. It spends provider usage but writes no diary, cutoff,
care, lesson, mood, Experience or wake, and leaves the schedule intact. Preview
does not drain owed moments. The six clock verbs (`MindClockVerb`) refuse preview
with a specific explanation before entering their effectful owners. Preview receipts
remain only redacted `mind.run_now` traces with `preview:true`; dispatch, provider
health/usage and repair evidence cannot turn an inspection into lived learning.
Other cognition clocks have matching immediate verbs, and `mind.cross` posts a
line as a world happening; [Subconscious](SUBCONSCIOUS.md#run-a-clock-owner-now)
owns their contract.

The diary entry uses the night's start date in the local calendar. Inspect the admission row
and dream outcome; absence of an entry alone is not evidence of failure. REM stages growth proposals through the approval
path rather than directly treating a dream as permission to rewrite persona.
Turn preparation reads the REM pin index through a checked cache: only a
missing index is empty; unreadable or invalid bytes fail the turn with the
owning path, without serving stale pins or rewriting the file.
Each saved dream section carries its claim-source block, immutable `dream-id`
and consumed-message cutoff. Before publication or effects, one durable
`dream_diary/work/<section UUID>.json` record lists the exact write, care/self input,
reflection judgment and integration, mood, completion signal, lessons and citations.
The [dream settlement law](COGNITION_WIRING.md#the-subconscious-loops--schedule-artifacts-re-entry) owns their ordering:
readable care evidence precedes the cutoff, the produced reflection receipt precedes
care/mood effects, and each effect records done or explicitly skipped. Failure notes
never gate retry. Every admitted real pass retries still-owed work across active and
archived nights, including when no new material exists. Completion is delivered from
that record after Stop or recovered publication; body-off completion is skipped.
Settled journals remain complete and permit force replacement; checkpoints leave
diary bytes stable. Dated mood and body completion claims persist with their effects.
REM checks complete claim blocks section by section, names damaged sections and
processes readable siblings. Damaged entries remain active past archival age,
and the next REM reads all active dates so late repairs are not lost.
REM excludes identity metadata from its model input. A failed evidence reading
releases the weekly claim if no proposals were saved; durable proposals keep
their IDs for staging. Archival shares the dream reservation so it cannot move
a file during publication.
Under the run reservation, the next pass reconciles `.dream_state.json` from the diary,
including archived entries, before gathering new material. A crash between
saving a section and advancing the mark therefore does not dream it again.
Archival removes an identical top-level duplicate only after comparing its
bytes; differing same-name entries are both retained, with a unique suffix
on the incoming copy. Existing archived writing is never replaced.

PersistenceCore's once-per-period reservation durably writes both the admitted
stamp and any restored prior bytes. Restoring confirmed absence removes the
stamp and syncs its parent directory under the same reservation lock.

The separate nightly practice compiler and its post-dream wake are removed
([Habits H4](HABITS.md#h4--one-crystallizer)). Dreams no longer start candidate
nomination, tape recording, keep turns, replay or admission. Repeated hand
work reaches their as a practice note inside the turn on its second meeting; no
`practice.night` rows or candidate ledger/tape writes remain.

### Scheduled reads are watches

The rhythm grammar (`TriggerScheduler/SchedulerRecurrence.swift`) refuses timestamps
outside Gregorian years 1–9999 or the checked occurrence-millisecond domain;
occurrence keys and next occurrences use the same checked conversions.

A `connector_action` read's `actionId` is any action of the app door (the agent's
parts as `authored.<id>`, the Mac's readers such as `mail.recent` or `mac.look`), and
it runs through that one door like any of the agent's calls (`ToolsFacade.withPartDoor`,
origin `scheduler:watch:<action>`), as a read. An action whose class, as the
door judges it as it runs (`PermissionLaw.doorClass`), is not a read is refused
when it is scheduled, with the sentence that a watch reads and that acting on a
schedule is a part's `schedule:<cron>` wake; each run asks again inside the door,
so a part rewritten to write since is refused there and nothing runs. Authored
read classification includes every declared primitive permission and action
dependency; `readOnly:true` cannot override modifying reach. Watches and turn
expansion use that same canonical classification. Native argument-sensitive
reads retain their enforced argument policy. A read the
door refuses or that fails owes repair on `clock/times.json > watch:<id>`; a
read that completes settles it. Each read is then compared with the watch's own
last read, on CPU with no model call. Its rows
are object or scalar observations (including arrays of either) of what the read returned: under the door's
receipt (`result`), a part's own answer (`returned`), never its runner's
ledger (`calls`, `changed`) or receipt status. The door's read/effect flags and
execution stamp are removed before checking the content's shape. Single objects retain nested detail,
including screen controls. An object's top-level arrays project their entries as
rows, while its non-array fields stay together as one observation, even when
those arrays are empty. Null or status-only results fail explicitly and keep
the previous baseline; an empty array is an observed empty collection.
A row is known by its identifier fields
(`id`, `…Id`, `…_id`) when it has them, else by its digest. The keys a read saw
are kept beside its clock time (payload `seen` in `clock/times.json`). Rows new
since the last read are posted to `SenseNewsBoard` as one notice whose observation
is the watch, which posts it as a `world` happening, so a later read's notice
replaces it rather than piling up; the first read only keeps what it saw, a read that did not complete keeps the last keys,
and a changed read advances those keys only after durable news acceptance
(a failed news write fails the occurrence and retains its prior baseline),
and nothing new posts nothing. The occurrence output names the count
(`newRows`). The Mail, Calendar and Reminders recipes in
`Resources/abilities/mac-watch-catalog.js` are such watches (`mail.recent`,
`calendar.upcoming`, `reminders.due_today`). A watch naming an action the door
does not have keeps its time and owes that refusal as repair on each run.
The catalog supplies recipes and words. `MacAssistantStatusResult` owns their
displayed readiness: each recipe's `jobPayload.payload.actionId` selects its
native access row, and both display that row's status. The recipe carries no
separate access prerequisites. A missing or unrecognized source action leaves
that recipe unavailable with its cause, without hiding the other readings.

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
The generator owns one running projection and a dirty follow-up, without a trailing clock;
termination joins accepted writes after
draining storage-owned pokes. Accepted canonical writes are not cancelled;
writes after projection closure are reconciled on the next launch.

Repair the canonical memory or generator when the projection is wrong; a manual
edit to the generated document is not a durable fix.

For after-turn promotion, proposal review and recall, see
[Internal Workings](INTERNAL_WORKINGS.md#2-anatomy-of-a-memory).

## 7. Approvals & trust gating

Composed calls carry the approval membrane's exact-call decision to the app
dispatcher and record it once. A changed tool, input, surface, turn or session
cannot reuse that decision; nested calls enter their own admission. Direct app
dispatch still enters SecurityCenter when no outer membrane served the call.
After a person answers a waiting card, the membrane refreshes hard blocks before
carrying the approved decision to execution.
Synchronous saved-policy consumers and authorization share TrustCenter's checked
reader; saved flag reads retain their declared defaults and report damaged state.
MacControl reads posture through `PermissionLaw` from the retained policy.

`ApprovalInbox/ApprovalInbox.swift` owns
`workflows/approvals/requests.json`. A pending request is a decision waiting
to be made, not automatically an automation failure. Read its origin, bound
action, decision and execution outcome.

Full Mac does not remove macOS privacy-reset approval. A turn an untrusted
agent started with its message gets one card on its first effect, and the
answer covers the rest of that turn; a read steers nothing. Agents enabled in
Trust → Connected agents carry the owner's authority on authenticated turns;
ordinary Trust and domain checks still apply. Unattended work (part wakes,
reflection, resumed turns) is admitted by
`UnattendedWork.allowed`: saved autonomy, Full Mac, or a checked Full Mac grant;
per-lane enable switches remain separate. A clock delivery does not grant
authority.

Their own hour is a presence opportunity through attention, at most once per local day during an observed active hour with its switch on.
It has no scheduled delivery or separate wander turn; its ordinary thought carries its material and owns its actions
([Subconscious](SUBCONSCIOUS.md#the-hour)).

The agent owns their mind's enable switches on Settings: memory recall, graph
and promotion, semantic memory, inner life and reflection, their hour,
overnight revision, dreams/REM, image understanding, document-reading
preferences and context flow. `setting.set` changes them both ways without
a quoted request or Trust-mode admission. The fields and stored choices stay
where they are; saved policy reads and writes remain checked. Missing
adaptive promotion is enabled, matching the running memory gate. The DOCX
preference is saved, but DOCX attachment ingestion remains unsupported.
Screen capture, cloud voice and image generation keep their Trust rules;
the keep gate, memory disclosure and REM proposal approval are unchanged.

See [Tool loading](TOOL_LOADING.md#authority-and-receipts) for the action
boundary and [Approval schema](approval-schema.md) for stored records.

## 8. Bounded inspection

Start with the smallest evidence relevant to the reported problem:

1. Establish the running root with `agent.introspect`.
2. Read the relevant app page or Doctor's non-repair report.
3. For a loop, compare its result, successful-work clock, listener health and
   failure receipts with its configuration and deadline.
4. For a clock time, read `clock/times.json` (each time's id `<owner>:<key>`, rhythm
   and next occurrence) and the owner's owed repair. The next occurrence moves
   forward and is saved with its consumed occurrence before delivery, so an occurrence is delivered at most once;
   one that came while the app was quit is delivered once when its owner registers.
   Duplicate saved IDs fail the checked read. Recurrence calculation is checked: a failed recurring item remains pending and owes
   named repair while healthy siblings proceed; it is not ended or immediately rearmed as a clock retry. Clock read/save failures owe
   named repair through the experience owner.
   One deadline is armed at the earliest handled time; a clock or zone change
   re-arms from what is saved (`TriggerScheduler/OneClock.swift`). A zone change while the clock is alive preserves each pending calendar
   occurrence's civil date and minute, resolves it in the new zone and saves before delivery. Intervals and explicit one-time instants stay absolute.
   A live Time carries its projection zone across declaration/listing suspensions; projection metadata alone never rewrites the saved time.
   An ended one-shot stays in the same clock as delivery evidence, outside pending listings and deadlines. Restore retains that evidence even for ids
   absent from the selected backup; withdrawing later work also retains its consumed occurrence.
   The saved Time contains `id`, `rhythm`, `next`, `payload` and optional `delivered` occurrence / `ended` flag, with no projection zone or civil occurrence identity. A time-zone change
   while the app is quit therefore leaves the saved instant unchanged on relaunch and may deliver at the wrong local hour. That case remains
   deferred; it needs durable civil-occurrence evidence and an explicit treatment of already saved unzoned times.
   Inbox triggers accept their card once under the inbox owner's lock before
   settling the occurrence. Delivery snapshots accepted cards before any knock,
   including cards with notification disabled; duplicate acceptance never knocks.
   Trigger claim admission locks configuration then state, re-reading the current
   enabled definition before the durable claim. Repair requires an exact retained
   unfinished occurrence and explicit current-life identity under the state lock;
   a sole retained occurrence may be selected when the optional occurrence is
   omitted. Missing, corrupt, stopped or ambiguous evidence produces no effect.
   The same admission transaction checks current configuration, inbox consent,
   cancellation and retained claim evidence before preparation runs any model or
   tool. Disabled retained occurrences settle as `disabled` without preparation;
   they are removed from unfinished claims and their repair obligation settles,
   without claiming a fire. Missing authority never seeds a repair definition.
   Publication rechecks the enabled definition and notification consent under the
   same config → state lock order after preparation. Repair never becomes manual
   fire. Unsupported trigger rows are reported rather than hidden; inbox deadline
   discovery does not suppress configuration failures and files its own repair
   obligation with the original cause. A failed discovery
   contributes no deadline until a source/repair event or the integrity sweep.
   Notifications go to their phone, their originating Telegram or Slack thread
   when present, and the Mac only while their input shows they are there. Importance
   does not choose a destination. Routine success stays in its rollup; adverse
   notices bypass the router's quiet-hours hold. A pinned door bypasses only
   for the person's own Mac act with positive local provenance, or a current
   request with direct-conversation and ingress proof ([reaching them](INTERNAL_WORKINGS.md)); peer or missing
   provenance stays held. Other notices wait in the router, which retains the
   due intent and releases it at quiet end.
   A held trigger or Desk notice is recorded and owed, with the policy's release time and a warning that another send would
   notify twice. It reports no delivery failure; [held delivery](INTERNAL_WORKINGS.md) owns its receipt and relaunch behavior.
   Desk submits due changes and nags at their own deadlines, including during
   quiet hours, and stamps durable retention without claiming delivery. Its
   mute window remains Desk's own rule. Approval refresh mirrors conversation
   cards without an independent Telegram prompt or a second quiet-hours check;
   its alert goes through the router.
   Delivery evidence names each occurrence destination. `accepted` requires
   every unsuppressed destination to accept; one accepted Mac banner cannot
   settle a pending phone receipt. `queued`, `deferred`, `failed` and
   `no_channel` stay distinct, and a door excluded by presence is not a failure.
5. For a turn, inspect its terminal trace; for a mobile command or approval,
   inspect that transaction's outcome.

`activity/events.jsonl` provides scheduler activity, while
the experience record's details hold turn evidence. Neither source substitutes for the owning
store's result. Do not infer that a system is healthy from an old successful
run, a recently rewritten timestamp, or a quiet failure log alone.

Context preparation, after-turn promotion, cognition and builder conversation
allocation also do work at their existing event boundaries. They do not need
invented loop IDs or separate periodic health campaigns. Their owners are mapped
in [Anatomy of a Turn](ANATOMY_OF_A_TURN.md),
[Internal Workings](INTERNAL_WORKINGS.md) and
[Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md).

### Event and lifecycle index

These mechanisms are not additional manager loop registrations. The final
column distinguishes status reads from work on their owning trigger, including
the artifact-listing exception. `EngineRuntime/EngineLaunch.swift` composes
their launch and termination lifetimes.

| Mechanism | Source owner | Trigger and evidence | Does a read probe or run work? |
|---|---|---|---|
| Part signals | `EngineRuntime/EnginePartWake.swift` | Source-owned signals and persisted turn terminals reach the wake index. | A part runs on its declared wake, not on a status read. [Wake contract](skill_manifest_spec.md#wake-signals). |
| Part file wakes | `EngineRuntime/EnginePartWake.swift` | Declared file watches deliver changes and suppress self-write echoes. | Reading status does not emit a file-change wake. [Wake contract](skill_manifest_spec.md#wake-signals), [watcher settlement](STOP.md). |
| Part presence wakes | `EngineRuntime/EnginePartWake.swift`; `MacControl/PersonPresence.swift`, `MacPersonInput.swift`; `PersistenceCore/PhoneSenseHistory.swift` | Mac-input transitions and durable phone-motion observations reach the same person presence owner; fresh walking/driving can signal away, later physical Mac input signals here. | No presence probe from a status read; silence/unknown is no phone verdict. [Wake contract](skill_manifest_spec.md#wake-signals), [phone evidence](mobile_companion.md#where-the-person-is). |
| Network sense and wakes | `NetworkSense.swift` | Path edges and return wakes. | [Request lifetime][provider-liveness]. |
| Part resume wakes | `EngineRuntime/EnginePartWake.swift` | Launch delivers `resumed` after registering source observers. | Reading status does not resume a part. [Wake contract](skill_manifest_spec.md#wake-signals). |
| First-terminal Doctor refresh | `EngineRuntime/EngineDoctor+FirstTurnRefresh.swift` | Once per launch, the first persisted terminal triggers a fresh Doctor pass under its configured gate. | The terminal event measures afresh; reading the saved report does not. See [Doctor](#3-doctor--the-health-authority). |
| Approval / Desk waits | `ApprovalTransactions/ApprovalReconciliation.swift` (`settleDeskWaitsOnEveryResolve`) | Manager-owned observation subscribes before launch reconciliation, then settles Desk waits on approval resolution. | Observation performs reconciliation; reading a card grants nothing. [Approval law](approval-schema.md#resolution-and-execution). |
| Grant observation | `ApprovalTransactions/InlineInteractionResolver+ChatLifecycle.swift` (`GrantWatch`) | Manager-owned permission-change observation and card taps coalesce grant rechecks. On each wake a running permission card records what it waits on (`waitingOn`) and, once that item is on, asks macOS for the next one in friction order, opening its pane; launch-applied grants share one restart, performed only by the person's tap on the card. | Its observation reads grants; only a card the person tapped asks for the next one, and a saved health read requests none. [Authority](TOOL_LOADING.md#authority-and-receipts). |
| Interaction delivery | `ApprovalTransactions/InlineInteractionDelivery.swift` | Manager-owned launch recovery restores card delivery pointers, then exact session changes refresh delivery. | The observer performs delivery work; reading saved status does not. [Delivery obligations](EXPERIENCE.md). |

The manager retains approval, grant and interaction observation together through
its `residentObservation` lifecycle. Their ownership is in
`BackgroundLoops/BackgroundLoopsManager.swift`, not a second scheduler.

Network sense and wakes use `NativeAgentCore/NetworkSense.swift`,
`EngineRuntime/EnginePartWake.swift` and `BackgroundWork/DelegationBackgroundWork.swift`.
One path monitor serves provider waits, iCloud drain-on-return and Dot recovery.
`network.down` / `network.up` publish on path edges; return re-ticks delegation.
The external delegation envelope still reads its configured wall plus 60 seconds.
Reading status does not probe the network. See the [wake contract](skill_manifest_spec.md#wake-signals)
and the [provider lifetime][provider-liveness]; path loss establishes no provider outcome.

[provider-liveness]: TURN_RESILIENCE.md#4-provider-liveness
