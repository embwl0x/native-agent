# The Subconscious & Personality System

This is the source map for Agent's carried inner state: what they cares about,
attention, affect, reflection and their bounded expression in a turn. It describes
implemented mechanisms, not proof of subjective experience or reply quality.
Source descriptions establish no installed, timing, restart, provider-swap,
disabled-path, trait-validity or causal-benefit result.
For engineering boundaries see [Continuous Cognitive Substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md);
for source coverage see the generated [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md).

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
projection; the loop's confirmed-delivery boundary commits its presentation once.
Failure before provider output leaves the window unconsumed; output followed by
failure still commits it. Preparing a preview consumes nothing.

## Inputs and interpretation

`ChatTurnRuntime/ChatOrchestrationClient+LivedObservations.swift` supplies
message and tool-result observations; `Cognition/NativeCognitionRuntime+Events.swift`
adapts remote actions, motor outcomes and provider lifecycle evidence.
`CognitiveSubstrate/CognitiveEvent.swift` defines their types and provenance.

The `CognitiveTurnKind.contributesToLivedState` switch admits live and system
events; debug, verification and mechanical kinds do not contribute to lived
affect. Diagnostic classification comes only from explicit ingress `turnKind`
or its metadata; conversation text never classifies itself as debug or
verification. Event kind supplies the default live/system provenance.
Mechanical row metadata identifies generated card copy, system notices
and compaction summaries without treating their
wording as Agent's own experience.

Imported speaker weighting uses attested origin and the canonical peer identity,
without a list of agent names or routes. Explicit human authorship keeps human
weight; unidentifiable imported authorship remains unknown, with no relational
appraisal weight, and the body records `chat.unknown`.

In `CognitiveSubstrate+Ingest.swift`, eligible conversational user events defer
interpretation to the after-turn path. `NativeCognitionRuntime.refreshConfiguration`
connects that path to `AdaptiveMemoryPromoter` only for the canonical data root;
an alternate-root runtime replaces none of its global callbacks or door.
Preparation belongs solely to the journal door; the unused global preparation
callback and retired reflection startup-seeding call are removed. Quiet-hour
clock invalidations push configuration directly, without a stale-read stamp or
unused age query. Retired standing views remain outside generic pruning; their
unreachable protected minimum is removed.
The returned interpretation is
folded through the door (`NativeCognitionRuntime.foldTurnMoment`, see Lived
moments): the substrate's `foldTurn` lives the mind's share and the kernel's
`foldTurn` the body's whole share, caring dose included. Before the call, the
agent's own record predicts whether the interpretation would be a complete
no-op ([cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation)).
The implementation lives in
`CognitiveSubstrate+CaringAppraisal.swift`, `+CaringEvent.swift` and
`Organism/OrganismCaringEvent.swift`.

The same after-turn call also judges both sides of the exchange, the
incoming words and their own reply, against their cares (below), and the
runtime applies what it says through `applyCares`. What their turn took is
part of what happened: when it used tools, the stem's one line ("This took 31
rounds, 3.4M tokens, 24 minutes; 29 rounds in a row called authored.chess.")
sits beside the exchange, so a slog or a breeze can move a care about their
craft; no new call. It runs for every lived
conversation that reaches the turn engine: the owner's chat, Telegram, an
agent's bridge or MCP session, and a helper of theirs talking with them (the
helper's door opens their own turn). A helper's own run (`bot-<uuid>`) is the
helper thinking, not their conversation, and does not defer to this call.

