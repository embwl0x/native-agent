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
  overdue once it misses a whole beat since launch. A pulse is an observation:
  failed passes can record `.skipped` diagnostics, so read outcome, note and
  cadence together; a fresh timestamp alone does not prove successful work.
  An organ whose clock stopped on purpose records `off: <reason>` and is
  never overdue.

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
| `launch.approval_executions` | `EngineRuntime/EngineLaunch.swift` | Unapplied approval executions settle before independent retained memory, procedure and REM catch-up branches; current-schema procedure activation is checked at its owner. |
| `launch.procedure_activation` | `EngineRuntime/EngineLaunch.swift` | Qualified local-file-copy activation reviews staged. |
| `launch.rem_staging` | `EngineRuntime/EngineDreams.swift` | Previously unstaged REM proposals staged. |
| `abandoned_turns` | `TurnTrace/AbandonedTurnReconciliationHook.swift` | Checkpoints offered for resume, legacy recovery obligations and recovery failures. |
| `history_index` | `ChatToolRuntime/ChatHistoryIndex.swift` | Transcripts/new lines absorbed and listing or persistence diagnostics; retained utility launch work independent of session-index repair. |
| `chrome_relay` | `ChromeControl/ChromeControlRuntime.swift` | Relay listening state, transport-authority failure or deliberate off state. |
| `embedding_warmup` | `MemoryV2/MemoryV2+EmbeddingRuntime.swift` | Launch embedder load, an already-loaded model or missing-store skip. |
| `icloud_drain` | `DeviceSync/iCloudBridge.swift` | Incoming drain counts/skips and the transport's current receive cadence or rest/off state. |
| `presence_beat` | `DeviceSync/MacSyncEngine+Lifecycle.swift`; `DeviceSync/iCloudBridge.swift` | Published Mac presence, starting cadence or transport off state. |
| `snapshot_integrity` | `DeviceSync/MacSyncEngine+Lifecycle.swift`; `DeviceSync/iCloudBridge.swift` | Snapshot integrity findings/skipped groups, starting cadence or unavailable-iCloud off state. |
| `studio_canon` | `Cognition/NativeCognitionRuntime+StudioCanon.swift` | Canon proposals staged and works evaluated on the tending pass. |
| `horizon_expectations` | `Cognition/NativeCognitionRuntime+Expectations.swift` | Open/settled expectations and composed sources, or organism off state. |

