# The agent instrument — hook in and take a look

Any agent (Claude, codex, a fresh Claude/GPT session) can run one command
against a NativeAgent data root and get a truthful, evidence-cited read of how
the agent is doing — as the best general-purpose agent it can be: memory,
personality/subconscious liveness, organization/desk throughput, turn speed,
cost. It is an **instrument, not an autopilot**: it reads and reports; humans
and the agents they point at it decide what to change.

## Run it

```bash
swift script/agent_instrument.swift --data-root ./data --days 7 --out /tmp/report.md
```

- `--data-root` — the NativeAgent data root to read (default `./data`).
- `--days` — reporting window (default 7; lane dormancy uses a longer lookback
  automatically so "last alive" can be dated).
- `--out` — where the markdown report goes. Refused if it resolves inside the
  data root.
- `--persona-root` — where `GROWTH.md` lives (default `<data-root>/../persona`).
- `--no-bridge-config` / `--no-machine-state` — switch off the two reads that
  reach OUTSIDE the data root: the `~/.config` wake lanes (SYS-01) and the
  installed app bundle + preferences domain (SYS-14). Both are already gated to
  a real install root; these flags turn them off everywhere.
- `--now <ISO-8601>` — pin the wall clock instead of using "right now". For
  frozen-root determinism checks only: two runs over identical bytes can only be
  byte-compared when the clock does not move between them. A pinned run stamps
  **CLOCK PINNED** in its own header, so it can never be mistaken for a live one.

Takes seconds. Safe to run against a live app: every SQLite store is copied
before it is queried, JSONL feeds are streamed read-only, and the tool refuses
to write anything into the data root.

## Read the report top-down

1. **BOOM** — one screen: health line, top 3 leads, top 3 blind spots. If you
   read nothing else, read this.
2. **Leads** — ranked, each citing its evidence (row counts, trace dates,
   store queries). A lead is a place to investigate, not a verdict.
3. **Blind spots** — places the instrument *cannot see* (dark stages,
   not-yet-persisted subsystems, uncovered feeds). These are as important as
   the leads: a lane nobody measures is where the next silent failure lives.
4. Detail sections (a)–(j) for whatever you dig into. (a)–(g) grade the
   COGNITIVE system against `docs/SUBCONSCIOUS.md`; **(h) the System matrix
   (SYS)** grades the FUNCTIONAL system against
   `docs/ARCHITECTURE_BLUEPRINT.md` — one row per organ SYS-01..14 with a
   status, its sources and a one-line live reading; (i) is the reach walk,
   (j) the leads.

| id | organ | its own detail block |
|---|---|---|
| SYS-01 | agent bridges (claude / codex / OMP wake lanes) | per-lane table |
| SYS-02 | background loops (scheduler tick outcomes) | per-loop table |
| SYS-03 | delegation / orchestration (task ledger + outcome cursors) | — |
| SYS-04 | notifications / push delivery (inbox, APNs, iCloud receipts) | — |
| SYS-05 | memory V2 housekeeping (proposals, tombstones, epoch, hygiene) | — |
| SYS-06 | Workshop (executions, receipts, background lease) | — |
| SYS-07 | GitHub command lane (watcher, ops ledger, approvals) | — |
| SYS-08 | heartbeat / self-healing | — |
| SYS-09 | providers / routing (surface pins, registry, substitutions) | per-surface pin-vs-observed table |
| SYS-10 | tools (dispatch outcomes, registry, gate refusals) | per-tool outcome table incl. `failure reason(s)` from the tracer's bounded `receipt.errorDetail` (rows before 2026-08-21 carry none) |
| SYS-11 | sync (iCloud bridge, companion snapshots, paired devices) | per-snapshot freshness table |
| SYS-12 | chat sessions (index, retention, per-surface turn volume) | — |
| SYS-13 | security / trust (gate decisions, approvals, mac control) | refusals + approval inbox |
| SYS-14 | update lane (Sparkle feed, honesty flag, installed build) | — |

Two organs read state that lives OUTSIDE the data root, under the same
hermeticity rule (real install root only, plus a kill switch): **SYS-01** reads
`~/.config/<lane>-bridge/…` (`--no-bridge-config`), and **SYS-14** reads the
installed app bundle's `Info.plist` and the app's preferences domain
(`--no-machine-state`). On a fixture root both correctly read `source absent`.

