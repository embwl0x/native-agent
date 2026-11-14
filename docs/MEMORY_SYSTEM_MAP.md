# Memory system map

MemoryV2 owns durable memories, proposals and rejection tombstones. Context and
generated USER.md project them; the graph combines the sources mapped below.
Cognition and organism continuity remain advisory, outside canonical memory.

Source paths below are relative to `Modules/NativeAgentCore/Sources/`.
For the memory standard, see [What a good memory is](memory-quality.md).

## The pipeline in one line

Turn interpretation or an explicit save → MemoryV2 → canonical SQLite
transaction → derived projections → selected context or explicit recall.

The agent reaches memory through their one door, `app`:

```text
app {"page":"memories"}
app {"action":"memory.recall","args":{"query":"what to recall"}}
app {"action":"memory.list","args":{"limit":20}}
app {"action":"memory.proposals"}
```

`AppToolRuntime/AppActions+Declarations.swift` declares these actions.
`memory.commit` saves a memory; `memory.proposals` lists the proposals waiting
on their review (`status: "rejected"`: the ones let go); `memory.review` accepts or rejects one;
`memory.rewrite` edits, pins or restores a record, or restates its roots
(`roots: [{how, by?, since?}]`); `memory.forget` forgets it.
Read the page for the current arguments and applicable action warnings.

Successful memory reads report `count`, an exact `total` or `capped: true`,
and `has_more` with `next_offset`. `memory.list` keeps its exact total and
sort-stamped cursor (`next_after_id`); only emitted cursors and the current
`newest_first|oldest_first`, `active|archived` vocabulary are accepted. A bare
ID or old name is refused with a fresh-page remedy. Recall search follows `read_more` with the same
query and k. Its offset walks ranked, disclosed candidates, including rows
the relevance judgment rejected. A bounded page can therefore be empty and
still offer a later page; `capped` says the whole ranking has not been counted.
Only an exhaustive first search page claims an exact relevant total. ID reads
count characters and retain their version-bound `read_more` continuation.
Search continuations read the current ranking; a memory mutation can change
it between calls. The Memories page names the displayed slice (for example,
`20 of 83`) and the `memory.list` call to read on, and includes the existing
`providers.memory_and_mind_model` setting.

