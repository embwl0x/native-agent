# Automated Systems — architecture map + health probes

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

This map identifies the registered background work, its owners and the
evidence to inspect. It describes code, not the health of a particular running
installation. Checks should be small and tied to the system being diagnosed.

## 0. Ground rule: pin the dataRoot first

Read `app {"action":"agent.introspect"}` and use its `data_root` when
inspecting files. Do not assume the checkout's `data/` is the live root.

`PersistenceCore/PersistenceCore/PersistenceDataRoot.swift` resolves the process root from
`NATIVE_AGENT_DATA_ROOT`, then a development bundle's `REPO_PATH` stamp,
otherwise Application Support. The root is fixed for that process.

Paths below are relative to that root unless identified as source paths.

## 1. The map — how it all connects

| Owner | Responsibility |
|---|---|
| `BodyRuntime/EngineRuntime/NativeAgentEngine.swift` | Root-scoped clients, stores and app ports. |
| `ChatTurnRuntime` | Conversation execution and after-turn work. |
| `SenseCore/BackgroundLoops/BackgroundLoopsManager.swift`, `ManagedLoopRunner.swift`, `BackgroundLoopWakes.swift` | Registrations, lifecycle, execution gates, event/deadline wakes and status. |
| `SenseCore/BackgroundLoops/BackgroundLoops.swift`, `LoopHistory.swift`, `LoopFailureReceipts.swift` | Scheduler timing, outcome accounting, durable clocks and failure receipts. |
| `SenseCore/BackgroundLoops/LoopContracts.swift`, `LoopStatusEvidence.swift` | Runner contracts, outcomes, backoff, tick execution until completion or cancellation and status evidence; watchdog wire keys remain unchanged. |
| `BackgroundWork` | Maintenance, work and connector runner bodies. |
| `BodyRuntime/EngineRuntime/EngineLaunch.swift`, `EngineComposition.swift` | Launch ordering and concrete loop composition; `EngineChatSurfaces.swift`, `EngineDreams.swift` and `EngineScheduledWork.swift` compose chat surfaces, Dream/REM and scheduled work through installed host effects. |
| `DeskCore/TriggerScheduler/OneClock.swift`, `EngineScheduledWork.swift` | The one clock: each declared time (`clock/times.json`), delivered once to its owner. |
| `BodyRuntime/DeviceSync/MacSyncEngine*.swift` | Mobile command transport and snapshots. |

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

A tick ends only on its own terminal event or cancellation: Stop, switching the
loop off or quitting the app. The manager awaits the runner directly; no
scheduler clock or per-runner timeout decides its outcome. A tick with no
terminal event remains visibly running with its start time and the runner's
named wait and cancellation lever. Doctor never judges an active tick stuck or
dormant by age; actual failures and listener failures retain their own evidence.

**The scheduler's passes wait for setup.** Before onboarding has completed
(`NativeAgentPublicSafety.hasCompletedOnboarding`: the `.onboarded` sentinel, with
no pending completion or reset) there is no agent. A runner that declares
`needsAgent` (cognition maintenance and replay, off-disk backup, Auto
Doctor) is not started by `ManagedLoopRunner`; its tick reads `not needed: Waiting
for setup to finish`, records no failure and advances no durable clock, so after
setup it is due by its ordinary rhythm. This replaces the per-pass setup checks:
the off-disk backup's own "setup is not complete" skip and the launch Doctor
tick's separate onboarding guard.

**The mind starts when the agent exists.** The body owns its mind's lifetime
(`MindLifetime`, `BodyRuntime/EngineRuntime/EngineMind.swift`), not a mind: before the same
setup predicate holds there is no cognition runtime, no attention intake, no
`BodyNerve` feeling beats, no mind stream, and none of the mind's sources or
clock deliveries (part wake, front-app sense, the one clock's part, watch and scan
owners). One serial owner decides, always rechecking setup: launch
asks once the body is up, and every setup transition asks through the shared
hook (`refreshResidentMindAfterOnboardingTransition`), after the pending
completion is removed. With setup finished and no mind it makes the runtime
once, opens it, then attaches the nerve, installs attention, opens the stream on
what was owed meanwhile and attaches the sources; with setup not finished it
closes a running mind. Happenings posted with no mind stay recorded and owed;
organ beats are recorded but not felt; clock times stay pending and are
delivered once to the next mind; helpers run unattended only while a mind runs.
A confirmed reset runs through the same owner: the mind closes first (attention
and the nerve detach, the stream's thoughts, returns and night with its dream
are stopped and joined, the sources and clock deliveries detach, the runtime
sleeps and is removed), then the identity is removed, then the owner decides
again, so a reset that did not complete starts a new mind. Every holder keeps
the owner, never a runtime: chat and tool clients made before setup or kept
across a reset reach whichever mind runs when they act, and its changes run
across absence and presence (`mind:opened`, `mind:closed`). Readers with no mind
report none (Doctor `unmeasured`, Cognition and mood faces unavailable, the
phone's body status `unavailable`, `mind.sleep` and dream or REM runs refused
with the reason). Quit closes a running mind and starts none after it.

A tick returns `LoopTickOutcome.completed`, `skipped` or `failed`.
A skip preserves an existing failure streak and updates live status only. Durable clocks
survive restart, and timing accounts for time already elapsed rather than
restarting a full period.

Inspect these together:

- `running`: the registration is active.
- `executing`, `executionStartedAt` and `waitingOn`: its body is currently
  running, when it started and what ends its wait. Slack shares its full tick sequence
  description with `slack/state.json`; other runners name their tick's return
  and cancellation. An absent start or wait description stays unavailable.
- `lastRun` and `lastResult`: the latest attempt, which may have skipped or
  failed.
