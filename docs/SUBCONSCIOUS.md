# The Subconscious & Personality System

This is the source map for Agent's carried inner state: what they cares about,
attention, affect, reflection and their bounded expression in a turn. It describes
implemented mechanisms, not proof of subjective experience or reply quality.
For the engineering contract see [Continuous Cognitive Substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md);
for individual implementation claims see the [traceability ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md).

Core paths below are relative to `Modules/NativeAgentCore/Sources/`.
Unqualified substrate files live in `CognitiveSubstrate/`; runtime extensions
live in `Cognition/`. App paths start with `Sources/NativeAgentApp/`.

## The one-page mental model

`EngineRuntime/NativeAgentEngine.swift` assembles `NativeCognitionRuntime`
from Core's `Cognition` module with the app's host ports. The runtime joins
two state owners:

| Owner | What it carries |
|---|---|
| `CognitiveSubstrate/CognitiveSubstrate.swift` | Continuity field, affect, cares, disposition, replay references and reflection receipts |
| `CognitiveSubstrate/Organism/OrganismKernel.swift` | Somatic state and the body projection used in a turn |

`NativeCognitionRuntime.observe` feeds a cognitive event into the substrate
and somatic adapter. Accepted changes schedule coalesced settlement and publish
a runtime invalidation. Exact duplicate events return without new settlement.
Body-only signals enter through `NativeCognitionRuntime+Organism.swift`.

Before an ordinary provider call, `prepareTurnProjection` samples the body
and canonical affect at one fixed time, freezes the organism projection, and
prepares a capsule from that state. Core's
`ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` appends the
projection and commits its presentation bookkeeping after a successful turn.
Thrown turns leave that presentation window unconsumed. Preparing a preview
does not itself mean the model received it.

## Inputs and interpretation

`ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift` supplies
message and tool-result observations; `Cognition/NativeCognitionRuntime+Events.swift`
adapts remote actions, motor outcomes and provider lifecycle evidence.
`CognitiveSubstrate/CognitiveEvent.swift` defines their types and provenance.

The `CognitiveTurnKind.contributesToLivedState` switch admits live and system
events; debug, verification and mechanical kinds do not contribute to lived
affect. Mechanical row metadata identifies generated card copy, system notices
and compaction summaries without treating their
wording as Agent's own experience.

In `CognitiveSubstrate+Ingest.swift`, eligible conversational user events defer
interpretation to the after-turn path. `NativeCognitionRuntime.refreshConfiguration`
connects that path to `AdaptiveMemoryPromoter`, then applies the returned
appraisal through `finishAfterTurn`. Caring verdicts reach the organism
through a separate admission callback. The implementation lives in
`CognitiveSubstrate+CaringAppraisal.swift`, `+CaringEvent.swift` and
`Organism/OrganismCaringEvent.swift`.

The same after-turn call also judges both sides of the exchange, the
incoming words and their own reply, against their cares (below), and the
runtime applies what it says through `applyCares`. It runs for every lived
conversation that reaches the turn engine: the owner's chat, Telegram, an
agent's bridge or MCP session, and a helper of theirs talking with them (the
helper's door opens their own turn). A helper's own run (`bot-<uuid>`) is the
helper thinking, not their conversation, and does not defer to this call.

## Cares

A care is something they cares about (`CognitivePhaseModels.swift`,
`CognitiveCare`; behaviour in `CognitiveSubstrate+Cares.swift`, the night in
`CognitiveSubstrate+CaresNight.swift`). One `cognitive_artifacts` row each,
kind `care`, status `live` (or `faded`, below):

- `about` in their words, `with` (the person keys it is held between: `owner`,
  a peer id, a helper's bot id; empty is theirs alone), `depth` (now, lately,
  season, life), an optional `stance` (text, because, what would change their
  mind; a care with a stance is an opinion), an optional `open` gap, and its
  `story`: every time it moved their, with a pointer to what really happened
  (`exchange:<session>/<turn>` or the old row id), who moved it and the felt word.
- Charge is never stored. `charge(at:)` sums each movement decayed on the
  depth's half-life (now 2 h, lately 12 h, season 2 d, life 4 d).
