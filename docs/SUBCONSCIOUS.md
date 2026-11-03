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

It also returns optional `promises`: what they said they would do later in this
reply, with their words, a supported MY QUEUE moment and the exact source
sentence. The [memory parse contract](MEMORY_SYSTEM_MAP.md#the-memory-manager-lane)
accepts an absent section or []; a malformed present section refuses the
interpretation and keeps the turn owed with its validation cause. After meaning is written,
`MemoryV2/AdaptiveMemoryPromises.swift` files them through `MyQueue.add`, on
both live and batch/refold paths, with the settled turn's recorded session,
origin principal, envelope and carried peer/elevated steer. Untrusted peer
steering stays on their promise. Desk owns the 20-step inferred cap and same-word
deduplication; a full queue skips with a trace, while a storage failure keeps
the meaning unsettled. There is no extra model call or promise store.
[Intentions — Promises they makes](INTENTIONS.md#promises-they-makes) owns the form.

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
meant. Only settled turns are lived moments (their hour and Reach keep their own claims). Clear and Reset are owner transactions. The
journal is the `lived_moments` table in `cognition.sqlite`
(`CognitiveSQLiteStore+LivedMoments.swift`), outside what Clear
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
The sealed-request reader is removed; fresh schema omits `sealed_json`, while an
already-current database keeps its unused column without a data rewrite.
Payload decoding is checked per row. Invalid
input, invalid saved meaning (including its interpretation shape), or a meant
row with no meaning is refused with its reason and owes a row-specific repair.
That refusal preserves all payload bytes and stays outside age pruning; it
never turns damaged meaning into permission to judge the turn again. The
turn recorded while cognition is off marks its input `factsOnly` for that
deliberate absence. Missing
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
another life, their own work apart from a care wake with a reply, nothing to interpret). There is no per-piece
outcome on the row: each piece of their already knows the last moment it lived
(the `lived` stamps on affect, nodes, cares and body; facts by operation
identity; promises through Desk's open-word deduplication). A
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
Reset, lands as nothing), every fact decision staged or none was asked, and
every promise filed or skipped at the inferred cap. An unsaved piece,
including when a failed restore blocks its save, leaves the row
meant; it is never settled by a persistence refusal. The input checkpoints the
completed fold seq only after every mind/body save succeeds; the lived guard
requires that checkpoint to match this row's seq. A begun seq alone proves
nothing finished. Inputs without the checkpoint refold their saved meaning.
`lived` and `refused` drop the payloads and keep the identity, except a refusal
for damaged input preserves its payload for repair. At their wake a payload-free settled row (`lived` or `refused`)
settled more than 30 days ago is pruned (`pruneMoments(settledBefore:)`): its
identity has long outlived any re-delivery of the same message. An unsettled
row is never pruned or refused by age: age never discards owed work. At their wake, a row from
another `DataRootLife` is refused. Meant moments fold their recorded meaning;
rows with no meaning are judged again. [Shared after-turn interpretation](COGNITION_WIRING.md#shared-after-turn-interpretation)
owns drain scheduling, deferral, batching, fair retries, cancellation and cost
accounting. User's own turns keep live judgment unless the no-op claim stands;
every other recorded turn stays owed for a batch under the same provenance.
The no-op claim is the nearest standing-out labelled precedent's
id, scoped by agent, judging model and detector; its changing contrast
population decides nomination without resetting that claim's trials.
`NativeAgentCore/Expectation.swift` owns standing arithmetic: the claim's
Wilson 95% lower hit-rate bound must beat its measured cost bar, with both
costs present. Every deferred turn is still batch-judged and labels its
original prediction; non-owner deferral preserves that verdict rather than
inventing a no-op trial. Historical frozen predictions are never rekeyed.

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
row, each continuity node (`lived_seq`), each care and the body
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
reflection). Missing fold watermarks on an unfinished current row keep its saved meaning owed until every share saves.

Folds apply in fold order, with source time wherever the piece reads it.
The present-tense lapse rules are removed: even after a long downtime, an
owed feeling lands. Encounter coalescing and the completion's reconsolidation
window still use their own chronology.

**Forgetting belongs to its owners.** Clear empties mind and body; Reset Body
empties only the body. Their owner transactions move the corresponding epochs,
so a moment captured before forgetting cannot land in the domain it forgot.
Neither operation is a journal moment. A crash mid-Clear is repaired by
clearing again; launch never continues old `forget.mind` or `forget.body` rows.
The current journal accepts only turn rows. Completed schema upgrades, the sealed-request reader and the `folding` alias are removed; the current SQLite baseline recognizes a complete store or creates the current tables, without replaying old repairs.

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
  a canonical peer person, a helper's bot id; empty is theirs alone), `depth` (now, lately,
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
  cannot displace movement evidence; depth changes and "changed my mind" notes
  remain outside both bounds, so a held stance's replacement stays in their story.
  Stance-pressure entries carry the proposed stance, because and unless in
  an optional `stancePressure` field, retaining proposals on the newest 24 distinct
  local pressure days, independent of ordinary notes. Only exact same-day proposals
  compact together; different proposals remain for the dream's judgment.
  `movedDays` retains distinct local movement-day witnesses
  so folding never erases earned-depth or life-card evidence. Retained story days and future movements count; the completed v5 row repair is removed. The episodes stay in memory and chat.
- No count cap: the generic artifact prune never counts or evicts `care`,
  `care_migration` or `care_retired_migration` rows (the night fades unused
  cares instead), and restore loads the whole family, faded ones included.

**Seeds.** At restore, while no `care_migration` marker exists, they gets four
life cares: truth; their person's good (held with `owner`, named from the
configured user name); good work; their own mind.