Use the [turn recovery map](TURN_RESILIENCE.md#9-process-continuation),
[memory map](MEMORY_SYSTEM_MAP.md), [mobile transport](mobile_companion.md),
[approval records](approval-schema.md) and [organism horizon](ORGANISM.md#the-horizon-family--toward)
for the owning behavior. A pulse count is that pass's observation, not a new
delivery or repair acceptance rule.

## 3. Doctor — the health authority

Morning briefs read a worklog only when its caller explicitly supplies a path;
an omitted path stays unconfigured and never selects another helper's directory.

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
and release the weekly reservation instead of supplying measured zeros.
Heartbeat also keeps source availability: a missing checklist is off, while an
unreadable checklist fails its tick; execution, task and error-log read failures
produce an unavailable assessment. Incomplete durable-residue categories are
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

An empty set is not persisted as a clean bill of health. Some behavioral
checks memoize, so publication time alone does not establish freshness.

`script/organism_doctor.sh` reads phone evidence only from
`<dataRoot>/mobile_snapshot_cache/snapshots/organism_living_status.json`, where
`NATIVE_AGENT_DATA_ROOT` selects the root (default: this checkout's `data`).
Missing evidence stays unavailable; there is no machine-wide snapshot search.
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
| `live.pulses` | `EngineRuntime/EngineDoctorMeasurements.swift` | Recorded organ outcomes, notes, cadence and overdue state. | No organ pass started. |
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

| loopId | Default wake or backstop | Work |
|---|---|---|
| `doctor_auto_run` | Launch, ok→adverse health reading, weekly; configured intervals at least 1h | Repair, publish Doctor snapshot, file one sign-in/permission ask. |
| `turn_trace_retention` | 6h | Prune expired trace data, lock sidecars and excess transcript backups. |
| `offdisk_backup` | Identity-file changes + persisted daily deadline; daily integrity | Create an off-disk backup when due or identity changed; skip alternate roots and unavailable iCloud Drive. |
| `data_root_disk_hygiene` | Persisted daily boundary; hourly retry while unreserved; daily integrity | Detect oversized state and file a notice; the scan does not delete it. |
| `self_improvement_sweep` | Weekly | Stage runtime improvement approval cards; requires its switch and unattended-work authority. |
| `trigger_scheduler_due_work` | Events/deadlines; 6h repair | Run due scheduler jobs. |
| `mission_executor` | Execution and Desk events/deadlines; daily repair | Drain Workshop executions and settle linked Desk cancellations; this is the registered wire name. |
| `workshop_pump` | Events/deadlines; daily repair | Admit bounded Workshop work through its policy and posture gates. |
| `cognition_maintenance` | Daily | Substrate maintenance. |
| `cognition_replay` | Daily | Episodic replay. |
| `cognition_reflection` | Daily | Budgeted cognitive reflection. |
| `heartbeat` | Assessment-input changes + age deadlines; 12h integrity | Assess health; surface stable anomaly cards. Clean assessments skip the model. |
| `desk_notify` | Events/deadlines; daily repair | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Events/deadlines; 6h repair | Reconcile terminal delegation jobs and their notifications. |
| `telegram_poll` | Long-poll transport | Admit configured Telegram messages. |
| `slack_socket_mode` | Socket transport | Admit configured Slack messages; socket failure is reported and reconnects that same transport, with no Web API ingress/history polling. |

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
Proactive scans use the checked scheduler, approval, inbox and Desk projections.
Their creation, update and execution share `ProactiveScanArguments`: `reason`,
`limit` (1–50), `surfaceLimit` (0–12) and `staleDays` (positive integer).
Missing optional arguments use their declared defaults; malformed or unknown
arguments are refused. The retired numeric coercions, `surface_limit`,
`stale_days` and unused `sources` input are removed.
Notification release reads the immutable delivery ledger described in
[Internal Workings](INTERNAL_WORKINGS.md). It does not rewrite its watched
inbox. Channel suppression settles once; only destination acceptance is
delivery, and unknown sends await evidence.

Healthy periodic ticks persist their admitted start for cadence across relaunch;
successful work keeps its separate completion timestamp. A long-running tick
therefore does not add its duration to the next period after a restart.

A Desk continuation awaiting Workshop approval remains a live domain wait.
The exact approval and terminal receipt wake its verifier; approval waiting
does not create a second owner request to reopen the parent task. Unknown
terminal effects still stop the continuation for domain verification.
Receipt-only delegation outcomes complete the same idempotent downstream
settlement before their cursor advances; they still suppress redundant cards.
Delegation snapshots carry the contact's declared name into cards and resident
notices; without one they preserve the original identifier and spelling.

The existing delegation scheduler combines contact-continuation deadlines with
`ResidentWakeRuntime`'s arrival/spacing deadline. Each owns its due-work pass;
a resident wake no longer preempts contact reply reads, and one owner's failed
pass is reported after its sibling runs. Their ledgers and the scheduler remain
unchanged; the continuation no longer implements resident wake work.

Heartbeat findings and age deadlines share each source's admission scan,
including bridge delivery and acknowledgment exclusions; deadline reads do not
mutate inbox cards. It retains its 12-hour integrity sweep for nested records outside its
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
Stopping scheduled jobs joins the retained
due-work body through settlement. Parent cancellation and timeouts both join
actual scheduled job bodies and retain their returned status, detail, output
and watch baseline in stopped settlement before the pass exits. A returned
result keeps its evidence rather than being labeled as unknown effects.
Crossing a helper's seconds budget reports the overrun; work continues and its
claim stays held until the session settles. The person's Stop ends work early.
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

What they means to do later is a MY QUEUE intention, filed through
`queue.add {text, when, until?, say?}`. `schedule.create` and `schedule.update`
advertise only body rhythms. Unsupported kinds, including `notify`, `turn`
and `workshop`, refuse before payload or schedule normalization and point to
`queue.add {text, when, until?, say?}`. Updates use the merged saved/requested
kind; connector creation and resume reach the same normalizer.

Creatable body rhythms are `dream`, `rem`, `part`, `connector_action`,
`harness_benchmark` and `proactive_scan`. A part rhythm posts its `schedule:`
signal; its execution remains the part's. Legacy intention runner cases are
removed. The launch migration backs up jobs byte for byte, moves enabled
intention work into MY QUEUE with its first
unconsumed clock occurrence, including calendar seconds. Disabled legacy
definitions retain words, timing and pause with a first-migration disposition
and are not pruned. The durable completion receipt ends migration permanently;
imported work waits for it. Later restored intention jobs stay stopped and
surface once as a keyed Desk notice inviting `queue.add`; they never reimport
or enter scheduler selection. Uncertain prior effects stay stopped
for reconciliation. Body-owned jobs remain scheduler rhythms. Today's Ahead
reads the next five queue clock moments within seven days,
alongside its dream and horizon rows. See [Intentions](INTENTIONS.md) for the
migration contract and remaining design.

`schedule.cancel` and `schedule.delete` share `scheduler_cancel_job`; saved
`scheduler_delete_job` calls resolve as its alias. Both retain resumable history,
require Scheduler Write and leave running work alone.
Canceling future runs retains an active scheduler occurrence. It cannot be
age-retired, and restart reconciliation selects it even while the job is disabled;
its unknown-outcome notice is durable before the claim is released.

### Scheduled Dream and REM

The calendar jobs `nativeagent-nightly-dream` and
`nativeagent-weekly-rem` run through `SchedulerDueJobRunner`; there are no
separate periodic Dream or REM wrappers in the loop manifest.
Bootstrap matches these jobs only by their canonical IDs. Retired job-name
aliases and connector-reader watch rewrites are removed.
Phone and agent creation share recurring-dream admission: a repeating reflection
uses that one nightly job, preserving pauses and reactivating cancellations.
Diary discovery and inbox deduplication must succeed before catch-up or backfill
can claim absence. A completed dream keeps its result if diary presentation
fails and reports that separate failure. If recurrence cannot advance, the
completed cycle stays completed and its future schedule is disabled with the
cause and repair instruction; its retained timing is not runnable while disabled.
Receipt backfill names the existing diary files it observed (at most five),
without claiming a new pass, sessions processed, or total entries written. It
does not update the job's execution history or consume its next occurrence.
Scheduled REM consumes the REM owner's typed outcome: reservation skips retain
their reason and settle as `skipped`; only a completed pass is `completed`,
including a completed pass with zero proposals.

`DreamREMCycle/DreamREMCycle.swift` owns the default schedule: Dream at
03:30 daily and REM at 04:30 Sunday, in the Mac's current time zone.
Read the persisted jobs and their enabled state to establish what will run
on an installation.

The same `mind_run` action family supports immediate owner passes:
`app {action:"mind.dream"}`, `mind.rem`, `mind.self_improvement`,
`mind.think_now` and `mind.reflect` retain their existing manual gates.
Scheduled jobs have no run-now verb: running one early would consume its real
occurrence (the nightly dream's 3:30 run). `mind.dream` runs a real dream and
changes their; `app {action:"mind.dream", preview:true}` instead generates and
decodes on current lived material, reporting care judgments through the same
apply checks on a copy. It spends provider usage but writes no diary, cutoff,
care, lesson, mood, Experience or wake, and leaves the schedule intact. Preview
does not drain owed moments. The other nine clock verbs refuse preview with a
specific explanation before entering their effectful owners. Preview receipts
remain only redacted `mind.run_now` traces with `preview:true`; dispatch, provider
health/usage and repair evidence cannot turn an inspection into lived learning.
Other cognition clocks and the real care crossing have matching immediate
verbs; [Subconscious](SUBCONSCIOUS.md#run-a-clock-owner-now) owns their contract.

The nightly diary entry uses the previous local calendar day's key. Inspect
the job outcome and file modification time; absence of a file named for today
is not evidence of failure. REM stages growth proposals through the approval
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
work reaches the turn's private keep on its second meeting; no
`practice.night` rows or candidate ledger/tape writes remain.

### Scheduled reads are watches

Scheduler readers and writers refuse timestamps outside Gregorian years 1–9999
or the checked occurrence-millisecond domain, naming the row and field and
preserving existing bytes. Runtime occurrence keys and next-run stamps use the
same checked conversions.

A `connector_action` job's `actionId` is any action of the app door (their parts
as `authored.<id>`, the Mac's readers such as `mail.recent` or `mac.look`), and
it runs through that one door like any of their calls (`ToolsFacade.withPartDoor`,
origin `scheduler:watch:<action>`), as a read. An action whose class, as the
door judges it as it runs (`PermissionLaw.doorClass`), is not a read is refused
when it is scheduled, with the sentence that a watch reads and that acting on a
schedule is a part's `schedule:<cron>` wake; each run asks again inside the door,
so a part rewritten to write since is refused there and nothing runs. Authored
read classification includes every declared primitive permission and action
dependency; `readOnly:true` cannot override modifying reach. Watches and turn
expansion use that same canonical classification. Native argument-sensitive
reads retain their enforced argument policy. A read the
door refuses or that fails is the occurrence's error. The job's run record
(`lastRunStatus`, `lastRunDetail`) is its receipt. Each read is then compared
with the job's own last read, on CPU with no model call. Its rows
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
are kept on the job's row (`lastSeen` in `scheduler/jobs.json`). Rows new since
the last read are posted to `SenseNewsBoard` as one notice whose observation is
the job, so a later read's notice replaces it rather than piling up; the first
read only keeps what it saw, a read that did not complete keeps the last keys,
and a changed read advances those keys only after durable news acceptance
(a failed news write fails the occurrence and retains its prior baseline),
and nothing new posts nothing. The occurrence output names the count
(`newRows`). The Mail, Calendar and Reminders recipes in
`Resources/abilities/mac-watch-catalog.js` are such jobs (`mail.recent`,
`calendar.upcoming`, `reminders.due_today`). A saved watch that names one of
those readers by its old connector id (`mac.mail_list_recent`,
`mac.calendar_list_upcoming`, `mac.reminders_list_due_today`) is rewritten once
by the scheduler's default-job repair to its door read, keeping its own
arguments under the door's names (`unread_only` is `unread`; `hours_back`,
`include_completed` and `list_name`, which those door reads do not take, are
left out), the recipe's input filling only what it left out (`limit` 20,
`hours_ahead` 24), and its schedule, state and `lastSeen`. Any other saved job naming an action
the door does not have keeps its schedule and records that refusal on each run.

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
   retained civil occurrence in the current zone; active claims keep their instant.
   Single-file job mutations share `updateJobRows`' locked, checked transaction;
   unchanged rows are not rewritten. Retirement also records its separate ledger.
   The canonical reader and writer validate required string identities, Boolean
   enabled/oneShot, agreement between oneShot and schedule type, structured
   schedules, supported payloads and current occurrence evidence. Damage is
   unavailable authority, never scalar coercion or a guessed hourly schedule.
   Current input units (`schedule`, `in_minutes`, `interval_seconds`) normalize
   once; saved jobs require `schedule.type`. Numeric duration strings remain
   supported documented units; booleans and fractional integers are refused.
   No-schedule execution, retry markers and civil-key reconstruction are removed.
   `nextRunAt` is the formatted list timestamp; the redundant `nextRunAtISO`
   projection and writes are removed. List projection omits even a retained
   `nextRunAtISO` key, so it cannot expose a stale timestamp. Reads leave saved
   bytes untouched.
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
   fire. Unsupported trigger rows are reported rather than hidden; neither inbox
   nor Workshop deadline discovery suppresses configuration failures, and each
   files its own repair obligation with the original cause. A failed discovery
   contributes no deadline until a source/repair event or the integrity sweep.
   `notified` means the notification router projected checked destination
   acceptance. `queued` is an unknown phone outcome awaiting its signed receipt;
   it cannot claim delivery. `accepted`, `queued`, `deferred`, `failed` and
   `no_channel` stay distinct in delivery evidence.
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

### Event and lifecycle index

These mechanisms are not additional manager loop registrations. The final
column distinguishes status reads from work on their owning trigger, including
the artifact-listing exception. `EngineRuntime/EngineLaunch.swift` composes
their launch and termination lifetimes.

| Mechanism | Source owner | Trigger and evidence | Does a read probe or run work? |
|---|---|---|---|
| Transcript aging | `ChatSessionWork/ChatSessionAgingConsolidation.swift` | A transcript append crossing the aging boundary schedules a retained body and cancellation deadline. | A history read does not start aging; the append path does. [Compaction law](TURN_RESILIENCE.md#8-context-compaction), [settlement](STOP.md). |
| Part signals | `EngineRuntime/EnginePartWake.swift` | Source-owned signals and persisted turn terminals reach the wake index. | A part runs on its declared wake, not on a status read. [Wake contract](skill_manifest_spec.md#wake-signals). |
| Part file wakes | `EngineRuntime/EnginePartWake.swift` | Declared file watches deliver changes and suppress self-write echoes. | Reading status does not emit a file-change wake. [Wake contract](skill_manifest_spec.md#wake-signals), [watcher settlement](STOP.md). |
| Part presence wakes | `EngineRuntime/EnginePartWake.swift`; `MacControl/PersonPresence.swift`, `MacPersonInput.swift`; `PersistenceCore/PhoneSenseHistory.swift` | Mac-input transitions and durable phone-motion observations reach the same person presence owner; fresh walking/driving can signal away, later physical Mac input signals here. | No presence probe from a status read; silence/unknown is no phone verdict. [Wake contract](skill_manifest_spec.md#wake-signals), [phone evidence](mobile_companion.md#where-the-person-is). |
| Network sense and wakes | `NativeAgentCore/NetworkSense.swift`; `EngineRuntime/EnginePartWake.swift`; `BackgroundWork/DelegationBackgroundWork.swift` | One process-wide path monitor serves provider waits, iCloud drain-on-return and Dot link recovery. `network.down` / `network.up` reach parts and intentions after five seconds of stable path state. Immediate offline state holds resident arrivals without claiming them; return re-ticks delegation. Its tick budget is the configured provider stream wall plus 60 seconds. | Reads use the owner's Bool; they do not create monitors or provider calls. [Wake contract](skill_manifest_spec.md#wake-signals), [provider deadlines](TURN_RESILIENCE.md#4-provider-timeouts). |
| Part resume wakes | `EngineRuntime/EnginePartWake.swift` | Launch delivers `resumed` after registering source observers. | Reading status does not resume a part. [Wake contract](skill_manifest_spec.md#wake-signals). |
| First-terminal Doctor refresh | `EngineRuntime/EngineDoctor+FirstTurnRefresh.swift` | Once per launch, the first persisted terminal triggers a fresh Doctor pass under its configured gate. | The terminal event measures afresh; reading the saved report does not. See [Doctor](#3-doctor--the-health-authority). |
| Approval / Desk waits | `ApprovalTransactions/ApprovalReconciliation.swift` (`settleDeskWaitsOnEveryResolve`) | Manager-owned observation subscribes before launch reconciliation, then settles Desk waits on approval resolution. | Observation performs reconciliation; reading a card grants nothing. [Approval law](approval-schema.md#resolution-and-execution). |
| Grant observation | `ApprovalTransactions/InlineInteractionResolver+ChatLifecycle.swift` (`GrantWatch`) | Manager-owned permission-change observation and card taps coalesce grant rechecks. | Its observation reads grants; a saved health read does not request one. [Authority](TOOL_LOADING.md#authority-and-receipts). |
| Interaction delivery | `ApprovalTransactions/InlineInteractionDelivery.swift` | Manager-owned launch recovery restores card delivery pointers, then exact session changes refresh delivery. | The observer performs delivery work; reading saved status does not. [Delivery obligations](EXPERIENCE.md). |
| Procedure-artifact retention | `Procedures/ProcedureRetention.swift` | Engine opens retention at launch; installation requests a coalesced sweep; termination closes admission and joins its flight. | Installation enforces the [shared discovery capacity](canonical_data_paths.md#procedure-artifacts) before writing. `statusSnapshot` only reads; an over-cap discovery read requests retention and refuses capacity. Protected references can prevent a sweep from freeing room. [Lifecycle settlement](STOP.md); this retained artifact owner is distinct from authored-part lifecycle. |

The manager retains approval, grant and interaction observation together through
its `residentObservation` lifecycle. Their ownership is in
`BackgroundLoops/BackgroundLoopsManager.swift`, not a second scheduler.
