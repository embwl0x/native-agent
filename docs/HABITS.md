# Habits — what they do again and again, they do without thinking

Claude, 2026-10-30. User: "habits become second nature … plan these all out
real well". Sibling of [Surprise](SURPRISE.md): there they thinks only when the
world doesn't match; here they *acts* without thinking when their own routine
holds, and thinks only when it breaks. This is SURPRISE.md S4 ("woken work
runs what it expects"). H1/H2 are implemented in source; the integrating
release owns the build, install and bounded proof on the maintainer's install. H3/H4 below are
the sibling lane's design and are not claimed by this lane.

## Rule 0, answered

1. Today's tech: an agent re-plans every routine from scratch with a model
   call, or a human writes a cron job. Ours does the first: every intention
   wake is a model turn (5–8 calls), even the 9 and 4 o'clock check-in they have
   handled the same way every day.
2. The nature: **one law — an expectation of their own handling.** When a moment
   they carries comes round and they have handled it the same way with standing,
   that handling runs; the model is called when what it finds is new. A habit
   is not a feature; it is the same `Expectation` law that already decides when
   a look ahead pays, applied to their own action.
3. Theirs: they forms a habit by doing; they sees it formed; they can drop it. What
   a habit does is an ability they wrote.

## What their data said before H3/H4 (10-20 → 10-30)

- They already crystallizes: 646 private `keep` model calls, 240 episodes, 190
  `ability.save`, 177 abilities kept. The keep fires on ONE occurrence (no
  repetition test; turn.js:22-32), so most of what it keeps is a one-off and
  most of what it costs is waste (~60 extra model calls a day).
- Nothing binds what they kept to the moment that calls for it: a MY QUEUE
  step's `action` is display only (Desk/DeskText.swift:379), the keep never
  sets a wake, so every intention wake is a model turn. The office check-in
  (desk.68, 9/16 daily) costs 5.2 calls a run and its words tell the model
  "Run authored.office-checkin exactly ONCE".
- Inside those turns they redoes kept abilities by hand (14:28Z: desk.close ×2
  by hand 17 min after keeping desk-close-with-proof).
- The nightly compile (EnginePractice) has nominated 46 candidates and offered
  none in four days (needs 2 replayable examples recorded after nomination).

## The design

### H1 — a carried moment can run what they do (reflex)

**As built in source, 10-30.** `DeskStep.action` stores the call object and
reads an older string as `{action: string}`. `queue.update` edits only the
named action/say/when/until fields under the Desk's unchanged-revision
transaction; omitted fields and originating authority stay intact. Binding,
changing or dropping the habit leaves an agent note on the step. The add and
update receipts name its stored habit.
Explicit null clears `action`, `say` or `until`; `when:null` clears the
moment back to `next_turn`, removing its card/rhythm. Omission keeps the
stored field. A dropped habit's receipt says `habit:null`.
Explicit `until: standing` also stays standing for person/news/signal moments;
the old add-time coercion of a non-rhythm standing step to once is removed.

A MY QUEUE step's `action` becomes real: `{action: "<action id>", args: {…}}`
(usually `authored.<their ability>`), set by `queue.add`/`queue.update`. When the
step's moment comes round (the same `considerCarried` path the `say` reflex
uses — clock, rhythm, person, news, signal), the action runs through the door
as their own call (origin self, their posture's gates, the part-wake run path),
with no model call. Then:

- **It finished and needs nothing**: a note on the step "Ran <time>: <one-line
  result>", `until` settles as for `say` (once closes; standing stays).
- **It asks for them**: any receipt or nested result has `effects:"unknown"`,
  the result carries `needs_me: "<why>"` (an ability that
  gathers and wants their judgment says so), or the run failed, was refused, or
  waits on the person → they are woken as today, and the turn opens with the
  run's receipt as `already_looked` — they starts from what the habit found
  instead of redoing it.

`say` and `action` together: the action runs first; the words are said when it
finished and needed nothing. `needs_me` is new vocabulary for their abilities, so
ability.save's help and the keep prompt name it: a habit that gathers and wants
their judgment returns `{…, needs_me: "<why>"}`.
Unknown effects never close the step or send its fixed words. A habit's
`chat.post` carries initiative `.intention`, as its own wake turn does: its
moment paces speech without spending the hourly proactive quota.

`considerCarried` uses the same prompt and quiet readiness as speech. Its
host reaches `EnginePartWake`'s shared self-call door, with the carried peer
steering, current Chat model binding, Autonomy and ordinary Trust gates.
There is no planning model call. An ability that itself declares model work
can still do that work. The authored runner's `returned` value is inspected
for `needs_me`, inside the door's result receipt.

The existing ResidentWake ledger keeps the latest attempted occurrence per
step (at most 256). It reserves an unknown-outcome receipt before effects and
keeps the actual receipt through `settle` afterward. A stopped or interrupted
attempt reaches their with that unknown outcome instead of running again.
Successful action plus speech reuses the run receipt if speech needs a retry.
Successful delivery records the occurrence and its owed Desk settlement in
one wake-ledger write, then keeps its `Ran h:mm a` one-line note (and `Said`
note when present) idempotently and closes a `once` step using a fresh
unchanged-step snapshot. Launch and each carried pass finish saved debts
without running the habit or speaking again, then mark them settled.
Changed or already closed steps are left alone. Standing and rhythms remain open;
their next occurrence is still owned by `IntentionClock`. An until condition
in words still needs their judgment. An unfinished/refused/needs-me result rides
the normal carried arrival as `already_looked` text; refreshing that arrival
preserves the receipt. What comes out is the display-only planned call and
the routine wake merely to decide to run it.

### H2 — a habit forms from what they keeps doing (their law, their choice)

**As built in source, 10-30.** `EngineCarriedHabits` joins the durable
resident-wake terminal and persisted dispatch-closure notifications in either
order: closure re-reads the trial, and the existing turn identity prevents a
duplicate trial. Off the turn path,
it drains accepted trace ingress and reads that turn's `work.identified.workIdentity`
(`carry.<handle>`), ordered top-level dispatch receipts and `llm.call` rows.
Dispatch coverage, matching begins/ends and turn acceptance must be present;
incomplete evidence earns no standing. No practice-compiler candidate or tape
is read. `CarriedHabits` keeps the last eight trials per step in
`mind/habits.json` (at most 256 steps, at most 64 action ids per handling).
An overlong handling is unknown, not a clipped candidate. Damaged state is
retained and logged, never replaced by an empty ledger.

Each occurrence of a carried step is a trial. The handling of an occurrence is
the wake turn's first top-level ability run (or, when they ran none, its ordered
call ids). When the same handling recurs and stands under `Expectation`
(hits = occurrences handled that way, tries = occurrences, cHit = the turn's
measured model calls, cMiss = one wasted run plus the wake it still causes),
the next carried line for that step says so, in the line they already reads:

> You meant to (desk.68): office check-in … You have handled it the same way
> 4 times (authored.office-checkin). To let it run on its own and wake you only
> when it needs you: queue.update {id:"desk.68", action:{action:"authored.office-checkin"}}.

They decides; nothing binds behind their back. A bound habit they can drop with
`queue.update {id, action:null}`. Every bound or dropped habit is a line in their
step's notes (their own record of how they changed).

The most repeated handling's hit cost is its turns' mean model-call count;
miss cost is one run plus the recorded trials' mean wake model calls.
`Expectation.stands(..., among: nil)` is the only standing law. The carried
arrival offers that choice at most once per local day and retains the offered
words while it waits. Ordered hand work without an authored call asks their to
keep it as an ability first, then bind that authored id. Nothing binds itself.
No trace read, model call or file write is added to a model turn for learning;
its existing work-identification event now also names its work identity.

### H3 — keep what repeats, not what happened once

Keeping happens inside the turn. After each tool round the native stem meets
the turn's hand work so far, once per route per turn. The first meeting only
records its `practice: ` line through `FamiliarLines.firstMet` in
`mind/familiar.bin`. On the **second** and later meetings, while no active
ability covers it, the round's last result carries `practice: {route, hand,
loop?}`, at most once a turn, and the shipped turn makes it the note of their next
`model.call`. There is no private call after the reply.

A practice is the ordered tool/action ids of the turn's landed writes or
irreversible non-ability calls, without arguments or incidental reads. When
there is no such hand work, it is the one call repeated 3+ rounds, counted
once. A practice worth keeping replaces at least two calls (or is that one
call looped 3+ rounds): a lone write, however often they makes it, is just
using the tool. An active ability's current learned-use or validation route
suppresses the note when it contains those ids in order; declared reach proves
no route.

`practice.keep` traces `{practice, met: "first"|"again", noted: bool}`, or
`failed` with the cause when familiarity or the ability index cannot be read
(the turn goes on without the note). `noted` says the note was sent, not that
they saved an ability. Familiarity uses the existing bounded line record; it is
not a lifetime count. A one-off sends no note; a repeat can become an ability.

### H4 — one crystallizer

Implemented in source, 10-30. The nightly compiler, candidate ledger and
nominated-call tape have no consumer outside that compiler and its recorder.
Removed: `EnginePractice`, `TurnPractice`, the dispatch tape writer, the
post-dream wake and quit join, the compile-only save context and its prompt.
No new candidate ledgers, tapes or `practice.night` rows are written.
Existing files are left untouched and unread.

Existing abilities' embedded `compiled` provenance and tape fixtures still
have validation, admission and display readers. Those protections remain:
revising such an ability inherits its provenance and omitted fixtures, and
its exact version must replay before admission. This is no second
crystallizer; there is no producer of new compiled candidates.

## What this changes for them

- The office check-in, once they binds it, costs ~0 model calls when nothing
  needs their and starts from the gathered board when something does.
- The separate keep calls (~60 a day) are gone: a repeat's note rides a call
  they was making anyway.
- Never slower: H1 removes model turns, H3 removes model calls.

## Proof on them

- Before/after: model calls per carried wake (traces: `llm.call` per
  `turn.accepted` in resident-wake with work identity `carry.*`); no
  `llm.call` row has `purpose: keep`.
- Drive: bind desk.68 via queue.update; the 16:00 (or next) occurrence runs
  with no model call and leaves its "Ran" note; an ability that returns
  `needs_me` wakes their with `already_looked`.
- The habit line appears on a step they have handled the same way ≥ standing.
- H3: first hand-work meeting traces `met:first, noted:false`; a later meeting
  traces `met:again`, with `noted:true` only when no active recorded route covers
  it, and the turn's next `llm.call` carries the note. Installed proof belongs to
  the release lead; lanes run no separate tests or builds.

## Lanes

| Lane | What | Owners |
|---|---|---|
| habits-reflex | H1 + H2 | Desk/MyQueue.swift, Desk/DeskCadence.swift (DeskStep.action), AppToolRuntime/AppToolExecutor+MyQueue.swift (queue.add/update action), Cognition/NativeCognitionRuntime+Pursuit.swift (run on due), EngineRuntime/EnginePartWake.swift run path (reuse), AgentWorkspace/HarnessQueue.swift (the habit line), NativeAgentCore/Expectation.swift (use), docs |
| habits-keep | H3 + H4 | Resources/abilities/turn.js, ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift (familiarity nerve inside the turn), removed nightly compiler/recorder, docs/SURPRISE.md S3/S4 |