- `lastSuccessfulWorkAt`: the latest completed work.
- `eventListener`: listener health for an event-driven lane.
- `wake.period`: a rhythm's period, absent for change-woken organs. Those organs
  have no periodic `nextTickAt` or status `nextRun`, and silence alone makes them
  neither overdue nor dormant. Failures and broken listeners
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
  (outcome `worked`, `nothing`, `held`, `busy`, `failed` or `stopped`, a note, an
  optional yield and cadence). The record compares those facts with the organ's
  latest stored beat in the write transaction; an unchanged reading writes nothing,
  including across relaunch. Every beat still feeds the live ring for liveness and
  repeated holds. Each organ retains its last 32 beats in memory, so a busy organ
  never evicts another's. Relaunch restores changed facts from the record. `OrganRecord` reads a ring: its
  latest beat and its deviation (missed, failed, stuck, off record), derived on every read
  and never stored. `OrganBody` is the one body projection over those records:
  each organ's line (latest beat, why, next beat due) and its deviation,
  deviations first. Doctor's `live.pulses` row (titled Body) and the agent's
  `mind.body` read draw the same lines. An organ with a declared cadence is
  missed once it misses a whole beat since launch. A fresh timestamp alone does
  not prove successful work: read outcome, note and cadence together. An organ
  whose clock stopped on purpose records a `held` beat noted `off: <reason>`:
  never overdue, never felt. A pass that was due but found its shared slot held
  by other work records a `busy` beat whose note names the holder and when the
  slot opens: not a hold and not a failure, so it never makes the organ stuck
  or failed and owes no repair. No beats yet means nothing is known, not a quiet
  body.
- **Felt.** The agent feels only what its body did not predict. A deviation
  not yet told to its turns rides the next turn's facts as one line ("In my
  body: …"), in every turn kind; a quiet body adds nothing. It is said at its
  start and again when its kind, onset or size changes; the
  said-memory (`mind/body_said.json`) is stamped only when the provider accepts
  a context carrying the line. A told deviation's mark stays until its organ
  completes a pass (`worked` or `nothing`) after the deviation began (for a
  failure or hold, after it in beat order, even within its second); once it no
  longer deviates, that pass gives the same line one sentence, "<organ> works
  again (it passed at <time>)", said once, and that exact mark goes (a newer
  fault's mark stays). A busy beat or a beat from before never says it. While a mind runs, `BodyNerve` re-reads the body on every beat: a
  deviation it has not felt becomes one `organDeviated` somatic signal, and a
  `failed` or `stuck` organ owes repair (operation `organ:<id>`) once, kept with
  why it is owed and settled by that organ's next completed pass (settled
  before new debts are read, so a pass and then a fresh fault in one read settle
  the old repair and owe the new one); a repair owed
  for being stuck is also settled by a `busy` beat, since busy is not a hold,
  and one owed for failing only by a pass, however many beats follow (a stuck
  organ that then fails is owed for its failure). Its memory is
  `mind/body_nerve.json`, so a relaunch neither signals an ongoing deviation
  again nor forgets its debt or its reason.

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
| `launch.chat_index` | `BodyRuntime/EngineRuntime/EngineLaunch.swift` | Recovered sessions, repaired index rows and corrupt transcripts found. |
| `launch.browser_stranded` | `BodyRuntime/EngineRuntime/EngineLaunch.swift` | Successful recovery's stranded browser operations closed as outcome unknown before ingress under the [browser ownership contract](INTERNAL_WORKINGS.md#built-in-browser-operation-ownership). Failed recovery leaves browser starts unavailable while the app starts; it emits no success count. Doctor reads the retained cause. |
| `launch.approval_executions` | `BodyRuntime/EngineRuntime/EngineLaunch.swift` | Unapplied approval executions settle before independent retained memory and REM catch-up branches. |
| `launch.rem_staging` | `BodyRuntime/EngineRuntime/EngineDreams.swift` | Previously unstaged REM proposals staged. |
| `abandoned_turns` | `SenseCore/TurnTrace/AbandonedTurnReconciliationHook.swift` | The engine resumes checkpoints and confirms settlement against in-flight turns and trace evidence for its own data root. |
| `history_index` | `BodyRuntime/ChatToolRuntime/ChatHistoryIndex.swift` | Transcripts/new lines absorbed and listing or persistence diagnostics; retained utility launch work independent of session-index repair. |
| `chrome_relay` | `MacNerves/ChromeControl/ChromeControlRuntime.swift` | Relay listening state, transport-authority failure or deliberate off state. |
| `embedding_warmup` | `MindCore/MemoryV2/MemoryV2+EmbeddingRuntime.swift` | Launch embedder load, an already-loaded model or missing-store skip. |
| `icloud_drain` | `BodyRuntime/DeviceSync/iCloudBridge.swift` | Incoming drain counts/skips and the transport's current receive cadence or rest/off state. |
| `presence_beat` | `BodyRuntime/DeviceSync/MacSyncEngine+Lifecycle.swift`; `BodyRuntime/DeviceSync/iCloudBridge.swift` | Published Mac presence, starting cadence or transport off state. |
| `desk_notify` | `BodyRuntime/BackgroundWork/DeskNotifyRunner.swift` | Each admitted pass records its actual outcome; no cadence. |
| `snapshot_integrity` | `BodyRuntime/DeviceSync/MacSyncEngine+Lifecycle.swift`; `BodyRuntime/DeviceSync/iCloudBridge.swift` | Snapshot integrity findings/skipped groups, starting cadence or unavailable-iCloud off state. |
| `studio_canon` | `BodyRuntime/Cognition/NativeCognitionRuntime+StudioCanon.swift` | Canon proposals staged and works evaluated on the tending pass. |
| `horizon_expectations` | `BodyRuntime/Cognition/NativeCognitionRuntime+Expectations.swift` | Open/settled expectations and composed sources, or organism off state. |