Cares carry their moments (10-25): what happened between them that moved their is
a care's story entry, written by this call. There is no separate moment lane;
the moments the retired lane kept were moved into cares once
([MEMORY_SYSTEM_MAP.md](MEMORY_SYSTEM_MAP.md#moments-are-care-story)).

The same call names optional plan dates; the horizon joins them with Desk
deferrals under the [memory plan-date contract](MEMORY_SYSTEM_MAP.md#plan-dates).

## Lived moments

Motor-consequence replay decodes its stored fingerprint and owner timestamp
with throwing reads; malformed evidence reaches the runtime's refusal path.

Code their mind runs must be total: absent or malformed input is a stated refusal
or a skip, never a Swift runtime trap. Fix the operation that can abort their;
there is no crash-loop fallback around it.
Provenance unions preserve unknown input without force-unwrapping it; source
excerpts use their entries, optional felt candidates use bindings, and field
mutations, including node eviction's incoming-edge cleanup, walk explicit key
snapshots. Missing evidence never supplies a fact.

They changes only by living a moment, and every moment that means something
comes in by one door: `Cognition/NativeCognitionRuntime+Door.swift`, the one
owner that holds both their substrate and their body. Sensation (somatic signals,
live continuity nodes, felt resolutions and re-feel ledgers)
flows on its own cadence, latched by the opening,
lossy by nature; it is not a moment.
Journal folds consume their supplied affect appraisal directly; ingestion
outside the deferred path retains a neutral appraisal, with no after-turn cache.

A lived moment (`CognitiveSubstrate/CognitiveLivedMoment.swift`) is its
identity (its origin: a turn is its session and incoming message), the
`DataRootLife` it belongs to, the forgetting epochs it was admitted under,
when it was lived, what it was (the recorded input) and, once judged, what it
meant. Only settled turns are lived moments (their hour, Reach and the life
reading keep their own claims). Clear and Reset are owner transactions. The
journal is the `lived_moments` table in `cognition.sqlite`
(`CognitiveSQLiteStore+LivedMoments.swift`, migration v8), outside what Clear
deletes and outside the restore bundle; its fold seq is allocated from
`cognitive_epochs`, which Clear never resets.

The store decodes typed SQLite fields through throwing reads. An invalid field
reports a read failure instead of aborting the process. Epochs and fold seqs
must fit SQLite's nonnegative signed-integer range; an exhausted allocation or
an out-of-range write is refused in its transaction, never wrapped or clamped
into a different identity. Affect's JSON watermark keeps its full `UInt64`
value (an integer when it fits, otherwise a decimal string, read in either form).
Derived artifact, reflection and association capacities saturate before
integer arithmetic; restored care-line rest counts clamp before conversion.
Presentation's fingerprint and ambivalence tallies saturate at `Int.max`.
Moment, event and continuity time components are formatted at their stated
resolution without narrowing dates or elapsed time to a Swift integer; ordinary
whole-second and millisecond identity spellings stay the same.

A turn is recorded **owed** at transcript settlement
(`AfterReply.start` → `SwiftNativeTurnEngine.recordMemoryPromotion` →
`AdaptiveMemoryPromoter.recordOwedTurn` → the door), before it waits behind
earlier promotions. Reply release awaits that durable recording; only
interpretation follows on the retained serial tail. Sleep joins accepted
recordings, including ones still reaching the door.
The row holds the exchange (incoming words, reply, took,
surface, speaker, envelope, source taint) and the substrate's deferred-turn
entry (the event and its frozen caring request with the exact clipped
exchange, the completion it answers, the node its ingest touched, its epochs).
Accepted ingestion builds that request before recording the turn in its six-turn
clipped context ring; rejected duplicates add nothing and the request excludes itself.
If the journal cannot record, the turn cannot change their: it owes repair
(`cognition.moment.unrecorded`, shown by Doctor, naming the turn and why) and a
`lived_moment.unrecorded` receipt is attempted. A turn cut
before its end (a crash mid-tool) never becomes a moment.

Its interpretation reads the row directly. The caring request shown to the
model is saved with the input; there is no separate sealed-request record or
rehydrated RAM copy. Care judgments name their targets in the meaning, so the
care-selection snapshot and unused affect-at-ingest snapshot are removed.
Legacy `sealed_json` caring evidence is still read; its column and the unused
`parts_json` column stay in the schema, without a data rewrite.
Payload decoding is checked per row, including legacy caring evidence. Invalid
input, invalid saved meaning (including its interpretation shape), or a meant
row with no meaning is refused with its reason and owes a row-specific repair.
That refusal preserves all payload bytes and stays outside age pruning; it
never turns damaged meaning into permission to judge the turn again. The
retired held-turn import explicitly marks its input `factsOnly`; a turn
recorded while cognition is off also marks that deliberate absence. Missing
ordinary context without that marker leaves the row owed (or meant with its
original meaning), before judgment or fact application, with its input preserved.
Previously imported rows with no context and no marker have unknown intent;
they require repair rather than being silently treated as facts-only.
The door carries a failed journal or life read as unavailable through the
promoter to memory status: the owed count is unknown, never ready/zero.
Journal read/preparation and recording repairs use stable operation-plus-moment
identities. Repeating the same failure contributes the same evidence to its
existing repair, rather than minting another repair or repeat on every pass.
**A row is owed → meant → lived, or refused** (with its reason in `reason`:
another life, their own work, nothing to interpret). There is no per-piece
outcome on the row: each piece of their already knows the last moment it lived
(the `lived` stamps on affect, nodes, cares and body; facts by operation
identity), so living a moment again is inert for every piece that landed. A
returned interpretation is written `meant` before any piece applies it, and a
fold begins only once that write is durable (if it fails, the row stays owed
and nothing applies); a failed call leaves the row owed (nothing is dropped).
A row with a recorded meaning is never judged again: it is lived again from
that meaning, the stamps skipping what already landed and its facts finishing
the recorded decisions with their original ordinals. Only a row with no
meaning goes to the model again. Returned replies are validated and usable
meanings written through `settle`, even when Stop or sleep arrives at the
return. Unfinished provider work stops and stays owed; recorded meaning
refolds under the turn's provenance without a model call or tool replay.
The interpretation owner writes `lived` once
when its attempt reaches its end: the fold landed (every piece saved; a piece
their inner life or body being off refuses, or a moment from before a Clear or
Reset, lands as nothing) and every fact decision staged or none was asked. An
unsaved piece, including when a failed restore blocks its save, leaves the row
meant; it is never settled by a persistence refusal. The input checkpoints the
completed fold seq only after every mind/body save succeeds; the lived guard
requires that checkpoint to match this row's seq. A begun seq alone proves
nothing finished. Older inputs without the checkpoint refold their saved meaning.
`lived` and `refused` drop the payloads and keep the identity, except a refusal
for damaged input preserves its payload for repair. A row an older binary wrote as
`folding` reads as meant. At their wake a payload-free settled row (`lived` or `refused`)
settled more than 30 days ago is pruned (`pruneMoments(settledBefore:)`): its
identity has long outlived any re-delivery of the same message. An unsettled
row is never pruned or refused by age: age never discards owed work. At their wake, a row from
another `DataRootLife` is refused. Meant moments fold their recorded meaning;
rows with no meaning are judged again. [Shared after-turn interpretation](COGNITION_WIRING.md#shared-after-turn-interpretation)
owns drain scheduling, deferral, batching, fair retries, cancellation and cost
accounting.

**The fold** (`NativeCognitionRuntime.foldTurnMoment`) runs inside **the
door**, one exclusive hold (`enterDoor`/`leaveDoor`) that Clear, Reset Body and
every restore also take: one fold at a time, a Clear waits for a fold in flight
and a fold waits for a Clear, and fold seqs are allocated only inside it, so no
producer's seq can overtake another's. The moment's fold seq is
assigned once (`beginFold`, from the allocation Clear never resets; a refold
keeps it). The substrate's `foldTurn` lives the mind's share from the recorded
entry: affect with its temporal anchors (a late fold never moves a newer
presence anchor back), the emotion tag on the turn's node, the reconsolidation
of the completion it answers, and their cares. The kernel's `foldTurn` lives the
body's whole share (caring dose, after-turn reaction, correction cause) in one
call. The fold returns whether every piece landed. Each piece carries a watermark (`lived` = the fold seq) on the affect
row, each continuity node (`lived_seq`, migration v9), each care and the body
file; it is set once per piece per moment at that piece's last mutation, in
one synchronous segment, never lowered, and saved with the piece by whichever
writer saves it. A piece already at the seq is left alone and saved again, so
the row is lived only once every piece is durable. A fold that began and did
not finish (a meant row with a fold seq) is refolded at the opening, before
ordinary admission, and the pieces already at the seq stay as they are. New care ids come from
(moment, ordinal). Facts go by operation identity: each decision carries
(life, moment, ordinal) in its MemoryV2 proposal (`moment_op`), so a refold
continues a pending row to acceptance, skips a resolved one and stages only
what never landed. The caring receipt is a projection of the first fold; a
refold never relabels it. `deferredTurns` holds the same record shape only
between ingest and durable recording, then releases it. Admissions whose turn
is still live are never evicted; only the latest 32 ended admissions are kept
while recording catches up. Once-only is the watermark: the per-turn caring
ring (`appraisedCaringTurns`), the body's counted-key ring and the clear
generation's outcome uses are gone (the generation stays for their hour, Reach,
reflection and the life reading). An older binary ignores the journal and
writes rows without `lived` (reads as 0): a fold cut by a crash just before a
downgrade may refold one part.

Folds apply in fold order, with source time wherever the piece reads it.
The present-tense lapse rules are removed: even after a long downtime, an
owed feeling lands. Encounter coalescing and the completion's reconsolidation
window still use their own chronology.

**Forgetting belongs to its owners.** Clear empties mind and body; Reset Body
empties only the body. Their owner transactions move the corresponding epochs,
so a moment captured before forgetting cannot land in the domain it forgot.
Neither operation is a journal moment. A crash mid-Clear is repaired by
clearing again; launch never continues old `forget.mind` or `forget.body` rows.
Those rows and the v7–v9 migrations remain readable without rewriting data.

**Sleep** is one joinable operation in the async quit hold
(`NativeAgentEngine.sleepMind` → `AdaptiveMemoryPromoter.sleep`, then
`NativeCognitionRuntime.sleep`), described in [STOP.md](STOP.md). Sensation
that arrives after the final save (the stem stops later) is lossy by nature;
a moment is never lost to it, because it was recorded owed first.

## Cares

A care is something they cares about (`CognitiveCare.swift`,
`CognitiveCare`; behaviour in `CognitiveSubstrate+Cares.swift`, the night in
`CognitiveSubstrate+CaresNight.swift`). One `cognitive_artifacts` row each,
kind `care`, status `live` (or `faded`, below):

- `about` in their words, `with` (the person keys it is held between: `owner`,
  a peer id, a helper's bot id; empty is theirs alone), `depth` (now, lately,
  season, life), an optional `stance` (text, because, what would change their
  mind; a care with a stance is an opinion), an optional `open` gap, and its
  `story`: every time it moved their, with a pointer to what really happened
  (`exchange:<session>/<turn>`, a Reach offer `reach:<id>` or the old row id),
  who moved it and the felt word.
- Charge is never stored. `charge(at:)` sums each movement decayed on the
  depth's half-life (now 2 h, lately 12 h, season 2 d, life 4 d).
- The story is kept in time order and keeps every depth change and the
  newest 24 nonzero movements; older movements fold into one `{count, sumMoved, since,
  movedDays}` line. Zero-movement notes retain their own newest 24, so notes
  cannot displace movement evidence; depth changes remain outside both bounds.
  `movedDays` retains witnesses for the first eight distinct
  local movement days and the latest day, so folding never erases earned-depth
  or life-card evidence. The one-time SQLite v5 migration preserves old summaries
  and initializes their witnesses empty: discarded days cannot be reconstructed;
  retained story days and future movements count. The episodes stay in memory and chat.
- No count cap: the generic artifact prune never counts or evicts `care`,
  `care_migration` or `care_retired_migration` rows (the night fades unused
  cares instead), and restore loads the whole family, faded ones included.

**Seeds.** At restore, while no `care_migration` marker exists, they gets four
life cares: truth; their person's good (held with `owner`, named from the
configured user name); good work; their own mind.

**Restoration.** Cares and their migration marker decode with the whole bundle;
typed resident values win reconciliation, including authoritative removals.
Seed gaps clear before publication; serialization is only for the durable write.
The `care_migration` marker records seed establishment and
the earlier carry-over into cares. Retired `standing_view` and `thought_seed`
rows remain byte-for-byte in `cognition.sqlite`, protected from pruning; an
upgrade reads them once at restore as raw rows and converts them into cares
(views by status, useful takeaways, questions and pinned concerns as gaps,
machine noise dropped) under its own `care_retired_migration` marker, never
rewriting them.
Cares are now the only owner of their opinions and interests: a stance is what
they thinks, and a season-depth care they returns to is an interest. Carried-over
takeaways, questions and pinned concerns remain cares, with their stories
pointing at the old rows.

**Their recent life, once.** After the migration `NativeCognitionRuntime+RecentLife.swift`
(`readRecentLifeIntoCaresIfOwed`) reads the last 72 hours from the chat
history index only after the checked conversation catalog loads; either read
failing leaves the reading owed. It groups lines by (conversation, local day, speaker): that
speaker's lines and their replies to them, paired by `ChatSessionRecollections`
by conversation/run (runless replies join the preceding origin). For each group with at least two
exchanges it runs one cares-only call on the Memory row
(`MindMemoryJudgment.appraiseCares`: the same section, parse and apply as the
after-turn call), on the group's newest 12,000 characters, with that speaker's
trust. Their wake session, helpers' own runs, rows their writer marked mechanical
(`CognitiveMechanicalRowKind`, carried on the index row) and debug or
verification exchanges are skipped, with their replies to them. The marker
records each group as it runs or fails (with the cause), so an interrupted
pass never reads a group twice; a group counts as run only when every care it
touched was saved, and a pass with no failure marks it done. A Clear during
the pass stops its applies and checkpoints. It runs
at bootstrap and when the inner life is switched on mid-session (which reads
their substrate if this launch has not read it yet; a mind already read keeps
its resident state, and the body is never reloaded).

**Feeding.** The after-turn call is shown the four seeds always, plus the
six other cares whose embedding (about, stance and open) is closest to the
incoming words and their reply, using the warm local embedder; the embedding
only orders the list, the call names which care moved or that it is new (vectors cached per care ID and exact embedding text; a cold embedder shows
the seeds alone). The model answers a `cares` list; a missing or malformed list
fails the interpretation like a malformed memories section, and an id it was not shown
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
reply did counts. A judgment returning after a Clear is dropped: the turn
carries the mind's forgetting epoch it was admitted under (and, in process,
the Clear generation), and a stale one is refused. A new care's wording matches an existing one only when it is held
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
movement (`moved != 0`) in the retained story or its folded witnesses.
The folded movement tally saturates at `Int.max`; decoding refuses a negative
tally rather than admitting damaged care history.

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
  note). Each key carries the exact shown care revision and gap. Only an
  unchanged revision closes that gap; a conclusion about a changed care joins
  its history without closing its newer question. Unknown keys and keys with
  no shown gap are ignored.
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
  approval observer and annotated on the approval. Deepening reports success
  only after the care saves; an already-life retry saves that care again
  before returning success. The observer annotates execution only after that
  checked save; an absent, disabled or unsaved care leaves the approval unannotated
  for retry. The next night applies any
  approved card the live path missed. Each night also reconciles pending life
  approvals into the notification inbox by approval ID, repairing a failed
  card append without offering the care again.