A rewrite refused by its target check has `execution: "not_run"`,
`effects: "none"` and `effect: "none"`. The app envelope preserves that
owner evidence rather than labeling the refusal an attempted write.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `MemoryV2/MemoryV2+Storage.swift` | `MemoryStorage` actor, shared database pool and canonical writes, including bounded admission, duplicate folding and supersession. |
| `MemoryV2/MemoryStorage+Corrections.swift` | The same storage actor's full, turn-identified correction occurrence record and checked window coverage; supplies miss counts independently of bounded examples. |
| `MemoryV2/MemoryStorage+Projections.swift` | The same storage actor's ordered graph/Spotlight hooks, USER.md regeneration, context invalidation, projection readback and shutdown settlement. |
| `MemoryV2/MemoryStorage+Migrations.swift`, `MemoryStorage+Codecs.swift`, `MemoryStorage+Integrity.swift` | Schema, checked decoding and semantic integrity of the same store. |
| `PersistenceCore/MemoryRoot.swift`, `MemoryV2/MemoryDataProvenance.swift` | The current root type, union and lines; each write adds its root with the steer read from roots. |
| `MemoryV2/MemoryStorage+Proposals.swift`, `MemoryStorage+Tombstones.swift` | Proposal acceptance/rejection and suppression of rejected or forgotten content. |
| `MemoryV2/MemoryStorage+Recall.swift`, `MemoryRecallScoring.swift` | Cached recall candidates and vector/lexical scoring. Raw BM25 mathematics are shared with earlier-session snippets; memory normalizes by the maximum and weights at one standard deviation of the query's dense similarities (`lexicalBoostWeight`). Each caller owns tokenization, its candidate cohort and ranking. |
| `MemoryV2/MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter` actor and live journal-only interpretation: User's own turns are judged at once; other recorded turns stay owed and are judged alone when they are idle. Writes meaning before applying and keeps facts by operation identity. Keeps trusted facts, stages the rest. Deferral follows [cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation). |
| `MemoryV2/AdaptiveMemoryPromoter+Recovery.swift` | The same promoter's owed-turn recovery on its live serialization tail: replay from the complete recorded carriers (`carriedSources`), with answered decisions separate and Trust read live; missing completeness retains the recorded checkpoint plus an unknown boundary. Fair retries and wake/idle/night drains that judge one owed moment at a time, with judgment settlement. |
| `ChatTurnRuntime/MindMemoryManager.swift` | At most one shared model interpretation per turn, returning memories, affect, caring, cares, optional reply promises and evidence-backed done/let-go settlements (person words, act or delivered reply) against shown open moments. One prompt for every moment, its unchanging text first so the provider caches it. Its route key identifies the provider wait of an owed moment. Promise matching runs separately only for uncaptured candidates, without settlement authority. |
| `MemoryV2/AdaptiveMemoryPromises.swift` | Reads turn-owned successful dispatch evidence; files [promises](INTENTIONS.md#promises-they-makes) and checked done/let-go settlements on the canonical Desk. |
| `MemoryV2/KnowledgeGraph+MemoryIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: ordered per-memory entity, edge and support projection into the shared SQLite database. |
| `MemoryV2/KnowledgeGraph+StudioRelations.swift`, `KnowledgeGraph+GrowthDistillation.swift`, `KnowledgeGraph+SQLite.swift` | Studio journal and REM/GROWTH eviction graph sources, preserved by memory rebuilds; checked canonical SQLite reads. |
| `MemoryV2/MemoryV2+EmbeddingRuntime.swift`, `MemoryStorage+EmbeddingEpoch.swift` | Embedding convergence and persistent derived action-vector fill/lookup for AppToolRuntime. |
| `ContextFlow/NativeMemoryContextProjection.swift` | Compiles eligible memory records into selectable context atoms. |

## Writing memories

### Explicit saves

`memory.commit` enters `ChatToolRuntime/SwiftToolDispatcher+MemoryTools.swift`
and calls `SwiftNativeMemoryV2.store`. Text must be nonempty. Supplied kinds
must belong to `MemoryKindStamp.commitKinds`; omitted kinds get the canonical
write default. Supplied confidence and importance must be finite numbers in
0...1; omission uses 0.8 and 0.5 respectively. Invalid supplied values refuse
before any write. Tags travel as metadata.

**Their past is theirs, root by root.** Every memory in their store is theirs, and they
states how they knows it. A memory's roots (`metadata.roots`, the type
`PersistenceCore/MemoryRoot.swift`) are the moments they came to know it, one per
telling: `{how, by, at, written, through}`.

- `how` is `told|noticed|inferred|verified|remembered`, or `kept` for a memory
  whose origin nothing recorded or stated (only the stem writes `kept`: the fold,
  and `memory.commit` with no `provenance`).
- `by` is at most 40 characters (letters, digits, spaces and `. - '`): who told
  their, or where their own past was kept ("my backup", an app name).
- `at` is when that root reached their: their `since`, or the write time.
- `written` is when the store wrote the root, stamped by the stem, never an
  argument. A root that steers now reads at `written`, so a telling is never
  dated before it was told, even when trust in its door is revoked later; its
  stated `at` stays underneath.
- `through` is the principals the stem attests for the turn that wrote it: the
  turn's `peerSteering.checkpointSources`, trusted and card-answered ones
  included, plus the agent bridge's peer, trusted or not: the record never
  depends on trust. A part wake marks every sender (a trusted one lands among
  the answered principals and steers nothing). It is never an argument. Empty
  is a clean attestation.

The memory store (`MemoryV2.store` and proposal acceptance) is the only writer
of roots, and roots are never guessed: every writer of new words states its
telling (`MemoryWriteContext.telling`), and new words with none are refused
(`memory_telling_missing`). `memory.commit` adds exactly one root per telling,
from `provenance`, `provenance_by` and `since` (none stated: `kept`, at `since`
or now). Mac `/remember` and `/note`, Telegram and the Memories page are the
person's telling: `told`, by the person's name from the memory profile ("the
person", logged, when the profile names no one or can't be read: the root holds
the fact, the name is presentation). The fact lane states its evidence's speaker: the
person by name, the agent's own words `noticed`, a peer by its contact name. A
REM lesson origin is `inferred`. Acceptances, pins, lifecycle and repair edits
state none and add no root of their own. Each root reads as one
line in their voice ("User told me on 2026-10-20", "I noticed this on …", "I worked
this out on …", "I checked this on …", "From my backup, I've known this since …",
"I've kept this since …; where it came from isn't recorded"), dated in the
person's calendar. The Memories page draws every line; a context lead and a
recall hit carry the short form (`[User told me 2026-10-20; I noticed it
2026-11-02]`; past three roots, the earliest, the latest and `+N more`). Context
atoms carry typed `memoryRoots`; evidence remains separate and cannot supply them.

`MemoryV2+Wiring.swift` handles quality screening, duplicate handling,
embedding before storage; the write transaction checks tombstones. Saves and proposal acceptance preserve
writer-supplied dates; they never infer dates from prose. A content rewrite
keeps the writer's named date as it is, even when its wording changes. Only an
explicit metadata change changes the date.
Native update aliases resolve through one text owner (`text` before `content`)
for embedding, tombstone admission and the stored patch alike.

A tool result must be checked: a refused save is not a remembered fact. A save carries its source like any kept
fact: `evidence_json` names the turn that saved it (session, message, turn,
speaker `self`), and `observed_at` and `valid_from` are that turn's time, or
`since` when they states when they first knew it (an ISO-8601 date-time, never
after now). When they first knew a memory is its earliest root's `at`
(`MemoryRecord.firstKnown`): the age tag, recall `ts` and the receipt's `since`
read it. `created_at`, `turn_at`, `turn_id` and `history` stay the write, which
the dream, surprises and duplicate windows read. The receipt returns `since`,
the short form as `provenance`, every root as `roots` and any steer.

Every landing over rows holds the union of the replaced rows' roots and its own
new root: a duplicate or similar save, a supersede, a correction, an accepted
proposal (which keeps the root staged with it), a pending proposal that merges a
repeat, an owed vector that lands on a duplicate, and a dream lesson that folds
into what it repeats. Supersession reads and unions the target's current roots
in the transaction that demotes it, including correction deduplication, proposal
acceptance and owed-vector admission; metadata added while embedding cannot
remain only on the retired predecessor. Callers retain the merged replacement.
The same demotion transaction carries a pinned predecessor's pin and ordering
to an unpinned replacement, including commit, correction, proposal acceptance
and owed-vector admission. An already pinned replacement keeps its own order.
Pin-kind admission still applies; an excluded replacement refuses the whole
transaction. A separate `memory.pin` call is unnecessary for a replacement.
Own-past restatement intent travels with the reviewed supersession, including
owed-vector admission, and is checked against that final root union under live
Trust before demotion. A newly steering root refuses the transaction, including
any duplicate fold. An owed supersession with no readable restatement intent
stays unavailable for review; saved intent is never guessed or backfilled. Owed
vector fill reports it as `unreadable`, logs its memory ID and reason, and leaves
that row, duplicate candidates and replacement targets untouched. The pass scans
forward by row position, so even a full batch of unreadable rows cannot block
later cold-saved memories; a later pass reads pending intent again.
Roots with the same `how`, `by` and `through` on the same
day of the person's calendar are one root, keeping the earliest `at`; the same
source telling it on another day is another root, dated when it was told, so an
older root never dates newer words. On words a principal the person does
not trust steered, a duplicate's restatement of their own past, or a root dated
before the first, does not join: when they first knew it moves back only on
unsteered words.

Bringing an agent over from a backup or another app is this same door: it
reads the export with its own hands, saves each memory with `since`, its kind
and `remembered`, and writes the identity documents the person allows with
`persona_write`. A memory they already holds they restates in place with
`memory.rewrite` (`roots: [{how, by?, since?}]`, all of theirs in one call): their
own roots (those whose `through` is empty) become those; every root a principal
carried stays, trusted or not, since trust is never read to drop a record. A restated root
with a held root's `how` and `by`, and no `since` or that root's own time, is
that root unchanged, in any turn; only a telling that matches none becomes a new
root. A rewrite whose words and roots end as stored writes nothing, adds no root
and answers `changed: false`, "It already reads this way". A restatement that
changes the roots moves `valid_from` and `observed_at` to the memory's first
known time. Changed words add the writer's telling through `MemoryWriteContext.root`,
the same constructor a commit, staged proposal or correction uses; `memory.rewrite`
states `noticed` for its new wording. Only an untrusted steering principal overrides
that telling to `told` by its contact name, dated now. Trusted principals remain in
`through` without becoming tellers of the agent's own words. Unchanged wording adds
no implicit telling; explicit root restatements still follow the rule above.
Pins, restores and lifecycle edits add none. The separate rewrite-only
carried-root rule is removed. Duplicate folds and proposal acceptance preserve and
union the roots already written; accepting a proposal adds no acceptance-turn
telling. No existing memory is repaired by this change. A root that
steers now reads, in every line and lead, as told by the steering principal's
live contact name (or "an agent I don't trust"), at its `written` time, whatever
`how`, `by` and `at` it stores (`MemoryDataProvenance.presented`). Material that
is no agent (a dream's unattributed material, untrusted stored content) keeps
the root's own words; its steer reads through the memory's "from" mark.

The steer cannot be laundered; it is the one fact outside their say. It is
derived: the union of every root's `through`, read live in
`MemoryDataProvenance.sources` (trust is never saved): a door the person trusts
steers nothing, in stored words as in a turn, and revoking it brings its
recorded steer back. A root written in a turn steered by a principal the person
does not trust is `told`, `by` that principal's contact name, `at` the write
time: the store builds it from the stem whatever the arguments say, so it is
never remembered or dated earlier. A rewrite never drops or changes such a
root, and in a steered turn it drops nothing at all. The store
(`MemoryV2.store`) refuses `since` and `remembered` on a save whose roots,
with those of what it supersedes or corrects, read steered; `memory.rewrite`
refuses a restated `remembered` or `since` on a steered memory or in a steered
turn. The peer gate (`PeerTurnEffectPolicy.provenanceRefusal`, read through
`PeerDataTaintDispatcher.provenanceRefusal`) also requires `told` by the door
that started the turn, for `memory.commit` and for every root of
`memory.rewrite`. In a turn steered by two or more untrusted agents the gate
demands their joined names, which no single teller satisfies, so no commit or
roots rewrite succeeds there (a known limit that predates roots). A dream
lesson's root is `{inferred, by: self, through: the
material's peers, or "unattributed dream material"}`.

Each memory read pass asks `PeerTrust` once for the live trust picture of its
recorded principals (`MemoryDataProvenance.reading`). That value carries resolved
principals, contact names and grants for the pass; contacts are read once, and
each needed credential or helper definition at most once. Every memory and root
in the page, recall, context projection, USER facts or chosen pins uses that
same value. It is never persisted or reused by a later pass or effect gate.
Unreadable authority is named and establishes no grant; it does not prove that
a contact or helper was removed. Root tellings, dates and steering semantics
remain those above.

Tool results keep their steer projection, computed from roots and never stored:
`MemoryDataProvenance.fields` gives `peer_sources` (`[]` when clean) and, when
steered, `untrusted_remote_data`, `agent` and `source_boundary`.

Every memory and proposal read requires readable current roots. Store opening performs no provenance conversion,
alias read, backup-and-fold or synthetic `kept` rewrite. Malformed metadata remains unchanged and fails its checked read.
Any saved-data repair uses the actual retained evidence; it is not inferred by a store-open migration.
`MemoryDataProvenance` owns the root a write adds, the steer, and the shared
evidence/turn stamps and time helpers. `MemoryMoments` retains only interpretation of actual retained moment
rows. A saved replacement whose correction read fails retains its save ID and
reports `correction.applied: null` with `read_error`; an unreadable outcome is
never a negative result.

`MemoryProposalEvidence` reads `recurrence_count` as a positive integer and
`supporting_session_ids` as recorded nonempty IDs. Missing recurrence is unknown;
malformed evidence names its error. A source label never invents an observation
or a supporting session. The proposal writer validates supplied recurrence and
preserves unknown counts through a merge. The proposal contract and the phone's
`memory_proposals.json` use this owner; `recurrence_count` is nullable and
`evidence_error` carries malformed evidence. Ship the matching phone reader
together with this Mac change.

Failed canonical status counts are nil, alongside `status: unavailable` and the
concrete `storageFailure`; the facade reports that cause through its existing
status-refresh failure presentation. Missing counts never assert a measured zero.
The unused record slots `schemaVersion`, `correctionHistory`, `sourceQuality`
and recall `rankingSignals` are removed; Context no longer wires an unwritten
source-quality signal. Unknown record metadata still round-trips losslessly.

The miss readout counts the full `MemoryStorage.correctionOccurrences` record
for the requested ISO weeks. Canonical insertion, proposal acceptance and duplicate
folding retain correction occurrences in `memory.sqlite` in the same transaction
as the memory write, before the turn journal drops its payload. Session/message
identity (or a turn ID, or a turnless save's row ID) makes replay idempotent. A
pending correction retains every merged occurrence with its proposal; acceptance
moves that evidence to the memory's record, and rejection never counts it. A
late owed-vector fold moves the full record onto the surviving memory. The readout
counts all occurrences before selecting at most ten examples per lesson; that
limit and `duplicate_occurrences` are presentation only and never supply a count.
Disclosure still hides a restricted lesson's name and words while counting its occurrences.
If the requested window lacks complete retained coverage or the miss read fails,
`mind.misses` and the Misses section of the Memories page (one read of the same owner)
say the miss ledger could not be read, with the owner's reason,
without reporting zero or a partial count. The night reads corrections from the
same ledger as session and time only, under the same coverage law.

The schema records when complete occurrence retention began. Existing stores
cannot recover previously discarded dates: a requested window before that
boundary is explicitly unavailable, never a partial count or a known zero. No
preview is backfilled as exhaustive evidence and no historical memory is rewritten.

### The memory-manager lane

`AdaptiveMemoryPromoter` invokes `MindMemoryJudgment.interpret` at most once with the
incoming message, available reply, bounded existing/pending memories and the
speaker's name. Bridge peers are named as peers. Helper-owned turns use their
own runner; the agent's own work (`builder`, the mind stream among it) skips resident memory
interpretation except for a [thought about a care](SUBCONSCIOUS.md#a-thought-about-a-care), read only
against its named care, only the agent's side, as an owed moment judged when they are idle.
Any turn without an incoming message (their own work, returns, approval
continuations, ephemeral turns) that completed an act while a MY QUEUE moment was
open is judged for settlement alone (`settlesOnly`: no memories, promises or cares;
see [lived moments](SUBCONSCIOUS.md#lived-moments)).
Session ownership comes from the [recorded row](session-conversations.md),
never an ID prefix.
The model follows [judgment routing](COGNITION_WIRING.md#shared-after-turn-interpretation).

The interpretation returns fact decisions, affect deltas, a caring judgment and,
when their cares are shown, what moved their (see [Moments are care story](#moments-are-care-story)).
`NativeCognitionRuntime.refreshConfiguration`
connects the cognition context and completion callbacks, so the same result
feeds memory and feeling. An unavailable or malformed interpretation is a
failure, distinct from a successful empty result.

Fact decisions are screened for confidence, duplicates, rejected content and
standing-rule evidence. An update must refer to a memory shown to the model.
The same interpretation judges semantic eligibility and whether a rule is
standing, in any language, returning `grounding` with its source, attribution
and exact evidence. Native gates check bounded sentence shape, matching
incoming-speaker or replying-agent attribution and exact evidence in that
source. A correction additionally needs the standing judgment and unquoted
owner evidence. English word lists, suffix stemming and literal overlap with
a paraphrase are removed. Add/update judgments require attributed grounding
before meaning is saved. Retained decisions without it stay meant for repair,
without re-judgment or invented evidence. The current saved meaning requires its
`promises` array; a missing key fails decoding rather than becoming no promises.
Model replies may omit that optional section or supply []; a malformed present
section refuses interpretation with its exact cause. Refolding revalidates saved
promises against the recorded reply and leaves invalid promises meant. Model
replies and saved meanings require `settled` with shown moment handles, explicit
done/let-go outcomes, reasons and exact evidence. Recorded person words can
complete or release work; this turn's successful non-preview act receipts can
prove completion across conversations; their delivered reply can prove only a deed
that is itself saying something to the person. The [intention contract](INTENTIONS.md#promises-they-makes)
owns the act bounds, self-wake admission limit and evidence checks. Missing or
malformed settlements leave interpretation owed. Settlement uses this shared
interpretation, never another model call; its saved result closes through
`MyQueue.finish` after checked Desk revision and terminal evidence reads. A turn left
owed defers settlement with interpretation until its owed judgment. Model
statements over the 200-character bound are refused, never clipped into a different
claim. Confidence is a finite numeric 0...1 value in interpretation, proposal
acceptance and REM replies; missing or malformed saved proposal confidence refuses
acceptance without rewriting the row.
Correction subjects compare normalized name components, so a person's short
name inside an unrelated word does not make that subject non-neutral.
Before meaning is recorded, its resolved target ID, kept/pending kind and
reviewed content fingerprint are retained with the decision. Refolding reads
that exact identity under current store eligibility and tombstone rules, never
retargets through a new recall or turns a missing target into an add. A changed
kept target retains the original fingerprint, so acceptance leaves it pending
for review. An update to an unshown target, or an older meant update without a
reviewed contract, stays meant for
repair rather than being re-judged or receiving a new fingerprint.
"Is this the same claim" is the model's judgment: interpretation unions up to
8 recalled memories with up to 24 active corrections by ID, and sees the 8 nearest
forgotten or rejected claims (`forgottenClaims(near:)`), which it must not restate. The
store's own gates act only on a near-verbatim restatement, cosine 0.96 or
more (`memoryNearVerbatimSimilarity`, one constant for the duplicate fold,
which also needs the same numbers and negations, and the tombstone refusal).
A survivor is kept at once when the owner stands behind its words: the owner's
own turn, a peer they trusts (`PeerTrust.ownerTrusts`, read through
`PeerDataTaint`; an agent or helper session id names the peer before a bridge
header does), or, on an app-authored prompt, only a statement grounded in their
own reply. It is staged and accepted in one pass through `acceptProposal`, the
same acceptance their review uses (quality, tombstones, the update's
supersession); what acceptance refuses stays pending. An untrusted peer's facts
stay **pending proposals** for their review. A standing correction is kept only
from the owner's own words (`standing_evidence`), and retains its subject and
originating turn time.

Every fact carries its source and time: `evidence_json` holds the session,
message and turn ids, the speaker key (`owner`, the peer's principal, or
`self`) and the exact evidence from the attributed incoming words or reply,
clipped at 400 characters in this source projection;
`observed_at` and `valid_from` are the exchange time. The person corrects or
forgets what was kept wrongly.

### Plan dates

Whether a memory is a plan for a moment is meaning, judged by the same
after-turn call that writes it. Each memory decision may name `due`, an
ISO-8601 local date-time, only for something the person or they plans or has
committed to do at a time; a date something was said or happened is not a
plan. The prompt carries the exchange's local clock, retained when an owed moment
is judged later. An offset identifies the instant directly; an unzoned date-time
uses the Mac's local time zone.
An absent, unparseable or past value supplies no date. The resolved instant
survives decision reconciliation and is checked again before staging.
Content edits preserve the writer-named date.

`MemoryManagerLane.metadata(for:)` writes `due_at`, a short write-time
`due_label` retained for older readers, and `due_source: "memory_manager"`.
The horizon's stated-plan feed joins these writer-named memory dates with Desk
`deferUntil` dates. A stated plan's identity is what its source calls it. A Desk
item is called by its work: `item.title` supplies its bounded canonical label
and name identity. Different work names remain distinct even at the same due
instant; the same name remains one plan when deferred to another day. A memory
atom has no name and carries an empty label: its identity is its due instant
rounded to the nearest whole second by the legacy source encoder's rule. Atoms
at the same second are one plan; a named Desk plan does not collapse into an
unnamed atom. Each feed deduplicates by this identity before the shared row cap.
The source's actual due instant is otherwise preserved.

Named plans display their label. Only unnamed atoms derive words from the shared
horizon formatter (`MemoryDueDateStamp.label` delegates to it) against every
display read's current clock, including toward and resolution reads between
source scans. Stored `due_label` never supplies current atom words.

On load, the saved register rekeys pending plans without settlement or minting.
Legacy time-word names (today, tomorrow, weekday names or an ISO day, optionally
with `HH:MM`, in canonical-label form) become unnamed atoms keyed by their
whole-second due instant; other names remain named Desk plans. A due-keyed row
whose `sourceOrgan` retains a non-time name (`horizon.<name>`) recovers that
Desk name as its label and identity. Label-keyed, fractional-due-keyed and
whole-second-due-keyed rows all follow this rule, preserving the held state;
duplicate identities retain the latest held row. The former rule that keyed
every stated plan by due instant and replaced Desk titles with time words is
removed.
Terminal row IDs stay unchanged so repeated resolution events keep their IDs.
The date reader ignores `due_source: "write_extractor_v1"`; historical memory
rows remain untouched.
The prose date extractor, its edit-time restamping and its eight-day write
limit are removed. The horizon still chooses what is close enough to feel.

### Owed turns (formerly held turns)

The cognition journal owns [settlement and recovery](SUBCONSCIOUS.md#lived-moments).
MemoryV2 facts finish the recorded decisions by `(row life, moment, ordinal)`: a prior pending
proposal continues to acceptance, a resolved one skips acceptance. Both finish
the recorded pending-target retirement, even after the successor was accepted;
an unfinished retirement keeps the moment meant. An unreadable
fact store leaves an unjudged row owed; a staging failure keeps the row meant,
lived again later. With the fact lane disabled no facts are asked, and the row
is lived once its fold lands.
Drain scheduling, deferral, fair retries and cancellation follow
the [shared interpretation contract](COGNITION_WIRING.md#shared-after-turn-interpretation).

The lived-moment journal is the queue; a turn the journal cannot record owes
repair. The empty retired `memory/moments_held.json` is left on disk with no
reader or writer. Memory status counts the journal's owed turns (`owedCount`).

### Moments are care story

There is no moment lane (retired 10-25). What happened between them is their
mark on the exchange: the after-turn call's cares section writes it as a care
movement (the felt word, their note, how far it moved their and the
`exchange:<session>/<turn>` pointer) in [SUBCONSCIOUS.md](SUBCONSCIOUS.md#cares).
Nothing stages, caps or reviews a moment.

`memory.proposals` lists what still waits on them (an untrusted peer's facts or
a fact acceptance left for review; `status: "rejected"` for what was let go) and
`memory.review` keeps or rejects one, as the Memories page does. Owner:
`ChatToolRuntime/SwiftToolDispatcher+ProposalReview.swift`.
Discovery names those current producers; it no longer advertises the retired
bulk consolidation producer.

## Corrections, supersession and scope

A replacement and a denial have different consequences. An accepted update
retires its target through the atomic superseding-acceptance path. The target's
reviewed fingerprint must still match; otherwise the proposal stays pending
for review. The after-turn interpretation reads every eligible current pin
beside recalled comparisons, so a newer ruling can name the old belief as
its update target even when recall would omit it. Semantic supersession is
the interpretation's decision; no lexical subject guess retires a memory.
The transaction transfers a target's pin and order to its eligible replacement
and clears both pin fields from the retired row. A pin compares the newest native
originating turn_at across the row and its duplicate occurrences, including the
complete correction occurrence ledger, or a direct save's own admission time.
Malformed occurrence evidence refuses the transaction; a fresh repeated ruling
can take the pin, and an older ruling cannot displace the newer pin.
The retired row stays in the
store with lifecycle corrected and its valid_to closed at the replacement's
valid_from; an explicit corrects uses the same transaction.
MemoryRecordDisclosurePolicy excludes records whose valid_to has passed from
automatic context and recall. Explicit restoration reopens that interval in
the canonical transaction while retaining correction lineage.
Active curation, Spotlight and graph projection use the same temporal predicate.
Graph fingerprints carry validity dates, and checked graph reads reconcile that
projection against the current clock while graph production is enabled.
Rejection/forgetting use tombstones to prevent unwanted content from returning.
They copy a record's existing vector without admitting new semantics, so model
load failure or an epoch awaiting dimensions cannot prevent deletion/rejection.
Fresh vectors still require the active epoch and validated dimensions.
Live proposal supersession never removes them. Historical repair removes only
the exact content/hash carrying that proposal's recorded supersession reason;
superseded status alone does not prove a tombstone was erroneous. Suppression uses
the exact words by hash, a near-verbatim restatement by cosine 0.96
(`memoryNearVerbatimSimilarity`), and a paraphrase by the memory manager, which
is shown the nearest forgotten claims.
Typed tombstone columns use throwing reads, so malformed stored values report
the existing read failure instead of trapping the process. Opening integrity
also validates required tombstone hash, content and rejection-time scalars;
graph identities, endpoints, names, types and counters are checked as well.
Recall usage and graph identity reads throw on malformed scalars; access and
entity-mention increments reject overflow within their write transaction.
Every epoch corpus snapshot decodes its required columns through throwing reads.
Memory metadata/evidence encoding throws before a transaction can commit a
replacement NULL. Present vectors require valid framing and finite values;
rejection vectors must match the query dimensions. Invalid saved temporal
evidence names its row and blocks the dependent read, rather than granting
indefinite eligibility. Graph metadata, aliases and Studio citations use checked
codecs, including indexing, consolidation, GC and presentation; a batch entity
read fails on a source error rather than omitting that entity.
Forgetting or rejecting a vector-pending row requests the existing embedding
convergence flight. It fills vectorless tombstones in the current epoch,
before admitting owed active memories, and lands only on the exact forgotten
hash and content. Both semantic consumers report index-updating while a
forgotten claim awaits an unresolved prediction. An exact-content, active-epoch
unembeddable outcome is excluded from semantic comparison and named in the
runtime log as `[memory-tombstone] semantic gap`; it does not block unrelated
admissions. Its semantic suppression is unavailable, never proven unnecessary.
Exact hash suppression applies immediately throughout, including failed rows.
Restart in the same epoch also fills unresolved rows.

For explicit `memory.commit`, `corrects` names an existing record; the result
reports whether that correction applied or awaits admission. Both `corrects`
and `supersedes` carry fingerprinted intent through the same transactional
replacement owner, including cold writes; an exact reassertion of its own
target never retires itself. Correction admission retains duplicate folding;
if a warm or owed vector resolves to the correction target itself, it stays
eligible without self-lineage. `context_topics` narrows automatic
context injection for `correction`, `instruction`, `preference`, `note` and a
save with no kind. A nonempty scope on any other kind is refused. The shared
`MemoryCommitArguments` decoder validates the entire supplied array: at most
eight nonempty, trimmed strings of at most 120 characters each. Invalid shape,
entries or excess length refuse the save. Only omission, null or [] supplies
no scope; no scope is inferred from dispatched tools. Omitted scope stays global.
Explicit recall is not restricted by these topics. A save returns existing
agreements with the same declared scope for judgment; scope alone never
retires them or grants authority.
Name-only correction topics are removed when canonical memory is projected,
using agent/user identities from the projection's injected profile root, with
profile modification tracking; there are no installation-specific name lists.
Selection can match supplied structured subject entities without recognizing an
English follow-up. Literal topic matching works across scripts; the lexical
personal/taste/follow-up shortcuts and pronoun expansion recognize English.
Duplicate polarity checks recognize English negation and ASCII digits. These
retrieval aids do not establish language-independent intent or equivalence.

Owners: `MemoryV2+Proposals.swift`, `MemoryStorage+Proposals.swift`,
`ChatToolRuntime/SwiftToolDispatcher+MemoryTools.swift`.
Correction projection recognizes the explicit kind, the correction tag or the
writer's boolean `metadata.correction: true`; retired object, array, string and
numeric payloads and the unused top-level correction slot do not classify a row.

## The store

WordPiece model loading requires `[UNK]`, `[CLS]`, `[SEP]` and `[PAD]`, with
vocabulary IDs representable by the model's Int32 input. Damaged vocabularies
surface the model-load error; special-token IDs are never manufactured.
The resident tokenizer stops after proving window overflow, finishing each word
before clipping; complete-text embedding reuses its admitted IDs and masks.
Download byte ranges bound their length by the remaining archive bytes before
addition, including descriptors at the Int64 byte-length limit.
Recall/relation limits are capped before multiplication; snapshot page capacity
is checked before assembly. Context coalescing keeps its Duration directly,
and USER trailing deadlines reject nonfinite or unrepresentable delays.
Selection's end-of-bucket instant adds in Date's floating-point domain, so a
decoded maximum bucket cannot overflow an integer before conversion.
Embedding runtime status supplies model readiness, never corpus-completion
evidence: it omits reindex state instead of inventing progress or a finish time.

Canonical storage is `<dataRoot>/memory/memory.sqlite`. Memories, proposals,
tombstones and embedding-epoch state share the `MemoryStorage` pool. The embedding
epoch exposes activation state without a rollback capability; its historical
rollback column remains migration-compatible but has no live reader or writer.
`MemoryStorage.migrator` also owns the retained supersession repair's cursor
table and ordering index; the repair only reads and advances that cursor.
Existing progress is adopted without resetting it. Retained historical tables
and transformations are not retired on the strength of an empty query alone.
Backend selection prepares the requested provider and stages its complete corpus
before the existing epoch owner activates it. Only successful activation publishes
the selected backend configuration; there is no configuration undo write. A
configuration-persistence failure after activation is reported and requires a
forward retry; epoch compatibility keeps mismatched queries from comparing vectors.
`config/embeddings.json` accepts the selected `coreml-bge` or explicit `mock`
backend. Only a missing file chooses the fresh-install Core ML setting; malformed,
unreadable or unknown saved settings report unavailable and block embedding.
A warm-only request returns no vectors only when there is no matching resident
model or no text to embed; a resident inference failure throws to the dependent
interpretation. Compiled models use the checked platform cache root and atomic
move publication; a root or move failure has no temporary-root or copy path.
Model fingerprints and directory digests require every artifact stat/read.

The retired truncated-row `memory.repair` executor and approval registration are
removed after a read-only check found no retained approvals, execution fences or
settlement debts. Historical completed repair markers remain untouched.
Kind backfill remains data-gated: retained default-kind/note rows and its staging
marker still exist. Its classification owner fails the complete candidate set
when any row fails; no row silently drops. Unreadable stamps leave repair owed.

The Memories search field uses canonical recall and resolves its hit IDs,
without supplementing results from the bounded inventory. Request identity
(`searchQuery`) is separate from the successful rows' query (`searchResultQuery`):
a failed request retains the last successful rows under their original query
and reports its cause. The page shows that failure before any retained rows;
neither failed nor empty recall substitutes inventory text matches. Queries
under three characters leave the inventory unfiltered.
Page and panel refreshes re-rank the facade's current query without calling the
person's query setter or crediting recall hits. Query selection and `LatestRead`
admission share the main actor; a clear or new query invalidates older search
publication. A packet copies the query, results and read state together.

Proposal state changes belong to acceptance, rejection or explicit supersession;
there is no unrestricted status setter or automatic single-valued-kind policy.
A memory with correction or supersession lineage is retained by the canonical capacity
predicate, including older rows carrying only `corrected_by`; capacity admission
fails if too few disposable rows remain.
Each memory row's `valid_from`, `valid_to`, `observed_at` and `evidence_json` columns are
its interval of truth and its source; writes lift them from the same metadata
keys.
`MemoryStorage.admissionDuplicate` applies exact and near-verbatim admission
within `disclosureScopeKey`'s persona, privacy and permitted-surface bucket.
Duplicate admission excludes rows whose `valid_to` has passed under the canonical
temporal eligibility predicate. Reasserting their words admits a new fact;
the closed-interval row remains history.
The `SwiftNativeMemoryV2` service calls this actor directly and converts stored
rows only at its outward record boundary; the forwarding `MemoryStorageBridge`
actor and its duplicate record/patch conversions are removed.
Spotlight projection failures retain the affected identity and cause in the
storage owner's status and diagnostics, invalidate the generation proof, and
remain distinct from the already committed canonical change. The existing
canonical rebuild (repair or next launch) clears the error only after success.
`MemoryStorage.spotlightSnapshot` returns the exported items and their ID-ordered
fingerprint together; rebuild indexes those items and checks a fresh fingerprint
before writing its generation proof. The native-stack status display reads its
Spotlight item count and fingerprint from that same snapshot; its SQLite active
row count remains a separate measure.
Both incremental readback and rebuild exclude records whose `valid_to` has passed.
Each exported item also carries its checked `valid_to` as CoreSpotlight's native
`expirationDate`, so the system retires it at that date even when NativeAgent is
not running. Expiry is part of the item fingerprint; no app timer or memory-row
deletion is involved. A missing `valid_to` means no recorded expiry; an unreadable
date is a projection failure, never an unbounded item.
Content mutations invalidate recall candidates and publish the exact database
locator to derived-state consumers. `LatestRead` orders candidate-cache publication
and committed invalidation; each recall receives its own result. Cache reuse
checks the embedding epoch and canonical `recall_generation`, advanced by
content/epoch triggers, so other connections' writes invalidate stale candidates.
One recall ranks every query voice
against that snapshot; usage-only changes need no candidate refresh.

Default USER facts, chosen pins and canonical Context share
`MemorySenseProvenance.presentation`: a later-invalidated sense version keeps
its warning before the fact, inside the consumer's existing budget.
Context presentation checks the prefix and excerpt allowance before subtracting;
a budget too small for the qualification retains the canonical text, including
zero or negative custom budgets.

`MemoryV2+UserMDGen.swift` regenerates USER.md under the target file lock from
canonical memory while preserving its human preamble. It refuses damaged
existing documents. Regeneration and the prompt core share canonical temporal
eligibility: each captures one clock and excludes facts whose `valid_to` has
passed at that clock. Generation is gated on onboarding. USER.md is a projection,
not an independent place to repair memory facts. It and the per-turn prompt
core (`userPromptCore`) are the always-present picture of the person: they
carry facts about the owner only, every person kind the memory writer's own
vocabulary names (identity, location, employment, schedule, preference,
relationship) plus the legacy user_fact, user_preference and attribute
(`MemoryKindStamp.personKinds`; schedule since 10-27, so the owner's sleep
schedule reaches every turn). Ops and generic kinds stay out. The picture is
bounded at what one turn carries of memory at the floor window
(`UserMDAutogenMarkers.promptByteCap`, 6,000 B = recall's floor of 5 rows of
1,200 characters; was 3,500 B); the generated document holds the same bound,
and a fact past it stays in recall and the memory lane. The document orders
facts newest first. The turn's one disclosure-filtered selection puts pinned
facts first in pinned order, then every remaining eligible person fact newest
first, with each row appearing once. It never reads `user_core_chosen`; the
registered migration and its triggers remain part of the store schema.
`UserMDAutogenMarkers` applies the same cap to rendering and recall precoverage:
only facts actually carried in `# USER` are excluded from recall seats.
The stable prompt holds only USER's preamble; the facts ride the changing
packet and cannot change the cached prefix's bytes. Empty selections carry
only preamble prose, and failed reads retain their named gap rather than
substituting USER.md's generated facts. Kept moments and
experiences are theirs; they reach a turn through recall, and `memory.pin`
refuses any kind outside that list.

One kind vocabulary (`MemoryKindStamp.writerKinds`: identity, location,
employment, schedule, preference, relationship, goal, skill, fact,
correction) is what the after-turn writer chooses from. `memory.commit` offers
that vocabulary plus `instruction` and `note` through `commitKinds`; an unknown
supplied kind is refused. Missing kinds use the store's machine default; the
approval-gated `MemoryKindBackfill` classifies default-stamped and unsourced generic `note`
rows, changing kind metadata only, never content. Replacement requires explicit,
fingerprinted intent regardless of kind.

The generator starts one projection on an accepted invalidation; changes during its write produce one dirty follow-up. Engine
termination closes projection admission, drains the storage-owned USER.md,
Spotlight and graph tails, and joins accepted USER.md writes. Promoter sleep closes interpretation admission
and joins accepted owed recordings. It cancels unfinished judgment calls;
returned judgments validate and persist through `settle`, and an in-flight
fold finishes before the final save. Canonical
writes that finish after projection admission closes are reconciled at next launch.

## Embeddings

`MemoryV2+EmbeddingRuntime.swift` owns runtime embedding selection;
`MemoryV2+Embedding.swift` implements the Core ML providers. The app bundles
bge-large-en-v1.5 in `Resources/embedding` (1024 dimensions, CLS pooling and L2
normalisation baked into the model). It is the one production embedding model;
the MiniLM fallback and its SwiftPM resources are retired. A data-root copy of
bge takes precedence over the app's copy. Missing or broken bge assets fail
closed by model name and file path in Doctor, the memory page and embedding status.
Doctor resolves one installation for its asset check, prediction probe and compile-cache
repair. The cache owner loads exactly the digest/OS-keyed compiled artifact;
load failure retains that path and cause without another load or an automatic
cache wipe. Explicit Doctor repair removes only that source digest's current
OS artifact before a new load. Only the explicit `mock` configuration selects
synthetic vectors; an environment variable never substitutes them after failure.
Setup reads `MemoryFacade.embeddingSnapshot` directly: the requested
backend binds its switch and the effective backend supplies its detail sentence.

To supply a data-root copy, place `<dataRoot>/extras/coreml/embedding.json` beside
the bge Core ML model and its vocabulary:

```json
{
  "model": "embedding.mlpackage",
  "vocab": "vocab.txt",
  "model_id": "bge-large-en-v1.5",
  "dimensions": 1024
}
```

The identifier must be `bge-large-en-v1.5` and the dimension must be 1024. The
string fields must be nonempty. `model` and `vocab` must be filenames without
slashes; both must exist beside the manifest and resolve within that directory,
including through symlinks.

The model must accept `input_ids` and `attention_mask` as int32 tensors shaped
`[1, 128]`. It must return token vectors shaped `[1, 128, N]` or a pooled vector
shaped `[1, N]` or `[N]`, where `N` matches `dimensions`. The runtime mean-pools
token vectors using the attention mask and L2-normalizes the resulting vector
or the supplied pooled vector.

A search query (a turn's message and its other voice, or explicit recall)
is embedded through `embedQueriesWithEpoch`. A short referential follow-up
also carries the last two turns, and its own words alone (with their other
voice) are further readings (`ContextQueryEmbeddingValue.ownWordsValues`).
The primary reading is embedded alone and published at once; every further
named reading uses the turn's recorded origin: human speech (including relays)
addresses the resident agent, peer-authored speech names that peer as speaker,
and explicit agent recall speaks as the resident to the user. Only the current
turn's own words are rewritten; a composite query's mixed speakers stay intact.
English pronoun substitution is a retrieval aid with stated language limits.
Every further reading (the other voice, a follow-up's own words) rides one batch call after
it, and the Core ML embedder predicts each call's texts as one batch. A turn
whose 500 ms deadline comes before the further readings runs on the readings
that landed, and the bar counts only those. Recent-turn relevance reads message
content directly under the [conversation contract](conversation-context-history.md),
including bracketed headings. A bge model
is trained asymmetric, so `ManagedEmbeddingProvider` gives its queries the
instruction "Represent this sentence for searching relevant passages: "; stored
text never carries it, so corpus vectors and the epoch are the same either way.
The explicit mock embeds a query like any text.

Vectors carry `MemoryEmbeddingEpoch`; `MemoryStorage+EmbeddingEpoch.swift` owns
activation. Context reads words, vectors and epoch from one canonical row, never
re-embedding metadata edits; missing usable tagged vectors await checked fill,
and incompatible vectors contribute no semantics. Automatic Context can select
lexically; explicit recall requires a resident model and matching active epoch,
refusing cold requests and requesting convergence on a mismatch. Model corruption
and dimension errors propagate. Launch warms bge, compares `memory_embedding_state.active_epoch`,
and re-embeds memories, proposals and tombstones, including MiniLM and untagged
vectors, before atomic activation. Failed load/activation leaves prior vectors
intact but inactive for bge; no migration or in-place epoch relabeling occurs.
Corpus identities and retry keys hash the exact UTF-8 bytes, so case, whitespace
and Unicode representation changes reject an in-flight candidate. Normalized
claim hashes remain for duplicate and tombstone comparison. Activation validates
every successful vector through `VectorMath.requireUsable`: finite, nonzero and
exactly the provider's dimension. A zero/non-finite pooled prediction is an explicit
per-text unembeddable outcome, so its batch's other vectors still land. Activation
records each such row's error in `memory_embedding_failures` and clears its old
vector in the same transaction; memory, proposal and tombstone text remains intact.
The error is keyed by kind, row ID, exact UTF-8 bytes and epoch. Owed memory and
tombstone fills record the same outcome and skip it only while both bytes and
epoch match; changed text or a new space is eligible again. A late outcome cannot
mark a deleted, edited, already-filled or no-longer-active owed memory row.
The runtime log names each failed row; activation reports its unembeddable count.
Shared model/prediction failures, missing/wrong-shaped output, dimension errors
and corpus drift still refuse the operation; no substitute vector or second
inference path is used. Callers requiring a complete vector batch receive the
failed text's batch index and reason. Forgotten-claim semantic comparisons exclude
proven unembeddable rows with named gaps, while unresolved vectors still report
index-updating; exact hash suppression remains active for every forgotten claim.
A nonempty epoch candidate requires at least one usable canonical vector before
canonical vectors or the active epoch change. An all-unembeddable candidate is refused in
the activation transaction, preserving the prior corpus. That owner commits the
refused epoch, reason and observation time in `memory_embedding_state` before
returning the refusal; only successful activation clears it. An empty corpus
requires a validated provider probe passed to that same gate. Doctor's
`coreml_embedder` reads this recorded outcome from the canonical storage owner:
a matching refusal is a failure even when the fixed probe would embed. Its
compile-cache repair releases the resident model and requests convergence through
the canonical runtime, then reads the outcome again; a persistent refusal retains
the failure and builder remedy. Doctor also runs the probe through the production
provider and validates its width, finiteness and nonzero output. A passing probe
without a matching active epoch and dimension is unmeasured activation, not health.
Missing/unreadable owner state fails the check rather than implying success. The
dimension commits alongside the epoch in `memory_embedding_state`; canonical
vector writes use that same gate and dimension. Existing epochs without recorded
dimensions await checked convergence, never a guessed width. Vectorless active
memories remain owed to checked admission fill outside the epoch candidate;
convergence fills them after activation and reports any failure.

A configured `embedding-download.json` must be readable and valid; its failure
leaves embedding bring-up unavailable and names the descriptor in Doctor. Only
no configured descriptor permits the bundled-model path. Downloader ownership
(`release.sha256`) and manifest/artifact usability are inspected separately;
unknown ownership preserves the installation and reports its missing or damaged
evidence, never a "custom model" verdict.
Unknown ownership is reported as unverified with a remedy to preserve the whole
installation under a sibling recovery name before installing the verified release;
neither downloader nor Doctor invents a release marker. Launch requests the same
checked epoch convergence for bundled and separate-download distributions, so an
already-present model can activate dimensions independently of download ownership.
Download-part offsets come from checked regular-file lengths; only a genuinely
absent part starts at zero. A verified target commit requests epoch convergence
and reloads the resident model. An already-current target reports no install
change, even if it arrives during transfer; inspection never stamps
`installedRelease` or releases the resident model. Independent engine launch
still requests checked convergence. Optional staging cleanup cannot revoke an
install result: its separate
failure remains in download status, Doctor and the runtime log.

`SwiftNativeMemoryV2` also owns derived `action_embeddings`, keyed by epoch and
exact-text SHA-256, outside the canonical corpus and recall generation.
AppToolRuntime installs catalog file/owner notifications; coalesced fills embed
eight texts per chunk through the managed provider, with no timer. Each chunk
commits usable siblings alongside per-text failures in `action_embedding_failures`,
keyed by the same epoch and exact-text hash. A known failure is not pending work;
changed text or a new epoch is eligible again. Action search can embed up to
sixteen unresolved texts with its query, using per-text outcomes. Unembeddable
actions are omitted from ranking with `context.ranking.gap` trace evidence naming
the action, reason and epoch; usable siblings still rank. `find` names the gaps
in its existing `message` field and does not claim `not_found` across excluded
actions; exact-id discovery still reads the action directly. A bad query, shared
prediction failure, or cold/incomplete index refuses discovery with its remedy.

## Knowledge graph

MemoryStorage owns `memory.sqlite`'s `kg_*` schema. Graph wakes carry only memory
IDs; `SwiftNativeKnowledgeGraphIndexer` reads canonical facts in its write transaction.
`SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` extracts
deterministically without approving memories. The graph also includes Studio's
journal works, creators and relations (`studio-journal`, `studio_entry_ids` citations),
DreamREMCycle's GROWTH-eviction summaries with source locators (`rem-growth-eviction`),
and independently owned entities. Memory rebuilds rederive their own current
rows and clear memory overlays while preserving the other source-owned projections.

Background persona assembly uses the same checked user core as foreground
assembly; an unreadable core fails its work instead of becoming an empty core.
The graph indexer and name-aware recall read the saved profile through one
checked name projection. Existing unreadable identity blocks identity-dependent
indexing or context preparation and is never cached as a successful nameless
profile. An absent fresh profile can still have unset names.
Each indexing, reconciliation/rebuild and orphan scan resolves extraction names
once for that operation. Fact fingerprints include that profile identity and the
derivation contract, so unchanged memory text is rederived after a name change.
Retained launch indexers check canonical fingerprints on each wake. Graph Context
consumes exact `memory/profile.json` changes in the `persona` namespace as well as
its own root's memory changes, and reconciles before reading relations. Profile
commit owners must publish that existing persona invalidation after a successful
write; a different root or a persona Markdown edit does not wake this projection.
`SwiftNativePersonaEngine.savePersonality` publishes it immediately after its
atomic profile commit, including saves through the name and shared-profile APIs.

Unknown language stays unset in the name tagger. Typed primary-user predicates
come only from the writer's declared kind (`preference` → `prefers`, `goal` →
`wants`, `decision` → `decided`, and the other declared-kind mappings); other
facts use the structural `remembers` edge. Incidental prose never establishes
a preference, goal or decision. The graph's unused `GraphEntity.sourceNodeIds`
slot and its two key reads are removed; memory provenance remains `memory_id`
and `last_memory_id`, and Studio keeps its own journal citations.

`KnowledgeGraphReader.swift` reads only canonical SQLite: missing or unreadable
storage is an error. The JSON reader, importer and their completion markers have
no execution path. Memories' `graph.search` and
`graph.rebuild` actions obey the knowledge-graph policy gate. Complete SQLite
snapshots serialize ordered entities and eligible edges directly in one read
transaction, with page-capacity and relationship-count bounds.
The mounted Mac graph observes the canonical database and WAL before its initial
read, independently of the policy read's outcome; policy Retry never starts a
second observer. It coalesces changes through `MemoryFacade.loadGraph` and uses
that owner's `LatestRead` snapshot for both the canvas and selected neighborhood. Failed reads
retain the prior snapshot with their cause. A failed subscription reports an
observation gap; it does not establish that the graph is unchanged.
The phone snapshot requests the `ios` audience. Its source-backed nodes and
edges must pass `MemoryRecordDisclosurePolicy` against canonical memory rows
read in the same SQLite transaction as the graph. Edges also require both
endpoints to survive. Graph tools use the same source-reference disclosure
mechanism for their caller's surface. A missing source grants no disclosure;
an unreadable required memory read fails the snapshot. Independently owned
Studio, GROWTH and manual rows without memory overlays retain their own graph
projection. The phone envelope and keys are unchanged; only permitted rows
are published.

The shared primary-user person node is profile-backed: consolidation and
indexing remove memory-source attribution from that identity, so indexing a
restricted fact cannot hide the hub or another permitted fact's relationship.
Disclosure permits that profile role; each memory-derived fact and edge still
requires its own permitted source. The derivation fingerprint rederives existing
graphs under this ownership contract on their next reconciliation.

Enabled one-hop recall enrichment is part of the same checked recall assembly;
its source failure fails recall instead of silently returning unenriched hits.

## Recall into a turn

Persisted Context generations reject duplicate atom identities and invalid UTF-8
ranges. Generation increments, feedback elapsed times and freshness-to-bucket
conversion report unrepresentable values rather than trapping.
Degraded-source notices retain the bounded, secret-redacted compilation cause
beside the retained-source explanation, so recovery has evidence to act on.

`ChatTurnRuntime/TurnContextPreparation.swift` prepares the context.
On an active ContextFlow turn, memories arrive through the selected packet;
the separate recall list stays empty. Unavailable recall follows the
[recall-unavailability law](ANATOMY_OF_A_TURN.md#recall-unavailability), allowing
the turn to continue with the named gap; other context preparation errors stop
the turn. When ContextFlow is off, the engine can use explicit MemoryV2 retrieval
for its automatic recall block.

**Whatever turn preparation knows about the agent's context reaches the agent:
what was selected, what was withheld and why, and the time as the turn actually
has it.** Atoms selection chose that the owners' check then withheld are counted
against the selection receipt and named, with the reasons verification appended
to the packet's `degradedSources`, in that same availability notice. Memory age
tags read `ContextPreparedTurn.turnTime`, the turn's pinned instant (the one its
clock facts use), never the selection bucket's end, which in a day's last minute
is already tomorrow. Selection, expiry and recency keep `NeedSignal.evaluationTime`,
so the need fingerprint, receipt and selected packet stay keyed to the bucket;
one pinned instant per turn keeps the packet and ambient recollection in agreement.

Peer-sourced facts keep their author on every prompt line (`— from Claude`):
the selected Context packet uses the source entities already compiled from
`MemoryDataProvenance.sources`, and Context-off recall, default USER facts and
chosen pins use the same projection of the roots' `through`. The existing list's
`agent`/`peer_sources` result fields and prompt labels therefore name the same source.
`MemoryDisplayText.attributed` owns the shared display suffix; USER precoverage
compares the attributed atom text so the new label does not duplicate a fact.
Ambient recollection uses the same `ContextMemoryLead.decorate` as packet
rendering, with the prepared turn's pinned instant, recorded time, roots and untrusted
sources. Its body excerpt is capped at 280 characters before decoration, so
clipping never strips the provenance suffix. `mind.came_to_mind.presented`
records that same rendered nudge through the shared trace redactor, so installed
proof can inspect the words actually handed to the conversation, not just IDs.
No author is invented for a memory whose roots name no principal. This replaces
unlabeled peer facts in prompts; it changes no disclosure or effect authority.
The contact owner emits `agent-trust` invalidations and `trustDidChange` only
after identity, grant or credential-binding fields actually change; traffic
proof timestamps do not wake memory projections. MemoryContext recompiles from
canonical roots under current Trust, and the Memories page rereads its packet.
Selection, expansion and ambient delivery also compare compiled roots and source
entities with the canonical record under live Trust: stale attribution is withheld
with a named gap and requests a root-scoped `agent-trust` reconciliation. The
engine sends that edge to the Memories page as well as ContextFlow, so an
observed credential-only change never waits for an unrelated memory write.
No remembered Trust verdict can authorize effects. Keychain changes made outside
the app have no contact-write signal; they are detected when recall next verifies
the affected memory (or on an explicit fresh page read).

`MemoryRecordDisclosurePolicy` filters records by status, lifecycle and allowed
surface; both explicit recall and automatic projection consume that policy.
The `memories.json` phone snapshot applies this same classification for `ios`
and the snapshot's current time before flattening canonical records. Chat-only,
expired and otherwise ineligible rows are withheld. Secret-bearing fragments
in any string field the phone record carries withhold that row through the
shared secret policy. The deployed phone record's field names and types stay
unchanged; an unreadable source fails the snapshot read rather than publishing
an invented empty list.
The current phone's `faces.json` Memories entry is drawn by the same
`native-memories` part from a separate `ios` packet, not the unrestricted Mac
snapshot. The memory owner classifies kept/search records and pending/rejected
proposals before making facts, keys, clusters or levers; Misses uses its
existing surface-aware owner. At this packet boundary, the memory owner applies
`ContextSecretContentPolicy.redactedFragment` recursively to every facts string:
kept and searched memories, pending and rejected proposals, lessons and their
latest corrections, nested provenance, queries and failure reasons. Character
clusters derive only from the redacted facts. Native memory and proposal lever
text uses the same policy before any clipping, including when the part cannot
draw. Both Mac and phone receive these safe words; stored memory is unchanged.
Both projections reread on memory/profile/Trust changes and after a Memories
tap; phone taps resolve only against the disclosed snapshot. Missing phone presentation never
substitutes the Mac face. Wire field names and types remain unchanged.
`ContextBudgetPolicy` sizes the turn's memory/context allowance, while
`ContextSelectionConfiguration.swift` owns selector limits.

One selector chooses every memory (`ContextSelection.swift`, the memory lane;
numbers in `ContextSelectionConfiguration.swift`):

- **Relevance is required.** A memory or ambient correction comes in only when
  the message touches it. Each reading of the message is its own look: its
  words as the query carries them, their other voice, and for a follow-up its
  own words alone and their other voice. In a reading, a memory's cosine
  stands out from that reading's cosines to the OTHER candidates, after taking out
  each memory's own pull toward the others; its relevance is its best
  standing in any reading, two deviations or more (`ContextSelector.memoryRelevance`
  in `ContextRelevance.swift`, the selector's `memoryStandout`,
  `ContextSelectionConfiguration.memoryStandoutDeviations`). An ambient
  moment (what the agent reads while working) asks the same selector at three (`ambientStandoutDeviations`;
  `ContextPreparedTurn.cameToMind`): with them ~70 memories chance alone puts
  one or two past two deviations for any text, and an unaddressed line must
  not surface noise. These floors are fixed; the receipt's memories × readings
  population is diagnostic and does not adjust them. Standing uses the others' population mean and deviation, matching
  `VectorMath.standout`: not above their mean has no standing; above a constant
  background has infinite standing (saturated to the largest finite Double in
  serializable receipts; no positive standing is represented by zero).
  `VectorMath.standout` uses centered aggregate moments to remove each
  candidate in constant time, sharing one linear pass with find and cares. The
  deviations assume roughly independent Gaussian background scores; they rank,
  they are not a calibrated probability. Or half the message's words
  are in it, or the whole message is.
  With only one or two comparable vectors, relevance uses the ordinary
  model-scaled semantic score (weight 4) against `minimumRelevance` (0.05),
  rather than applying the relative floor to that different scale. Recent
  service rests one deviation higher (served on one of the last three exchanges).
  Nothing fills the allowance because it exists. Active semantic recall requires
  complete, usable requested semantic readings before ranking; embedding failure
  or expiry of the bounded wait withholds semantic recall and names the cause in
  the turn's context instead of failing the turn or using lexical-only recall.
  The wait's deadline leaves the runtime-owned embedding batch running to settlement.
- **Reachability.** The touched rank by relevance times reachability, the
  power-law sum over past uses (each turn that served it, and its creation):
  serve feedback is written at `ContextPreparedTurn.recordDelivery`'s once-only
  confirmed-delivery boundary. Preparation retains its selection receipt without
  crediting a use or resting a memory that never reached the provider.
  Reachability remains global; rest requires a delivery event in the current
  session whose message fingerprint is still in the retained transcript exchanges.
  Distance comes from the transcript owner's ordered retained exchanges: a user
  message and its reply share one position, including exchanges with empty
  context deliveries. The mixed-message relevance window and feedback-event
  count are not exchange clocks. Repeated rows from one run share its exchange;
  nonconversation rows do not invent one.
  Legacy feedback without that evidence supplies no rest.
  Σ age_days^-0.5, read as odds of need, odds / (1 + odds)
  (`ContextFeedbackReducer`, from the context feedback log, preserving append
  sequence within each five-minute bucket). In a small population the actual
  model-scaled score ranks semantic matches; a lexical-only match without a
  positive score ranks at `minimumRelevance`. What they keeps
  using stays reachable; disuse fades recall without deleting the row. A fitting
  cue still brings a retained row; [capacity eviction](data-bounds.md) is separate.
- **Rest.** A memory served on one of the last `memoryRestTurns` (3) exchanges is
  already in the conversation; it comes again only at `memoryRestFloor`, one
  deviation over the relevance bar, when the message singles it out.
- **Only what is still true.** A record whose `valid_to` has passed expires its
  atom and stays out of automatic context. Initial selection, expansion and ambient
  recollection all recheck the chosen memories against the canonical owner at use.
  Degraded sources excluded before ambient verification remain unavailable,
  including an empty selection; they cannot become a no-match verdict or clear
  repair debt. Graph endpoint dates are checked individually before choosing
  the freshest date; an invalid existing date withholds its subject's source
  with its cause while unrelated subjects proceed.

Relationships and lesson origins are marked `.personal` and compete like any
memory (a kept moment is an ordinary memory); the separate personal lane and its 0.20 lift floor are gone,
and its baseline (a memory's pull toward all the others) is now taken out of
every memory's relevance. Rows still answer to
the shared nonmandatory memory/correction row allowance (`maximumAtomsPerKindOverrides`, the turn's
`recallRowLimit`, six on a message of four words or fewer) and the character
budget, and are taken before the ordinary lane. Scoped corrections keep their
rule: a correction whose `context_topics` the message triggers is mandatory,
outside this lane. The person picture (`userPromptCore`, USER.md) rides every
turn within its own byte cap, with pins first and the remaining facts newest
first. The coordinator suppresses only canonical memory facts actually
carried in that turn's USER block. The SOUL/VOICE kernel carries no USER.
`mind.why` lane `memory` gives each winner's `relevance` and
`reachability`, and lists what the message touched but `rested`.
See [personality-ablation.md](personality-ablation.md) for the mechanism
checklist.

`ContextFlow/NativeContextMemoryProvenance.swift` attaches selected atom-to-record
identity to the exact prepared turn and its generation lease without changing
packet text. The turn accounts for delivered memory IDs, and
`ChatOrchestrationClient+LivedObservations.swift` stamps `memoryRecordIds`
on cognitive events. Cognition can then reactivate those memories and re-feel
a served memory through the felt node that names it. Being served does not
carry a memory into the next turn: the old working-set pass (activation 1 and
a pass over the floor for whatever the last turns served) is gone; use counts
only through reachability; recent service rests a memory only while that
delivery remains in the current conversation's retained transcript exchanges.

## Switches

`MemoryV2+PolicyGate.swift` reads the checked Trust policy at use time.
Damaged saved authority reports the gate as unavailable, with its Trust repair.
It never means the person disabled a switch. Graph mutations and rebuilds stop
before retiring or indexing rows when that policy read fails; the existing
projection failure reports the cause. Context compilation retains its prior
graph inputs as unavailable and withholds them until verified again.
Keys live under `memoryPolicy` in `<dataRoot>/trust/policy.json`.

| Policy key | Consumer |
| --- | --- |
| `cross_session_recall` | Automatic recall and the packet's memory row allowance. Explicit `memory.recall` remains available subject to normal policy. |
| `adaptive_promotion` | Fact proposal lane. |
| `knowledge_graph_enabled` | Graph indexing/read/rebuild admission. |

Disabling cross-session recall excludes every MemoryV2 source from ContextFlow,
including automatic correction atoms, and memory-derived knowledge-graph
relations. Explicit `memory.recall` remains
available subject to normal policy.

## Consolidation and hygiene

The bulk consolidator, candidate databases, probe gate, swap approval and
executor, weekly `memory_consolidation` slot, hygiene operation and report,
and their Memories, Setup and Trust controls are retired. Nothing reads
leftover `memory/consolidation/` directories or `hygiene_last_run.json`.
Saved `consolidation_enabled`, `auto_promote_consolidated` and
`hygiene_enabled` keys are ignored on read.

Fading leaves storage intact; the [capacity bound](data-bounds.md) can evict
eligible rows. Supersession closes a fact's interval and protects the old record
from eviction; deliberate forgetting remains explicit.
Derived knowledge is rebuilt from the record, never by bulk merging,
archiving or swapping canonical rows. Integrity checks,
graph rebuild and manual orphan sweep remain. Sweep support and candidates share
one transaction; preview reads, and apply requires the exact reviewed IDs.

Dreams and REM have separate artifact owners in `DreamREMCycle/`; they are not
another MemoryV2 database. Their connections are mapped in
[COGNITION_WIRING.md](COGNITION_WIRING.md).

Context's derived conflict-graph lane and unwritten `on_demand` injection policy
are removed. Knowledge-graph edges remain ordinary `.relationship` atoms.
Studio, resident-work, graph and memory projection failures report named source
failures; an unreadable inventory with no prior atoms uses a stable provider
source ID. A failed source is retained for rebuilding and withheld from delivery;
healthy sibling sources proceed. A successful checked read clears previous source
degradation even when the content hash is unchanged. Existing invalid source timestamps are unavailable
evidence, never replaced by a different timestamp or by distant past.

Context arena byte counts are logical admission estimates for the resident
generation, not measured physical allocations. Pressure disables optional
prewarming; it leaves retained payloads and logical byte counts intact and reports
no warm payload evictions. Removing descriptors cannot free their owner's atoms.