Current-state precedence is explicit in the report. A fresh connected
`slack/state.json` heartbeat outranks historical Slack error rows; Telegram's
`update_inbox/claims_index.json` separates pending/processing work from the
intentional newest-256 terminal-claim retention set. Provider routing recognizes
`desk` as canonical and `cognition_cue` as retired compatibility state. Turn
lifecycle grading requires at least one `context.ready` and uses the earliest
one for initial provider ordering, because tool/provider rounds may rebuild
context legitimately. GitHub Command `ready`/`waiting_external` motor rows are
watcher-owned waits rather than abandoned actions. The passive organism-watch
timeline is historical/inactive unless its writer lock directory proves an
explicit run is currently active.

**SYS-14 is the one organ the data root persists nothing for.** That is a
finding, not a hole in the reader: `UpdateController` keeps its notice in
`UserDefaults` and the publish-honesty flag (`NativeAgentUpdateFeedPublished`)
lives in the shipped bundle. The row says so in as many words.

**Secret discipline (SYS-09, SYS-11).** Wave 2 is the first to read credential
files — `data/providers/<id>.json` holds live API keys and OAuth tokens, and
`mobile_push/tokens.json` holds APNs device tokens. The provider reader has an
ALLOWLIST (`providerSafeKeys` = `auth_mode`, `default_model`) of keys it may
even look at; everything else about those files is reported as shape only
(parsed / not parsed, key count). Treat that list as a security boundary — the
test suite plants a fake secret in a fixture credential file and asserts it
never appears anywhere in the report, with a mutation test that widens the
allowlist and proves the assertion goes red.

### The SYS severity rule

The BOOM's `system: N/14 organs measured, worst: …` line picks its "worst"
organ from one fixed order, lowest first, ties broken on the SYS id — so the
same data always names the same organ:

| rank | state | meaning |
|---|---|---|
| 0 | `unreadable` | a feed exists and would not read — every number is unknown AND something is broken |
| 1 | `absent-expected` | the organ's feeds are not on disk; an unmeasured organ can hide anything |
| 2 | `failure-streak` | measured and failing now (repeated loop failures, an undelivered backlog, a non-`ok` heartbeat) |
| 3 | `stale` | measured, not failing, but its clock stopped (a loop that stopped ticking, a watcher going cold) |
| 4 | `healthy` | measured, inside every bound the reader knows |

A known failure ranks *below* an unknown one on purpose: we can see it and act.
The rule lives on `SysSeverity` in `script/agent_instrument.swift`.

### The uncovered-feed burndown

The reach walk's NOT COVERED count is a **tracked number**, not a fact of
nature. The BOOM's reach line reads it against an in-code baseline:

```
[reach] 671 uncovered feed(s), 165 active — 103 closed since the 2026-08-21 baseline of 774
```

`uncoveredBaseline` / `uncoveredBaselineDate` live in
`script/agent_instrument.swift` with the wave-by-wave history beside them. The
rules that keep it from rotting into decoration:

- the baseline moves **only** together with a wave that shipped readers, never
  to make a delta look better;
- each wave states in `docs/build_plans/full-system-eval-coverage.md` what it
  claimed and what it deliberately left;
- a **rise** is normal and is printed plainly — a new subsystem announces itself
  as a blind spot the day it starts writing, which is the property the walker
  exists for.

A reader may only claim a feed family it actually opens. An inventory-only
glance is not coverage; those stay in NOT COVERED on purpose.

### Determinism

Two runs of the instrument over a **frozen** data root produce a byte-identical
report — the whole report, not just one section. That is load-bearing: it is
what makes "diff two reports" a usable way to see what changed in the system
rather than what changed in Swift's per-process Dictionary seed. It costs two
things:

- every dictionary-derived sort carries a **name tie-break** (equal counts,
  equal ages, equal byte sizes all resolve on the key), and
- the scratch dir is printed with its pid elided, since it is created per run
  and deleted at exit.

The clock is the only remaining moving part, so `--now` pins it. The proof
lives in the test suite (`(u) whole-report determinism over a frozen root`),
with a mutation test that deletes two tie-breaks and confirms the byte
comparison goes red.

Note on SYS-01: the bridge lanes live outside the data root
(`~/.config/<lane>-bridge/…`). They are read **only** when the data root is a
real install root, and `--no-bridge-config` turns them off entirely — so on a
fixture root SYS-01 correctly reads `source absent`, never zero. SYS-14's
machine-global reads follow the same rule under `--no-machine-state`.