Use the [turn recovery map](TURN_RESILIENCE.md#9-process-continuation),
[memory map](MEMORY_SYSTEM_MAP.md), [mobile transport](mobile_companion.md),
[approval records](approval-schema.md) and [organism horizon](ORGANISM.md#the-horizon-family--toward)
for the owning behavior. A pulse count is that pass's observation, not a new
delivery or repair acceptance rule.

## 3. Doctor — the health authority

The admitted morning-brief ability assembles its checked sources for
`operation:"brief"`, directly or bound to their own queue step. Its primary-root
worklog path is `InstallPaths.current.claudeWorklog`, also read by the Agents
view; secondary roots leave it unconfigured. It returns a proposed card.
No brief clock, trigger config, defaults seed or trigger control publishes one.

Activity history rejects negative retained event counts and reports unrepresentable
rollup conversions or merged counts as source errors, leaving stored rows intact.
Clearing history orders the current span's close, deletion and a fresh permitted
span through the capture pump, so later capture never targets a deleted row.
After idle closes a span, the agent activates an app, or they raises a window
in the foreground app, capture requires newer person input. A confirmed raise sets
that cutoff at report time, even if the app leaves the foreground before capture
handles it. Person input that interrupts a foreground act wakes capture without
waiting for the act to finish. Presence, focus, activation and idle
checks all reopen through the same privacy and input checks. Without Input
Monitoring, capture uses hardware HID idle and excludes the agent's own posts.

`BodyRuntime/DoctorChecks/DoctorChecks.swift` defines `SwiftNativeDoctorChecks.defaultChecks`:
16 checks covering storage, runtime JSON, run-ledger and turn-trace integrity,
sessions and identity, prompt-prefix health, subconscious vitals, model
compensations, messages, persona, memory, embeddings, ability files, iCloud,
operation logs and OAuth expiry. The app adds live checks, including
background-loop health; the visible report is not a fixed 16-row checklist.
`Model compensations` (`model.shims`) is a read-only count of `shim.fired`
receipts by census ID in a bounded measurement window, excluded from heartbeat
sweeps.
Sound echo's ordinary quiet cadence emits no compensation receipt; it is not counted as a model correction.
Prompt-prefix token aggregation uses checked sums; an unrepresentable total is
unmeasured with a failed row naming the provider, turn, session and timestamp.
Prefix health, subconscious vitals and model compensations measure the running build:
trace timestamps from that build's first launch (`firstLaunchedAt` in `build_launch.json`,
kept across its relaunches, renewed by a new build), bounded by `ExperienceStore.detailHorizon`.
A stamp that does not name the running build reads unmeasured. Empty evidence stays unmeasured. A damaged Doctor snapshot
or iPhone snapshot-skip ledger is a named storage failure. Fresh readings retain
any failed snapshot publication alongside their measurement.
Absent Auto Doctor settings use fresh-install defaults. An existing unreadable
or invalid configuration disables automatic/startup execution and makes its
registered tick fail with the file path and cause; the bytes remain untouched.
Incomplete disk accounting retains unreadable paths and causes in its outcome,
preserves prior notices, and releases the daily reservation. A partial scan
cannot claim disk clean or retire an existing finding.
Watchdog snapshots encode the live runtime lifecycle and running
execution counts; retired daemon and LaunchAgent fields are absent.

Saved-provider read failures and failed native provider probes report `fail`;
explicit connection checks probe the current saved credential, including OAuth,
and a model call the provider answered leaves the same receipt for the credential
it sent. An unhealthy provider path reports `warn`. A stale probe retains an adverse
registry verdict and otherwise reports `unmeasured`; a readable compensation
scan without a v2 turn is also `unmeasured`. `off` and `not needed` remain
distinct non-fault states, not evidence of healthy work.
**Doctor says `fail` only for something that was set up and does not work.**
Something never set up is `off`, with one plain sentence on how to turn it on
in `human_action`; an `off` row is not adverse, so it neither owes repair
(`DoctorReadout.recordReadings` settles an open one) nor joins the inbox ask
(`DoctorSafeRepairPolicy.isUserAsk`). Search with no service set reads `off`
("Web search is off: no search service is set."), as Telegram never enabled
does; a set address that is malformed or does not answer stays a fault. This
replaces Search's former `fail` for a missing SearXNG address. Phone sync with no
iCloud account and no phone paired reads `off` ("Phone sync is off: this Mac is
not signed in to iCloud."), replacing its warning and sign-in ask; with a paired
phone, a missing account still warns and asks. The bridge's health snapshot
carries the pairing owner's paired-phone count for this. Before setup
finishes, the persona check reads `not needed` ("Waiting for setup to finish").
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
hour); before setup finishes it reads `not needed` like every pass that needs
the agent; it runs every safe repair and files one inbox ask for the sign-ins and
permissions it cannot do itself. Its `doctor/latest.json` contains:

- `measuredAt`: when measurement began;
- `runAt`: when the snapshot was published;
- `launchID`: the process launch that measured the snapshot;
- `checks`: the findings; an unreadable config is a fault with its file,
  never "off".

Every snapshot projects all unsettled `owes.repair`, regardless of evidence source;
an in-place refresh replaces the prior debt projection from the experience owner.
Unknown current measurements retain each debt as unmeasured and never settle it.

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
the UI and automatic runs. Every full run includes the same Desk and Recent
activity checks in `EngineDoctorRuntime.runDoctor`, including automatic runs
and the Doctor shortcut; surface refreshes use those same status readers.
The Diagnostics header reads that latest-run
availability before retained checks and says every check passed only when all
rows were measured and passed; empty, unmeasured or unclear checks stay incomplete.
Only a completed full run clears a failed-run issue. Current route details come
from one checked provider snapshot at the Doctor facade's own root. A failed
read is a structured `current_route_issue` and makes the envelope unavailable;
an absent provider is not a route-read failure.
Health-cache reuse requires the current `launchID` and a `runAt` age from zero
to less than 60 seconds; a fresh core reading never merges rows from an earlier
launch.
Projected rows retain the measured check's verdict, detail and executable repair
across cache reads and in-place updates; refreshed checks replace them by check identity.
`getHealth` preserves the phone's existing keys and adds independent `reachable`,
`doctorStatus` and `doctorIssue` metadata. The answering runtime reports reachable
even while Doctor is missing, running, failed or incomplete. `ok` means a current,
completed Doctor report is healthy; otherwise it is false, with the Doctor status
and issue distinguishing an adverse verdict from unavailable or incomplete evidence.
Connectivity labels read reachability. Retained snapshots without the added metadata
leave those fields unknown, allowing the next owner publication to replace them.
Support export never waits for or runs Doctor: `support_diagnostics.json` includes
the retained `doctorReport` (null when absent), `doctorReportCompletedAt`, current
`doctorStatus` and `doctorIssue`, while `health.json` records independent reachability.
An unavailable report does not prevent archive creation.

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
| `live.providers` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift`; `BodyRuntime/EngineRuntime/DoctorProviderPathReading.swift` | Saved authentication, active route and native connection-test reading. | No new connection test; reads the provider status feed. Explicit connection tests probe the saved credential. |
| `live.memory` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Mounted canonical store attachment, query response, graph reconciliation failure and SQLite integrity. | Yes: queries the running store each time; `quick_check` is cached between integrity readings. |
| `live.bridges` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Expected local listeners, bound ports and startup failures. | No; reads listener snapshots. |
| `live.mac_operation_recovery` | `BodyRuntime/EngineRuntime/EngineDoctorRuntime.swift`; `MacNerves/MacControl/MacControlOperationStore.swift` | Mac owner's launch-recovery admission state, original failure and repair; unavailable refuses Mac effects while looking and other surfaces remain available. | No; reads owner state, never runs recovery. |
| `live.browser_operation_recovery` | `BodyRuntime/EngineRuntime/EngineDoctorRuntime.swift`; `MacNerves/Browser/Browser+OperationStore.swift` | Browser owner's launch-recovery state and individual damaged run causes. Uncertain damaged runs refuse new effects; valid sibling rows remain readable and damaged row bytes stay intact. | No; reads owner state and canonical runs, never runs recovery. |
| `live.agent_connections` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift`; `BodyRuntime/AgentConversations/AgentContactHealth.swift` | Contact readiness, saved reply-path evidence and open connection repairs. | Refreshes readiness; definite unsent failures remain `not_reached` with current readable prerequisites, without reply-path repair. May schedule bounded connection verification for a possibly delivered failed path, without resending its message. |
| `live.telegram` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Configuration, credential availability, poller state and fresh successful-poll evidence. | No new Telegram request; reads the transport's evidence, separately from loop registration. |
| `live.search` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Configured SearXNG URL and bounded checked search response, retaining probe failures separately from refused listeners; no address set reads `off`. | Doctor runs probe; ordinary live refresh reads the retained result, valid for that URL for less than ten minutes. Repair checks/starts only that configured server; explicit setup owns discovery and endpoint selection. Only the Repair button may open Docker Desktop; background repair reports unavailable inventory when its daemon is down. |
| `live.tools` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Unavailable rows fail; quarantined tools warn, naming each to repair or remove; an empty registry is ok. | No tool invoked; execution remains unmeasured. |
| `live.autonomy` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Saved enable posture and reported autonomy runtime state. | No unattended work started. |
| `install.data_root` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | Installation move marker and any recorded backup location. | No; reads local installation evidence. |
| `live.inspector_feed` | `BodyRuntime/DoctorChecks/DoctorRunsInspectorChecks.swift` (`InspectorFeedHealth`) | Whether an open Inspector observes persisted trace changes. A window with no connection to answer (`face_disconnected`, `face_reply_lost`, `renderer_unavailable`, a closed link) is the closed case. | No; reads observation state. |
| `live.embedding_download` | `BodyRuntime/EngineRuntime/DoctorEmbeddingDownloadCheck.swift` | Runtime mode, distribution descriptor, installed release/epoch and retained transfer state. | No transfer or model-load check started; reads local owners and saved parts. |
| `live.background_loops` | `BodyRuntime/BackgroundWork/DoctorLoopHealth.swift` | Aggregate manager execution, cadence and listener health. | No tick started; evaluates manager/receipt evidence. |
| `live.background_loop.<loopId>` | `BodyRuntime/BackgroundWork/DoctorLoopRecovery.swift` | Each configured registration's health and any repair still awaiting a clean tick. | No tick or restart started. |
| `live.pulses` | `BodyRuntime/EngineRuntime/EngineDoctorMeasurements.swift` | The Body view: each organ's `OrganBody` line, deviations first (the same lines as `mind.body`). | No organ pass started. |
| `live.cognition.runtime` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Mounted cognition state is readable; each component row carries its own verdict; disabled cognition reads off. | No; reads mounted state after bootstrap. |
| `live.cognition.persistence` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Persistence state, blocked writes and failure stage. | No restore attempted; reads the cognition snapshot. |
| `live.cognition.receipts` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Availability of persisted cognition loop receipts. | Reads receipt evidence; no loop run. |
| `live.cognition.readouts` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Enabled mood/body values and body-sample freshness. | No new body sample; validates retained readings. |
| `live.cognition.body` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | A due residual repair warns; other body observations are stated on an ok row. | No residual repair run. |
| `live.cognition.capacity` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Node and workspace counts against configured caps. | No; reads snapshot counts. |
| `live.cognition.associations` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Any link the association producer drops for missing endpoints warns. | No graph repair or second reader; the frozen read carries the producer's dropped count. |
| `live.cognition.context_flow` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Context Flow registration, source errors and arena pressure. | No reconciliation; reads the owner's health state. |
| `live.cognition.phone_pairing` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Checked pairing authority and the bridge's pairing/last-exchange assessment. | No phone message sent. |
| `live.phone_notifications` | `BodyRuntime/EngineRuntime/EngineDoctor+Cognition.swift` | Checked paired-phone authority; optional APNS credentials and wake outcomes do not gate ordinary notifications. | No push sent; unreadable authority reports unavailable. |
| `status.desk_attention` | `BodyRuntime/EngineRuntime/EngineDoctor+StatusChecks.swift` | Blocked work or parent/descendant contradictions warn; person decisions stay distinct. | Reads stores and diagnostic narration; reconciles parents only on repair. |
| `status.activity` | `BodyRuntime/EngineRuntime/EngineDoctor+StatusChecks.swift` | Malformed rows, unreadable trace rows, or a failed turn whose experience still owes something fail; settled failures are stated (count, newest) on an ok row; unresolved effects stay unmeasured. | Reads activity and cross-launch trace details; no replay. |

Domain laws remain in the [memory map](MEMORY_SYSTEM_MAP.md),
[authored-part manifest](skill_manifest_spec.md),
[action authority](ONE_DOOR.md#authority-and-receipts),
[cross-surface ownership](INTERNAL_WORKINGS.md#6-one-agent-across-every-surface),
[capability map](CAPABILITIES.md), [cognition wiring](COGNITION_WIRING.md)
and [experience/repair law](EXPERIENCE.md). This table identifies measurements;
it does not grant a repair or infer delivery from setup.

## 4. The loop manifest — every registered lane

`BodyRuntime/EngineRuntime/EngineLaunch.swift` registers the lanes. The table gives the
lanes and their production defaults as of this writing; the installed set is
`logs/background_loop_state.json` and Doctor's aggregate `live.background_loops`
row, with individual readings at `live.background_loop.<loopId>`. Enabled state,
event deadlines, backoff and saved configuration determine actual work.

Senses registration never gates this manifest or its resident observations.
Loops start together, including Telegram/Slack ingress, reply reconciliation
and Desk notifications. Rows marked *needs the agent* read `not needed` until
setup finishes (§2). A loop's work that actually selects a sense waits at
the shared read door; sense wakes and file subscriptions wait at their own
owners. Doctor retains registration failures and their repair instructions.
An explicit run of a stopped loop follows the same per-read rule. See
[sense readiness and repair](SENSES.md) for bounds and subscription recovery.

| loopId | Declared wake | Work |
|---|---|---|
| `doctor_auto_run` | Launch, ok→adverse health reading, weekly; configured intervals at least 1h | Repair, publish Doctor snapshot, file one sign-in/permission ask. *Needs the agent.* |
| `offdisk_backup` | Daily rhythm, identity changes, daily deadline | Back up when due or identity changes; skip alternate roots and unavailable iCloud. *Needs the agent.* |
| `data_root_disk_hygiene` | Daily rhythm/boundary; hourly retry while unreserved | Detect oversized state and file a notice; never delete it. |
| `cognition_maintenance` | Daily | Substrate maintenance. *Needs the agent.* |
| `cognition_replay` | Daily | Episodic replay. *Needs the agent.* |
| `desk_notify` | Declared changes, next nag or quiet end, launch | Notify about eligible tracked Desk changes. |
| `delegation_outcome` | Launch, owner changes, quiet-hours end | Reconcile jobs, notifications, contact replies and settled Desk waits. |
| `telegram_poll` | Long-poll transport | Admit configured Telegram messages. |
| `slack_socket_mode` | Socket transport | Admit configured Slack messages; socket failure is reported and reconnects that same transport, with no Web API ingress/history polling. |
| `presence_beat` | Mac activity edges + 240s renewal; 300s due-only reconciliation | Publish canonical presence on launch, activation/deactivation, wake, network regain and completed conversations. Renew inside the phone's 300s contact window; never renew unchanged snapshots. Independent transport-owned reads continue at 20s regardless of publication outcome. Ship the phone freshness reader first. |

`desk_notify` offers each admitted outcome as a beat with no cadence, including
repeated failures. A thrown `CancellationError` or the proposal owner's
`PartCallError(code: "cancelled")` stops its work without filing a Desk fault
or claiming health; actual delivery verdicts and settlement failures
remain failures. Cancelled deadline computation records no failure. It
watches Desk ops/base, nag config, the desk-notify part, live inbox and user
preferences. `ForPerson` emits only changed matters, so an unchanged Desk
question cannot wake this evaluation and its run accounting again; see the
[unchanged experience law](EXPERIENCE.md#delivery-and-face). Its CPU-only proposal
calls no action and changes no notebook. A settled live evaluation records run
accounting if its version is still current or previous at settlement. An
explicit preview skips settlement and accounting. A missing count alone cannot
establish whether an evaluation ran. See the [run evidence contract](skill_manifest_spec.md).

Telegram and Slack remain registered as disabled when unconfigured and perform
no remote work. Saved-configuration or credential read failures register as
unreadable, so unavailable credentials do not appear disconnected. Launch and
restart use the same registration factory. Registration alone is not proof
that a connector is configured.

The Mac's mobile receiver uses push, launch, network wakes and explicit
refresh. A failed push registration reports its cause without a timed drain.
Snapshot integrity uses exact file/store invalidations and launch reconciliation;
there is no periodic missed-event pass. Unreadable held-notification or proactive
scan inputs fail at their owner and retain owed work rather than count as empty.
Proactive scans use the checked approval and Desk projections. Stale Now and Next
work can qualify once its [Desk defer ends](DESK.md). Each scan keeps
its posted opportunity ids beside its clock time and posts only ids it has not posted.
Their creation and execution share `ProactiveScanArguments`: `reason`,
`limit` (1–50), `surfaceLimit` (0–12) and `staleDays` (positive integer).
Missing optional arguments use their declared defaults; malformed or unknown
arguments are refused. The retired numeric coercions, `surface_limit`,
`stale_days` and unused `sources` input are removed.
Notification release reads owed experience obligations through `ForPerson`.
Channel suppression settles once; only destination acceptance is delivery,
and unknown sends await evidence. See [Internal Workings](INTERNAL_WORKINGS.md).

Completed periodic work persists its admitted start for cadence across relaunch;
successful work keeps its separate completion timestamp. A long-running tick
therefore does not add its duration to the next period after a restart.

A Desk continuation whose helper run is still queued or running remains a
live domain wait. Unknown terminal effects stop the continuation for domain
verification.
Queued helper runs retain their initiating turn's steering sources through claim and execution.
Requested helper replies follow queue and shelf changes, without a thirty-second
pending-result poll. A helper's cadence is its `helper:<id>` time on the one clock
(`BodyRuntime/StandingBots/BotRunnerScheduler.swift`). The scheduler drains queued requests.
When recovery finds an interrupted claim that never admitted execution, it
saves the request's refusal before retiring the claim and continues the drain.
A helper's cron cadence declares its rhythm on that clock, including when an old
runner occurrence is carried over and after each delivery, so a live time-zone
change preserves its pending local date and minute. Existing declarations missing
that rhythm gain it without moving their pending occurrence. Interval cadences
stay absolute and retain the helper's minimum spacing. The retired
`runner-tick.json` pass ledger is neither read nor written; a quiet
interval between source changes cannot prove Mac sleep.
Receipt-only delegation outcomes complete the same idempotent downstream
settlement before their cursor advances; they still suppress redundant cards.
A pass that records receipts reports completed work with its receipt count,
even when it files no cards; an idle pass with an established cursor remains skipped.
Delegation snapshots carry the contact's declared name into cards and resident
notices; without one they preserve the original identifier and spelling.

The `delegation_outcome` runner reads contact owner changes and the
quiet-hours end. Failed settlement waits for a source or repair event.
Its pass reads contact replies and returns settled Desk waits
(`EngineComposition.reconcileAgentConversations`). Neither decides that the agent
thinks: what comes back is a `returned` happening written through Attention's
intake. Desk completion requires a [checked return](EXPERIENCE.md#implemented-boundaries)
with the same helper receipts, including material beyond the display limit.
A matching return that is still owed is offered again on retry, and the post's
repair debt settles before Desk completes.
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

Reply tasks wake on contact push, conversation-store changes, an explicit read or
the next [conversation read on the one clock](agent-communication.md#honest-states).
Silence never expires a reply. Launch reconciliation
and delegation-loop restart resume saved queues after the prior pass and its reply work join.
Each contact retains one ordered
reply task, while other contacts can receive their own replies immediately;
there is no shared three-reply or one-turn cap. Completing a contact's work
invalidates its canonical conversation file through the store change bus.
Stop cancels and drains these tasks before closing their transports. A failed
read or write retains attention and repair with its cause. A pending task with no
event remains waiting and can be read or cancelled explicitly.

Scheduler sleep conversion checks the rounded floating-point boundary before
converting.

Stopping background scheduling closes bot admission, cancels and joins the
retained managed tick owned by `BackgroundLoopLifetimes`. Due and lifecycle
checks follow gate admission. The retained child's value owns actual exit;
its gate releases only after body exit and outcome accounting.
Helper sessions settle on their actual result, error or explicit Stop. Their live writer claim remains running until that settlement;
no wall-clock overrun marker is produced.
Helper arguments use their declared closed schema after reference and null
normalization; route admission and `BotDefinitionStore.check` retain semantic
validation. A helper budget contains a positive integer token allowance; helper sessions have no duration budget.
Helper definitions accept typed cadence, event and budget values; each Mac or
phone form parses its own controls before calling the definition owner. A
failed fresh definition read does not imply an unpaused helper. Event hold
receipt failures report their storage cause through scheduler availability.
Before execution, provider, unattended and daily-ceiling refusals settle the
exact queue request as refused and retire its claim. Admission commits the
exact claim or refusal before removing the queued request. A failed claim
write retains the queue entry; a later interruption retains the claim until
recovery settles it: a claim that never admitted execution gets its refusal,
and only an execution that lost settlement is reconciled as interrupted. Daily
reservations read and write only that helper's own `bots/<id>/daily-spend.json`;
no fleet-wide allowance is
charged against a new helper.

### Intentions and body rhythms

What the agent means to do later is a MY QUEUE intention, filed through
`queue.add {text, when, until?, say?}`. Each step's next time is a `moment:<handle>`
time on the one clock, and what comes due is posted once as a `moment` happening
([Intentions](INTENTIONS.md)). Every declared time is a `DeskCore/TriggerScheduler/OneClock.swift`
time (`clock/times.json`), its next occurrence saved before delivery, delivered once
to whoever declared it (`EngineScheduledWork.registerClockOwners`): `part:<id>:<cron>` (a part header's `schedule:` wake; the
clock posts its signal and the run is the part's), `watch:<id>` and `scan:<id>`,
`helper:<id>` and `moment:*`. Clock registration withdraws any pending `brief:`
times without delivering them. Sleep and REM declare no times and have no handlers.

`schedule.create` schedules only reads: `connector_action` (a watch) or
`proactive_scan` (`DeskCore/TriggerScheduler/ScheduledReads.swift`). Any other kind is
refused as unsupported before timing normalization; the action's description
points intentions, check-ins and reminders to `queue.add`. `schedule.list` lists the scheduled reads;
`schedule.cancel` requires the canonical ID returned by listing. It and `schedule.delete` share `scheduler_cancel_job`, which
withdraws the read's time and leaves a read already running alone. Creation and
cancellation require Scheduler Write. `clock/times.json` is the declaration
owner. Engine launch reads no retired scheduler rows or migration marker and
attaches helpers without importing their retired runner jobs. Watch and scan
handlers register independently; an item's failure names that item while its
healthy siblings retain their declarations. A scan ranks the checked inbox,
approval and Desk opportunities; a watch compares an app read with its saved
row baseline. Both post news to their attention, never directly to the person.
A scan posts once per nonempty surfaced result, using its opportunity ids as
the change identity. The news board persists before posting the `world`
happening; their `weigh` decides its worth. Empty results post nothing; failed
reads or news persistence keep their cause as repair owed.

### Scheduled Dream and REM

Dream surprise reading preserves source-read causes. An unreadable correction ledger fails dream synthesis before the consumed cutoff
advances; a partial reading cannot stand in for complete correction evidence.

Attention admits the night through `MindStream.night`; its source and policy are owned by
[Subconscious: Attention](SUBCONSCIOUS.md#attention). There are no sleep or REM clock declarations,
handlers or launch-time withdrawals. Each night offers REM to its existing gate.
Dream and REM failures owe repair on `attention > night`, naming `mind.dream` or `mind.rem`.
A completed dream keeps its result if diary presentation fails and reports that separate failure.
Its Inbox body shows the dream message once: a summary that begins the words is not repeated.
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
does not drain owed moments. The five clock verbs (`MindClockVerb`) refuse preview
with a specific explanation before entering their effectful owners. Preview receipts
remain only redacted `mind.run_now` traces with `preview:true`; dispatch, provider
health/usage and repair evidence cannot turn an inspection into lived learning.
Other cognition clocks have matching immediate verbs;
[Subconscious](SUBCONSCIOUS.md#run-a-clock-owner-now) owns their contract.

The diary entry uses the night's start date in the local calendar. Inspect the admission row
and dream outcome; absence of an entry alone is not evidence of failure. REM stages growth proposals through the approval
path rather than directly treating a dream as permission to rewrite persona.
Turn preparation reads the REM pin index through a checked cache: only a
missing index is empty; unreadable or invalid bytes fail the turn with the
owning path, without serving stale pins or rewriting the file.
Each saved dream section carries its claim-source block and immutable `dream-id`.
Before publication or effects, one durable `dream_diary/work/<section UUID>.json`
record holds the exact write, consumed-message cutoff, care/self input,
reflection judgment and integration, mood, completion signal, lessons and citations.
The [dream settlement law](COGNITION_WIRING.md#the-subconscious-loops--times-artifacts-re-entry) owns their ordering:
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
Under the run reservation, the next pass finishes journaled publications, then reads
the cutoff from `.dream_state.json` before gathering new material. Recovery after a crash
between writing a section and advancing the cutoff uses the journal's retained cutoff.
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

The rhythm grammar (`DeskCore/TriggerScheduler/SchedulerRecurrence.swift`) refuses timestamps
outside Gregorian years 1–9999 or the checked occurrence-millisecond domain;
occurrence keys and next occurrences use the same checked conversions.
Calendar rhythms walk the clock's civil minutes: a minute a spring-forward gap
skips occurs at the first minute after the gap, a fall-back minute occurs once,
and a rhythm with no occurrence in one 400-year Gregorian cycle has none. A
stepped cron value (`5/15`) runs from that value through the field's maximum.

A `connector_action` read's `actionId` is any action of the app door (the agent's
parts as `authored.<id>`, the Mac's readers such as `mail.recent` or `mac.look`), and
it runs through that one door like any of the agent's calls (`NativeAgentEngine.withPartDoor`,
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
(`id`, `…Id`, `…_id`) and its change stamp (`modified_at`, `modifiedAt`) when it has ids, else by its digest, so an
edited row is news as a new one is. The keys a read saw
are kept beside its clock time (payload `seen` in `clock/times.json`). Rows new
since the last read are posted to `SenseNewsBoard` as one notice whose observation
is the watch, which posts it as a `world` happening, so a later read's notice
replaces it rather than piling up. A watch is read once as it is made: `schedule.create` has the clock deliver it now
(`OneClock.deliverNow`, without moving its next occurrence) and answers after that read, saying what it established. That first
read only keeps what it saw, as the baseline, so whatever comes after creation is news to the first scheduled read; if it did not
complete, or no mind takes watch deliveries yet, the first scheduled read that completes is the baseline. Each watch carries the
mark of the schedule entry it is (payload `made`); a read's keys are kept only on the entry it was read for (`OneClock.revise`), so a
watch cancelled and made again under the same id never takes an earlier read's keys. A read that did not complete keeps the last keys,
and a changed read advances those keys only after durable news acceptance
(a failed news write fails the occurrence and retains its prior baseline),
and nothing new posts nothing. The Mail, Calendar and Reminders recipes in
`Resources/abilities/mac-watch-catalog.js` are such watches (`mail.recent`,
`calendar.upcoming`, and `reminders.query` over open reminders, dated or not, most recently made or edited first, 200 a read).
A watch naming an action the door
does not have keeps its time and owes that refusal as repair on each run.
The catalog supplies recipes and words. `MacAssistantStatusResult` owns their
displayed readiness: each recipe's `jobPayload.payload.actionId` selects its
native access row, and both display that row's status. The recipe carries no
separate access prerequisites. A missing or unrecognized source action leaves
that recipe unavailable with its cause, without hiding the other readings.

## 5. MacSync / iCloud bridge (Mac ⇄ iPhone)

`BodyRuntime/DeviceSync/MacSyncEngine` receives signed commands, checks their identity,
dispatches through the Mac and publishes responses and snapshots.

Cognition events compare the phone-visible organism status with `generatedAt`
cleared and call plain `writeSnapshots()` only when it changes. Experience
changes skip snapshot publication when their mobile projection is equal.

The local bookkeeping under `icloud/` is distinct from the transport's
container. `PersistenceCore/DeviceSyncState/ICloudSyncStatePaths.swift` defines:

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

`MindCore/MemoryV2/MemoryV2+UserMDGen.swift` regenerates `USER.md` in the active
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

`MacNerves/ApprovalInbox/ApprovalInbox.swift` owns
`workflows/approvals/requests.json`. A pending request is a decision waiting
to be made, not automatically an automation failure. Read its origin, bound
action, decision and execution outcome.

Full Mac keeps macOS privacy-reset approval. An untrusted agent's card offers
**Just this** for one call or **For this task** for the run. Approve alone means
Just this; a read steers nothing. Agents enabled in
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

See [One door](ONE_DOOR.md#authority-and-receipts) for the action
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
   re-arms from what is saved (`DeskCore/TriggerScheduler/OneClock.swift`). A zone change while the clock is alive preserves each pending calendar
   occurrence's civil date and minute, resolves it in the new zone and saves before delivery. Intervals and explicit one-time instants stay absolute.
   A live Time carries its projection zone across declaration/listing suspensions; projection metadata alone never rewrites the saved time.
   An ended one-shot stays in the same clock as delivery evidence, outside pending listings and deadlines. Restore retains that evidence even for ids
   absent from the selected backup; withdrawing later work also retains its consumed occurrence.
   The saved Time contains `id`, `rhythm`, `next`, `payload` and optional `delivered` occurrence / `ended` flag, with no projection zone or civil occurrence identity. A time-zone change
   while the app is quit therefore leaves the saved instant unchanged on relaunch and may deliver at the wrong local hour. That case remains
   deferred; it needs durable civil-occurrence evidence and an explicit treatment of already saved unzoned times.
   Notifications go to their phone, their originating Telegram or Slack thread
   when present, and the Mac only while their input shows they are there. Importance
   does not choose a destination. Routine success stays in its rollup; adverse
   notices bypass the router's quiet-hours hold. A pinned door bypasses only
   for the person's own Mac act with positive local provenance, or a current
   request with direct-conversation and ingress proof ([reaching them](INTERNAL_WORKINGS.md)); peer or missing
   provenance stays held. Other notices wait in the router, which retains the
   due intent and releases it at quiet end.
   A held notice is recorded and owed, with the policy's release time and a warning that another send would
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
the artifact-listing exception. `BodyRuntime/EngineRuntime/EngineLaunch.swift` composes
their launch and termination lifetimes.

| Mechanism | Source owner | Trigger and evidence | Does a read probe or run work? |
|---|---|---|---|
| Part signals | `BodyRuntime/EngineRuntime/EnginePartWake.swift` | Source-owned signals and persisted turn terminals reach the wake index. | A part runs on its declared wake, not on a status read. [Wake contract](skill_manifest_spec.md#wake-signals). |
| Part file wakes | `BodyRuntime/EngineRuntime/EnginePartWake.swift` | Declared file watches deliver changes and suppress self-write echoes. | Reading status does not emit a file-change wake. [Wake contract](skill_manifest_spec.md#wake-signals), [watcher settlement](STOP.md). |
| Part presence wakes | `BodyRuntime/EngineRuntime/EnginePartWake.swift`; `MacNerves/MacControl/PersonPresence.swift`, `MacPersonInput.swift`; `PersistenceCore/PersistenceCore/PhoneSenseHistory.swift` | Mac-input transitions and durable phone-motion observations reach the same person presence owner; fresh walking/driving can signal away, later physical Mac input signals here. | No presence probe from a status read; silence/unknown is no phone verdict. [Wake contract](skill_manifest_spec.md#wake-signals), [phone evidence](mobile_companion.md#where-the-person-is). |
| Network sense and wakes | `NetworkSense.swift` | Path edges and return wakes. | [Request lifetime][provider-liveness]. |
| Part resume wakes | `BodyRuntime/EngineRuntime/EnginePartWake.swift` | The mind's start (launch once setup has finished, or setup finishing) delivers `resumed` after registering source observers. | Reading status does not resume a part. [Wake contract](skill_manifest_spec.md#wake-signals). |
| First-terminal Doctor refresh | `BodyRuntime/EngineRuntime/EngineDoctor+FirstTurnRefresh.swift` | Once per launch, the first persisted terminal triggers a fresh Doctor pass under its configured gate. | The terminal event measures afresh; reading the saved report does not. See [Doctor](#3-doctor--the-health-authority). |
| Approval / Desk waits | `BodyRuntime/ApprovalTransactions/ApprovalReconciliation.swift` (`settleDeskWaitsOnEveryResolve`) | Manager-owned observation subscribes before launch reconciliation, then settles Desk waits on approval resolution. | Observation performs reconciliation; reading a card grants nothing. [Approval law](approval-schema.md#resolution-and-execution). |
| Grant observation | `BodyRuntime/ApprovalTransactions/InlineInteractionCoordinator+ChatLifecycle.swift` (`InlineInteractionCoordinator.observeGrants`) | Manager-owned permission-change observation (the agent's window coming to the front, a grant changed, System Settings quit) and card taps coalesce grant rechecks. The one walk (`SystemPermissionPreflight.requestMacOSAccess`) first asks every grant macOS can still ask in place, a failed request said in its result while the rest go on, then opens the pane of the first grant still off. On each wake a running permission card re-reads macOS; when that grant is on, or the person came back without it (the pane joins the card's shown panes and the walk moves past it), the walk goes on and the card records what it waits on (`waitingOn`) after that ask. The one restart is offered once, at the end, beside Go through again; Continue starts the walk over. Trust's "Ask for every prompt not yet answered" and the agent's ask on the person's word continue an open card holding those grants or file one. Launch-applied grants share that restart, performed only by the person's tap on the card. | Its observation reads grants; only a card the person tapped asks for the next one, and a saved health read requests none. [Authority](ONE_DOOR.md#authority-and-receipts). |
| Interaction delivery | `BodyRuntime/ApprovalTransactions/InlineInteractionDelivery.swift` | Manager-owned launch recovery restores card delivery pointers, then exact session changes refresh delivery. | The observer performs delivery work; reading saved status does not. [Delivery obligations](EXPERIENCE.md). |

The manager retains approval, grant and interaction observation together through
its `residentObservation` lifecycle. Their ownership is in
`SenseCore/BackgroundLoops/BackgroundLoopsManager.swift`, not a second scheduler.

Network sense and wakes use `NativeAgentCore/NativeAgentCore/NetworkSense.swift`,
`BodyRuntime/EngineRuntime/EnginePartWake.swift` and `BodyRuntime/BackgroundWork/DelegationBackgroundWork.swift`.
One path monitor serves provider waits, iCloud drain-on-return and Dot recovery.
`network.down` / `network.up` publish on path edges; return re-ticks delegation.
Each edge after the initial path baseline also posts one `world` happening on door `mac`, keyed by edge and source callback time.
The existing Workspace sleep/wake subscription posts the same kind and door, keyed by awake state and callback time.
Authenticated phone-reading changes post on door `phone` at their receiver; [phone evidence](mobile_companion.md#where-the-person-is)
owns the first-reading, change and freshness rules. These posts reach attention's `weigh`, not Live sense news.
The external delegation envelope still reads its configured wall plus 60 seconds.
Reading status does not probe the network. See the [wake contract](skill_manifest_spec.md#wake-signals)
and the [provider lifetime][provider-liveness]; path loss establishes no provider outcome.

[provider-liveness]: TURN_RESILIENCE.md#4-provider-liveness