- Receipt `cares.night` counts what was settled, let go, faded and deepened,
  and lists the cares ready for life.

**Pressure** (`CognitiveSubstrate+CaresMind.swift`) is read, never stored:
`|charge(now)|`, times 1.5 while the care is open. Pressing for a speaker
means the cares held with that speaker or theirs alone, highest first. The
turn's speaker is `owner` on User's verified turns, else the peer key read from
the session and origin as the after-turn cares read it, else nobody (their wake):
only their own cares press then.

**What matters.** `CognitiveSubstrate+SemanticAppraisal.swift` matches an
event's words to live cares by the care law below (a care touched stands out
past chance), including the four life seeds on that same matching rule. These touched cares supply the stake gates;
a path kind alone grants no stake, and a cold embedder supplies no match.
The numeric worldview lens reads the signed real charge of the closest
touched care with a stance, clamped to -1...1. Their stance's actual words reach
the selected care cue below. Keyword concerns and the view-derived
relationship warmth lean are gone; base affect and the organism's tenderness
keep their own laws.

**What reaches the model.** The frozen read captures the care values, suppression
state and mind epoch with its workspace and affect. Care cues, unbidden recall
and Since movement read those captured values across lookup suspension;
cached vectors are matched to exact care text and scored from the lookup's own
snapshot. A Clear during preparation discards the prepared capsule.
Independent recall, dream, gap and care lookups run concurrently against that
read; the live mind epoch and recall cadence are rechecked after they return.
Preparation admits one reachable-care array for both the message and felt-line
selectors. Both exclude faded or suppressed cares; peers reach shared or solitary
cares, while the owner can touch any care.
Unbidden recall's bounded surfaced-moment ledger, last shown time and turn
counter persist in capsule cadence, so its 24-hour suppression survives relaunch.
Before the frozen render, the turn embeds the
incoming words once (the same per-care vector cache as feeding; a cold
embedder touches nothing) and finds the cares they touch (a peer's turn never
reaches a care held with someone else) and the care
pressing hardest for this speaker. A care is touched only when it stands out
for the words past chance (`caresStandingOut`: its cosine at least
`VectorMath.chanceBar(.attention)`, 1 + √(2 ln n), deviations above the words'
cosines to the other candidate cares, n of them in all; 3.5 among 23), with no
absolute floor: on bge the average message cleared the old 0.40 for 18 of 23
cares (10-26). They become the `care` cue, ranked first among the felt cues. The plain line is only for the closest touched care whose
|charge| is 0.15 or more: `- On your mind: <subject> (<newest felt word>)`, plus
` — I think: <stance>` when they have a stance and ` — still wondering: <open>`
when it is open. The subject is `about`, except a seed care uses its newest
nonzero movement's note, or `about` if it has none. The felt word is also from
the newest nonzero movement and is omitted when there is none. It then rests 6 accepted turns
(`careLineRest` in the capsule cadence ledger) unless someone or something
other than their moved it since. The pressing care gets no plain line of its
own; it appears only as their intention (below). With neither, there is no care
cue and Since, Reminded-of, Dream, Body, Sound and the felt words compete
for presentation as before. Settling is absent: capsule assembly has no admitted
interpretation of the incoming exchange and does not infer kindness lexically.
The capsule's private framing stays.