SYS-01 also reads the codex lane's `reply-jobs/undelivered/` (2026-08-21):
replies the bridge PRESERVED with full text because delivery settled 409 /
outcome_unknown, and which nothing replays by design. The row prints
`preserved-undelivered: N (oldest Xd)` — age is the reply's own completion
stamp — and the per-lane table has a `preserved (undelivered/)` column. The
directory is created lazily by the first preserve, so a lane without one
prints `—` (a dash, not 0) and the row cell is omitted when no lane has one;
a present-but-garbage directory reads UNREADABLE like any job family. A
non-zero count is `stale` severity and raises a ranked lead: it is completed
work nobody acknowledged, and the app's inbox carries a rolling
"Codex: N undelivered replies preserved" card over the same directory.

## Interpretation rules (the instrument enforces these; you should too)

- **Absent is not zero.** "Source absent" / "unmeasured" / "dark" mean the
  instrument could not measure — never treat them as a healthy 0.
- **Dormant is a suspicion, not a diagnosis.** A lane at zero for days means a
  wire MAY have come loose. Verify against the code and live stores before
  declaring anything dead (see the sweep of 2026-08-20: a "dead" memory lane
  was a stale counter, the memory itself was flowing).
- **Zero-is-healthy flags** (…Truncated, …Failed, …Error) are listed but never
  flagged; judgment is the reader's.

## Turning findings into work

Findings become **code changes, decided by humans** — that is the whole
design. The loop that "improves the agent by writing into its memory or
persona" is deliberately not built and must not be added: the resident agent's
memory, persona, and views are its own; the instrument measures, it never
treats (see the Hard rules in
`docs/build_plans/agent-improvement-instrument.md`).

Practical routes, in order of weight:
- a chip / spawned task for a one-file fix (cite the report line as evidence),
- a desk card when the resident agent should track it,
- a build-plan file (`docs/build_plans/`) for anything multi-step.

## The turn-replay bench — "did we change who the agent is"

The instrument above *reads* the live stores. The bench *re-runs the agent*. It is the
release gate: take real recorded turns, replay them through the candidate
build's own context-assembly code against a frozen snapshot of the stores, and
check that the things that make the agent distinct still show up.

It never calls an LLM. On a non-default data root the chat factory installs
`AlternateRootUnavailableChatLLMClient`, which throws on any provider call — and
the bench never reaches it, because **assembling the context is the measured
artifact**. No network, no tokens.

### Run it against the checked-in synthetic fixture (always)

```bash
swift test --filter TurnReplayBench
```

That exercises the whole bench end-to-end on a tiny hand-built root created in a
temp dir — generic persona docs, a substrate seeded through the real ingest API,
no personal data. It runs in CI and on every `script/test.sh`.

### Release-gate mode

On a release close-out, run the real-fixture lane with the gate armed — a
missing fixture then FAILS instead of skipping:

```bash
NATIVEAGENT_RELEASE_GATE=1 NATIVEAGENT_BENCH_FIXTURE=local/bench_fixtures/<dir> \
  swift test --filter TurnReplayBench
```

### The session-history lane (v2 fixtures, 2026-08-21)

Production streaming with a sessionId does not call bare `buildTurnContext`; it
runs `buildTurnContextWithHistory` — prior rows read off
`chat/messages/<sessionId>.jsonl`, the recall query EXPANDED with the latest
prior user/assistant lines, `recentTurns` threaded into context selection, and
a rendered history block appended to the DYNAMIC segment — and emits its own
`context.history.summary` receipt. Since v2 fixtures the bench replays THAT
path: every captured turn carries a bounded transcript window (the rows the
source turn actually saw), the bench stages it at the production-keyed path for
the duration of the turn, replays through `buildTurnContextWithHistory` with a
fixture-rooted reader and a hermetically-rooted digest provider, and grades
both receipts. A v1 fixture (no window) still replays the bare path; the
synthetic fixture runs one bare turn and one history-lane turn on every
`swift test`, so the lane cannot go dark unnoticed.

Named limit: because the window is bounded, the reader's relevance-sampled
MIDDLE lane still runs on windows above 40 rows but samples the window, not the
full source transcript — a regression confined to middle-snippet selection over
a long transcript is named here, not graded.

### Run it against real recorded turns

```bash
# 1. snapshot a hermetic fixture (READ-ONLY on the live root)
swift script/agent_bench_capture.swift --data-root ./data --turns 6 --days 14

# 2. replay it
NATIVEAGENT_BENCH_FIXTURE=local/bench_fixtures/<fixture-dir> \
  swift test --filter TurnReplayBench
```

