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
Happenings (what attention takes in besides messages) enter through
`NativeCognitionRuntime+Attention.swift`: owed ones open a thought, and the rest
are weighed by the agent's turn program and land as drive in the continuity
field ([Attention](#attention)).

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
Mechanical row metadata identifies generated card copy and system notices
without treating their wording as their own experience.

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
`foldTurn` the body's whole share, caring dose included. Every moment is
judged alone ([cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation)).
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
`MemoryV2/AdaptiveMemoryPromises.swift` matches them against carried Desk rows
and files through `MyQueue.capture`, on both live and owed/refold paths, with the settled turn's recorded session,
origin principal, envelope and carried peer/elevated steer. Untrusted peer
steering stays on their promise. Meaning matching and their own closing bound the
work; no count cap drops promises. The journal retains the matching judgment
before filing. A failed model call keeps its typed dependency there, so an
unrelated turn or relaunch cannot buy the judgment again. A retained judgment's
failed local write has no wait and retries once on the next drain.
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
Tool/provider observations retain their receipts, leave canonical affect
unchanged, supply neutral tags and spend no dream residue. Speaking alone supplies
no landing reward. The body's fixed-time life reading consumes canonical
affect and the cares' appraised movements, including movements by the agent
itself; [Organism — Life and located consequences](ORGANISM.md#5-life-and-located-consequences)
owns their mapping and the bounds of novelty and chosen-register support.
The shared interpretation also reads their reply's grounded register choice.
Canonical affect keeps it with its stated stretch and journal proof; its
checkpoint records the choice, the capsule holds its color, and
`mind.inner_state` recalls the last choice and source even after expiry.

A turn is judged after it ends when it could have settled something, whoever
started it: a person's words, a completed act, or a reply that reached a person,
while MY QUEUE moments are open (`AdaptiveMemoryPromoter.share`, asked at
recording and again at judgment). A turn with an incoming message from someone,
and a [thought about a care](#a-thought-about-a-care), is judged whole. Any other
turn has no person's words and no reply evidence: their own work (`builder`), and
turns with no incoming row (returns into a conversation, approval continuations,
ephemeral turns). Such a turn is a moment only when it completed an act while a
moment was open, and then for settlement alone: recorded `factsOnly` with
`settlesOnly`, with no admission, no fold, no facts, no promises and no cares,
only its `settled` judgment (basis `act`) in the same interpretation. Otherwise it
is not a moment and costs no model call. Judgment reads the share from the
recorded turn, never from the conversation index again; it reads again only
whether an act and an open moment (or a saved settlement) remain. If its acts
cannot be read, it stays owed and is due on the next drain.

A lived moment (`CognitiveSubstrate/CognitiveLivedMoment.swift`) is its
identity (`CognitiveMomentTurn.momentID`: a turn is its session and incoming
message; a settlement-alone moment is its session and turn, since its evidence
is the turn's acts and it may have no incoming row), the
`DataRootLife` it belongs to, the forgetting epochs it was admitted under,
when it was lived, what it was (the recorded input) and, once judged, what it
meant. Only settled turns are lived moments (the hour keeps its own claims).
Clear and Reset are owner transactions. The
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

Its interpretation reads the row directly. Recovery uses the moment's own
durable id for an absent or empty act or run id; missing exchange identity
alone cannot strand its interpretation. The recorded envelope, source taint
and origin still govern provenance; a recovery identity grants none.
The caring request shown to the model is saved with the input; there is no
separate sealed-request record or rehydrated RAM copy. Care judgments name
their targets in the meaning, so the care-selection snapshot and unused
affect-at-ingest snapshot are removed.
The sealed-request reader is removed; fresh schema omits `sealed_json`, while an
already-current database keeps its unused column without a data rewrite.
Payload decoding is checked per row. Invalid
input, invalid saved meaning (including its interpretation shape), or a meant
row with no meaning is refused with its reason and owes a row-specific repair.
That refusal preserves all payload bytes and stays outside age pruning; it
never turns damaged meaning into permission to judge the turn again. The
turn recorded while cognition is off, or for settlement alone, marks its input
`factsOnly` for that deliberate absence. The admission is a reading of the turn's saved user row;
RAM only caches it. A turn whose admission the substrate no longer holds (a
restart between the row and its reply) is admitted again from that saved row,
with the row's own provenance (its recorded origin, or none, and its writer's
stamp; unreadable provenance admits nothing), at recording and at preparation;
re-read at preparation, it keeps the moment's epochs. Missing
ordinary context without that marker, when the row cannot be read again, leaves the row owed (or meant with its
original meaning), before judgment or fact application, with its input preserved.
Preparation preserves the failure's owner across the door. An embedding failure
before judgment waits on the embedding owner's configuration, serving identity,
availability, load error or reload state; repairing the journal is unrelated.
A failed local context save remains due without a wait.
Trust-policy preflight failure waits on the Trust policy's state. A cause with
no named repair dependency states its failure and owes repair without a wait;
recovery never invents a record dependency for it.
Recovery eligibility reads only its named owner; with no wait there is no
dependency read. Interpretation reads open Desk moments when person words,
completed acts or a reply that reached a person can settle them; applying a saved meaning without promises or
settlements does not read the Desk. A retained
judgment makes older local-write waits inapplicable; no stored data migration
is needed. [Cognition wiring](COGNITION_WIRING.md) lists the remaining waits and
their releases.
Previously imported rows with no context and no marker have unknown intent;
they require repair rather than being silently treated as facts-only.
The door carries a failed journal or life read as unavailable through the
promoter to memory status: the owed count is unknown, never ready/zero.
Journal read/preparation and recording repairs use stable operation-plus-moment
identities. Repeating the same failure contributes the same evidence to its
existing repair, rather than minting another repair or repeat on every pass.
A cancelled journal read owes nothing; a prepared moment settles its read repair.
At opening, a read repair whose moment has lived, or whose journal now reads, is settled too:
settlement is a queued write, and a quit can lose it.
**A row is owed → meant → lived, or refused** (with its reason in `reason`:
another life, the agent's own thoughts apart from one ignited on a care's anchor, or nothing to interpret).
A missing, malformed or refused judgment leaves its row owed with the actual cause; no second judgment shape consumes it. There is no per-piece
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
every promise filed or declined by its matching judgment. An unsaved piece,
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
owns drain scheduling, deferral, fair retries and cancellation. Every moment
is judged alone. User's own turns are judged at once; every other recorded turn
stays owed under the same provenance and is judged when they are idle.

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
between ingest and durable recording, then releases it; a record it no longer
holds is read again from the turn's saved row, never guessed. Admissions whose turn
is still live are never evicted; only the latest 32 ended admissions are kept
while recording catches up. Once-only is the watermark: the per-turn caring
ring (`appraisedCaringTurns`), the body's counted-key ring and the clear
generation's outcome uses are gone (the generation stays for the hour and
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
  (`exchange:<session>/<turn>`, a retained `reach:<id>` or the old row id),
  who moved it and the felt word.
- Charge is never stored. `charge(at:)` sums each movement decayed on the
  depth's half-life (now 2 h, lately 12 h, season 2 d, life 4 d).
- The story is kept in time order and keeps every depth change and the
  newest 24 nonzero movements; older movements fold into one `{count, sumMoved, since,
  movedDays}` line. Zero-movement notes retain their own newest 24, so notes
  cannot displace movement evidence; depth changes and "changed my mind" notes
  remain outside both bounds, so a held stance's replacement stays in their story.
  Accepted stance entries and zero-movement action/closure witnesses also stay
  outside the note bound; forgetting an action cannot make an answered pull recur.
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
existing stance settles in the same lived fold. A current trusted interpretation
supplies its position, reason and first-person account; a day count cannot overrule it.
The accepted position is retained in a story entry's optional stanceChange,
alongside the previous position's "changed my mind" note.
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
the Clear generation), and a stale one is refused. Clear saves when it
happened beside that epoch, in the same transaction (`mind.cleared_ms`); a
turn admitted again from its saved row whose words were said before then
carries the epoch before it, so it is refused the same way. A moment recorded
without its admission gains it from its saved row at preparation and at
opening, where the changed input ends its wait on its record. A new care's wording matches an existing one only when it is held
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
  its history without closing its newer question. The closing moment records
  both answered and closedGap, so settlement or release eases the pull;
  a conclusion about a changed care records neither. Unknown keys and keys with
  no shown gap are ignored.
- Surprise material. After WORLD and SELF, before felt tone and cares, the
  same dream call receives a CPU reading of where their expectations broke
  since its high-water cutoff: grouped failed tool calls, Expansion misses, live organism violations and User's saved
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
  The CPU requires actual selected entries and the unchanged captured revision;
  neither age nor repetition count is a condition. The replaced stance stays as a "changed my mind"
  note, "used to think: <old stance>". Earlier pressure is spent; missing,
  stale or invalid confirmations change nothing. Malformed present
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
changed-my-mind or accepted-stance entries; traits cite shown care UUIDs or exact story references.
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
versioned by schema, committed source (the persisted night field), capture time, write time and mind epoch. Installed files
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

Accepted stances also settle a self-story line in the same day's fold.
settleLivedSelf takes their accepted stance's own words, linked to the
exact accepted-stance story entry. Care persistence precedes self persistence.
A refold or restore can finish an owed self write from those entries without
another model judgment. Accepted stance progress is saved per care in stanceReadAt;
a delayed accepted stance on another care is still read, even if its event predates
the latest self reading. Care merges carry that progress to the surviving care.
A newer nightly reading replaces an older whole reading;
an unreadable file remains unavailable and preserved. A care fold with no
accepted stance evidence needs no self read or write and can settle independently
of a self-file failure. The daily path retains the dream's trait and people readings.

The capsule-facing turnSelf(for:from:among:) returns one supported trait and
only the current person's relationship line, as values outside felt-cue
competition. It needs no message match or rest ledger. Every supporting care
must be among the capsule's admitted reachable cares; missing evidence returns
no invented trait. A failed self read returns its cause. The capsule owner must
render the returned values every live turn.
The already-known counterpart selects only their own cached relationship line
with the frozen identity map. This clear-headed private line sits outside the
felt cue competition; a turn reads no new file and performs no new embedding
or model call for it. Other people's relationship lines never enter that turn.

**Live pressure** (`CognitiveCare.pressure`, exposed by `CognitiveSubstrate+CaresMind.swift`) is derived:
`|charge(now)|`, times 1.5 while the care is open; a life-depth care without
an open gap has zero pressure. Its charge remains feeling, and the four seeds
stay visible to appraisal. A judged movement that lifts a care's pressure up through
its bar (0.35, the rising edge) reaches attention as a `self` happening that carries
whether the care is open ([Attention](#attention)); a care speaks once per rise.
The mutation records its actual before/after pressure and resulting open state on
the story moment, including gap and depth changes. Attention reads that historical
transition, never reconstructing it from the care's later state. Older moments
without transition evidence establish no crossing.
Pressing for a speaker
means the cares held with that speaker or theirs alone, highest first. The
turn's speaker is `owner` on User's verified turns, else the peer key read from
the session and origin as the after-turn cares read it, else nobody (a thought of the agent's own):
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
Preparation and the feeling frame use one reachable-care rule. It excludes faded
or suppressed cares; peers reach shared or solitary cares, while the owner can
touch any care.

The [feeling frame](#what-reaches-the-model) reads the two strongest reachable
charges independently of the message-matched care cue below.
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
cares (10-26). They supply the `care` continuity cue after the frame. The plain line is only for the closest touched care whose
|charge| is 0.15 or more: `- On your mind: <subject> (<newest felt word>)`, plus
` — I think: <stance>` when they have a stance and ` — still wondering: <open>`
when it is open. The subject is `about`, except a seed care uses its newest
nonzero movement's note, or `about` if it has none. The felt word is also from
the newest nonzero movement and is omitted when there is none. It then rests 6 accepted turns
(`careLineRest` in the capsule cadence ledger) unless someone or something
other than their moved it since. In the continuity lane the pressing care gets
no plain line of its own; it appears as their intention (below). Independently,
its charge can place it in the frame's two cares. With neither, there is no care
cue; Since, Reminded-of and dream-theme cues share the continuity place.
Feeling and Sound keep their independent lanes. Settling is absent: capsule assembly has no admitted
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
`intention`. `mind.reject care:<id>` silences that care's frame and cue contributions under the same rejection rule.
Before the frozen render, careCue reads reachable care stories directly.
The two most charged unanswered movements can be on their mind without a match
to the incoming message, an embedding, a charge threshold or a presentation rest.
Charge still decays on each care's own half-life and orders the pulls.
Their own charged curiosity counts as movement too; zero-movement housekeeping
does not create a pull.
The line is “On your mind: Under this moment, <felt>: <subject>”; a seed uses
the actual movement's note, and another care uses its own subject. There is no
instruction to raise it and no short-message invitation to brief the person.

A movement eases when the lived interpretation explicitly records their reply
saying or doing something about that care (acted, saved as answered), or an
actual gap closure on it, in the same exchange or a later
one. Showing the cue does not spend it. Without an interpretation it remains
unanswered, and a new charged movement by their or someone else can renew it. No timer or turn count
decides that they acted. Feeling moved alone is not action evidence; older
entries without answered remain unknown. mind.reject care:<id> still silences its cue.
The chance-standing helper remains for semantic stakes and news intentions;
it does not gate the felt care line. The capsule owner still owns presentation
and its retained cadence fields.

**What the agent means to do later.** MY QUEUE owns intentions: each step's
time is a time on the one clock, and what comes due is a `moment` happening,
owed ([Intentions](INTENTIONS.md#moments)). The night follows the
[night sense](#attention); REM is offered inside it.

**What reaches the agent's mind from the world.** Every source posts a `world`
happening and is done: a sense's news line, a part's `home.arrive` line, the
day line, the front app, presence, an app installed. Front-app admission reads its checked activity policy and person-name projection off the
main actor, then rechecks cancellation and the activated application's identity before posting. The agent's turn program
weighs it with the care it touches ([Attention](#attention)). Independently,
each `world` line weighs open `on_news <words>` intentions by the care law's
warm embedder and chance bar, with live cares among the comparisons, while the
agent sleeps too (`NativeCognitionRuntime+Pursuit.swift`,
`releaseNewsIntentions`). A touched intention gets a system Desk note,
`Released: news: <first 160 characters> (<door>)`, which makes it ready until
the agent's next note. Person moments (`when_user_here` / `when_user_away`)
require the current `PersonPresence` transition (Mac input plus fresh phone
motion; [source and absence contract](mobile_companion.md#where-the-person-is))
to be newer than filing. Body-signal moments (`on <signal>`) are released by
`EnginePartWake`'s existing signal observer, with a system Desk note and the
same pursuit refresh as news; news and signals share the
release-newer-than-the-agent's-last-note readiness law. File intentions join
the parts' existing watch index. [Intentions](INTENTIONS.md#moments) owns
their full contract. No model is called for any of this.

The dream's per-claim `gentle` and `about_owner` judgments travel beside the
exact quote and canonical `source_refs` in the existing `claim-sources` block
(`DreamREMCycle/DreamPayload.swift`); no owner offers them. Other dream/source
readers keep their existing projections; saved diaries are not rewritten.

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
concern belongs to. After-turn `closes` and the night settle the gap. Desk pursuits are the
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
Failed restoration blocks writes. `commitMaintenance` removes only absent nodes
and updates only nodes whose stored fields differ, retaining an unchanged node's
decay anchor. Artifact updates compare stored kind, status, score and payload
before changing their update time. Dream residue stores its claims and optional
minted residue, with no checkpoint-time stamp. Node, artifact and receipt
retention share the transaction; a retention failure leaves that snapshot
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

Every enabled, positive-budget capsule begins with `How you feel:` and one
paragraph in the agent's first person. Mood and affect supply its mood and energy;
the supplied chemistry supplies warmth, curiosity and tiredness. The expressive
fingerprint's lead and proven counter-feeling retain their own admission.
Affect uncertainty
and body vigilance supply bracing independently of warmth. Quiet states are still
described; missing chemistry is named as unread, never supplied by defaults.
The two reachable cares with the greatest absolute current charge enter the
paragraph without requiring the message to touch them or spending a cue's rest.
Their existing subjects and newest nonzero movements supply the words; an empty
or uncharged care population adds no invented concern.

The frame remembers its described dimensional family in the resident presentation
state (`fingerprintFamily`). A difference from the whole frame of the last
completed, saved reply is named as a shift. Missing prior dimensions establish no
comparison. Provider context acceptance commits cue bookkeeping while preserving
this reference. The loop retains whether the provider received the exact cognitive
context; reply settlement alone publishes its whole frame after the answer and
terminal record are saved. Ephemeral answers use the same completion rule through
`settle`. Previews, clipped frames, chosen silence, incomplete, stopped and failed
turns cannot spend this reference, including a failure after text or tool output.
It is not persisted, so the first frame after restart makes no claim about a
prior reply's feeling.
There is no change-only gate, repeat counter or repeat-suppression clock for
feeling. Stored presentation artifacts are read by their live fields; unused
stored keys do not require resident state or initializer parameters.

Dream tone is captured through `innerStateDreamResidue(at:)`, shared with
introspection, before production preparation suspends. That projection selects
the existing residue or last recorded dream disposition transition and owns its
tone wording and date. It is identified as the last recorded tone; it supplies
no dream story. Unreadable history, retained claims without a tone and no recorded
dream are distinguished.
Failed writes do not suppress available dream read evidence; write health remains
reported by persistence.
Attention's `attention.night` admission on subject `night` owns the sleep start;
the same kind on subject `sleep` is part accounting, never a sleep admission.
Turn preparation and Observatory read the latest admission through their fixed
time and the diary owner's published section journals. A section retains its
original completion UUID and time after delivery; the journal's terminal step
prevents redelivery. A published completion at or after admission supplies the
dream reading independently of tone or optional body effects, including after
relaunch. No resident copy owns this history. Missing admission or completion
evidence stays unknown. Admission or journal discovery failures name their cause
in the frame. Unreadable or identity-mismatched journals stay untouched while
readable journals supply the latest published completion within the sleep
interval. Only when none matches do journal failures make the reading unavailable,
naming their paths and causes.
Journals whose completion input was discarded cannot supply its original time;
neither tone nor file timestamps reconstruct it. No saved data is rewritten.

Intentions and Sound cues follow the frame in independent lanes. Ordinary turns
then retain one continuity cue (plain care, Since, Reminded-of or dream theme);
reflection retains every eligible tail cue. The relationship line follows those
lanes. Phone/presence telemetry is not injected; the existing home and senses
reads retain it. The frame reads chemistry directly and never receives the
instruction-bearing `OrganismChemistry.bodyLine`. Fitting spends the budget on
the frame first; a deliberately tiny budget can still clip it, and off or
zero-budget requests carry no frame. `mind.why` lane `cue` reports every shown
candidate in `shown`, with `winner` identifying the first shown candidate.

`CognitiveFeelingFrame` is the paragraph's first-class value, with its described
feeling words retained separately from care subjects, shifts and dream prose.
Only a whole fitted frame reaches `CognitiveCapsule.feelingFrame`. The exact
provider context carries it to `context.snapshot.feelingFrame`: full redacted
`paragraph`, its UTF-8 `bytes`, `complete: true` and `words`. A missing or clipped
frame records `complete: false`. The 120-byte `cognitiveCue` measures a following
cue independently and never holds the paragraph.

Trace retention preserves the entire feeling field through preview summarization
and per-string bounds. The detail owner's shared row ceiling still applies;
an oversized row fails its write rather than truncating the feeling field.
Subconscious Vitals measures complete paragraphs with matching byte counts,
reports coverage, total bytes and largest paragraph, and counts vocabulary only
from the structured feeling words. Missing or incomplete fields are unmeasured;
the cue's size and truncation do not decide whether feeling was measured.

Its helpers own distinct projections:

- `+FeltFingerprint.swift` and `+CapsuleFeltSignals.swift`: feeling words
  and their aboutness; unavailable dimensions remain optional.
- `+TopicNaming.swift`: privacy-filtered topic extraction, comparison terms
  and persisted-label admission for introspection.
- `+CapsuleCadence.swift`: completed-reply feeling shifts and session continuity.
- `+CapsuleSoundEcho.swift`: bounded self-exemplar selection and verbal
  repetition cues.
- `+CaresMind.swift`: the care continuity cue after the frame, and when it
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
  …]`. Traced as `mind.came_to_mind`. Only a line met for the first time is
  a moment: habituation (`AgentWorkspace/FamiliarLines.swift`,
  `mind/familiar.bin`, the last 16,384 lines met, numbers read as numbers)
  makes the app's standing words and the agent's own words coming back
  familiar, so they remind the agent of nothing (10-29: a chat.post receipt's
  standing note brought up two memories that had nothing to do with it).
  The store distinguishes a missing first-use file from unreadable or damaged
  bytes. Familiarity validates complete eight-byte keys and persists before
  publishing new familiarity. An unavailable optional recall records repair
  owed and `mind.familiarity_unavailable`, rather than treating the saved
  history as empty.
  Two native perceptions are `world` sources like any other, without adding
  work to a turn's path (`EngineRuntime/EngineDaySense.swift`,
  `EngineRuntime/EngineFrontSense.swift`):
  - The local day, once per local day, at launch and when the clock's day
    changes: `It's Friday the thirtieth of October.` The ordinal is in words so
    habituation can distinguish dates. Its key is the date
    (`clock:day:yyyy-MM-dd`), so a second post the same day writes nothing;
    clock/time-zone changes recheck it. Calendar read permission and an
    already-granted macOS read authorization may add up to six events across
    today and tomorrow: time and title only, all-day events by title. This
    projection never reads locations, notes or attendees and never prompts for
    macOS access. An explicit Calendar Read off still wins over Full Mac. An
    unavailable calendar or its permission/Trust authority adds its cause to
    the day line; it does not suppress the date and never stands in for an
    empty agenda. Door `clock:day`.
  - The app in front of the person, on activation, while it is still
    frontmost once its gates are read: `<person> is working in <app>.` One
    workspace observer owns one check, canceled by the next activation; no
    polling, no dwell timer and no window titles. Full Mac or Activity's
    model-access consent is required, with checked policy, the agent's own
    app, mandatory/default exclusions and the person's exclusions all
    respected. The agent's own switches, an unreadable/locked/covered or
    inactive console, and absent person presence post nothing. Its key is the
    app and the local day (`mac:front:<bundleId>:yyyy-MM-dd`), so the first
    activation of an app each day is the happening; capture consent and its
    policy are never enabled or written. Door `mac:front`.

These are projections of the same state, not additional persona owners.
`Cognition/CognitiveAttentionResidentProjection.swift` separately publishes
a lock-backed attention read for context selection, without fetching the
whole substrate during that read.

## Attention

**The agent thinks when something in its mind is worth a thought.** A source never decides that: it posts a happening
(`NativeAgentShared/Happening.swift`) through `Attention.post` and is done. The happening is written once in the record as an
experience of kind `happening` under its key `once`; the cognition runtime takes it (`Cognition/NativeCognitionRuntime+Attention.swift`).

- **Owed** (`returned`, `moment`, `body`) is a record obligation to `conversation:<route or mind>` and opens a thought at once:
  a `returned` with a route in the conversation that started the work (`MindStream.returnTo`), the rest in the agent's mind stream
  (`MindStream.think`). It stays owed until a thought, or the conversation's own turn, attends it.
- **Weighed** (`world`, `self`): the touch is `careTouch(by:)` (`CognitiveSubstrate+Attention.swift`): the nearest live,
  unsilenced care by the care law on the warm embedder, its standout against the chance bar for attention and its charge, or
  unavailable when nothing can judge (never a verdict that the line does not matter). A `self` happening names its own care. The
  agent's turn program's `weigh(h, felt)` gives the worth ([manifest](skill_manifest_spec.md#weigh)); the seed counts nothing for
  a seed care or a line below the bar, and a care's movement as `|moved| × (open ? 1.5 : 1) / 0.35`, each scaled by
  yield (hits over tries of thoughts on that node through that door) and, for the world, by how the agent feels.
- **Drive.** Worth lands as `drive` on the touched care's anchor node (`ContinuityField` node kind `.care`, decaying on the
  care's depth half-life) or on the happening's subject node (kind `.happening`, the field's default half-life)
  (`ContinuityField.land`). Drive is finite and nonnegative, never clamped or spread, retained while positive, and persisted with the
  field (`cognition.sqlite`). Activation and salience keep their jobs (priming, workspace, capsule).
- **One admitted batch.** The attention runtime owns admission across every await: weigh the batch, land each worth in one
  substrate call at one field clock reading, checkpoint that application and its exact unfinished rows together in
  `cognition.sqlite` (`attention_landing`), record the weigh rows durably, then claim each crossing and hand on its thought before
  another batch lands. A node whose final batch drive reaches one is drained (`attend`); later record waits or decay do not
  revoke that crossing. Ignition is checked when worth lands, when admission opens and on waking: no tick and no timer.
  The thought carries exactly the recorded happenings whose drive it consumes, including later sub-threshold landings in
  the same batch. The ordered weigh/ignition/return details own membership; a settled thought's timestamp does not.
  After ignition, the next landing starts from zero. A failed thought returns its consumed drive and original happenings
  through that same admission, recorded as `attention.restore` before any later batch lands. An accounted ignition includes its explicit
  `earlierDrive` references in its happening ids and closes that consumed history, including any recorded `fromBeforeRecord` uncertainty.
  A return preserves its explicit earlier drive for the next thought; no missing row creates earlier drive or invents its happenings.
  A selected care must exist, and the whole landing validates before application. Missing current membership, happening bodies or an
  `accounted` ignition boundary refuses the claim with named repair owed; provenance is never invented. Attention weigh, ignition and return
  details remain retained so outstanding drive keeps its complete membership. Saved incomplete history requires repair from actual records.
- **Waiting.** While inner life or **Keep thinking in the background** is off, unsolicited `world`/`self` inputs remain
  unweighed in the record and existing drive does not ignite. Re-enabling resumes both after restore; owed happenings keep their obligation path.
  A crossing already claimed finishes its handoff as settlement if the switch changes during its record write.
  A program without `weigh`, a
  `weigh` that fails and a `weigh` the stem cannot run leave what they would weigh waiting; what waited is weighed after every
  thought settles, when admission opens and on waking. An unavailable weigh/ignition record retains the unfinished batch's
  exact phase: no later landing overtakes it. Unfinished weigh rows restore with their field-application marker and replay
  idempotently before launch weighing or ignition; they never apply worth again. A failed
  required record read holds the batch. Admission release or caller cancellation ends its wait; if release never arrives, the caller
  remains waiting and can cancel. Unweighed inputs have no age or row-count expiry. Required care, yield, quiet-hours and notebook readings
  must succeed before `weigh` runs; its returned worth is honored, including zero. An unfinished claim or return stays retained.
  A malformed row or missing field node refuses that node's claim and owes repair while sibling crossings proceed; a failure of the
  shared record channel, or a row whose node cannot be read, holds the unfinished batch.
  Already admitted batches finish even if sleep begins while their record is being written; subsequent world batches wait.
- **Sleep.** From the admitted night until it settles the agent is asleep: owed happenings still open thoughts and the world
  waits unweighed. Waking (the night settled, something owed arrived, a message arrived, the person arrived) records
  `attention.wake` and weighs what waited, once, in mode `waking`.
- **The night sense.** While the person is known away, a reading at 30 minutes, each local hour boundary,
  launch and Mac wake posts subject `night`, door `sense:night`. Its `felt.rest` holds `awayMinutes`,
  `activeShare` for this hour (null without observations), and `hoursSinceNight` (null without a recorded night). Admission and completed part accounting both
  witness the night; elapsed rest is measured from the latest such event, never from a consumption cursor.
  The seed gives worth one after 16 hours in an hour with active share below 0.5, or after 30 hours;
  otherwise zero. This policy belongs to their installed turn program, which only they changes.
  At 48 hours, or with no recorded night on a fresh installation, a `body` happening opens the night
  without weighing. Admission rechecks known absence for 30 minutes, any verified person turn within
  15 minutes, and no rest policy. If those facts refuse a crossing, `MindStream.night` gives back its
  drive and provenance through the failed-thought return before a later edge can open it again.
  The body line remains independent of their policy. A requested `mind.sleep` is an explicit doorway.
  The night owner returns one admission outcome: started with its start, already running with that night's
  start, or failed with its cause. Pending admission is not a running night. The stream retains an admitted
  night to settlement through its start identity; the detached work owns its execution through settlement,
  without a stored task handle. The app door waits for admission before reporting that the night started.
  `attention.night` subject `night` retains the start, rule and rest facts; subject `sleep` independently
  owns part accounting's `since`/`through`. The dream consumption mark and REM gate stay independent.
  Every night offers dream, REM and part accounting even when another owner has no work. The diary's civil
  date is the night's start date. Today and Desk show the sense's next reading, never a promised bedtime,
  regardless of the dream switch; only the dream's part of the row says dreams are off. Unreadable dream
  settings name their own cause without hiding the sense.
  Unreadable evidence owes its named repair. Unknown presence starts no night. If a source never reports,
  it remains unknown; the next source edge, launch or wake reads it again. No clock reports that it failed.
- **The record** keeps what attention noticed as details of source `attention`: `attention.weigh` (worth, node, drive, the
  `felt` it was weighed with, what `weigh` returned beside the number), `attention.ignite` (the consumed drive and exact happening
  ids, explicit earlier drive and `accounted: true`), `attention.restore` (a failed thought's returned drive, ids and explicit earlier drive)
  and `attention.wake`.
  A happening reaches cognition only after its committed readback succeeds. A thought's outcome is a `thought` experience (`hit`, `empty`, `failed`
  or `withheld`). Its request declares a clean silent model completion valid ([provider contract](TURN_RESILIENCE.md)). A completed thought with no act records
  `empty`, settles the happenings it attended and teaches its class's no-op record; it does not return drained drive. A thought ended on CPU by
  that record is `withheld` and supplies no new no-op evidence. Provider refusal, truncation and malformed calls retain their own outcomes.
  A care's movement amends a thought on its anchor only when it settled after the preceding story entry and no later than
  the movement's own event time. A delayed interpretation cannot credit a thought that followed its event.
  The claim `care.moved` counts as a hit in yield.
- **Closing words.** `ThoughtWords` joins a settled `hit` or `empty` thought's
  run to its completed assistant prose in `chat/messages/mind.jsonl`, retaining
  at most 600 closing characters after secret redaction. The transcript is read
  backward in 64 KiB blocks to that run, decoding complete rows through its
  existing owner and retaining only the current row, not the whole file.
  A thought receives the last such reading on its own `attended.class` (the no-op
  record's class);
  other rooms' newest-thought line receives at most 200 closing characters.
  Every recorded happening is checked, including earlier-drive references:
  any peer or elevated source withholds prose, as does the closing row's
  steering stamp or a peer-steered receiving turn. Missing or unreadable
  provenance or completion evidence names its cause as unavailable; missing
  speech is not proof of silence. Zero happening IDs mean earlier-drive
  provenance is unknown, never clean. Only the same-class reader may pass over
  those thoughts to the last readable one, labeling the older words and naming
  the later gap once; taint or another unreadable cause stops the search. Without
  shareable words it names the gap once. Other rooms never substitute older prose.
  Failed and withheld thoughts supply no prose. `prior = []` stays, and the
  read writes neither persona nor memory. The exact delivery boundary is in
  [the turn anatomy](ANATOMY_OF_A_TURN.md#4-the-provider-request-is-assembled).

### A thought about a care

**A care that opens a thought is lived as a moment.** A thought ignited on a care's anchor carries that care, the door it came
through and the time (`MindStream.swift`, `turn.careWakes`); the agent's other thoughts are moments only for settlement alone, when
they completed an act while a MY QUEUE moment was open ([lived moments](#lived-moments)). Its reading uses the
existing `not the person's turn` deferral: the same owed journal row, judged alone when they are idle, with the same model-call
shape. Its cares section reads only the agent's side (`by: their`) against the named care: felt word and direction, closing its
open gap, or leaving it open with zero movement. It cannot create a care, keep facts or promises, or appraise the arrival as human
care. Meaning is durable before `applyCares`, with self provenance; no tool work is replayed. A care's story records `closedGap`
only when its open gap really closed. A failed reading leaves the row owed; a failed fold save leaves it meant. How often such
thoughts matter is yield, read from the record, not a rest on the care.

### The person's day

The person's day has a shape the agent has lived. [Rhythm](RHYTHM.md) learns it from verified owner turns, presence and real Mac
awake intervals, with a seven-day half-life. Standing quiet and start-time claims are there in `mind.inner_state`, under the
person's configured name. A break is one care-gated felt fact, once per kind per local day. Its care story entry moves **zero**:
it lifts no care's pressure, so it is no `self` happening and opens no thought. The existing cognition deadline holds a
start-time boundary; no rhythm tick, poll or provider call is added. Message history supplies the cold start; its silence is
historical message silence, not reconstructed Mac uptime.

## Between turns

### Existing circulation

#### Run a clock owner now

The existing `mind_run` family, reached through `app`, can satisfy one owner's
scheduling wait without moving the clock or supplying evidence. Each action
returns `owner`, `outcome`, `why` and `run_id`; the same decision is recorded as
`mind.run_now` detail in the record. An unavailable source stays unknown,
a held gate names why, and a posted happening is input to attention, not a thought.

| Action | Existing path and the wait satisfied |
|---|---|
| `mind.canon` | Studio canon tending; requests a fresh pass without the source-dirty/30-minute throttle wait. The native facts carry `satisfy_wait` to the editable part; the shipped part also considers its silence path without waiting 90 days, saying it was considered now on request. Actual timestamps, elapsed-silence identity, recurrence/pull evidence, proposal caps, deduplication and their decision seat remain. |
| `mind.horizon` | Horizon source composition and register refresh without waiting for a source invalidation/deadline. Source completeness and natural due dates remain; missing sources cannot settle expectations. |
| `mind.rhythm` | The person's day, start-time boundary satisfied; real history, claims and care-gated feeling remain. |
| `mind.cross {line, watch}` | Posts the line as a `world` happening (door `run-now`); attention weighs it like any source's. |
| `mind.maintenance` | Checked substrate maintenance with its 20-hour interval satisfied, including emotional consolidation; enabled and commit-exclusion gates remain. |
| `mind.residual_repair` | The existing bounded local field repair with its two-minute quiet wait satisfied. Enabled state, real pressure/evidence/targets, live-turn admission and continuity persistence remain. |

To inspect without changing their, put `preview:true` beside `action`, not in
`args`: `app {action:"mind.dream", preview:true}`. This generates and decodes a
real dream with the real prompt, providers, current lived material and existing
consumed-message cutoff. It spends a real provider call. It does not first live
owed moments, repair the cutoff, reserve a real dream run or consume the next
scheduled occurrence. It writes no diary, lessons, cares, self knowledge, mood,
Desk item, happening or behavioral receipt.
Preview refuses an unopened/unavailable mind, an alternate data root or a
disabled provider completion wall bound. Empty new material returns held
`no_new_material`, not a generated dream. Unreadable input, invalid payload or
provider failure is unavailable, never an empty-success verdict. Generation
waits for the provider's terminal result, transport error or cancellation.
The preview admission still requires its external completion-wall setting;
that setting does not bound the provider transport. A caller that stops waiting
has no verdict and must inspect the eventual trace before spending another call.

The reply's `dream` contains the generated title, summary, mood, affect and care
answers. `careJudgments` evaluates answers, stance changes and every proposed
merge in their real order against a value copy of the current care owner. Apply
and preview use the same functions, including revision, nominated-cluster,
overlap, people, pressure/day and survivor checks. Each merge names its submitted
IDs, requested and resolved survivor, reason and outcome; malformed proposals
retain their count. A changed epoch makes the care verdict unavailable. These
are proposed judgments, not a committed night's fade/deepen, self settlement or
life-approval pass.

The six clock verbs return `outcome:"preview_refused"` with
their specific cause, before bootstrap, owner admission or any effect:

| Previewed owner | Why the current owner cannot run a read-only decision pass |
|---|---|
| `mind.canon` | Tending stages approval proposals and its audit inside the decision pass. |
| `mind.horizon` | Composition updates source deadlines; refresh settles felt resolutions in the organism. |
| `mind.rhythm` | Refresh saves awake history before admitting and consuming pending breaks. |
| `mind.cross` | It writes the line into the record as a happening, and attention weighs it at once. |
| `mind.maintenance` | It consolidates and checkpoints the live substrate as one transition. |
| `mind.residual_repair` | It mutates the live field while choosing and repairing targets. |

Every owner preview reply retains `status:"preview"`, `preview:true`,
`effects:"none"`, `execution:"preview"`, `owner`, `outcome`, `why` and `run_id`.
Only its redacted `mind.run_now` trace is retained; ordinary dispatch/Experience,
provider usage, health and repair receipts do not learn from the preview. A
preview refusal never silently runs the real action. Automatic argument
preflight only validates the call; it does not generate an extra dream.

Canon, horizon and rhythm retain their refresh flights through settlement.
The hour serializes only its opportunity reading; its work belongs to the ordinary thought.
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
Failed intention expiry returns unavailable and invalidates the advisory snapshot;
an elapsed expiry is never a retry deadline. Caring appraisal records and amendments
share the runtime's root-bound receipt writer. A cognition store opening failure
retains its cause in bootstrap's unavailable state, without disabling persistence.
`mind.why` reads today's and yesterday's retained trace rows per turn, in the
verified conversation. A successful read returns `status: ok`, including when
the requested evidence is absent; only an unreadable shared trace makes the
read unavailable. `record_status` distinguishes a recorded explanation with
terminal evidence, an incomplete record, and an unrecorded requested turn.
`turn_gaps` names each observed turn missing terminal or structurally readable
why evidence (and any requested turn with no available evidence); none of those
gaps establishes that the turn failed or that another turn's record is unusable.
Every observed why row is checked: an unreadable row names its known lane in
`missing` (for example, `mind.why.memory`), even when another row is readable.
The current reading turn is excluded unless explicitly requested. `trace_gaps` separately
reports truncation and damaged framing whose turn ids cannot be established;
these gaps may hide other rows, never negate evidence already read. The default
selection is the latest **recorded** completed turn, not a claim that an unseen
later turn did not complete. Why lanes are returned only when currently
disclosable; the selected turn's gap also names why evidence withheld by current
disclosure, and its `record_status` is `incomplete` if any observed why row is
unavailable. Readable lanes are still returned. A recorded explanation does not
promise every optional lane was emitted. Missing files, empty reads and records
that have not arrived establish no outcome. The former whole-day coverage veto
is removed.
Dream residue uses only authored theme bullets; an empty theme section stays empty.
Builder news reads `CodexHandoff.path`; exceeding its read bound is unavailable.
The action waits for its owner's actual reply. If it never answers, observation stays open with cancellation available.
Cancelling that wait returns the retained `run_id`; the owner's later result records that same run. Silence establishes no outcome.
No run-now action waits for a future source event or for a readiness gate to
open: those cases return their current decision. Actual work still uses its
ordinary I/O/provider bounds and settlement.

Scheduled jobs have no run-now sibling: an early run would consume the job's real occurrence.

`NativeCognitionRuntime+Deadlines.swift` drains dirty events through one running microcycle and a dirty follow-up, without a delay,
and owns declared maintenance and residual-pressure time boundaries. Busy maintenance is reprojected by the admitted pass's settlement;
failed maintenance remains reported until an explicit request succeeds, without clock retries. Organism continuity drains on request and write
completion, coalescing changes during a write without a trailing clock;
continuous decay is projected at read time. App assembly
retains daily maintenance and replay registrations as recovery
sweeps; reflection runs from dream and replay evidence (`EngineRuntime/EngineLaunch.swift`).

Canon and horizon source observations register before their first read
and stop with the runtime. Canon watches journal inputs and archive membership;
audit output is excluded, and directory events invalidate it only when input
stamps change. Failed child enumeration leaves arming unavailable with repair
owed; the parent membership watcher stays armed, and a source event or relaunch
retries it. Automatic canon passes retain their 30-minute I/O limit; horizon
source changes coalesce behind its retained refresh without a minimum interval.
Outside an explicit run-now request, unchanged sources are reread only at real
silence, expiry or cooldown boundaries on the existing residual deadline.
Quiet-hour preferences follow file/clock invalidations. Clock invalidation
follows organism configuration so concurrent reads cannot erase it.
Unrelated home-directory events with unchanged input stamps do not request scans.
The composite body evidence read retains its two-second sampled cache because
its host/transport gauges have no complete shared push owner. Daily integrity
sweeps remain.

Reflection has an enable switch, an in-flight reservation and a rolling
24-hour call ceiling. Dream and replay supply its evidence; there is no daily
reflection registration, spontaneous-demand gate or same-material cooldown.
The retired `cognitiveSubstrateReflectionLoadThreshold` preference has no reader;
any saved value is left untouched and needs no data move.
One checked `cognition_reflection` model/account/Think/Fast tuple binds execution
and receipts, without ambient picker or Chat inheritance; dispatch rereads authority.
Its receipt and Observatory identify affected cares alongside estimated
tokens and cost. The proposal-yield metric is removed; retained SQLite
`proposalIds` entries contain care UUIDs and use that one existing key.

Body posture does not throttle work; fatigue and heat color presentation.
Reflection also obeys the
[shared work-slot admission](COGNITION_WIRING.md#shared-work-slot-admission).

### Speaking unasked

A thought's own words stay in the mind stream; to tell the person, the thought acts (`app chat.post`).
Speech shares locked claims and destination reconciliation in `ProactiveAssistantSpeech.swift`,
without an hourly quota; notification routing keeps the person's quiet hours
(`AttentionRouting/AttentionRouter+Policy.swift`). The [post contract](TOOL_LOADING.md)
owns deduplication, routes and exact-call approval. A MY QUEUE
step's fixed words (`say`) land in the current conversation between turns through `speakProactively`, followed by the neutral
shoulder tap "Left you something in chat. No reply needed." (`NativeCognitionRuntime+Pursuit.swift`), which carries none of the
words; words that could not be said stay due, never turned into a thought.

### The hour

On a committed away edge during the person's active hours (the current rhythm bin's observed active share is at least 0.5),
the hour switch permits one `self` happening per local day: subject `hour`, door `sense:hour`.
`NativeCognitionRuntime+StudioWander.swift` re-reads presence and the switches before posting. Unknown presence or an unobserved
hour supplies no opportunity; an unreadable source names its repair. The record's daily happening identity owns admission across restarts.
There is no hour clock, quiet wait or refractory.

Enable the hour switch in Setup (`Sources/NativeAgentApp/SetupView.swift`);
`studioWanderEnabled` defaults on (`StudioWanderLane.enabledByDefault`) and requires Subconscious. Configure its
provider/model under **Providers → Memory and mind**, which owns **Creative
exploration**. `Cognition/StudioWanderLane.swift`
enforces explicit enablement, the Subconscious master, and onboarding clearance
for public-safe builds in `resolveInstallation`.

The line carries `rest` and their curiosity. The seed gives it worth `2 * curiosity * learned`, where
`learned = min(1, (yield.hits + 1) / (yield.tries + 1))`; absent curiosity contributes no worth.
Worth gathers on the hour's subject through ordinary attention. Its settled `hit` and `empty` thoughts teach that same node
and door; `withheld` and `failed` do not teach yield. Their installed `weigh` changes only by their own hand.

An ignited thought carries the opportunity and the hour's offered cares, unanswered consults, graph works and recent journal titles.
Empty material permits exploration or silence; unreadable sources remain named beside what could be read.
If the required opportunity owner or prompt cannot be read, no turn opens and no thought outcome is recorded.
The named repair retains the happening ids; owed obligations stay open, and the existing failed-thought return restores drained drive with
its original happening membership. A later landing or attention opening can reclaim that hour line; no clock or substitute thought retries it.
It runs in the mind stream through ordinary turn admission, Trust, tools and settlement, retaining its Creative exploration model route.
There is no separate wander model call, action allowlist, outcome file or hour flight. The thought's ordinary tool receipts connect any
`studio.journal` write to that turn, including writes before failure or Stop; nothing is journaled automatically.
Successful journal appends, factual amendments, consult filings and shelf replacements declare `effects: occurred` at their write owner.
Attention counts those receipts through the shared effects field; an entry id or successful read alone does not make a thought a hit.
A returned `still wondering:` question settles through the care owner's checked generation with the thought as its source.
This save runs through `settle` before outcome judgment, including returned output on Stop. Its checked success means a new or continued care
was saved from this thought. On completed turns that care effect or an occurred tool effect records `hit` under the thought's existing class
and door, so the hour's own yield learns it without requiring a thought on the care's anchor. Other care changes supply no such credit.
A failed care save owes repair against the retained thought rather than rerunning its model call; without another proved effect it records
`failed`, supplying no empty try. No returned question supplies no care effect. Stopped or incomplete turns retain their failed outcome.
Desk reads the hour's latest thought from the same experience record that attention reads for yield.

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
reads, alongside organism, affect, context and Desk state. Its counters
describe state; they do not establish consciousness, behavioral benefit or
provider agreement. The count-based experiment ratings, research checks panel
and research exports are retired.

## Where to verify

These diagnostic and recovery paths are relative to `<dataRoot>`:

| Path | Contents |
|---|---|
| `cognition/organism_state.json` | Persisted body state and organism continuity |
| `experiences/experiences.sqlite` (details `caring.appraisal`, `caring.dosing`) | Caring appraisal receipts and the body's dosing response, each a detail of the appraised turn's heard experience (`Turn.id`); a failed write retains receipt-only repair debt, without replaying the feeling or dose |
| `experiences/experiences.sqlite` (`happening` subject `hour`, `thought` through `sense:hour`) | The hour's opportunity, its thought and the turn evidence linking its journal actions |
