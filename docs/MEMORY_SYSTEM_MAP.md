# Memory system map

MemoryV2 owns durable memories, proposals and rejection tombstones. Context and
generated USER.md project them; the graph combines the sources mapped below.
Cognition and organism continuity remain advisory, outside canonical memory.

Source paths below are relative to `Modules/NativeAgentCore/Sources/`.
For the memory standard, see [What a good memory is](memory-quality.md).

## The pipeline in one line

Turn interpretation or an explicit save → MemoryV2 → canonical SQLite
transaction → derived projections → selected context or explicit recall.

Agent reaches memory through their one `app` tool:

```text
app {"page":"memories"}
app {"action":"memory.recall","args":{"query":"what to recall"}}
app {"action":"memory.list","args":{"limit":20}}
app {"action":"memory.proposals"}
```

`AppToolRuntime/AppActions+Declarations.swift` declares these actions.
`memory.commit` saves a memory; `memory.proposals` lists the proposals waiting
on their review (`status: "rejected"`: the ones let go); `memory.review` accepts or rejects one;
`memory.rewrite` edits, pins or restores a record; `memory.forget` forgets it.
Read the page for the current arguments and applicable action warnings.

Successful memory reads report `count`, an exact `total` or `capped: true`,
and `has_more` with `next_offset`. `memory.list` keeps its exact total and
cursor (`next_after_id`); recall search follows `read_more` with the same
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
| `MemoryV2/MemoryStorage+Projections.swift` | The same storage actor's ordered graph/Spotlight hooks, USER.md regeneration, context invalidation, projection readback and shutdown settlement. |
| `MemoryV2/MemoryStorage+Migrations.swift`, `MemoryStorage+Codecs.swift`, `MemoryStorage+Integrity.swift` | Schema, checked decoding and semantic integrity of the same store. |
| `MemoryV2/MemoryStorage+Proposals.swift`, `MemoryStorage+Tombstones.swift` | Proposal acceptance/rejection and suppression of rejected or forgotten content. |
| `MemoryV2/MemoryStorage+Recall.swift`, `MemoryRecallScoring.swift` | Cached recall candidates and vector/lexical scoring. Raw BM25 mathematics are shared with earlier-session snippets; memory normalizes by the maximum and weights at one standard deviation of the query's dense similarities (`lexicalBoostWeight`). Each caller owns tokenization, its candidate cohort and ranking. |
| `MemoryV2/MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter` actor and live journal-only interpretation: predicts complete no-ops, leaves a standing no-op owed until due, writes meaning before applying and keeps facts by operation identity. Keeps trusted facts, stages the rest. Deferral and labels follow [cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation). |
| `MemoryV2/AdaptiveMemoryPromoter+Recovery.swift` | The same promoter's owed-turn recovery on its live serialization tail: recorded-provenance replay, fair retries and bounded wake/idle/night batches with judgment settlement. |
| `MemoryV2/AdaptiveMemoryPromoter+Migrations.swift` | The same promoter's retired held-file import and one-time trusted backlog and moment-to-care migrations; persisted formats and markers stay unchanged. |
| `MemoryV2/AfterTurnMemorySurprise.swift`, `AfterTurnSurpriseLedger.swift` | The agent's own learned complete no-op prediction (language-independent warm-vector precedents, keyed by agent, memory model and detector) and its labelled record with the Wilson-bound cost law. See [cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation). |
| `ChatTurnRuntime/MindMemoryManager.swift` | At most one shared model interpretation per turn, returning memories, affect, a caring judgment and what moved their (cares), or one call for a batch of owed turns (the rules once, one section per turn; a missing section stays owed); its checked route key scopes the prediction record. |
| `MemoryV2/KnowledgeGraph+MemoryIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: ordered per-memory entity, edge and support projection into the shared SQLite database. |
| `MemoryV2/KnowledgeGraph+StudioRelations.swift`, `KnowledgeGraph+GrowthDistillation.swift`, `KnowledgeGraph+SQLite.swift` | Studio journal, REM/GROWTH eviction and legacy-import graph sources, preserved by memory rebuilds. |
| `MemoryV2/MemoryV2+EmbeddingRuntime.swift`, `MemoryStorage+EmbeddingEpoch.swift` | Embedding convergence and persistent derived action-vector fill/lookup for AppToolRuntime. |
| `ContextFlow/NativeMemoryContextProjection.swift` | Compiles eligible memory records into selectable context atoms. |

## Writing memories

### Explicit saves

`memory.commit` enters `ChatToolRuntime/SwiftToolDispatcher+MemoryTools.swift`
and calls `SwiftNativeMemoryV2.store`. Text must be nonempty. Kind, confidence,
importance, tags and supplied provenance travel as metadata.

Optional `provenance` is `verified|told|inferred`; `provenance_by` is at most
40 characters (letters, digits, spaces and `. - '`). `ContextMemoryProvenance`
owns the vocabulary and wording: recall returns plain `provenance`, context
brackets it, and absent provenance stays absent.