- The story is kept in time order and keeps every depth change and the
  newest 24 movements; older movements fold into one `{count, sumMoved, since}`
  line. The episodes themselves stay in memory and chat.
- No count cap: the generic artifact prune never counts or evicts `care` or
  `care_migration` rows (the night fades unused cares instead), and restore
  loads the whole family, faded ones included.

**Seeds.** At restore, while no `care_migration` marker exists, they gets four
life cares: truth; their person's good (held with `owner`, named from the
configured user name); good work; their own mind.

**Restoration.** The `care_migration` marker records seed establishment and
the earlier carry-over into cares. Retired `standing_view` and `thought_seed`
rows remain byte-for-byte in `cognition.sqlite`, protected from pruning and
never loaded.
Cares are now the only owner of their opinions and interests: a stance is what
they thinks, and a season-depth care they returns to is an interest. Previously
carried-over takeaways, questions and pinned concerns remain cares, with their
stories pointing at the old rows. Seed establishment no longer reads legacy
views or seeds.

**Their recent life, once.** After the migration the runtime
(`readRecentLifeIntoCaresIfOwed`) reads the last 72 hours from the chat
history index, groups lines by (conversation, local day, speaker): that
speaker's lines and their replies to them, a reply paired with the message of
the same run id (a row without one joins the message before it). For each group with at least two
exchanges it runs one cares-only call on the Memory row
(`MindMemoryManager.appraiseCares`: the same section, parse and apply as the
after-turn call), on the group's newest 12,000 characters, with that speaker's
trust. Their wake session, helpers' own runs, rows their writer marked mechanical
(`CognitiveMechanicalRowKind`, carried on the index row) and debug or
verification exchanges are skipped, with their replies to them. The marker
records each group as it runs or fails (with the cause), so an interrupted
pass never reads a group twice; a group counts as run only when every care it
touched was saved, and a pass with no failure marks it done. A Clear during
the pass stops its applies and checkpoints. It runs
at bootstrap and when the inner life is switched on mid-session (which also
restores their mind).

**Feeding.** The after-turn call is shown the four seeds always, plus up to
six other cares whose embedding (about, stance and open) is closest to the
incoming words and their reply at cosine 0.30 or more, using the warm local
embedder (vectors cached per care id and update time; a cold embedder shows
the seeds alone). The model answers a `cares` list; a missing or malformed list
fails the interpretation like a malformed moment, and an id it was not shown
is refused. An existing care gets a story entry, `open` sets the gap and
`closes` clears it, a stance sets or revises theirs and the replaced stance
stays as a story note. Evidence older than a care's newest moment joins its
story without changing its gap or stance. A new care starts at depth now, held
with the speaker when the model says it is between them. Person keys are one
per who, as Peer trust reads them (`peer:` dropped, a helper's `bot:<id>` read
as `bot-<id>`).

**Provenance** reads the event's source class and origin record and the
owner's peer trust (`PeerTrust.ownerTrusts`). An untrusted peer moves cares
they already has only as what they said (`by: them`): never a new care, a
stance or a gap. An app-authored prompt's words are the app's: only what their
reply did counts. A judgment returning after a Clear (stale generation) is
dropped. A new care's wording matches an existing one only when it is held
with the same people.