**When they brings it up.** Three moments: an opening (User's first turn after
the Since gap of 6 hours, the same `sinceGapOpened` read), winding down (the
message is 8 words or fewer and asks nothing), and a step from what is said
(the pressing care is also one the message touches). At one of them, when the
pressing care's pressure is 0.35 or more, its line becomes their intention:
`- You've been wanting to bring up <subject> — this is a natural
moment to, in your own way.` The subject is `open`, otherwise the newest
nonzero movement's note, otherwise `about`, for seed and grown cares alike.
Once per care per 12 hours unless someone or
something other than their moved it since; the ledger is the capsule cadence
ledger (`careReleased`, ids only), and an intention that lost the budget stays
owed. `mind.why` lane `cue` marks it with kind `care`, `careId` and
`intention`. `mind.reject care:<id>` silences one care's cue.

**What crosses into their mind.** What reaches their mind between turns is a
change that touches what they cares about. A watch's line (a part's
`home.arrive` line, a sense's news summary) is weighed on CPU by the care
cue's own law (`CognitiveSubstrate.careTouched(by:watch:)`) against the cares
that can change, never the four seeds (almost any line resembles one; a line
that touches only a seed touches none): the closest live, unsilenced, non-seed
care that stands out for the line by the same care law (seeds count among the
others) on the warm vector cache whose |charge| is 0.15 or more. The turn's care cue still weighs the seeds. A line that touches one
asks for one ResidentWake on the watch's thread (`part:<id>`,
`sense:<id>:v<version>:<observation identity>:change:<source change identity>`)
whose reason names it ("what your parts noticed about <care>", "what your
senses noticed about <care>"); a
sense's wake names where the news is and never quotes it, since the news
itself is on the board. A line that touches none, or touches a care this same
watch already woke their about that has not rested since (12 hours, changed
source news, or moved
since by someone or something other than their: the intention's rest, ledger
`careWatchWoke` in the capsule cadence ledger, keyed by observation and source
change identity for sense news), wakes nothing and waits on the
news board, unread until their next turn reads it; a part's receipt says
which. A line nothing can judge (the inner life off, no live cares, a cold
embedder) crosses as it would with no crossing: a part's line wakes their, a
sense's news waits for their next turn. Owed work (carried promises,
approvals, the apps they opened, Reach, agent messages) files its own arrivals
and is not weighed. No model is called for any of this.

