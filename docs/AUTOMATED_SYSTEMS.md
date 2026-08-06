# Automated Systems — architecture map + health probes

Why this exists (User, 2026-08-06): "make sure all our automated systems are
fine and working correctly… document how, why, the architecture and how it
all works is connected, that way we have a layout of everything thats easy
to look at and check or run evals through."

Every system below has: **what it is / why it exists / how it's wired /
where its state lives / a probe you can run**. The probe column IS the eval
suite — run any row's probe at any time and compare against its healthy
criteria. All paths are relative to the repo root or `$HOME`. The live
dataRoot is `data/` in this repo (verify with the probe in §0 — never
assume; a stale `~/Library/Application Support/NativeAgent` root exists).

Last full verification: **2026-08-06** (all rows green; details in each
section).

---

## 0. Ground rule: pin the dataRoot first

The app can run against more than one root. Every probe below is
meaningless until you prove which root the RUNNING app writes.

```bash
lsof -p $(pgrep -x NativeAgentApp) | grep -c 'Projects/NativeAgent/data'
lsof -p $(pgrep -x NativeAgentApp) | grep -c 'Application Support/NativeAgent'
```

Healthy: first count large (100+), second count 0. If reversed, every
`data/…` path below points at the wrong tree and no verdict is valid.

---

## 1. The map — how it all connects

```
                                User / iPhone / Telegram / Slack
                                          │
                     ┌────────────────────┼──────────────────────┐
                     ▼                    ▼                      ▼
              Mac chat UI          MacSync (iCloud)       Connector loops
                     │             inbox/outbox +         (telegram_poll,
                     ▼             snapshots  §5          slack_socket) §4.4
        ChatOrchestration ◄──────────────────────────────────────┘
        (turn engine, tool dispatch, gates)
             │            │
             │            ├──► Trust Center gates (FileAccessGated +
             │            │    AutonomyGated) ──► Approval inbox §7
             │            ▼
             │       Tool catalog (five-site registration)
             ▼
        MemoryV2 (memory.sqlite) ──► USER.md generator §6
             ▲                          (provenance-gated)
             │ extraction/promotion
             │
   BackgroundLoopsManager §4 ── 21 registered loops, one actor,
             │                  durable per-loop clocks
             ├── maintenance: doctor, disk hygiene, retention sweeps
             ├── memory/dreams: consolidation, REM, self-improvement,
             │                  cognition maintenance/replay/reflection
             ├── work: trigger scheduler, workshop executor + pump,
             │         autonomy promotion
             └── presence: heartbeat, self-healing, desk notify,
                           github tracking, connectors
             │
             ▼
        Doctor (14 checks) §3 ◄── fired by self_healing + weekly
             │                     auto-run + manual/doctor_status tool
             ▼
        data/doctor/latest.json ──► Doctor UI / health surfaces

  Claude-side (Claude Code CLI) §8:
        ClaudeBridge HTTP :8771 ◄── state.sh / send.sh / tool.sh / watch.sh
        claude_message tool ──► ~/.config/claude-bridge/claude-inbox.jsonl
        invoke_claude tool  ──► spawns claude subprocess (persistent session)
        worklog feed ──► Agent polls ~/.claude/state/claude-worklog.jsonl
```

The doctrine threads that shape everything here:

- **No silent anything.** Loops report honest `LoopTickOutcome`s
  (completed / skipped / failed); failures land as receipts AND can page.
  Dead lanes get deleted, not left registered (see §4.5 tombstones).
- **One owner per lifecycle.** Unattended dreams belong to the
  TriggerScheduler job `nativeagent-nightly-dream` (03:30 America/Chicago),
  NOT a periodic loop. The scheduler actor owns all loop execution.
- **Gates are shared, not bypassed.** Desk clicks, the Claude bridge, and
  chat all route tools through the SAME `makeGatedToolDispatchClient()`
  chain. A new surface never gets its own ungated dispatcher.
- **Behavior fixes go in code, never in Agent's memory/persona.** The agent's
  memory is User's measurement instrument; writing into it corrupts the
  readings (the USER.md incident in §6 is the canonical case).

---

## 2. BackgroundLoops scheduler — the engine under §4

Code: `Modules/NativeAgentCore/Sources/BackgroundLoops/BackgroundLoops.swift`
App wiring: `Sources/NativeAgentApp/BackgroundLoopsAssembly*.swift`