`agent_bench_capture.swift` copies `cognition.sqlite` and `memory.sqlite`
(db + `-wal` + `-shm`, then `PRAGMA quick_check` on the COPY), the persona docs,
the config files assembly reads, and the recorded turns' user messages from
`data/chat/messages/<sessionId>.jsonl` — linked to their traces through the
assistant row's `metadata.turnTraceId`. For each turn it also copies a
**bounded transcript window** — the raw rows strictly BEFORE the source user
row, reduced exactly the way `SessionHistoryReader` bounds its own read (first
3 head-anchor lines + a tail of ≤80 lines / ≤192KB), verbatim — to
`root/chat/transcripts/<turnId>.jsonl`. Per turn, not per session, because two
turns from one session saw two different windows while production keys the
file by sessionId; the bench stages each window into
`root/chat/messages/<sessionId>.jsonl` only for that turn's replay. Alongside
them it writes `expectations.json` (schema `turn-replay-bench.expectations.v2`):
each turn's own `context.summary` counts, its FIRST `context.history.summary`
counts (`history.priorCount`, `history.recallQueryChars`, `historyBlockChars`,
…), its `context.snapshot` capsule bytes, and the window's line/byte/truncated
stats.

Flags: `--turns N` (default 5), `--days N` (default 7), `--sessions id,id`,
`--persona-root`, `--out`. Turn selection spreads across sessions and surfaces
before backfilling by recency, so a fixture is never six turns from one burst on
one lane.

- **PRIVACY.** A real fixture contains User's actual memory, persona, cognition
  state, chat text, AND the verbatim prior-conversation windows under
  `chat/transcripts/`. Every fixture dir is stamped `FIXTURE-PRIVATE`, and the
  default output is `local/bench_fixtures/` — `local/` is gitignored. Keep them
  out of the tree; delete them when done.
- The tool **refuses** to write inside the data root or the persona root, and
  **refuses** to produce a fixture with zero replayable turns.

### What it checks (envelope invariants, not byte equality)

Substrate state legitimately drifts, so the bench asks "is this lane still alive
and in shape", using the recorded turn's numbers as a floor:

| Invariant | Claim |
| --- | --- |
| `capsule.injected` | a `[CognitiveSubstrate]` block reached the system prompt where the source turn had one |
| `capsule.kernel` / `capsule.feltLines` | the capsule has a stable kernel and non-empty felt lines |
| `capsule.provenance` | ≥1 provenance node id — proof the capsule was composed from live substrate nodes, not a constant |
| `capsule.fingerprint` | every felt word comes from a family this build can still reach |
| `felt.vocabulary` | ≥12 distinct fingerprint words reachable at all (build-level probe, no fixture needed) |
| `organism.posture` / `organism.injected` | the `[OrganismBehavior]` posture block still renders |
| `contextFlow.attention*` | each attention lane nonzero where the source turn's was |
| `memory.records` | ≥1 memory record selected where the source turn had ≥1 |
| `affect.axes` / `affect.liveness` | four axes finite in 0…1, and not all flat at zero when the source carried a live capsule |
| `segments.stable` / `segments.dynamic` | both system segments render, sizes within **0.5x–2x** (stable) and **0.25x–4x** (dynamic) of the source turn |
| `persona.docCount` | at least as many persona docs load as the source turn had |
| `history.injected` | (history lane) where the source saw prior rows: the reader returns >0 rows off the staged window, the renderer produces a non-empty block, AND the block actually landed in the dynamic segment (outer − inner `system.dynamicChars` ≥ block chars — a block that is rendered but never appended fails here) |
| `history.recallQuery` | (history lane) where the source produced a recall query: the replay's is non-empty, and where prior rows were read it is LONGER than the bare `Current user:` line — the expansion still feeds prior-turn context into memory recall |
| `history.traced` / `history.staged` / `history.sessionId` | (history lane) the outer `context.history.summary` receipt arrived within the deadline; the window could be staged; the session id is one the production reader accepts |
| `bench.nonvacuous` | **≥1 turn replayed.** A run that replays nothing is a FAILURE, never a pass |

Every failure names the turn, the invariant, and expected-vs-got.

### Two things the bench will tell you that are not verdicts

- **UNMEASURABLE lanes.** `attentionActivation` / `attentionWorkingAtoms` are
  read off the substrate's hot set, which decays on a 1h activation half-life.
  If the fixture was captured more than 2h after a recorded turn, those numbers
  cannot transfer — the bench says so by name, with the gap, and grades neither
  pass nor fail. Capture close to the turns you care about if you want those
  lanes graded.
- **The replay clock is pinned to capture time**, not to the turn's timestamp.
  Capture time is the only instant at which the fixture's stores are internally
  coherent; winding back to the turn puts the clock behind the substrate's own
  `updatedAt` and reads every affect axis as 0. (Both of these were found by
  running it, not by reasoning about it.)

### Proving the gate still bites