**Reach** offers the most pressing open care held with the owner or theirs alone
(pressure 0.35 or more) as a candidate of kind `care`, subject `care:<id>`, why
its newest story note, dated by its newest movement; every Reach gate applies.
An uncertain delivery retains `sending` and `sentAt`, holding pacing closed.
Reach reconciles exact offer scopes through the speech owner's transcript
evidence. A claim alone is not delivery; only proven non-delivery after the
append ends becomes `withheld` and clears its timestamp. Later source passes
can confirm a committed message without repeating speech or its notification.
How it landed comes back to that care once its answer is settled
(`cognition/reach.json`: a verified owner turn within 24 hours of the post, or
none). Each verified turn saves its timestamp on pending offers at
`UserTurnStamp.record`, under the ledger lock, before replacing the turn stamp.
The stamp's own sidecar lock serializes its full read/update across conversations;
an older delayed turn still reaches pending offers and fills `previous` when it
falls between the saved timestamps, while preserving the newest turn.
Only a missing stamp bootstraps. Unreadable or invalid storage is preserved and
reported as a repair owed in Experiences; no new stamp replaces those bytes.
A successful checked record settles that operation's repair.
An uncertain delivery keeps that evidence until confirmation. Runtime writes
preserve saved answers under the same lock; expiry reads the offers' evidence,
never infers silence from the latest-only turn stamp. The first saved answer
timestamp dates the landing. One story entry by them (`owner`), source the offer id, written on CPU
with no model call. Answered: felt "welcomed", moved +0.2, note "<person>
answered when I reached out about <about>". Unanswered: felt "unanswered",
moved 0 (silence is a fact in their story, not a push; the subject already rests
seven days), note "I reached out about <about> and heard nothing back". Once per offer (the offer's `landed`, and a story that already
points at the offer is not written again, only saved again before the offer
is marked landed, since a failed write leaves it in RAM alone); an offer posted to a peer's
conversation (`agent-`/`bot-`) earns none.