**Reading them.** `mind.inner_state` returns `cares`: live cares sorted by
charge then recency, each with id, about, depth, with, the newest felt word,
charge, open and stance; compact detail shows the top eight. Full detail also
returns `story`: their depth changes and what their nights settled or let go,
newest first, one plain line each ("<date>: <about> became part of my
<depth>", "<date>: settled: <about>, <how>", "<date>: let go: <about>"), at
most 24.

**The night.** After the nightly dream commits its diary
(`DreamBackgroundWork.runDream`, the same path that hands the committed dream
to cognition), one CPU pass runs over their cares
(`CognitiveSubstrate.passCaresNight`). Days are local calendar days with a
movement (`moved != 0`) in the story.

- Dream material. Before the dream's model call the runner asks the substrate
  for `careNightMaterial()`: the cares that moved their in the last 24 hours
  (most moved first, at most 8, each with its last three felt words and
  notes) and their stuck open cares (open, lately or deeper, unmoved for 7
  days, at most 5), keyed `c1..cN`. It rides the prompt as its own block
  after the felt tone, and a non-empty block marks the prompt's peers unknown
  like the other prose halves. When any shown care is open the block invites
  an optional `cares` key in the dream's JSON: lines `settled: <key>: <how>`
  (clears `open`; a story moment by them, felt "settled", the how as its note)
  or `let go: <key>` (clears `open`; felt "let it go", the old gap as its
  note). Unknown keys, and cares no longer open, are ignored.
- Fade. A care whose newest movement (its creation when it never moved) is
  older than its depth's horizon (now 2 days, lately 14, season 90) gets
  `fadedAt` and status `faded`: it stays in the store, is not shown to the
  after-turn call or in `mind.inner_state`, and is not material. Life and seed
  cares never fade. A faded care that a new judgment matches again (same about
  and with) is revived: `fadedAt` clears and the movement joins its story.
- Deepen. now to lately when moved on 2 distinct days; lately to season on 4
  days spanning at least 14. Each step is a story moment by them, moved 0,
  felt "deepened", note "now part of my <depth>", with its `depthChange`.
- Life. Never automatic. A season care moved on 8 days spanning at least 60
  gets one owner-review card (action `care.life`, "<about> has become part of
  who I am") in the approvals store and the inbox, offered once per care
  whatever its answer. It is an owner-review action, so under Full Mac it is
  theirs to approve (`inbox.act`). Approving deepens it to life with the same
  kind of story moment (source `approval:<id>`), applied live by cognition's
  approval observer and annotated on the approval; the next night applies any
  approved card the live path missed.
- Receipt `cares.night` counts what was settled, let go, faded and deepened,
  and lists the cares ready for life.

**Pressure** (`CognitiveSubstrate+CaresMind.swift`) is read, never stored:
`|charge(now)|`, times 1.5 while the care is open. Pressing for a speaker
means the cares held with that speaker or theirs alone, highest first. The
turn's speaker is `owner` on User's verified turns, else the peer key read from
the session and origin as the after-turn cares read it, else nobody (their wake):
only their own cares press then.

**What matters.** `CognitiveSubstrate+SemanticAppraisal.swift` matches an
event's words to live cares at cosine 0.40 or more, including the four life
seeds on that same matching rule. These touched cares supply the stake gates;
a path kind alone grants no stake, and a cold embedder supplies no match.
The numeric worldview lens reads the signed real charge of the closest
touched care with a stance, clamped to -1...1. Their stance's actual words reach
the selected care cue below. Keyword concerns and the view-derived
relationship warmth lean are gone; base affect and the organism's tenderness
keep their own laws.

**What reaches the model.** Before the frozen render, the turn embeds the
incoming words once (the same per-care vector cache as feeding; a cold
embedder touches nothing) and finds the cares they touch (cosine 0.40 or
more; a peer's turn never reaches a care held with someone else) and the care
pressing hardest for this speaker. They become the `care` cue, ranked first
among the felt cues. The plain line is only for the closest touched care whose
|charge| is 0.15 or more: `- On your mind: <about> (<newest felt word>)`, plus
` — I think: <stance>` when they have a stance and ` — still wondering: <open>`
when it is open. It then rests 6 accepted turns
(`careLineRest` in the capsule cadence ledger) unless someone or something
other than their moved it since. The pressing care gets no plain line of its
own; it appears only as their intention (below). With neither, there is no care
cue and Since, Settling, Reminded-of, Dream, Body, Sound and the felt words compete
as before. The capsule's private framing stays.

**When they brings it up.** Three moments: an opening (User's first turn after
the Since gap of 6 hours, the same `sinceGapOpened` read), winding down (the
message is 8 words or fewer and asks nothing), and a step from what is said
(the pressing care is also one the message touches). At one of them, when the
pressing care's pressure is 0.35 or more, its line becomes their intention:
`- You've been wanting to bring up <open, else about> — this is a natural
moment to, in your own way.` Once per care per 12 hours unless someone or
something other than their moved it since; the ledger is the capsule cadence
ledger (`careReleased`, ids only), and an intention that lost the budget stays
owed. `mind.why` lane `cue` marks it with kind `care`, `careId` and
`intention`. `mind.reject care:<id>` silences one care's cue.

**Reach** offers the most pressing open care held with the owner or theirs alone
(pressure 0.35 or more) as a candidate of kind `care`, subject `care:<id>`, why
its newest story note, dated by its newest movement; every Reach gate applies.

**Their hour** offers their own open cares (theirs alone, most pressing first, up to
three), and with any offered asks for them
`still wondering:` line. That line, after a real encounter, becomes the open
question of the offered care it is closest to (cosine 0.40 or more), or a new
care of theirs at depth now; either way with a story entry by them, felt
"curious", pointing at the journal entry or the hour.

**Reflection's stance.** Its `view:`, `because:` and `unless:` lines write
through `applyCares`, by them, to the closest live care at cosine 0.40 or more,
or to a new care of theirs. A reflection marked untrusted-fed writes no care stance.
Replacing a stance keeps what they used to think in the care's story. There
is no separate view lifecycle, approval action or experiment switch.
Growth-week view revision and retirement rows are gone; their story is read
from cares.

**What is still open.** Reflection's takeaway sets a care's `open` through
`applyReflectionCare`: the closest live care at cosine 0.40 or more, else a
new care of theirs, with no care write from an untrusted-fed reflection. The
live-turn-gated `mind.pin_concern` action sets `open` through `applyCares`,
by them, with the supplied concern, or the most pressing care's own words when
omitted. It uses the closest live care at the same floor, else a new care theirs
alone. Spontaneous
reflection reads the summed `carePressure` of live open cares as unresolved
load. After-turn `closes` and the night settle the gap. Desk pursuits are the
person's tasks and do not feed their mind.

Reflection's automatic Desk proposer may cite only a live, non-seed,
life-depth care with a stance. Life depth comes through the existing
`care.life` approval boundary, so a same-turn opinion cannot authorize a
pursuit. Desk deduplication, capacity and unattended-work gates still apply.

## What persists and what is derived

| Layer | Current mechanism and source |
|---|---|
| Working attention | `ContinuityField.swift` bounds nodes, decays activation and spreads associations. `CognitiveSubstrate+Workspace.swift` selects a bounded set, inhibits redundant candidates and records selection reasons. This internal cognitive workspace is a read model. |
| Affect | `CognitiveSubstrate+Affect.swift` updates and analytically decays arousal, uncertainty, task pressure and social warmth. |
| Mood and disposition | `CognitiveSubstrate+Mood.swift` derives mood from tagged nodes and current affect; a persisted disposition adds a slower undertone. |
| Personality dynamics | `PersonalityDynamicsConfiguration.swift` holds numeric rates, thresholds and cadence; warmth maps to `feltWarmthEarnedSpan` and humor to `playModeWeight`. Other trait prose remains separate from these numeric mappings. |
| Cares | `CognitiveSubstrate+Cares.swift`: one row per care, charge read from its story at read time, no count cap (see Cares). |
| Replay | `Cognition/NativeCognitionRuntime+Replay.swift` reads Dream diary and REM proposal records. `CognitiveSubstrate+Replay.swift` integrates bounded references and developmental lineage with deduplication and checked persistence. |
| Reflection | `CognitiveSubstrate+Reflection.swift` plans and records bounded reflection; `Cognition/NativeCognitionRuntime+Reflection.swift` owns provider execution and its result. |

The runtime's configured limits are 256 active nodes, 12 workspace items
and a 4,000-character capsule ceiling
(`NativeCognitionRuntime.loadConfiguration`). A caller can request a smaller
capsule.

Cognitive persistence is `<dataRoot>/cognition/cognition.sqlite`, owned by
`CognitiveSQLiteStore.swift`. `CognitiveSubstrate+Restore.swift` validates
the restore bundle before applying it and blocks state writes when restoration
fails. This is continuity state, not another canonical fact or persona store.

## What reaches the model

`CognitiveSubstrate+Capsule.swift` fits a selected expression of current
state into the requested budget. Its helpers own distinct projections:

- `+FeltFingerprint.swift` and `+CapsuleFeltSignals.swift`: feeling words
  and their aboutness; unavailable dimensions remain optional.
- `+CapsuleCadence.swift`: cue repetition limits and
  session continuity.
- `+CapsuleSoundEcho.swift`: bounded self-exemplar selection and verbal
  repetition cues.
- `+CaresMind.swift`: the care cue, first among the felt cues, and when it
  becomes their intention to bring a care up (see Cares).

These are projections of the same state, not additional persona owners.
`Cognition/CognitiveAttentionResidentProjection.swift` separately publishes
a lock-backed attention read for context selection, without fetching the
whole substrate during that read.

## Between turns

`NativeCognitionRuntime` coalesces dirty event bursts with a 0.25-second
delay. `NativeCognitionRuntime+Deadlines.swift` owns maintenance and residual
repair deadlines; continuous decay is projected at read time. App assembly
retains daily maintenance, replay and reflection registrations as recovery
sweeps (`EngineRuntime/EngineLaunch.swift`).

Canon, horizon and Reach source observations register before their first read
and stop with the runtime. Canon watches journal inputs and archive membership;
audit output is excluded, and directory events invalidate it only when input
stamps change. Their 30-, 15- and 10-minute I/O limits remain;
unchanged sources are reread only at real silence, eligibility, quiet-hour,
expiry or cooldown boundaries on the existing residual deadline. Reach retains
a blocked timing gate's eligibility boundary before candidates have been read;
opening the gate schedules the pending source scan. Committed dreams invalidate
Reach through the existing `dreamCompleted` signal, including after a clean scan.
Quiet-hour preferences follow file/clock invalidations. Clock invalidation
follows organism configuration so concurrent reads cannot erase it. Reach watches handoff
selection changes as well as selected content;
unrelated home-directory events with unchanged input stamps do not request scans.
The composite body evidence read retains its two-second sampled cache because
its host/transport gauges have no complete shared push owner. Daily integrity
sweeps remain.

Reflection has an enable switch, an in-flight reservation and a rolling
24-hour call ceiling. Spontaneous reflection also requires unresolved load;
requested reflection bypasses that load threshold, not the cost ceiling.
Its model/provider comes from checked `cognition_reflection` routing, not
a fixed model name.

They are always on while the Mac is on (User 10-24): their model calls run at the provider, so no power, heat or tiredness gate defers or throttles any background lane.

### Reach notification privacy

`Cognition/NativeCognitionRuntime+Reach.swift` owns the notification after
Agent posts an authored reply to the owner's conversation. Its neutral push body is
“Left you something in chat. No reply needed.” It points to chat without
including the reply or conversation-derived seed text. If the conversation
is the owner's Telegram DM, Reach instead sends the authored reply there, with no
additional push. Telegram delivery therefore carries their reply text; the
neutral lock-screen/APNS body does not.

### Their hour

Enable the hour switch in Setup (`Sources/NativeAgentApp/SetupView.swift`);
`studioWanderEnabled` defaults off and requires Subconscious. Configure its
provider/model under **Providers → Memory and mind**, which owns **Creative
exploration**. `Cognition/StudioWanderLane.swift`
enforces explicit enablement, the Subconscious master, and onboarding clearance
for public-safe builds in `resolveInstallation`.

## Reading and acting on their state

Agent reaches this through their one `app` tool:

```json
{"action":"mind.inner_state","args":{"detail":"compact"}}
```

`app {}` is home; `app {"page":"personality"}` reads that page, and
`find` discovers actions. `AppToolRuntime/AppActionRegistry.swift` declares
the inner-state action and `ToolRegistry/ToolNameAliases.swift` maps its
internal implementation name. `CognitiveSubstrate+InnerState.swift` bounds
the returned record; it is an inspection, not a fresh model interpretation.

The human-facing Observatory is
`Sources/NativeAgentApp/CognitionObservatoryView.swift`. It subscribes to
owner changes and exposes the runtime's last committed live capsule separately
from inspection reads. Its counters and research exports describe state;
they do not establish consciousness, behavioral benefit or provider agreement.

## Where to verify

These diagnostic and recovery paths are relative to `<dataRoot>`:

| Path | Contents |
|---|---|
| `cognition/organism_state.json` | Persisted body state and organism continuity |
| `cognition/caring_appraisals.jsonl` | Caring appraisal receipts and the body's dosing response |
| `studio/wander/wander.json` | Hour/wander refractory state and trace history |