A bench that cannot catch a lobotomy is theater. Two checks keep it honest:

- `benchReportsANamedFindingWhenAnInvariantCannotHold` — an in-suite negative
  control that poisons a fixture expectation and asserts the named finding
  appears.
- A **mutation drill** before you trust a change to this file: temporarily break
  `contextByAppendingCognitiveCapsule` (return before the injection) or
  `NativeCognitionRuntime.attentionSignals` (return nil), rebuild, and confirm
  the bench fails with `capsule.injected` / `contextFlow.attentionTerms` on every
  turn. Verified 2026-08-21 against both fixtures; restore and re-run green.
- The **history-lane drills** (run 2026-08-21 against the synthetic fixture and a
  4-turn real fixture, restore + green rerun after each):
  1. `buildTurnContextWithHistory`: `let historyBlock: String? = nil` → every
     history-lane turn fails `history.injected` ("read N prior rows but nothing
     rendered");
  2. the segment combine: `dynamic: seg.dynamic` (block rendered, never
     appended) → every turn fails `history.injected` ("rendered but not
     injected", outer − inner ≈ 320 chars of clock line vs a 2–21k block);
  3. `SessionHistoryPromptRenderer.recallQuery(… messages: [])` → every turn
     fails `history.recallQuery` (bare line of 61/111/128/144/537 chars vs the
     source's 793–1200). Drill 3 found a gap the first time — a >520-char
     message's `...` cap suffix let the unexpanded query pass by 3 chars —
     fixed, re-proved on all four turns.
  The in-suite negative control also stages an EMPTY window under an expectation
  that claims prior rows, and asserts `history.injected` is named.

## Extending it

The reach walker inventories the entire data root; **any feed without a reader
appears in NOT COVERED automatically** — new subsystems announce themselves as
blind spots the day they ship. To close one:
1. add a reader in `script/agent_instrument.swift` (copy-before-query for
   sqlite, streamed read-only for JSONL),
2. if it is part of the cognitive system, add/upgrade its row in the coverage
   matrix (the in-code inventory mirroring `docs/SUBCONSCIOUS.md`),
3. add a fixture case to `tests/scripts/agent_instrument_test.sh` — including
   the negative control (absent source renders absent, not zero).

The map of what the cognitive subsystems ARE lives in `docs/SUBCONSCIOUS.md`;
the instrument's coverage matrix is graded against it.

## The personality range bench — the whole range, never on the resident agent

Layer 1 (`tests/NativeAgentAppTests/PersonalityRangeBenchTests.swift`, runs in
every `swift test`): scripted emotional sequences — hostility → repair,
joke-after-tension, sustained pressure, adversarial bursts — driven through
the REAL appraisal door on disposable hermetic clones, asserting envelope
properties of the response curves (direction, bounds, saturation,
half-life-proportioned decay, fingerprint-family walk). Never exact values: a
retune passes, a flattened or unbounded response fails by name. The ethic is
a hard rule with runtime teeth: clones only, under the system temp dir; a
root that is the default data root aborts the scenario. Layer 2 (real-turn
behavioral ritual on a sandbox seat) is designed in
`docs/build_plans/personality-range-bench.md`.

## The two-minute check — `script/evals.sh` + the coverage ledger

One command, run from anywhere, ~40 s:

    script/evals.sh            # smoke · instrument (live, read-only) · turn-replay · range-bench L1 · ledger keeper
    script/evals.sh --live     # + range bench scenario #2 on a disposable clone (real tokens)
    script/evals.sh --ui       # + user-mode AX walk of the installed app (MOVES THE SCREEN — Agent's lane)

Green means: scripts self-check, every instrument section renders from live data,
a synthetic turn replays with every envelope invariant held, the personality
substrate still moves through its range, and every enumerable surface (modules,
screens, tools, @AppStorage keys, scripts) has a coverage-ledger row.

The ledger (`docs/evals/ledger.json`, rendered at `docs/evals/COVERAGE.md`) is the
map: every surface COVERED / REPORTS-ONLY / UNCOVERED with its silent-failure mode
named. It is maintained by merge, never by hand:

    swift script/evals_ledger_merge.swift <fragments.json> --out docs/evals

The keeper test (`EvalCoverageLedgerTests`) fails the build on any NEW enumerable
surface without a row; known gaps live in `docs/evals/keeper-baseline.json` with a
date, and get burned down, not tolerated forever. Build waves land through
`swift script/evals_apply_wave.swift <wave-output.json>` — per fence: apply, retest
here, one commit; anything failing is HELD and listed, never silently skipped.
Campaign log: `docs/build_plans/evals-total-coverage.md`.