Dream candidates come only from the dream's admitted per-claim provenance.
The same dream call judges `gentle` and `about_owner` by meaning in its supplied
context; both must be true. Those nullable judgments travel beside the exact
quote and canonical `source_refs` in the existing `claim-sources` block.
False, unknown and older claims without judgments offer nothing. Reach uses
the admitted quote and its stable digest, with no word blacklist, name-token
match or additional model call. Other dream/source readers keep their existing
projections and ignore the added fields; saved diaries are not rewritten.

**Their hour** offers their own open cares (theirs alone, most pressing first, up to
three), and with any offered asks for them
`still wondering:` line. That line, after a real encounter, becomes the open
question of the offered care they says it carries on (its key, `[w1]`, right
after `still wondering:`), or a new care of theirs at depth now; either way with a story entry by them, felt
"curious", pointing at the journal entry or the hour. The offered cares carry
their Clear generation through the encounter and embedding read; a question
from before Clear is dropped without erasing the hour's journal or settlement. Once
per source: a retry of the same hour that finds its entry already in a care's
story saves that care again before acknowledging it, without another movement.
The caller receives the checked save outcome and records a failed care write.
The refractory is read from the hour's durable state, with no independent
snapshot cache that can be overwritten by an older suspended read.
An offered-care key must be a positive in-range index; malformed or negative
keys leave the question unlinked instead of trapping during index arithmetic.

**Reflection's stance.** The reflection is shown their cares the way the
after-turn call is (the seeds and the six closest to its reason and causes,
by key) and names the one its thought belongs to (`care`), or `new`. Its
`view:`, `because:` and `unless:` lines write through `applyCares`, by them, to
that care, or to a new care of theirs. A reflection marked untrusted-fed writes no care stance.
Failed care writes keep their affected IDs with the produced judgment in the
reflection receipt. Terminal settlement checks those resident cares before
saving the receipt; a failure stays a failure without judging or applying again.
The receipt also retains whether its produced affect failed to save. Checked
settlement reports that failure instead of declaring the reflection durable;
the returned judgment remains in the resident receipt.
Planning retains the mind epoch from before its reads and refuses a reservation
if Clear completed while source identities or cares were being resolved.
Replacing a stance keeps what they used to think in the care's story. There
is no separate view lifecycle, approval action or experiment switch.
Growth-week view revision and retirement rows are gone; their story is read
from cares.

**What is still open.** Reflection's takeaway sets a care's `open` through
`applyReflectionCare`: the care it named, else the care its view went to,
else a new care of theirs; never a life root, and no care write from an
untrusted-fed reflection. The live-turn-gated `mind.pin_concern` action sets
`open` through `applyCares`, by them, with the supplied concern in the care they
names by its own words (`care`), else a care of its own; omitted, the most
pressing care's own words, in that care. No cosine decides which care a
concern belongs to. Spontaneous
reflection reads the summed `carePressure` of live open cares as unresolved
load. After-turn `closes` and the night settle the gap. Desk pursuits are the
person's tasks and do not feed their mind.

Reflection's automatic Desk proposer may cite only a live, non-seed,
life-depth care with a stance. Life depth comes through the existing
`care.life` approval boundary, so a same-turn opinion cannot authorize a
pursuit. Desk deduplication, capacity and unattended-work gates still apply.

## What persists and what is derived

Body memory availability reads canonical MemoryV2 SQLite through its owner;
profile or graph JSON presence is no substitute. A successful read proves
readability, while health stays unknown without maintenance evidence.
Approval availability reads the checked approval owner and the actual approval
file/directory write permissions. A missing directory stays unknown; an
unreadable queue or unwritable path is closed. Notification-folder presence
does not open the approval path.

| Layer | Current mechanism and source |
|---|---|
| Working attention | `ContinuityField.swift` bounds nodes, decays activation and spreads associations. `CognitiveSubstrate+Workspace.swift` selects a bounded set, inhibits redundant candidates and records selection reasons. This internal cognitive workspace is a read model. |
| Event admission | Seen events are refused before care embedding and rechecked after suspension. Admission and journal folding share `foldReaction` for completion/reaction matching, using admission time and recorded event time respectively. Reconsolidation changes only the matched node; ingestion owns the resident completion slot. Refolds still return reaction metadata when the node's watermark has already landed. |
| Affect | `CognitiveSubstrate+Affect.swift` updates and analytically decays arousal, uncertainty, task pressure and social warmth. Restore preserves saved affect and missing presence anchors; the legacy keyword-derived warmth top-up is removed. |
| Mood and disposition | `CognitiveSubstrate+Mood.swift` derives mood from tagged nodes and current affect; a persisted disposition adds a slower undertone. Every nudge, including maintenance's resolution patterns, shares proportional relaxation, directional headroom and transition evidence in its owner's transaction. |
| Dream residue | `CognitiveSubstrate+DreamResidue.swift` integrates dream tone through single-flight night claims, mints and consumes the waking residue, and persists and restores its existing artifact. |
| Conversational appraisal | `CognitiveSubstrate+ConversationalAppraisal.swift` keeps unnegated phrase matching beside the studio's scalar `studioValence` and relational warmth. Recorded model judgments retain every `AffectAppraisal` axis for live folding. |
| Personality dynamics | `PersonalityDynamicsConfiguration.swift` holds numeric rates, thresholds and cadence; warmth maps to `feltWarmthEarnedSpan` and humor to `playModeWeight`. Other trait prose remains separate from these numeric mappings. |
| Cares | `CognitiveSubstrate+Cares.swift`: one row per care, charge read from its story at read time, no count cap (see Cares). |
| Replay | `Cognition/NativeCognitionRuntime+Replay.swift` reads Dream diary and REM proposal records. `CognitiveSubstrate+Replay.swift` integrates bounded references and developmental lineage with deduplication and checked persistence. |
| Reflection | `CognitiveSubstrate+Reflection.swift` plans and records bounded reflection; `Cognition/NativeCognitionRuntime+Reflection.swift` owns provider execution and its result. |