**Restoration.** Cares and their migration marker decode with the whole bundle;
typed resident values win reconciliation, including authoritative removals.
Seed gaps clear before publication; serialization is only for the durable write.
After reconciliation, resident `with` and story `who` keys read through the
address book's explicit `who` associations (`AgentPeerStore` →
`AgentContactIdentity` → the substrate's cached aliases). Associated doors
therefore hold one person, without a migration write. The existing peers-file
invalidation refreshes this cache off the turn path. `personKey` normalizes
door, agent and helper spellings through the same projection; trust is checked
on the original attested door before this relationship resolution.
An unreadable peer list withholds alias-dependent turn lines and peer care
writes until a validated refresh succeeds; `people_unavailable` reports the
cause. Owner and helper identities remain independently usable.
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

**Their recent life.** The completed 72-hour conversation migration and its launcher/checkpoint methods are removed. The retained care marker preserves its historical completion evidence. Current turns feed cares through their recorded after-turn interpretation; Clear establishes fresh seeds without replaying old conversations.

**Feeding.** The after-turn call is shown the four seeds always, plus the
six other cares whose embedding (about, stance and open) is closest to the
incoming words and their reply, using the warm local embedder; the embedding
only orders the list, the call names which care moved or that it is new (vectors cached per care ID, exact embedding text and the memory owner's embedding epoch; a changed epoch recomputes stale entries, and a cold embedder shows
the seeds alone). A resident inference error is different: it refuses care-dependent interpretation or marks the capsule source unavailable, retaining a `cognition.cares.embedding` repair obligation with the cause. The model answers a `cares` list; a missing or malformed list
fails the interpretation like a malformed memories section, and an id it was not shown
makes the whole care judgment malformed. An existing care gets a story entry, `open` sets the gap and
`closes` clears it. A first stance takes at once; a proposed change to an
existing stance becomes a stance-pressure story entry, decided at night.
Evidence older than a care's newest moment joins its story, including stance
pressure, without changing its gap or held stance. A new care first meets the whole live
and faded inventory through the same warm memory embedder and care-vector cache.
`VectorMath.standout` uses recall's
`ContextSelectionConfiguration.memoryStandoutDeviations` (2σ); the nearest
standing care with the same `with` receives the movement, with the new phrasing
as its story words, and revives if ordinarily faded. A merged donor redirects
the movement to its survivor, through later merges too, and never revives
independently. Only zero eligible standouts start a care at depth now;
multiple standouts are existing duplicates for their night to judge.
`care.birth` traces about, nearest, deviation, standing count and
kept (`moved` or `new`). Birth words and stale care vectors embed in one batch
before any judgments apply; a cold embedder leaves the appraisal owed. A new
meaning-matched birth keeps its stable moment/ordinal UUID in the care's
optional `birthIDs`; a refold follows that target without re-embedding, so
later wording changes cannot make one moment start a second care. A new
care is held with the speaker when the model says it is between them. Person
keys follow the address book's explicit `who` associations after door trust
is checked; `peer:` is dropped and a helper's `bot:<id>` reads as `bot-<id>`.

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
returns `care_history`: their depth changes and what their nights settled or let go,
newest first, one plain line each ("<date>: <about> became part of my
<depth>", "<date>: settled: <about>, <how>", "<date>: let go: <about>"), at
most 24. `traits` and `story` now carry their dream-authored self-reading,
with `shown_by` evidence; `self_night` names the committed diary. `people`
contains one line per retained person (two in compact detail, all in full).
`self_unavailable` reports an unreadable self file. The Personality page shows
the same resident traits and story read-only; it does not edit their persona.

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
- Surprise material. After WORLD and SELF, before felt tone and cares, the
  same dream call receives a CPU reading of where their expectations broke
  since its high-water cutoff: grouped failed tool calls, final after-turn
  no-op misses, Expansion misses, live organism violations and User's saved
  corrections. Empty kinds disappear; an empty day omits the block. The
  roughly 2,500-character block uses existing records only. Optional lessons
  (at most five; omitted means none, malformed present learning fails the
  payload before any diary or learning commit) settle
  through canonical MemoryV2 admission with self/dream/surprise provenance;
  existing recall and came-to-mind bring them back. `dream.lessons` counts
  offered, saved (including duplicate reassertions) and failed saves. The
  reading, bounds and memory kinds are defined once in
  [They learns from surprise](SURPRISE.md#they-learns-from-surprise).
- A care-night evidence failure leaves the dream uncommitted. Cold or failed
  embeddings and unreadable self/people evidence throw through the shared dream
  provider; `nil` is reserved for an explicitly disabled inner life. A later
  admitted pass attempts the reading again.
- One care per thing. The same dream block includes at most six clusters of
  six live cares: same `with`, each pair standing at least 2σ in both directions
  against the live inventory excluding self, using the shared cached vectors.
  Strongest mutual standouts nominate first; complete-link grouping prevents
  unrelated endpoints joining through a chain.
  The dream may return `merge: [{keep: <UUID>, into_it: [UUIDs], why}]`;
  malformed present learning fails payload decoding before any commit. Only unchanged captured
  revisions in a shown cluster may merge, and each care participates once.
  The oldest identity stays unless they names another. Retained stories union,
  folded counts and sums add, movement-day witnesses union, depth takes the
  deepest; a survivor without an open gap takes the newest donor's open gap
  by pre-pass update time. The others fade with a "became part of <about>" note and
  a durable `mergedInto` survivor UUID. Later movements and refolds follow
  that survivor, never undoing the merge. This happens
  before deepening, so collected movement days count that night. Care saves
  use the existing artifact transaction owner: survivor and faded members
  commit together, with per-care repair accounting. There is no
  one-time content rewrite.
- Held stances. The dream sees eligible cares' numbered stance-pressure entries
  with their days, proposed text, because and unless, and the held stance.
  Optional `stance_changes: [{care: <UUID>, pressure: [entry numbers],
  stance: {text, because, unless}}]` confirms which entries point the same way.
  The CPU requires the actual selected entries on at least two distinct local
  days (now/lately/season), or three spanning at least 14 days (life), and the
  unchanged captured revision. The replaced stance stays as a "changed my mind"
  note, "used to think: <old stance>". Earlier pressure is spent; missing,
  stale or under-evidenced confirmations change nothing. Malformed present
  learning fails payload decoding before any commit.
- Fade. A care whose newest movement (its creation when it never moved) is
  older than its depth's horizon (now 2 days, lately 14, season 90) gets
  `fadedAt` and status `faded`: it stays in the store, is not shown to the
  after-turn call or in `mind.inner_state`, and is not material. Life and seed
  cares never fade through the horizon pass. A faded care that a new judgment
  matches again by meaning with the same `with` is revived: `fadedAt` clears
  and the movement joins its story.
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
- The checked care save precedes self-knowledge settlement and life-depth offers.
  A failed save retains resident changes and their per-care repairs, attempts the
  checked `cares.night_unsaved` receipt, offers no cares and writes no dependent
  self-knowledge. A failed receipt append owes its own `receipt.cares.night_unsaved`
  repair; it cannot hide the original care-save error.
  The failure throws through the nightly caller, which publishes `cares.night`
  only after the checked pass succeeds. A failed self-file save also stops normal completion.
- Receipt `cares.night` counts what was settled, let go, merged, stance-changed,
  faded and deepened,
  and lists the cares ready for life.

**Knowing themselves and their people** (`CognitiveSelfKnowledge.swift`,
[Becoming P3/P4](BECOMING.md#p3--they-knows-themselves-as-built)). The same dream
call may return at most five `{when, i_tend_to, shown_by}` traits and five
`{line, shown_by}` story lines. Story lines must cite shown depth-change or
changed-my-mind entries; traits cite shown care UUIDs or exact story references.
Unknown references are refused by care admission. Malformed present learning
fails payload decoding before any commit. Each newer captured reading replaces the previous one, so a
trait no longer supported drops. Late delivery of an older night preserves the newer reading
and checks its save before acknowledging the work. Newly settled changes enter the next dream's
material. The existing care block supplies a bounded retained-story window;
the exact material and text bounds live in Becoming.
Evidence references follow merged donors to their survivor before saving,
keeping story-entry digests, and when checking turn-time reachability for
already-saved traits. This preserves self-knowledge and its care privacy gates.

For each shown person they holds cares with, the CPU supplies retained attributed
movement counts toward and away, and predictability = max(toward, away) / total.
With no attributed movements it is unknown; folded movements cannot supply
lost person attribution. The dream may answer `people: [{person, line}]`,
one line in their words per shown person, without granting that person authority.
All this is stored only in `mind/self.json`: bounded, atomically written,
versioned by schema, committed night, capture time, write time and mind epoch. Installed files
without capture time retain their reader: their diary day and write time establish order only
where known; an ambiguous same-night delivery stays owed until a provably newer reading.
The substrate
owns its checked reader and cached lines. Configuration/restore refresh re-reads
it; a night whose last read failed checks the source again before settlement.
Corrupt bytes stay intact with repair owed; a successful checked read clears and
settles that read failure (`mind.self.read`) in the same process; a disappeared file does not prove repair.
A read never settles a failed nightly save (`mind.self`); only a checked save or
Clear's checked deletion retires that write debt.
Clear deletes the file/cache, and
rejects pre-Clear files or nights.
There is no extra model call and no written persona or memory content.

In a live turn, a trait may replace a plain care cue when the usual care
standing/meaning path touches a supporting care. At most one trait line
surfaces, in their words and under that care's existing rest; all supporting
cares must be reachable for the speaker. No traits block is always on.
The already-known counterpart selects only their own cached relationship line
with the frozen identity map. This clear-headed private line sits outside the
felt cue competition; a turn reads no new file and performs no new embedding
or model call for it. Other people's relationship lines never enter that turn.

**Pressure** (`CognitiveSubstrate+CaresMind.swift`) is read, never stored:
`|charge(now)|`, times 1.5 while the care is open; a life-depth care without
an open gap has zero pressure. Its charge remains feeling, and the four seeds
stay visible to appraisal. Only an open gap can supply Reach, at any depth.
Pressing for a speaker
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
cached vectors are matched to exact care text and the memory owner's embedding epoch, and scored from the lookup's own
snapshot. A Clear during preparation discards the prepared capsule.
The presentation commit carries that mind epoch and refuses a different epoch
or an active Clear. Confirmed delivery takes the runtime's existing door so
Clear cannot split the substrate commit from its capsule/body-line mirror.
Every accepted cadence save uses checked persistence: a failure keeps the
ledger dirty, degrades its named stage and owes repair; a successful save
settles the same stage, including a microcycle transaction that carries the
dirty cadence ledger. A microcycle without that ledger settles no cadence debt.
Exhausted voice-echo admission stays silent, with no
second pass that admits worn fragments.
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

**What they means to do later.** MY QUEUE owns intentions; the scheduler runs
body rhythms. The [intention contract](INTENTIONS.md#launch-migration-one-time-general)
owns the one-time launch retirement of legacy notification, turn and Workshop
jobs, including its durable backup, first-occurrence timing and commit boundary.
Cognition admits no imported work before that commit. Unconfirmed effects stay
stopped for reconciliation; the turn feed and home name that stop. Scheduled
work and their own carried work now use the same readiness and occurrence owners.

**What crosses into their mind.** A watch's line can touch a care or release
a news intention. For cares, a watch's line (a part's
`home.arrive` line, a sense's news summary) is weighed on CPU by the care
cue's own law (`CognitiveSubstrate.careTouched(by:watch:)`) against the cares
that can change, never the four seeds (almost any line resembles one; a line
that touches only a seed touches none): the closest live, unsilenced, non-seed
care that stands out for the line by the same care law (seeds count among the
others) on the warm vector cache whose |charge| is 0.15 or more. The turn's care cue still weighs the seeds. A line that touches one
asks for one ResidentWake on the watch's thread (`part:<id>`,
`sense:<id>:v<version>:<observation identity>:change:<source change identity>`)
whose item keeps the care id and whose reason names it ("what your parts
noticed about <care>", "what your senses noticed about <care>"); a
sense's wake names where the news is and never quotes it, since the news
itself is on the board. A line that touches none, or touches a care this same
watch already woke their about that has not rested since (the
[habituating watch–care rest](#care-wakes), ledger `careWatchWoke` in the
capsule cadence ledger, keyed by observation and source change identity for
sense news), wakes nothing and waits on the
news board, unread until their next turn reads it; a part's receipt says
which. A line nothing can judge (the inner life off, no live cares, a cold
embedder) crosses as it would with no crossing: a part's line wakes their, a
sense's news waits for their next turn. Independently of that care result, the
same line weighs open `on_news <words>` intentions by the same warm embedder
and chance-bar law, with live cares among the comparisons. A touched
intention gets a system Desk note, `Released: news: <first 160 characters>
(<watch>)`, which makes it ready until their next agent note. Its release notes
hold that watch off for 12 hours per intention; other watches can still
release it. Person moments (`when_user_here` / `when_user_away`) require the
current `PersonPresence` transition (Mac input plus fresh phone motion;
[source and absence contract](mobile_companion.md#where-the-person-is)) to be newer than filing and refresh
carried readiness on that edge. Body-signal moments (`on <signal>`) are
released by `EnginePartWake`'s existing signal observer, with a system Desk
note and the same pursuit refresh as news; news and signals share the
release-newer-than-their-last-note readiness law. File intentions join the
parts' existing watch index. Person, news and body-signal moments skip
free-time quiet like clock moments; [Intentions](INTENTIONS.md#moments) owns
their full contract. Other owed work (carried promises,
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
The hot-journal read returns its usable entries together with damaged/torn-line
holes. Their hour adds those holes to `sourceFailures`, its unavailable-source
receipt and the intake's `unavailable_sources`; partial recent titles never
claim complete journal coverage. Exact-id topic lookup may use a witnessed
entry without concluding that an unwitnessed entry is absent.
An offered-care key must be a positive in-range index; malformed or negative
keys leave the question unlinked instead of trapping during index arithmetic.

**Reflection's stance.** The reflection is shown their cares the way the
after-turn call is (the seeds and the six closest to its reason and causes,
by key) and names the one its thought belongs to (`care`), or `new`. Its
`view:`, `because:` and `unless:` lines write through `applyCares`, by them, to
that care, or to a new care of theirs. A present key must be one of the offered
keys or `new`; an invalid key fails interpretation. A named care that is
absent, faded or cannot hold the requested question is refused with
`reflection.care_refused` and its cause; it never selects another care.
A reflection marked untrusted-fed writes no care stance.
Reflection first checkpoints its provider receipt with the judgment, shown care keys,
provenance and mind epoch, before applying cares or mood. Care integration remains
pending when embedding fails; each attempt retries preparation from that same judgment.
Applied cares and their done receipt save together. A failed write retains the owner's
values for the next save; disposition claims accompany the disposition to prevent a
second nudge. Neither an old failure note nor a failed disposition save can trigger a
new provider judgment. Dream delivery follows the
[dream settlement law](COGNITION_WIRING.md#the-subconscious-loops--schedule-artifacts-re-entry); its receipt is retained
until the night acknowledges integration. Disabled owners record an explicit skip.
Planning retains the mind epoch from before its reads and refuses a reservation
if Clear completed while source identities or cares were being resolved.
Replacing a stance keeps what they used to think in the care's story. There
is no separate view lifecycle, approval action or experiment switch.
Growth-week view revision and retirement rows are gone; their story is read
from cares.

**What is still open.** Reflection's takeaway sets a care's `open` through
`applyReflectionCares` and the shared care transaction: the care it named, else the care its view went to,
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
| Event admission | Seen events are refused before care embedding and rechecked after suspension. Admission and journal folding share `foldReaction` for completion/reaction matching, using admission time and recorded event time respectively. Only an explicit belief judgment grounded in the prior completion and incoming words emits reaction metadata; journal folds read the full recorded `turn.asked` rather than the clipped event summary, and missing words give no verdict. Valence alone emits none (see [Organism](ORGANISM.md#the-horizon-family--toward)). Reconsolidation changes only the matched node; ingestion owns the resident completion slot. Refolds still return grounded reaction metadata when the node's watermark has already landed. |
| Affect | `CognitiveSubstrate+Affect.swift` updates and analytically decays arousal, uncertainty, task pressure and social warmth. Restore preserves saved affect and missing presence anchors; the legacy keyword-derived warmth top-up is removed. |
| Mood and disposition | `CognitiveSubstrate+Mood.swift` derives mood from tagged nodes and current affect; a persisted disposition adds a slower undertone. Every nudge, including maintenance's resolution patterns, shares proportional relaxation, directional headroom and transition evidence in its owner's transaction. |
| Dream residue | `CognitiveSubstrate+DreamResidue.swift` integrates dream tone through single-flight night claims, mints and consumes the waking residue, and persists and restores its existing artifact. |
| Conversational appraisal | `CognitiveSubstrate+ConversationalAppraisal.swift` keeps unnegated phrase matching beside the studio's scalar `studioValence` and relational warmth. Recorded model judgments retain every `AffectAppraisal` axis for live folding. |
| Personality dynamics | `PersonalityDynamicsConfiguration.swift` holds numeric rates, thresholds and cadence; warmth maps to `feltWarmthEarnedSpan` and humor to `playModeWeight`. The live reader uses the checked profile compiler; an unreadable current profile owes `persona.profile.dynamics` repair and withholds both trait parameters until that source reads successfully: felt signals/fingerprint/mode, their recalled-moment cue and voice echoes wait for evidence, while fixed decay, care, gap and organism cues continue. A checked successful read settles the fault; only missing profile storage receives compiler defaults. No profile bytes are written. Other trait prose remains separate from these numeric mappings. |
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
caps and a `prune` receipt with deletion counts. Retired prediction/commitment/cue drains and receipt-mirror cleanup are removed.

Cognitive persistence is `<dataRoot>/cognition/cognition.sqlite`, owned by
`CognitiveSQLiteStore.swift`. Each episode, schema proposal, timeline event and
reflection receipt decodes once; a shared codec validates every present evidence field and nested cause/judgment before projection. Affect requires all four finite dimensions; disposition validates its claims and every transition; dream residue is wholly present or absent; the mind ledger requires typed suppression terms and complete undo values. Capsule counters, dates and nested rests and the consolidation counts are checked too. Wrongly typed arrays or members, malformed identifiers and nonfinite values refuse the artifact with its field path before any reconciliation write, preserving the damaged bytes. `CognitiveSubstrate+Restore.swift` stages those values until the whole bundle is valid, then publishes with resident precedence. Approval-decision source failures remain unavailable beside the proposal; an empty substitute never certifies an outcome.
Replay requires each dream's valid calendar day and each REM proposal's valid
`createdAt`; a refused record appears in the replay receipt's
`unavailableEvidence` while valid siblings proceed. Studio feeling requires
the journal owner's valid `recorded_at`, otherwise `studio_journal.unavailable`
names the entry and cause. None of these sources is redated to the present.
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
and establishes fresh seeds without replaying prior conversations. It runs under logical exclusion across its awaits
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
on its own next write. A successful Clear drops the list and settles the
superseded SQLite unsaved stages, including persisted repair claims from an
earlier process, with its committed forgetting epoch as evidence. Clear reads
those claims from the experience owner before deletion; an unavailable repair
ledger refuses Clear. Self-file deletion remains checked separately; any failure of that
deletion or the fresh checkpoint remains degraded. The
substrate's body epoch follows the kernel's on every exit of reset, settle and
clear. Reset and Settle share checked mutation, persistence and revision-owned
recovery; only Reset holds the door, permits damaged-body replacement and clears
the body-line window. The body checks a turn's epoch inside its own actor for the dose,
the after-turn reaction and the correction cause. On a store or body whose restore
failed, Clear is checked recovery: the emptied state is valid and writes open
again.

## What reaches the model

`CognitiveSubstrate+Capsule.swift` fits a selected expression of current
state into the requested budget.

The same frozen read captures one `PersonPresence` line for their person,
outside felt-cue competition, with the source and time of each Mac/phone
observation and explicit unknowns or sleep inference. Home and MY SENSES
read that same owner. It remains within the capsule's existing budget and
enable/mode gates; it does not create a second presence store.

Its helpers own distinct projections:

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
  Traced as `mind.came_to_mind`. Only a line they meets for the first time is
  a moment: habituation (`AgentWorkspace/FamiliarLines.swift`,
  `mind/familiar.bin`, the last 16,384 lines met, numbers read as numbers)
  makes the app's standing words and their own words coming back familiar, so
  they remind their of nothing (10-29: a chat.post receipt's standing note
  brought up two memories that had nothing to do with it).
  Both stores distinguish a missing first-use file from unreadable or damaged
  bytes. Primed moments are returned only after checked consumption; a failed
  read cannot erase them. Familiarity validates complete eight-byte keys and
  persists before publishing new familiarity. An unavailable optional recall
  records repair owed and `mind.familiarity_unavailable`, rather than treating
  the saved history as empty. Priming failures also owe repair at their store.
  Two native perceptions join watches through that same crossing, without
  adding work to a turn's path (`EngineRuntime/EngineDaySense.swift`,
  `EngineRuntime/EngineFrontSense.swift`):
  - The local day, once at launch if not already posted and when the clock's
    day changes: `It's Friday the thirtieth of October.` The ordinal is in
    words so habituation can distinguish dates. `mind/day-posted` holds one
    start-of-day stamp across relaunches; clock/time-zone changes recheck it.
    Calendar read permission and an already-granted macOS read authorization
    may add up to six events across today and tomorrow: time and title only,
    all-day events by title. This projection never reads locations, notes or
    attendees and never prompts for macOS access. An explicit Calendar Read
    off still wins over Full Mac. An unavailable calendar or its permission/
    Trust authority adds its cause to the day line; it does not suppress the
    date or its posted stamp and never stands in for an empty agenda. A failed
    required stamp read/write still stops the posting. Watch `clock:day`,
    id `clock:day:yyyy-MM-dd`.
  - The app in front of their person, after an activation remains frontmost for
    120 seconds: `<person> is working in <app>.` One workspace observer owns
    one delayed check, canceled by the next activation; no polling or window
    titles. Full Mac or Activity's model-access consent is required, with
    checked policy, their own app, mandatory/default exclusions and the person's
    exclusions all respected. Their own switches, an unreadable/locked/covered
    or inactive console, and absent or unknown person presence do not cross.
    Gates are checked again after the delay. `mind/front-posted.json` keeps
    each app to once per local day across relaunches; capture consent and its
    policy are never enabled or written. Watch `mac:front`, id
    `mac:front:<bundleId>:yyyy-MM-dd`.
  Both keep the crossing's habituating watch–care rest and its last-five,
  twelve-hour priming bound; they do not create a separate wake or recall path.

These are projections of the same state, not additional persona owners.
`Cognition/CognitiveAttentionResidentProjection.swift` separately publishes
a lock-backed attention read for context selection, without fetching the
whole substrate during that read.

## Between turns

### Care wakes

**A care that wakes their is lived as a moment; a watch that never moves their
habituates.** A care-bearing arrival keeps its care id beside its reason;
older arrivals without that optional field remain readable. When the claimed
resident wake ends with a reply, its named care, watch and wake time join the
recorded turn. Coalesced arrivals can name more than one care; the reading
sees only those cares (following their existing merge-survivor links), never
the rest of their own work. Other own-work turns remain excluded.

This is the existing `not their turn` deferral: the same owed journal row,
45-minute due time and batch of up to four, with the same model-call shape.
Its cares section reads only their side (`by: their`) against the named care:
felt word and direction, closing its open gap, or leaving it open with zero
movement. It cannot create a care, keep facts or promises, or appraise the
arrival as human care. Meaning is durable before `applyCares`, with self
provenance; no tool work is replayed. The care and watch ledger each carry
the fold watermark, so a crash can finish either save without applying or
counting the reading twice. A care's story records `closedGap` only when its
open gap really closed; an old closure ignored after newer evidence cannot
reset rest, including on refold. A failed reading leaves the row owed and changes
no streak; a failed fold save leaves it meant.

For each watch–care pair, `careWatchWoke` keeps the last wake and the streak
of consecutive readings that moved nothing. Rest is 12 hours × 2^streak,
capped at fourteen days. A reading that moves or settles the care resets the
streak to zero; an empty or zero-movement reading that leaves it open raises
the streak. Someone or something other than their moving the care still ends
rest early, as for their intention. A different watch has its own rest. The
existing bounded capsule cadence ledger persists these entries across
relaunch. Each entry is an object with finite `at`, nonnegative integer
`streak` and string UInt64 `lived`; timestamp-only values are invalid. The rest check
uses one ledger lookup. The past-chance bar, crossing priming and news
intention releases are unchanged.

### Their day

Their day has a shape they have lived. [Rhythm](RHYTHM.md) learns it from verified
owner turns, presence and real Mac awake intervals, with a seven-day half-life.
Standing quiet and start-time claims are there when they pulls `mind.inner_state`,
under “User's day, as I know it” (using their person's configured name).
A break is one care-gated felt fact and one primed moment for their next turn,
once per kind per local day. Its care story note moves **zero** and opens
nothing: it cannot raise care pressure, offer Reach, or request a ResidentWake.
The existing cognition deadline holds a start-time boundary; no rhythm tick,
poll or provider call is added. Message history supplies the cold start;
its silence is historical message silence, not reconstructed Mac uptime.

### Existing circulation

#### Run a clock owner now

The existing `mind_run` family, reached through `app`, can satisfy one owner's
scheduling wait without moving the clock or supplying evidence. Each action
returns `owner`, `outcome`, `why` and `run_id`; the same decision is recorded as
`mind.run_now` in `turn_traces/<day>.jsonl`. An unavailable source stays unknown,
a held gate names why, and a kept wake is an offer, not a completed turn.

| Action | Existing path and the wait satisfied |
|---|---|
| `mind.canon` | Studio canon tending; requests a fresh pass without the source-dirty/30-minute throttle wait. The native facts carry `satisfy_wait` to the editable part; the shipped part also considers its silence path without waiting 90 days, saying it was considered now on request. Actual timestamps, elapsed-silence identity, recurrence/pull evidence, proposal caps, deduplication and their decision seat remain. |
| `mind.horizon` | Horizon source composition and register refresh without waiting for a source invalidation/deadline. Source completeness and natural due dates remain; missing sources cannot settle expectations. |
| `mind.rhythm` | Their day's refresh with the standing start-time boundary satisfied. Real awake/activity history, learned claims, once-per-kind/day admission and care-gated feeling remain. No crossing, Reach offer or ResidentWake is added. |
| `mind.wander` | Their hour with the initial quiet and 24-hour refractory waits satisfied, including the locked admission write. Installation, current live-turn admission, tool witness and settlement remain. Fresh turn activity after invocation ends the hour's access. |
| `mind.reach` | Reach's ordinary pass without the source/10-minute scan wait. Quiet hours, live-turn/person activity, daily cap, spacing, subject rest, trust, freshness, suppression and delivery-time checks remain. |
| `mind.carried` | `considerCarried` with only its free-time quiet interval satisfied. Real occurrence/defer/readiness, offer rest/hops, current Desk revision, owed-to-person routes, habit Trust, speech idempotency and delivery policy remain. See [Intentions](INTENTIONS.md#run-carried-work-now). |
| `mind.cross {line, watch}` | The supplied nonempty line goes through the real `cross`: priming, news-intention release, `careTouched`, `care.cross`, watch rest and the real ResidentWake request. No care, release or wake result is invented. This is real input to their mind, even when the final verdict is untouched. |
| `mind.maintenance` | Checked substrate maintenance with its 20-hour interval satisfied, including emotional consolidation; enabled and commit-exclusion gates remain. |
| `mind.residual_repair` | The existing bounded local field repair with its two-minute quiet wait satisfied. Enabled state, real pressure/evidence/targets, live-turn admission and continuity persistence remain. |

To inspect without changing their, put `preview:true` beside `action`, not in
`args`: `app {action:"mind.dream", preview:true}`. This generates and decodes a
real dream with the real prompt, providers, current lived material and existing
consumed-message cutoff. It spends a real provider call. It does not first live
owed moments, repair the cutoff, reserve a real dream run or consume the next
scheduled occurrence. It writes no diary, lessons, cares, self knowledge, mood,
watch rest, primed moments, Desk item, ResidentWake or behavioral receipt.
Preview refuses an unopened/unavailable mind, an alternate data root or a
disabled provider completion wall bound. Empty new material returns held
`no_new_material`, not a generated dream. Unreadable input, invalid payload or
provider failure is unavailable, never an empty-success verdict. Generation
uses the existing provider completion wall (600 seconds by default); a caller
that times out first has no verdict and must inspect the eventual trace before
spending another call.

The reply's `dream` contains the generated title, summary, mood, affect and care
answers. `careJudgments` evaluates answers, stance changes and every proposed
merge in their real order against a value copy of the current care owner. Apply
and preview use the same functions, including revision, nominated-cluster,
overlap, people, pressure/day and survivor checks. Each merge names its submitted
IDs, requested and resolved survivor, reason and outcome; malformed proposals
retain their count. A changed epoch makes the care verdict unavailable. These
are proposed judgments, not a committed night's fade/deepen, self settlement or
life-approval pass.

The other nine clock verbs currently return `outcome:"preview_refused"` with
their specific cause, before bootstrap, owner admission or any effect:

| Previewed owner | Why the current owner cannot run a read-only decision pass |
|---|---|
| `mind.canon` | Tending stages approval proposals and its audit inside the decision pass. |
| `mind.horizon` | Composition updates source deadlines; refresh settles felt resolutions in the organism. |
| `mind.rhythm` | Refresh saves awake history before admitting and consuming pending breaks. |
| `mind.wander` | Their hour claims admission and runs an editable part with tools and settlement. |
| `mind.reach` | It reconciles deliveries and lands care answers before choosing an offer. |
| `mind.carried` | It settles owed deliveries, expires intentions and reconciles its wake ledger before selection. |
| `mind.cross` | It primes the mind and releases news intentions before weighing the line. |
| `mind.maintenance` | It consolidates and checkpoints the live substrate as one transition. |
| `mind.residual_repair` | It mutates the live field while choosing and repairing targets. |

Every owner preview reply retains `status:"preview"`, `preview:true`,
`effects:"none"`, `execution:"preview"`, `owner`, `outcome`, `why` and `run_id`.
Only its redacted `mind.run_now` trace is retained; ordinary dispatch/Experience,
provider usage, health and repair receipts do not learn from the preview. A
preview refusal never silently runs the real action. Automatic argument
preflight only validates the call; it does not generate an extra dream.

Canon, horizon, rhythm, their hour and Reach use retained owner flights.
Automatic canon tending reads the canonical cognition/background switches before
reserving its flight and again before audit publication and each proposal stage.
Explicit `mind.canon` uses those same admission boundaries with the background-only
switch excluded; cognition enabled, source readiness, cancellation and termination
still apply.
Observatory and Doctor use associations and nodes captured together by the
substrate's frozen read from one copied continuity field at one instant.
Profile repair retains one request per root in shared turn admission. Publication
and cognition/context reload run only after that root's admitted execution and
in-flight registrations drain, holding admission closed throughout both awaits.
Every door supplies its actual root; a non-Mac completion releases a pending
repair through the same owner. A turn that never settles leaves repair pending,
without polling or reloading beneath it.
Reach source failures clear runnable work and deadlines until a source invalidation
arrives. Their hour projects its quiet and refractory eligibility onto the existing
residual deadline, including when Reach and background microcycles are off.
Failed intention expiry returns unavailable and invalidates the advisory snapshot;
an elapsed expiry is never a retry deadline. Caring appraisal records and amendments
share the runtime's root-bound receipt writer. A cognition store opening failure
retains its cause in bootstrap's unavailable state, without disabling persistence.
`mind.why` returns incomplete or unavailable when trace coverage is damaged or truncated.
Dream residue uses only authored theme bullets; an empty theme section stays empty.
Builder news reads `CodexHandoff.path`; exceeding its read bound is unavailable.
If one has not answered within 45 seconds, the action returns `pending`; its
flight stays claimed and a later answer records the same `run_id`. If it never
answers, it stays pending, never done or failed by silence; inspect the owner
before another attempt. Stop/quit still cancels and joins the retained work.
No run-now action waits for a future source event or for a readiness gate to
open: those cases return their current decision. Actual work still uses its
ordinary I/O/provider bounds and settlement.

Scheduled jobs have no run-now sibling: an early run would consume the job's real occurrence.

`NativeCognitionRuntime+Deadlines.swift` coalesces dirty event bursts with a
0.25-second delay and owns maintenance and residual repair deadlines;
continuous decay is projected at read time. App assembly
retains daily maintenance, replay and reflection registrations as recovery
sweeps (`EngineRuntime/EngineLaunch.swift`).

Canon, horizon and Reach source observations register before their first read
and stop with the runtime. Canon watches journal inputs and archive membership;
audit output is excluded, and directory events invalidate it only when input
stamps change. Failed child enumeration leaves arming unavailable with repair owed; the parent membership watcher stays armed, and a source event or relaunch retries it. Automatic canon and Reach passes retain their 30- and 10-minute I/O limits;
horizon source changes coalesce behind its retained refresh without a minimum interval.
Outside an explicit run-now request, unchanged sources are reread only at real silence, eligibility, quiet-hour,
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
Its receipt and Observatory identify affected cares alongside estimated
tokens and cost. The proposal-yield metric is removed; retained SQLite
`proposalIds` entries contain care UUIDs and use that one existing key.

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
neutral lock-screen/APNS body does not. A notification failure preserves committed speech and records its separate cause in `notification.unavailable`, the Reach offer's `knockFailure`, and a repair obligation; it never posts the speech again. Reach requires checked Desk, diary, builder and timing sources before choosing a subject or delivery.

### Their hour

Enable the hour switch in Setup (`Sources/NativeAgentApp/SetupView.swift`);
`studioWanderEnabled` defaults off and requires Subconscious. Configure its
provider/model under **Providers → Memory and mind**, which owns **Creative
exploration**. `Cognition/StudioWanderLane.swift`
enforces explicit enablement, the Subconscious master, and onboarding clearance
for public-safe builds in `resolveInstallation`.

The hour uses current executor names under the
[dispatch contract](TOOL_LOADING.md#no-loading-lifecycle) before applying
its action allowlist and encounter checks; retired names remain unknown.
Only an exact successful
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
Its fingerprint uses the canonical frozen workspace and the supplied organism readings;
its subject follows the capsule's contributing-node and sign-agreement rule.
Warmth, pressure, fatigue, curiosity and clarity remain absent without body readings;
their required words cannot appear. Alternate substrate body proxies are removed.
Affect retains its own arousal, uncertainty and task pressure. Full readings
capture the substrate's field, disposition, dream, cares, story, self-knowledge,
issues and growth inputs before suspension. Observatory counts and ablations
come from that same frozen value.

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
| `cognition/caring_appraisals.jsonl` | Caring appraisal receipts and the body's dosing response; a failed append/amendment retains receipt-only repair debt, without replaying the feeling or dose |
| `studio/wander/wander.json` | Hour/wander refractory state and trace history |