`MemoryV2+Wiring.swift` handles quality screening, duplicate handling,
embedding before storage; the write transaction checks tombstones. Saves and proposal acceptance preserve
writer-supplied dates; they never infer dates from prose. A content rewrite
keeps the writer's named date as it is, even when its wording changes. Only an
explicit metadata change changes the date.
Native update aliases resolve through one text owner (`text` before `content`)
for embedding, tombstone admission and the stored patch alike.

A tool result must be checked: a refused save is not a remembered fact. A save carries its source like any kept
fact: `evidence_json` names the turn that saved it (session, message, turn,
speaker `self`), and `observed_at` and `valid_from` are that turn's time.

### The memory-manager lane

`AdaptiveMemoryPromoter` invokes `MindMemoryJudgment.interpret` at most once with the
incoming message, available reply, bounded existing/pending memories and the
speaker's name. Bridge peers are named as peers. Helper-owned turns use their
own runner; their own work (`builder`) skips resident memory interpretation.
Session ownership comes from the [recorded row](session-conversations.md),
never an ID prefix.
The model follows [judgment routing](COGNITION_WIRING.md#shared-after-turn-interpretation).
The [shared interpretation contract](COGNITION_WIRING.md#shared-after-turn-interpretation)
owns surprise-ledger cost accounting.

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
a paraphrase are removed. Older meant decisions without attributed grounding
finish under their recorded judgment: an absent field means grounded under the
rule that judged them. They are never re-judged or held owed for that newer field.
New add/update judgments require attributed grounding before meaning is saved.
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

Once per store, at launch (`keepTrustedBacklogOnce`, marker
`memory/migrations/trusted_pending_facts_v1.done`), pending fact proposals from
before this rule, never moments, are judged by the same trust from what they
carry (their session id and `peer_sources`) and kept through the same
acceptance with their source filled; the others stay pending. The log line
names the kept, waiting and refused counts.

### Plan dates

Whether a memory is a plan for a moment is meaning, judged by the same
after-turn call that writes it. Each memory decision may name `due`, an
ISO-8601 local date-time, only for something the person or they plans or has
committed to do at a time; a date something was said or happened is not a
plan. The prompt carries the exchange's local clock, retained on held-turn
recovery. An offset identifies the instant directly; an unzoned date-time
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
Drain scheduling, deferral, batching, fair retries and cancellation follow
the [shared interpretation contract](COGNITION_WIRING.md#shared-after-turn-interpretation).

`memory/moments_held.json` is import-only: its turns enter the journal in one
transaction before the file is emptied, and nothing writes it again (the
journal is the queue; a turn the journal cannot record owes repair instead).
Memory status counts the journal's owed turns (`owedCount`), not the file.

### Moments are care story

There is no moment lane (retired 10-25). What happened between them is their
mark on the exchange: the after-turn call's cares section writes it as a care
movement (the felt word, their note, how far it moved their and the
`exchange:<session>/<turn>` pointer) in [SUBCONSCIOUS.md](SUBCONSCIOUS.md#cares).
Nothing stages, caps or reviews a moment.

Once per store, at cognition bootstrap (`moveMomentsIntoCaresOnce`, marker
`memory/migrations/moments_into_cares_v1.done`), every kept moment and every
moment still pending became a care movement through the same `applyCares`:
on the care whose story already points at its exchange (then nothing is
written twice), else the live care the moment touches (the care law: its
cosine stands out past chance among their live cares, `caresStandingOut`), else
a new care of theirs alone; moved from its valence, felt a plain word from valence and
salience, note its own sentence (≤120 characters), at its time. A pending
moment was then rejected with the receipt "now a care" (an untrusted peer's
with no care to join: "not kept"). A kept moment stays in the store as a
record and an ordinary memory: not `.personal`, not re-felt.

`memory.proposals` lists what still waits on them (an untrusted peer's facts or
a fact acceptance left for review; `status: "rejected"` for what was let go) and
`memory.review` keeps or rejects one, as the Memories page does. Owner:
`ChatToolRuntime/SwiftToolDispatcher+ProposalReview.swift`.

## Corrections, supersession and scope

A replacement and a denial have different consequences. An accepted update
retires its target through the atomic superseding-acceptance path. The target's
reviewed fingerprint must still match; otherwise the proposal stays pending
for review. The retired row stays in the store with lifecycle `corrected` and
its `valid_to` closed at the replacement's `valid_from` (an explicit
`corrects` does the same). `MemoryRecordDisclosurePolicy` leaves out a record
whose `valid_to` has passed, so it reaches neither automatic context nor
recall; no recall asks for history yet. Explicit restoration reopens that interval
in the canonical update transaction while retaining correction lineage.
Active curation and graph projection use the same temporal predicate. Graph
fingerprints carry validity dates, and checked graph reads reconcile that
projection against the current clock while graph production is enabled.
Rejection/forgetting use tombstones to prevent unwanted content from returning.
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
Forgetting or rejecting a vector-pending row requests the existing embedding
convergence flight. It fills vectorless tombstones in the current epoch,
before admitting owed active memories, and lands only on the exact forgotten
hash and content. Both semantic consumers report index-updating while any
forgotten claim awaits its vector; a missing vector never means permission
to admit a restatement or an empty forgotten set. Exact hash suppression
applies immediately throughout. Restart in the same epoch also fills them.

For explicit `memory.commit`, `corrects` names an existing record; the result
reports whether that correction applied or awaits admission. Both `corrects`
and `supersedes` carry fingerprinted intent through the same transactional
replacement owner, including cold writes; an exact reassertion of its own
target never retires itself. Correction admission retains duplicate folding;
if a warm or owed vector resolves to the correction target itself, it stays
eligible without self-lineage. `context_topics` narrows automatic
context injection for `correction`, `instruction`, `preference`, `note` and a
save with no kind; other kinds ignore it. Intake keeps up to eight non-empty, trimmed topic
strings of at most 120 characters each. Empty or invalid input supplies no
scope; no scope is inferred from dispatched tools. Omitted scope stays global.
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

## The store

WordPiece model loading requires `[UNK]`, `[CLS]`, `[SEP]` and `[PAD]`, with
vocabulary IDs representable by the model's Int32 input. Damaged vocabularies
surface the model-load error; special-token IDs are never manufactured.
The resident tokenizer stops after proving window overflow, finishing each word
before clipping; complete-text embedding reuses its admitted IDs and masks.
The no-op predictor embeds covered pieces in batches of at most sixteen under one epoch.
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
Backend selection prepares the requested provider and stages its complete corpus
before the existing epoch owner activates it. Only successful activation publishes
the selected backend configuration; there is no configuration undo write. A
configuration-persistence failure after activation is reported and requires a
forward retry; epoch compatibility keeps mismatched queries from comparing vectors.

The Memories search field uses canonical recall and resolves its hit IDs,
without supplementing results from the bounded inventory. Request identity
(`searchQuery`) is separate from the successful rows' query (`searchResultQuery`):
a failed request retains the last successful rows under their original query
and reports its cause. The page shows that failure before any retained rows;
neither failed nor empty recall substitutes inventory text matches. Queries
under three characters leave the inventory unfiltered.

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
before writing its generation proof.
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
not an independent place to repair memory facts. It and the per-turn pinned
core (`userPromptCore`) are the always-present picture of the person: they
carry facts about the owner only, every person kind the memory writer's own
vocabulary names (identity, location, employment, schedule, preference,
relationship) plus the legacy user_fact, user_preference and attribute
(`MemoryKindStamp.personKinds`; schedule since 10-27, so the owner's sleep
schedule reaches every turn). Ops and generic kinds stay out. The picture is
bounded, newest first, at what one turn carries of memory at the floor window
(`UserMDAutogenMarkers.promptByteCap`, 6,000 B = recall's floor of 5 rows of
1,200 characters; was 3,500 B); the generated document holds the same bound,
and a fact past it stays in recall and the memory lane. Kept moments and
experiences are theirs; they reach a turn through recall, and `memory.pin`
refuses any kind outside that list.

One kind vocabulary (`MemoryKindStamp.writerKinds`: identity, location,
employment, schedule, preference, relationship, goal, skill, fact,
correction) is what the after-turn writer chooses from and what
`memory.commit` offers as `kind` (a plain string, so no strict provider
refuses the call). Explicit `instruction` is also accepted for existing-agreement
lookup. An unknown supplied kind is echoed as `kind_requested` in the save
receipt. Unknown or missing kinds use the store's machine default; the
approval-gated `MemoryKindBackfill` classifies those and unsourced generic `note`
rows, changing kind metadata only, never content. Replacement requires explicit,
fingerprinted intent regardless of kind.

The generator retains its trailing deadline through regeneration. Engine
termination closes projection admission, drains the storage-owned USER.md,
Spotlight and graph tails, and flushes accepted USER.md requests after cancelling
any sleeping debounce deadline. Promoter sleep closes interpretation admission
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
Doctor resolves one installation for its asset check, load probe and compile-cache
repair. Setup reads `MemoryFacade.embeddingSnapshot` directly: the requested
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

`SwiftNativeMemoryV2` also owns derived `action_embeddings`, keyed by epoch and
exact-text SHA-256, outside the canonical corpus and recall generation.
AppToolRuntime installs catalog file/owner notifications; coalesced fills embed
eight texts per chunk through the managed provider, with no timer. Action search
can embed up to sixteen missing texts with its query; cold/incomplete index failures
are reported to the caller, which ranks by words and names that limitation.

## Knowledge graph

MemoryStorage owns `memory.sqlite`'s `kg_*` schema. Graph wakes carry only memory
IDs; `SwiftNativeKnowledgeGraphIndexer` reads canonical facts in its write transaction.
`SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` extracts
deterministically without approving memories. The graph also includes Studio's
journal works, creators and relations (`studio-journal`, `studio_entry_ids` citations),
DreamREMCycle's GROWTH-eviction summaries with source locators (`rem-growth-eviction`),
and the one-time JSON import (`legacy-import`). Memory rebuilds rederive their own
rows and clear memory overlays while preserving those three source-owned projections.

`KnowledgeGraphReader.swift` exposes checked reads: unreadable existing SQLite is
an error; JSON is only pre-SQLite compatibility. Memories' `graph.search` and
`graph.rebuild` actions obey the knowledge-graph policy gate. Complete SQLite
snapshots serialize ordered entities and eligible edges directly in one read
transaction, with page-capacity and relationship-count bounds.

## Recall into a turn

Persisted Context generations reject duplicate atom identities and invalid UTF-8
ranges. Generation increments, feedback elapsed times and freshness-to-bucket
conversion report unrepresentable values rather than trapping.
Degraded-source notices retain the bounded, secret-redacted compilation cause
beside the retained-source explanation, so recovery has evidence to act on.

`ChatTurnRuntime/TurnContextPreparation.swift` prepares the context.
On an active ContextFlow turn, memories arrive through the selected packet;
the separate recall list stays empty. Context preparation errors stop that
turn. When ContextFlow is off, the engine can use explicit MemoryV2 retrieval
for its automatic recall block.

Peer-sourced facts keep their author on every prompt line (`— from Claude`):
the selected Context packet uses the source entities already compiled from
`MemoryDataProvenance.sources`, and legacy recall, default USER facts and
chosen pins use the same canonical-source projection. The existing list's
`agent`/`peer_sources` fields and prompt labels therefore name the same source.
`MemoryDisplayText.attributed` owns the shared display suffix; USER precoverage
compares the attributed atom text so the new label does not duplicate a fact.
No author is invented for owner-authored or unstamped records. This replaces
unlabeled peer facts in prompts; it changes no disclosure or effect authority.

`MemoryRecordDisclosurePolicy` filters records by status, lifecycle and allowed
surface; both explicit recall and automatic projection consume that policy.
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
  moment (what they reads while working, what their crossing noticed between
  turns) asks the same selector at three (`ambientStandoutDeviations`;
  `ContextPreparedTurn.cameToMind`): with them ~70 memories chance alone puts
  one or two past two deviations for any text, and an unaddressed line must
  not surface noise. (A chance bar over memories × readings, about four
  deviations, held 10-27 to 10-29 and let ~0.1 memories a turn through, against
  4.8 on 10-25 and 1.6 at two deviations.) Standing uses the others' population mean and deviation, matching
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
  service rests one deviation higher (served on one of the last three turns).
  Nothing fills the allowance because it exists. With no query vector only
  words touch.
- **Reachability.** The touched rank by relevance times reachability, the
  power-law sum over past uses (each turn that served it, and its creation):
  serve feedback is written at `ContextPreparedTurn.recordDelivery`'s once-only
  confirmed-delivery boundary. Preparation retains its selection receipt without
  crediting a use or resting a memory that never reached the provider.
  Reachability remains global; rest requires a delivery event in the current
  session whose message fingerprint is still in the supplied history window.
  Legacy feedback without that evidence supplies no rest.
  Σ age_days^-0.5, read as odds of need, odds / (1 + odds)
  (`ContextFeedbackReducer`, from the context feedback log, preserving append
  sequence within each five-minute bucket). In a small population the actual
  model-scaled score ranks semantic matches; a lexical-only match without a
  positive score ranks at `minimumRelevance`. What they keeps
  using stays reachable; disuse fades recall without deleting the row. A fitting
  cue still brings a retained row; [capacity eviction](data-bounds.md) is separate.
- **Rest.** A memory served on one of the last `memoryRestTurns` (3) turns is
  already in the conversation; it comes again only at `memoryRestFloor`, one
  deviation over the relevance bar, when the message singles it out.
- **Only what is still true.** A record whose `valid_to` has passed expires its
  atom and stays out of automatic context.

Relationships and lesson origins are marked `.personal` and compete like any
memory (a kept moment is an ordinary memory); the separate personal lane and its 0.20 lift floor are gone,
and its baseline (a memory's pull toward all the others) is now taken out of
every memory's relevance. Rows still answer to
the memory-row allowance (`maximumAtomsPerKindOverrides`, the turn's
`recallRowLimit`, six on a message of four words or fewer) and the character
budget, and are taken before the ordinary lane. Scoped corrections keep their
rule: a correction whose `context_topics` the message triggers is mandatory,
outside this lane. The pinned core about the owner (`userPromptCore`, USER.md)
is unchanged. The coordinator suppresses only canonical memory facts actually
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
delivery remains in the current conversation's supplied history window.

## Switches

`MemoryV2+PolicyGate.swift` reads the checked Trust policy at use time.
Damaged saved authority disables the affected gate.
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
archiving or swapping canonical rows. Integrity checks, `memory.repair`,
graph rebuild and manual orphan sweep remain. Sweep support and candidates share
one transaction; preview reads, and apply requires the exact reviewed IDs.

Dreams and REM have separate artifact owners in `DreamREMCycle/`; they are not
another MemoryV2 database. Their connections are mapped in
[COGNITION_WIRING.md](COGNITION_WIRING.md).