The runtime's configured limits are 256 active nodes, 12 workspace items
and a 4,000-character capsule ceiling
(`NativeCognitionRuntime.loadConfiguration`). A caller can request a smaller
capsule.

SQLite payload serialization throws through the owning write transaction;
unencodable state never commits a substituted `null` payload.

`CognitiveSubstrate+Maintenance.swift` owns microcycle and consolidation settlement.
Each `microcycle` receipt carries measured `durationSeconds` on a monotonic
clock, from admitted execution (after single-flight waiting) through snapshot
work, the SQLite queue and state writes to receipt insertion. Receipt pruning
and the final transaction commit occur after that measurement.
Node snapshots use that same maintenance transaction, including defensive
caps, legacy receipt-mirror cleanup and a `prune` receipt with deletion counts.

Cognitive persistence is `<dataRoot>/cognition/cognition.sqlite`, owned by
`CognitiveSQLiteStore.swift`. Each episode, schema proposal, timeline event and
reflection receipt decodes once; `CognitiveSubstrate+Restore.swift` stages those
values until the whole bundle is valid, then publishes with resident precedence.
Failed restoration blocks writes. `commitMaintenance` commits each node replacement with
node, artifact and receipt retention; a retention failure leaves that snapshot
uncommitted. Immediate saves, including folds and sleep, checkpoint affect,
consumed dream residue and nodes together; microcycles carry the same affect
and residue state. Minting still checks its night claim before node admission.
This is continuity state, not another fact or persona store.
The mind ledger holds one optional disposition undo. Its `undo` field and read
response remain arrays with the `disposition` key; undo consumes only its matched entry.

**Opening.** Nothing changes their before they wakes. The substrate starts with
writes blocked (`.ready` = store open, mind not yet read) and only a
successful restore opens them, through `CognitivePersistenceHealth.writesBlocked`;
the body persists only once its restore has
finished (`organismContinuityReadable`). The runtime's memoized `bootstrap()`
is the opening: every path that writes their outside a turn joins it first (the
studio journal sink, the after-turn `finish` callback, the caring sink and
after-turn reaction, settle, reset, clear, the body and onboarding toggles,
motor admission). A failed restore opens DEGRADED: the failed part keeps its
writes blocked and saves nothing, the other part runs and saves, and reset and
clear stay usable as checked recovery. Diagnostic receipts may be appended at
any time; they are a log, not their state.