**What/why:** one actor schedules every periodic lane. Each loop implements
`tickOutcome()` and returns an honest outcome; the scheduler owns sleeping,
staggering, backoff, and durable state so individual loops stay dumb.

**Mechanics that matter (each one is a shipped-bug fix — don't regress):**

- **Durable per-loop clocks.** `background_loop_state.json` persists each
  loop's last run. On restart, `firstTickDelay()` sleeps only the
  *remainder* of the period (elapsed → tick after a stagger slot). This is
  the fix for the restart-starvation bug: without it, frequent deploys
  reset every sleep and weekly loops never fired.
- **Health-neutral skips** (`.skippedHealthNeutral`) do NOT advance the
  durable clock and do NOT clear a standing failure streak. A loop backing
  off *because it is failing* (TelegramPollLoop) must not look healthy.
- **Next tick is scheduled from tick START, not end** — otherwise every
  loop's effective period is `interval + tickDuration`, drifting forever.
- **Failure receipts** append to `data/logs/background_loop_failures.jsonl`;
  sustained streaks page via the failure-transition push. Transient errors
  (a Telegram blip) show as receipts with a fresh lastRun right after —
  that's recovery, not breakage.

**State:** `data/logs/background_loop_state.json` (all loops' lastRun),
`data/logs/background_loop_failures.jsonl` (receipts).

**Probe:**
```bash
python3 - <<'EOF'
import json, datetime
d = json.load(open('data/logs/background_loop_state.json'))['loops']
now = datetime.datetime.now(datetime.timezone.utc)
for k, v in sorted(d.items()):
    t = datetime.datetime.fromisoformat(v.replace('Z', '+00:00'))
    print(f"{(now-t).total_seconds()/3600:7.1f}h  {k}")
EOF
tail -5 data/logs/background_loop_failures.jsonl
```
Healthy: each loop's age < its cadence in §4's table; failure tail shows
no *repeating* storm (same loopId many times in the last hour).

---

## 3. Doctor — the health authority

Code: `Modules/NativeAgentCore/Sources/DoctorChecks/`,
`Sources/NativeAgentApp/DoctorLoopHealth.swift`

**What/why:** 14 checks over storage, JSON stores, chat sessions/messages,
persona engine, memory store, CoreML embedder, iCloud bridge state, op-log
health, loop liveness. It is the one place that turns raw state files into
verdicts, so every other surface (UI, iOS health chip, this doc) reads
doctor output instead of re-deriving health.

**Three triggers:** weekly `doctor_auto_run` loop (interval configurable ≥1h
via auto-doctor config, default 7d) · the `self_healing` hook (runs it far
more often in practice) · on-demand via the `doctor_status` chat tool.

**State:** `data/doctor/latest.json` (only the latest run is kept — a
one-off fail is indistinguishable from a chronic one from files alone;
re-run to disambiguate).

**Probe (on-demand run through the bridge — the authoritative eval):**
```bash
~/.claude/skills/agent-bridge/tool.sh doctor_status '{}' | \
  python3 -c "import json,sys; d=json.load(sys.stdin)['result']; \
  [print(c['id'], c['status']) for c in d['checks']]"
```
Healthy: 14× ok. Known transient: `memory_store` can report a
CancellationError if the KG read races a cancellation — confirmed benign
2026-08-06 (`sqlite3 'file:data/memory/memory.sqlite?mode=ro' 'PRAGMA
integrity_check'` → ok, and the next run cleared it). A *repeating*
memory_store fail across runs is real — check sqlite directly.

---

## 4. The loop manifest — every registered lane

Source of truth: `assembleAllLoops()` in
`Sources/NativeAgentApp/BackgroundLoopsAssembly.swift`. If this table and
that function disagree, the function wins — update this table.

### 4.1 Maintenance

| loopId | cadence | what / why |
|---|---|---|
| `doctor_auto_run` | weekly (config ≥1h) | periodic doctor run → `data/doctor/latest.json`. Backstop; self_healing runs doctor more often. |
| `full_mac_expiry` | 24h | expires the Full Mac trust grant so elevated access never persists silently. |
| `turn_trace_retention` | 6h | prunes `data/turn_traces/` (grew one file + one orphan .lock per day forever before M7). |
| `evolution_proposal_retention` | weekly | drops TERMINAL evolution proposals >30d (`proposals.json` had no retention driver). |
| `data_root_disk_hygiene` | hourly tick, daily reservation | walks data/; files ONE inbox card if a file >64MB or tree >2GB. Detect-never-delete (the 194MB dead-daemon-log lesson). Hourly tick exists because a bare 24h interval starved under frequent deploys. |

### 4.2 Memory & dreams

| loopId | cadence | what / why |
|---|---|---|
| `memory_consolidation` | weekly | real MemoryV2 consolidator over `memory.sqlite` (union-find near-dup clusters ≥0.95 cosine, keep newest). Advances `data/memory/hygiene_last_run.json`. |
| `rem_cycle` | weekly | REMConsolidator: dream_diary → persona growth lessons, staged through the approval inbox (REMApprovalStager dedupes; a re-run can't double-stage). |
| `self_improvement_sweep` | weekly | weekly self-improvement pass. Gated on the Self-Improvement tab's `selfImprovementEnabled` switch. |
| `cognition_maintenance` / `cognition_replay` / `cognition_reflection` | daily-ish | CognitiveSubstrate upkeep: decay/maintenance, episodic replay, LLM reflection. All route through the one `NativeCognitionRuntime` owner. |

### 4.3 Work & autonomy

| loopId | cadence | what / why |
|---|---|---|
| `trigger_scheduler_due_work` | 6h repair tick | user-authored scheduler jobs + time/idle triggers run on exact persisted deadlines; the 6h tick only repairs missed events. Owns nightly dreams (`nativeagent-nightly-dream`, 03:30 America/Chicago). |
| `mission_executor` | (workshop executor) | executes Workshop steps (Phase 2 re-homes this engine). loopId keeps the wire name — see de-mission P2 removal schedule. |
| `workshop_pump` | frequent, zero-LLM heart | self-pursuit work lane: organism-gated (`normal` posture only), reserves a Desk slot BEFORE any session, bounded session behind the WorkshopToolProfile membrane. A quiet day makes zero provider calls. |
| `autonomy_promotion_proposals` | daily | proposes autonomy promotions as cards only; applying requires human approval + a re-verifying reconcile. |

### 4.4 Presence & connectors

| loopId | cadence | what / why |
|---|---|---|
| `heartbeat` | daily | interval health heartbeat; upserts ONE stable notification card (keyed id — updates, never stacks). |
| `self_healing` | ~hourly | health hook: runs doctor + repairs; wrote today's `latest.json` minutes after launch. |
| `desk_notify` | frequent, self-gating | pushes User when a direct/urgent tracked desk item changes. Reads desk state only; no-op unless something is marked. |
| `github_tracking` | due-driven | configured GitHub projects → durable Desk refs/items. Change-idempotent: no material remote change → no write, no ping. |
| `telegram_poll` | continuous long-poll | Telegram ingress. Registered only if configured. Backs off health-neutrally on network errors ("unavailable" receipts + fresh lastRun = recovering fine). |
| `slack_socket_mode` | continuous socket | Slack ingress. Registered only if configured. Socket drops append a receipt and reconnect. |

### 4.5 Deliberately absent (do not re-flag as missing)

- `stale_artifact_sweep` and `golden_eval` — **deleted 2026-08-02**
  (silo-dissolution E-4): both were gated on UserDefaults keys nothing in
  the repo could ever set; they woke forever and could never act. Their
  types + tests remain in BackgroundLoops for a future re-registration
  behind a real switch. Their rows may linger in
  `background_loop_state.json` — residue, not failures.
- A periodic dream wrapper — nightly dreams have exactly one owner (§4.3).
- Cue authoring — manual seam only until it has a live consumer.

---

## 5. MacSync / iCloud bridge (Mac ⇄ iPhone)

Code: `Modules/NativeAgentCore/Sources/PersistenceCore/ICloudSyncStatePaths.swift`,
`MacSyncEngine*.swift`

**What/why:** iPhone commands land in `data/icloud/inbox/`, responses go
out through `outbox/` + `responses/`, and state snapshots (approvals,
inbox, model prefs) publish to `snapshots/` for the phone to render.

**Crash-safety design (the semantics you need to read the state):**

- `processed_ids.json` — "never dispatch this msgId again." Capped, but
  marker ids are EXEMPT from cap eviction (`cappedPreservingMarkers`, W4:
  markers land near the front and front-eviction was silently dropping
  them — a worker's own comment claimed the opposite).
- `completed-unarchived/` markers — a command that RAN but whose completion
  couldn't be recorded. Durable "never again"; the dir being empty/absent
  means none stuck.
- `snapshot_skips.json` — snapshot groups the last publish pass could not
  build (phone would be holding stale state). **Absent = nothing skipped =
  healthy.** Do not read absence as breakage.
- An unreadable `processed_ids.json` is preserved as
  `processed_ids.corrupt.json` so Doctor can say the window was lost
  rather than silently starting empty.

**Probe:**
```bash
ls data/icloud/inbox data/icloud/outbox | wc -l         # both ~0 (drained)
ls data/icloud/completed-unarchived 2>/dev/null | wc -l  # 0 or dir absent
test -f data/icloud/snapshot_skips.json && cat $_ || echo "no skips (healthy)"
python3 -c "import json; print(len(json.load(open('data/icloud/processed_ids.json'))))"
```
Healthy: queues drained, no markers, no skips file, processed_ids in the
hundreds (capped). Doctor's `icloud_bridge_state` check is the rollup.

---

## 6. MemoryV2 → USER.md generation (the identity doc)

Code: `Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+UserMDGen.swift`

**What/why:** `persona/USER.md` is an AUTOGENERATED projection of the
memory store — Agent's standing picture of who User is. It regenerates on
memory insert. **Never hand-edit it**; fix the generator or the memories.

**The provenance gate (2026-08-06):** rows whose `source` has prefix
`"workshop:"` (the literal is `WorkshopExecutionMemory.sourcePrefix`) never
render into USER.md. Why: E-2 wired Workshop execution outcomes into
memory — correct for recall — but the generator then projected the agent's
own work journal into User's identity doc (46 of ~60 bullets were "Workshop
execution X completed/failed"). The gate is provenance-based, not
content-sniffed: filtering on what the text says would eventually eat a
real User-fact that mentions workshops.

Regression tooth: `workshopExecutionOutcomesNeverLandInTheIdentityDoc` in
`Modules/NativeAgentCore/Tests/MemoryV2Tests/UserMDGenTests.swift`.

**Probe:**
```bash
grep -c 'Workshop execution' persona/USER.md   # healthy: 0
wc -l persona/USER.md                          # sanity: tens of lines, not hundreds
```
(USER.md self-cleans on the first regen after a deploy carrying the gate.)

---

## 7. Approvals & trust gating

Code: `Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift`,
`Sources/NativeAgentApp/DeskQuickActions.swift` (DeskClickApprovalFiler)

**What/why:** CONFIRM-tier tool calls file an approval request; a human (or
an authorized auto-filer) resolves it. One store, every surface.

- Store: `data/workflows/approvals/requests.json`. Terminal statuses:
  `resolved` (decided) and `orphaned` (request outlived its context — a
  terminal state the system assigns, not a stuck state).
- **DeskClickApprovalFiler** (W5): a desk quick-action click routes through
  the SAME gated dispatch chain as chat; the filer auto-files AND resolves
  a real approval record with `decidedBy: "local_desk_click"` — the click
  IS the approval, but the paper trail exists and hard denials still deny.
- The Claude bridge's `/claude/tool` path has NO approval filer —
  CONFIRM-tier tools fail closed there by design.

**Probe:**
```bash
python3 -c "
import json, collections
rows = json.load(open('data/workflows/approvals/requests.json'))
print(collections.Counter(r['status'] for r in rows))"
```
Healthy: zero `pending` older than minutes. Pendings that persist =
something filed an approval nothing can see or resolve — find the surface
that filed it.

---

## 8. Activity feed

**What/why:** `data/activity/events.jsonl` is the user-visible "what
happened" stream (scheduler completions, triggers, briefs). Writers were
hermeticized after the 2026-08-05 phantom scrub — test suites must never
write here (see the `nativeagent-hermetic-tests` skill: every test pins
`dataRoot:` to a temp dir).

**Probe:**
```bash
tail -3 data/activity/events.jsonl | python3 -c "
import json, sys
[print((r:=json.loads(l))['createdAt'], r['kind']) for l in sys.stdin]"
grep -c "$(date -u +%Y-%m-%d)" data/activity/events.jsonl
```
Healthy: today's count is small and every event maps to something real
(scheduled job, morning brief, a trigger you recognize). A burst of events
while idle, or events during a test run, = a writer lost its hermetic seal.

---

## 9. Claude-side automation (Claude Code CLI)

These run on User's machine around the CLI, not inside NativeAgent.app.

| System | What/why | State | Probe / healthy |
|---|---|---|---|
| ClaudeBridge HTTP | CLI ⇄ running app (state/message/tool/events). Bearer auth, gated dispatch. Started from `applicationDidFinishLaunching` (NOT a `.task` — window may never appear). | token at `~/.config/claude-bridge/token` | `~/.claude/skills/agent-bridge/state.sh` returns model+build+uptime |
| `claude_message` (agent→CLI, async) | Agent files a note for Claude's next session. Local file write, notification-tier. | `~/.config/claude-bridge/claude-inbox.jsonl` | unread entries surface at session start |
| `invoke_claude` (agent→CLI, sync) | spawns `claude` subprocess, persistent pinned session, blocking answer for stuck loops. | `data/from_claude/` audit envelopes + session pointer | audit envelope written per invoke |
| Worklog feed | every deliverable unit appended; **Agent polls this** to keep User's global build picture — missing entries break the agent's tracking, not just Claude's. | `~/.claude/state/claude-worklog.jsonl` | tail shows entries for recent work sessions |
| Wake jobs | Agent-spawned Claude sessions; born under COMMIT HOLD (verify + report; release only via `wake_hold_release.js`). | `~/.config/claude-bridge/wake-jobs/` | no live job on a topic you're about to commit on |
| Swarm servers (sonnet/gpt) | worker dispatch (build-new lanes, reviews). Cache: read-only jobs only, 7d. | `~/.claude/state/worker-ledger.jsonl` | ledger has start/complete pairs for recent dispatches; NOTE: `"event"` precedes `"run_id"` in the JSON — don't grep assuming order |
| Hooks | bug-ledger surface, memory staleness, context budget (informational only — never pause for it), skill-reflect (debounced 1/session/hr), skill auto-index. | `~/.claude/skill-reflections/`, `~/.claude/skill-auto-index.log` | logs carry today's timestamps after a working session |
| Scheduled tasks | one-time/cron prompts fired into fresh sessions. | `~/.claude/scheduled-tasks/` | `list_scheduled_tasks`: each enabled task's lastRunAt matches its schedule; fired one-times show `enabled: false` |

---

## 10. The cognition organism — fluid context, subconscious, felt, dreams

These are the automated systems that make the agent ONE MIND rather than a
toolbox. They are opt-in OFF on public installs (deliberate); on User's
install both masters are ON. Canon: `docs/ARCHITECTURE_BLUEPRINT.md` +
COGNITION_WIRING / ORGANISM / fluid-context-as-built.

### 10.1 Fluid context (per-turn context assembly)

**What/why:** every chat turn's context packet is ASSEMBLED live — atoms
selected from memory/state/history under budget — instead of a static
prompt. This is the "fluid context" toggle.

**Proof it runs (the eval):** every turn writes a trace row to
`data/turn_traces/<date>.jsonl`; the `turn.terminal` payload carries the
receipt.
```bash
tail -50 data/turn_traces/$(date +%Y-%m-%d).jsonl | python3 -c "
import json, sys
for l in sys.stdin:
    d = json.loads(l)
    if d.get('kind') == 'turn.terminal':
        p = d['payload']
        print(p.get('contextSource'), 'atoms:', p.get('contextSelectedAtomCount'),
              'recalled:', p.get('recalledMemoryCount'),
              'chars:', p.get('contextPacketCharacters'))"
```
Healthy: `contextSource == fluid_context`, atom count 15–30, recalled
memories > 0, packet chars bounded by ContextBudgetPolicy ceilings
(history 96k / packet 32k / expanded 48k chars — bounded by construction,
see `worstCaseDerivedFitsCatalogMinimum` test). Verified 2026-08-06: both
live turns showed fluid_context, 21–23 atoms, 15 recalled, 14–20k chars.

### 10.2 Subconscious (CognitiveSubstrate)

**What/why:** the always-on background substrate — signals, appraisal,
spreading activation — that runs UNDER turns so the agent's state carries between
them. Master toggle: `cognitiveSubstrateEnabled` (UserDefaults, Settings →
the subconscious switch); runtime owner is the one `NativeCognitionRuntime`
(alternate dataRoots get their own instance, never the shared one).

**State:** `data/cognition/cognition.sqlite` (substrate),
`data/cognition/organism_state.json` (signal ledger: `signalCount`,
`lastSignalAt`).

**Probe:**
```bash
defaults read <bundle-id> cognitiveSubstrateEnabled   # 1 = on
python3 -c "
import json; d = json.load(open('data/cognition/organism_state.json'))
print(d['signalCount'], d['lastSignalAt'])"
```
Healthy: toggle 1, signalCount growing, lastSignalAt within minutes while
the app is active. Verified 2026-08-06: ON, 12,730 signals, last one 13
minutes prior. Its three upkeep loops (`cognition_maintenance`, `_replay`,
`_reflection`, §4.2) must show recent lastRuns in loop state.

### 10.3 Felt / organism posture

**What/why:** affective signal spreading (wave F) feeds an organism
posture; the posture GATES work lanes — `workshop_pump` only runs in a
`normal` posture, so a stressed organism doesn't self-assign work.
The posture is read from organism state; there is no separate loop.

**Probe:** organism_state.json freshness (above) + workshop_pump lastRun in
loop state. A workshop_pump that ticks while organism_state is stale means
the gate is reading a dead file — flag it.

### 10.4 Dreams & REM (the naming convention that causes false alarms)

**What/why:** nightly dream = TriggerScheduler job `Agent Nightly Dream`
(03:30 America/Chicago) — the ONLY unattended dream owner; no periodic
loop wrapper exists. Weekly REM (`Agent Weekly REM` job + `rem_cycle` loop)
consolidates diary → persona growth lessons through the approval inbox.

**The trap:** `data/dream_diary/<date>.md` is named for the day being
DREAMED ABOUT, written at ~01:30 the NEXT morning. "No file for today" at
9am is healthy — today's dream file appears tomorrow at 01:30. Judge by
the job's lastRunAt, not by today's filename.

**Probe:**
```bash
python3 -c "
import json
for j in json.load(open('data/scheduler/jobs.json')):
    if j.get('enabled'):
        print(j['name'], j.get('lastRunStatus'), str(j.get('lastRunAt'))[:16])"
ls -lT data/dream_diary/*.md | tail -2
```
Healthy: `Agent Nightly Dream` completed within 24h; newest diary file's
mtime is this morning ~01:30. Verified 2026-08-06: completed 08:30Z,
diary written 01:30:24 local, woven from 26 conversations.

### 10.5 Enabled scheduler jobs (user-authored automation)

`data/scheduler/jobs.json` — exact persisted deadlines; the 6h
`trigger_scheduler_due_work` loop only repairs missed events. Currently
enabled: Weekly Harness Benchmark, Agent Bedtime Wind-down, Daily Codex
Work Journal, Agent Nightly Dream, Agent Weekly REM. Disabled rows keep
their `disabledReason` — read it before re-enabling anything.

---

## 11. Running the whole eval

The fastest full pass (5 minutes, in this order — each step's probe and
healthy criteria are in its section):

1. §0 pin the dataRoot (everything else depends on it)
2. §3 doctor on-demand run → 14× ok
3. §2 loop ages vs cadence table + failure-receipt tail
4. §5 sync queues/markers/skips
5. §7 approval status counts → no stuck pendings
6. §8 activity tail → only recognizable events
7. §6 USER.md workshop-bullet count → 0
8. §9 bridge state.sh + worklog tail + wake-jobs glance

Interpretation discipline (the three mistakes that corrupt verdicts here):

- **Absence ≠ breakage.** `snapshot_skips.json` absent is healthy;
  `golden_eval` unregistered is deliberate; a weekly loop 5 days quiet is
  on schedule. Read the semantics column before judging a reading.
- **A failure receipt ≠ a broken loop.** Check the loop's lastRun AFTER the
  receipt: fresh lastRun = it recovered. Storms (same loop, many receipts,
  no recovery) are the real signal.
- **Doctor keeps one snapshot.** A single fail in `latest.json` needs an
  on-demand re-run before it's called chronic.