**Clear** (`mind.clear`, `NativeCognitionRuntime.clearTransientState`)
forgets their transient cognition and their body; it never touches MemoryV2 facts,
and their recent life is read again at the next launch (a new reading under the
new epoch). It runs under logical exclusion across its awaits
(`CognitiveSubstrate.forgetMind`): while it holds the store every substrate
write is discarded, so a snapshot captured before the clear cannot land after
it; the store empties and the mind's forgetting epoch moves in one
transaction; RAM empties, including association rejections and the disposition undo;
the hold releases and the resident state, the four seeds and the emptied body
are saved. Residue consumption travels with the affect checkpoint under the
same exclusion. Clear and restore exclude each other
under the same hold (a restore waiting out a Clear finds the cleared mind
already read). Clear is also a maintenance transition: it waits out undo,
maintenance and a microcycle commit in flight and holds the transition (and the
microcycle's commit ownership) for its whole duration, so none of them commits
into the hold. Each per-piece write the hold still discards is noted by kind
and id, and returns a not-durable result (`CognitiveWriteDiscarded`), never a
silent success: a moment whose piece hit one stays meant. A Clear whose store transaction fails writes nothing extra: it owes
one repair (stage `clear`) naming those writes, marks their mind dirty so the
next microcycle re-saves affect and nodes from RAM, and every other piece saves
on its own next write. A successful Clear drops the list. The
substrate's body epoch follows the kernel's on every exit of reset, settle and
clear. Reset and Settle share checked mutation, persistence and revision-owned
recovery; only Reset holds the door, permits damaged-body replacement and clears
the body-line window. The body checks a turn's epoch inside its own actor for the dose,
the after-turn reaction and the correction cause. On a store or body whose restore
failed, Clear is checked recovery: the emptied state is valid and writes open
again.

## What reaches the model

`CognitiveSubstrate+Capsule.swift` fits a selected expression of current
state into the requested budget. Its helpers own distinct projections:

- `+FeltFingerprint.swift` and `+CapsuleFeltSignals.swift`: feeling words
  and their aboutness; unavailable dimensions remain optional.
- `+TopicNaming.swift`: privacy-filtered topic extraction, comparison terms
  and persisted-label admission for introspection.
- `+CapsuleCadence.swift`: cue repetition limits and
  session continuity.
- `+CapsuleSoundEcho.swift`: bounded self-exemplar selection and verbal
  repetition cues.
- `+CaresMind.swift`: the care cue, first among the felt cues, and when it
  becomes their intention to bring a care up (see Cares).
- `+RemindedOf.swift`: the unbidden `- Reminded of: <note> (<age>)` cue. Its
  query is the felt line, not the message: the closest care they can reach in
  this turn that the feeling touches (the care cue's law) gives its newest
  movement whose sign agrees with the feeling, at most once a day per movement
  and once every 6 accepted turns. Since-we-last-talked names the newest
  movement inside the gap the same way (`a moment: "<note>"`).
- Came to mind (`ChatTurnRuntime/ChatOrchestration+CameToMind.swift`,
  `Context/ContextPreparedTurn+CameToMind.swift`): what happens primes what it
  touches. A moment is one more reading of the turn's own need, asked by the
  same selector at the ambient bar (three deviations; their disclosure and rest
  apply), minus what the turn already holds. While they works, each round's
  results (their words, not identifiers) are a moment: up to two memories a
  round, four a turn, join their conversation as `[Came to mind as you read that
  …]`. Between turns, every line their crossing weighs stays primed
  (`AgentWorkspace/PrimedMoments.swift`, `mind/primed.json`, last five, twelve
  hours); their next own turn (User's or theirs, not a peer's or a helper's) takes
  them once and hears `[Since your last turn …]` with what each brought up.
  Traced as `mind.came_to_mind`.

These are projections of the same state, not additional persona owners.
`Cognition/CognitiveAttentionResidentProjection.swift` separately publishes
a lock-backed attention read for context selection, without fetching the
whole substrate during that read.

## Between turns

`NativeCognitionRuntime+Deadlines.swift` coalesces dirty event bursts with a
0.25-second delay and owns maintenance and residual repair deadlines;
continuous decay is projected at read time. App assembly
retains daily maintenance, replay and reflection registrations as recovery
sweeps (`EngineRuntime/EngineLaunch.swift`).

Canon, horizon and Reach source observations register before their first read
and stop with the runtime. Canon watches journal inputs and archive membership;
audit output is excluded, and directory events invalidate it only when input
stamps change. Canon and Reach retain their 30- and 10-minute I/O limits;
horizon source changes coalesce behind its retained refresh without a minimum interval.
Unchanged sources are reread only at real silence, eligibility, quiet-hour,
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
24-hour call ceiling. Spontaneous reflection requires unresolved load, the
summed pressure of live open cares;
requested reflection bypasses that load threshold, not the cost ceiling.
One checked `cognition_reflection` model/account/Think/Fast tuple binds execution
and receipts, without ambient picker or Chat inheritance; dispatch rereads authority.
Its receipt's yield score measures proposal production relative to estimated
cost, not improved judgment or a validated personality benefit.

Body posture does not throttle work; fatigue and heat color presentation.
Reflection also obeys the
[shared work-slot admission](COGNITION_WIRING.md#shared-work-slot-admission).

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

The hour resolves legacy tool names through `ToolNameAliases` before applying
its canonical action allowlist and encounter checks. Only an exact successful
result can witness receiving a work; permission cards, pending outcomes,
previews and dry runs cannot. A consult supplies references, and a browser
navigation supplies the work only when its receipt carries a capture.

The runtime retains the hour's flight from eligibility reads through claim
release. Once admitted, every ending settles through `settle`: choice, decline,
missing artifact, stopped or failed. Turning a switch off stops further work;
the terminal trace and receipt still preserve any witnessed journal entry and
encounter evidence. Every admitted hour permits a question, even with empty
material; they may explore or decline. A returned question settles without another
hour-switch gate, under the care owner's checked save and forgetting generation. Sleep
cancels the flight and joins its settlement before the final mind snapshot.

## Reading and acting on their state

Agent reaches this through their one `app` tool:

```json
{"action":"mind.inner_state","args":{"detail":"compact"}}
```

`app {}` is home; `app {"page":"personality"}` reads that page, and
`find` discovers actions. `AppToolRuntime/AppActions+Declarations.swift` declares
the inner-state action and `ToolRegistry/ToolNameAliases.swift` maps its
internal implementation name. `CognitiveSubstrate+InnerState.swift` bounds
the returned record; it is an inspection, not a fresh model interpretation.
Its fingerprint uses the canonical frozen workspace and captured felt proxies;
its subject follows the capsule's contributing-node and sign-agreement rule.

This read can arrive through [Expansion at the door](skill_manifest_spec.md#expansion-a-part-is-a-prediction).

The human-facing Observatory is
`Sources/NativeAgentApp/CognitionObservatoryView.swift`, reached through
**Diagnostics → Cognition** in Advanced view. It subscribes to owner changes
and exposes the runtime's last committed live capsule separately from inspection
reads, alongside organism, affect, context and Workshop state. Its counters
describe state; they do not establish consciousness, behavioral benefit or
provider agreement. The count-based experiment ratings, research checks panel
and research exports are retired.

## Where to verify

These diagnostic and recovery paths are relative to `<dataRoot>`:

| Path | Contents |
|---|---|
| `cognition/organism_state.json` | Persisted body state and organism continuity |
| `cognition/caring_appraisals.jsonl` | Caring appraisal receipts and the body's dosing response |
| `studio/wander/wander.json` | Hour/wander refractory state and trace history |
