# Memory system map

Where every part of the memory pipeline lives, which switch controls it, how to see
it working, and what a regression looks like. The standard the pieces are held to is
[What a good memory is](memory-quality.md). The lifecycle narrative is
[Internal Workings, anatomy of a memory](INTERNAL_WORKINGS.md#2-anatomy-of-a-memory).

## The pipeline in one line

turn → moment extractor / commit_memory → MemoryV2 store → knowledge graph
projection (+ vectors) → recall into the next turn → weekly consolidation and
hygiene → the agent's own curation tools.

## Review surfaces

The Mac Memories page loads rejected proposal history separately when the page
refreshes, through `NativeClient.getRejectedMemoryProposals`. Its database/WAL
subscription refreshes that history after rejection. The shared
`AppModel.memoryProposals` queue and `getMemoryProposals()` remain pending-only.
History read failures retain the last loaded history and display an error.
Today watches `memory/memory.sqlite` and its WAL alongside the approval and
notification queues in its existing coalesced refresh, so pending-memory counts
and the rail indicator update after another surface resolves a proposal.

## Switches

Self-improvement's training, promotion, and route-through-promotion gates read
the saved trust policy through `SelfImprovement+TrainingReads.swift`. Only a
missing policy receives bootstrap defaults. An existing dangling `policy.json`
symlink is unreadable authority: training and promotion deny, and approval
routing throws before mutation, preserving the saved entry.

Mac semantic search resolves recall IDs from canonical active records instead
of intersecting them with the newest-200 browsing list. Deleted, corrected,
and contradicted records are excluded at projection time; lexical fallback
still uses the bounded browsing list.
Every successful canonical list refresh reruns an active semantic query through
the existing generation gate, invalidating copied results and older completions
even when the changed record lies outside that browsing window.

All six live in `<dataRoot>/trust/policy.json` under `memoryPolicy` and are read
fresh on every call by `MemoryPolicyGate`
(`Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+PolicyGate.swift`). An
unparsable file fails closed. The Settings cards in
`Sources/NativeAgentApp/SetupFeatureRows.swift` write the same keys.

| Key | Default | Settings card | Gates |
|---|---|---|---|
| `knowledge_graph_enabled` | off | Knowledge graph | projection hook (a delete, and a write while off, always reach the graph — as a retirement, never as an index), backfill, recall enrichment, `search_kg`, `rebuild_knowledge_graph`, hygiene backfill |
| `cross_session_recall` | on | Remember across conversations | packet memory lane and automatic recall; the `recall_memory` tool is never gated |
| `consolidation_enabled` | on | Memory consolidation | the weekly card |
| `adaptive_promotion` | on | Memories that recur become facts | promoter closure in `AppDelegate+Launch.swift` |
| `auto_promote_consolidated` | on | Keep consolidated memories without asking | consolidator |
| `hygiene_enabled` | on | Memory hygiene | consolidator and hygiene cleanup in the runner |

"Memory in every reply" separately selects the ContextFlow mode (Off, Observe
only, or Active); it is not the cross-session recall policy switch.

The meaning-based memory card (vectors) is a separate capability switch; the
graph's `meaning_search` follows it. See Embeddings below for the model.

Regression looks like: a switch off in Settings but the feature still firing (check
`memory.crossSessionRecall` in the turn trace), or the gate reading a stale value
after the file changed.

## Writing memories

Opening MemoryV2 checks memory and proposal scalar decoding as well as JSON and embedding
integrity. Invalid required fields (including a NULL primary key) throw through
the storage-unavailable path; later row reads also use checked decoding. Repair
must preserve the damaged database rather than replacing it with an empty store.

### commit_memory

`SwiftToolDispatcher+MemoryTools.swift`. Contract: the text is the thing itself.
No date, time, source, session id, or heading in the text; those are fields.

### The moment lane

`MemoryV2+Moments.swift`. Narrations only: balanced JSON parse, at least six words,
word-fold span check so a user's own sentence is never stored as a moment.

`MindMomentExtractor` (`Sources/NativeAgentApp/MindMomentExtractor.swift`) runs the
extractor on the agent's real mind: a Providers "Memory" row that says anything — a
model pin, or a provider assigned to it — resolves on the "memory" routing surface,
where the pin wins and an assignment-without-pin decides the model (2026-09-06 — it
used to demand a pin, which ignored the assignment). A BLANK Memory row resolves on
"chat" instead, so it inherits chat's provider as well as chat's model; on "memory" it
would carry no active-provider entry and dispatch would infer the transport from the
model prefix. Same resolution in the kind backfill
(`NativeClient+MemoryApprovalExecutors.swift`). The
system prompt carries the personality background context verbatim; 20 s deadline;
on-device fallback.

Regression looks like: rows that start with "Record of", carry a timestamp in the
text, or quote the user verbatim as a moment.

## The store

MemoryV2, `Modules/NativeAgentCore/Sources/MemoryV2/`. Storage path under the data
root; the consolidator derives the policy root from it (two levels up) UNLESS the
caller passes one. The consolidation gate always passes the real data root: it runs
the consolidator against a candidate COPY of the database under
`memory/consolidation/candidates/<runId>/`, and no `trust/policy.json` is ever
copied there, so a derived root read no policy at all and both switches fell back
to on (2026-09-06).

## Embeddings

`Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Embedding.swift` and
`MemoryV2+EmbeddingRuntime.swift`. A CoreML sentence embedder on the Neural Engine, run
from Swift; the WordPiece tokenizer is Swift too. Nothing else is involved at
runtime.

- **Bundled floor**: `minilm.mlpackage` + `minilm_vocab.txt` in the MemoryV2
  resource bundle, all-MiniLM-L6-v2, 384 dimensions, 43 MB. Always present.
- **Optional large model**: when staging succeeds, a release DMG carries `Contents/Resources/embedding/`
  (`embedding.json` + model + vocab), staged by `script/build_and_run.sh` and
  `script/release.sh` from `extras/embedding/` in the checkout, which is
  gitignored because the model is too big for git. The model is published as
  an asset on the standalone GitHub pre-release
  `embedding-model-bge-large-en-v1.5`; `script/fetch_embedding_model.sh`
  downloads, verifies and unpacks it, and `build_and_run.sh` runs that fetch on
  a first build (`NATIVEAGENT_SKIP_EMBEDDING_FETCH=1` to skip). Source builds
  and release builds without the folder fall back to MiniLM. A failed release
  fetch is nonfatal; a DMG is not guaranteed to contain bge-large.
- **Installed model** (user-placed, wins over both):
  `<dataRoot>/extras/coreml/embedding.json` beside the files it names:
  `{"model": "embedding.mlpackage", "vocab": "vocab.txt", "model_id": "…",
  "dimensions": N}`. The model must take `input_ids` and `attention_mask`
  (int32, [1, 128]) and return either token vectors [1, 128, N] or a pooled
  vector [1, N]; the runtime L2-normalises either. Producing one is a one-time
  build step (PyTorch to CoreML through coremltools); the app never runs it.
- **Epoch**: model id, dimensions, model digest and vocab digest form the
  embedding epoch. At launch `reconcileMemoryEmbeddingEpochAtLaunch()` in
  `Sources/NativeAgentApp/NativeAgentEmbeddingWarmup.swift` compares the store's
  active epoch with the provider's; on a mismatch it re-embeds every memory,
  proposal and tombstone atomically and keeps the previous epoch for rollback.
  Launch skill-pointer synchronization follows epoch reconciliation, so changed
  skill bodies can be written against the newly activated provider epoch.
  An unknown retained corpus kind refuses rollback as `unusableCandidate`
  before comparing row sets or changing embeddings; damaged rollback rows do
  not trap the process or mutate the active epoch.
  A memory written or forgotten mid-flight invalidates the candidate snapshot
  and the activation refuses it as `corpusDrift`; the warmup then re-snapshots
  and retries, up to three attempts (`attempts` in the receipt). A refusal for
  the candidate itself (`unusableCandidate`: duplicate staged rows, empty
  vectors, mixed dimensions) fails once and stops — retrying it would embed the
  whole corpus three times for the same answer. Should the store still end up on a
  different epoch from the provider, recall degrades to the keyword lane rather
  than returning nothing, and says so: storage returns the fallback flag with
  its hits, so `MemoryRecallHit.source` is `swift-native-keyword-fallback`, the
  dense-lane persona-starvation alarm stays quiet, and `search_kg` reports
  `meaning_search: keyword-fallback`. Receipt:
  `<dataRoot>/memory/embedding_epoch_receipt.json`.
- 2026-09-06: the directory digest is length-prefixed (path and contents), which
  closes a serialisation collision between different file layouts and changes
  every epoch fingerprint — every install re-embeds once at the next launch.
- **Query expansion**: recall asks every question twice, as written and with
  first-person words swapped for the agent's name and second-person words for
  the user's (`MemoryV2+RecallQueryExpansion.swift`), keeping the better score
  per row. A row written in either voice answers a question asked in either.
  2026-09-06: the Fluid Context packet lane does it too — `beginQueryEmbedding`
  embeds both voices in ONE batch, the ticket and `ContextTurnRequest` carry
  the second vector, and selection's semantic feature takes the better of the
  two cosines. Until then only the legacy lane expanded, so automatic packet
  recall missed the row the legacy lane found.
- **Lexical lane**: the dense cosine carries an additive normalised-BM25 boost
  (`memoryBM25LexicalBoost`, 0.25) before kind-recency decay, lifecycle and the
  bounded use-count nudge. 2026-09-06: the BM25 QUERY terms are filtered through
  `RecallLexicalNormalization.stopWords` — the same list the context router has
  always used — because the boost is normalised by the best candidate's raw
  score, so a row sharing only "what"/"does"/"me" with the question could take
  the whole boost from the row that answered it. Documents keep every token; a
  question made only of stopwords ("who are you") gets ZERO keyword signal —
  the dense lane carries it. The cold keyword lane (`recallByKeyword`, used
  when no query embedding exists) selects on the SAME filtered terms as it
  ranks on, so its bounded candidate scan cannot fill with filler
  matches before BM25 runs. The scan uses `memoryStoredRowCap` (2,000), the
  canonical corpus bound, so 400 earlier matches cannot hide newer answers
  before ranking or prevent the disclosure lane from refilling its results.

2026-09-05, measured on the agent's own rows, sixteen questions they would ask,
rank of the row that should win, with the query expansion applied:

| Model | dims | size | top-1 | top-3 | worst rank |
|---|---|---|---|---|---|
| all-MiniLM-L6-v2 (bundled) | 384 | 43 MB | 10/16 | 14/16 | 32 |
| bge-small-en-v1.5 | 384 | 65 MB | 13/16 | 13/16 | 23 |
| gte-small | 384 | 65 MB | 10/16 | 13/16 | 19 |
| gte-large | 1024 | 670 MB | 12/16 | 15/16 | 23 |
| mxbai-embed-large-v1 | 1024 | 670 MB | 12/16 | 13/16 | 6 |
| **bge-large-en-v1.5** (installed) | 1024 | 637 MB | 13/16 | 13/16 | 5 |

Apple's own `NLContextualEmbedding` was tried and ranked below MiniLM on the
same pairs; it is a token-level model, not a retrieval one. bge-large is the
installed model on the primary machine (CLS pooling and normalisation baked
into the package; parity with PyTorch cosine 0.9999994). Recall latency with it
is 70 to 180 ms per query.

Note: until 2026-09-05 the bundled MiniLM vocabulary differed from the standard
uncased BERT vocabulary in exactly one token: "user" had been replaced by "user"
(a de-personalisation sweep), so under MiniLM the primary user's name tokenised
as sub-words. The standard file is restored; the vocab digest is part of the
epoch, so MiniLM installs re-embed once at the next launch.

Regression looks like: the receipt stuck on "failed", `on_new_epoch` below the
active row count (`select count(*) from memories where status='active' and
embedding_epoch = (select active_epoch from memory_embedding_state)`), or
`meaning_search: unavailable` from `search_kg`.

## Knowledge graph

`Modules/NativeAgentCore/Sources/KnowledgeGraph/KnowledgeGraph+MemoryIndexing.swift`
owns scheduling and rebuilds. Entity extraction and `taggedNameIsCredible` live
in `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` in the same directory.

- Entity extraction, in order: known people (the primary user, the agent's
  own name from `profile.json`, and the built-in peer agents Claude and
  Codex), known terms (products, model families as tools), backticked
  identifiers (a bare lowercase word is skipped), file names, then
  `NLTagger` name types filtered by `taggedNameIsCredible`. One node per name;
  the first lane to claim a name wins, so a name can never be both a person
  and a concept.
- `taggedNameIsCredible` drops the tagger's known mistakes on short rows, each
  from a live failure on 2026-09-05: glue with a lowercase word inside
  ("KG upgrades"), a verb glued to a known person ("Greet User"), short all-caps
  acronyms ("AI", "API"), titles ending in a role noun ("Agentic Systems
  Architect"), a common noun after the/a/an ("Fear the Sky"), a place used as
  an adjective ("Pacific time", "Chicago style"), and a sentence-initial word
  that never appears mid-sentence in the row ("Judge glass…", "Nudge it…").
- The canonical rebuild is a function of the current rows: after
  primary-user consolidation it purges every node no indexer stamped and every
  edge no indexer wrote, whatever provenance they carry, keeping the
  primary-user hub and the rows other live writers own (`studio-journal`,
  `rem-growth-eviction`, and `legacy-import`, which the one-time JSON import in
  `KnowledgeGraph+SQLite.swift` stamps on every row it lands so the purge can
  tell hand-written legacy content from daemon-era residue). The hub's mention count is reset to zero first, so a
  rebuild states counts instead of adding to them. Before this, "Agent"
  survived as a concept with 42 000 mentions and edges like "User instance_of
  Agent" through every rebuild, and any import with some other provenance kept
  being re-adopted by name and re-incremented.
- Garbage collection extracts with the same `knownPeople` the indexer used, from
  the one resolver, so a name the indexer filed as a person (`CODEX`) is not
  read back as junk and swept along with a surviving memory's edge to it.
- Index version `swift-memory-kg-v5`; `ownedIndexerVersions` includes v4 so old
  rows are re-owned and re-indexed, never orphaned.
- KG's SQLite search candidate filter uses GRDB's `swiftLowercaseString`, the
  same Unicode case conversion as the Swift reranker, so uppercase accented
  names are not dropped by ASCII-only filtering before scoring.
- KG page offsets that exceed the integer range return empty entities/edges
  with the requested page and actual totals (2026-09-06). SQLite still checks
  store availability; legacy slices also bound the end without overflowing.
- `search_kg` (`SwiftToolDispatcher+KnowledgeGraphTools.swift`) fuses text hits
  with `memoryV2.recall` vectors by reciprocal rank; results carry `matched_by`
  and `meaning_search`; limit clamped 1 to 100. When recall degrades to the
  keyword lane (epoch mismatch or a cold embedder) the hits are labelled
  `swift-native-keyword-fallback`, `matched_by` says `keyword` rather than
  `meaning`, and `meaning_search` reports `keyword-fallback`.
- `rebuild_knowledge_graph` calls `reconcileKnowledgeGraphProjection`.
- Studio works (`KnowledgeGraph+StudioRelations.swift`) are identified by title
  AND creator, not title alone (2026-09-06): two different works sharing a title
  used to become one node, and the relation drawn between them came out as a
  self-loop and was dropped. Medium and date stay out of the key — they are
  optional per entry, and one work journaled with and without a medium must not
  split in two. Identity holds on the READ side too: the relation audit and the
  canon evidence key works by title and creator, and `studioEdgeCitations` keys
  each edge endpoint by the writer's node key (the creator read off the work's
  own `created_by` edge), not by the endpoint's name. So does the encounter
  intake — `unjournaledWorkCandidates` suppresses a graph work only when the
  journal has answered that title BY THAT CREATOR. Two keys cannot re-collapse
  onto one entity id: an id another key resolved to in the same pass is claimed
  in every branch of `upsertStudioEntity`, and the name+type reuse fallback also
  refuses any row that IS another key's derived id. A key left with no usable id
  writes no node and no edge that pass rather than borrowing another work's row.

Regression looks like: a rebuild that reports far fewer facts than active rows
with names in them, `search_kg` results with `matched_by` never showing
`meaning`, a person node whose name is a verb or an acronym, or the same name
under two types. Check with: `select type, name, mention_count from kg_entities
where type <> 'fact' order by mention_count desc`.

## Recall into a turn

`ChatOrchestration+TurnEngine.swift`: cross-session recall and the packet memory
lane, both behind `cross_session_recall`; trace flag `memory.crossSessionRecall`.
Corrections still ride into turns when recall is off (deliberate; flag if
unwanted).

## Consolidation and hygiene

`Sources/NativeAgentApp/MemoryConsolidationHygieneRunner.swift` and
`MemoryV2+Consolidator.swift`. Weekly card on the approved cadence; only an
explicit block skips it (Full Mac no longer does). Hygiene cleanup and graph
backfill run on the same cadence behind their switches.

What consolidation may and may not merge (2026-09-06):

- **Stale archive evidence (2026-09-06).** An unrepresentable numeric
  `recall_count` throws through consolidation's existing failure path before
  that memory is archived. Valid truncation, age and usage checks are unchanged.
- **Atomic corroboration.** Resolving a duplicate proposal and incrementing the
  target memory's `recall_count` share one SQLite write transaction. Metadata
  is read inside that transaction so concurrent corroborations cannot overwrite
  one another. Missing targets or already-resolved proposals abort the merge;
  projection hooks run only after commit.
- **Duplicate-write counters (2026-09-06).** Reasserting an identical memory
  rejects unrepresentable numeric `recall_count` values or increment overflow
  before updating the row, using the existing storage error path. Representable
  doubles still truncate toward zero; missing/other-typed counts still start at zero.
- **Scope.** Every hygiene pass lists with `persona: nil`, so both the exact-text
  grouping and the semantic pass key on the DISCLOSURE SCOPE as well as the text:
  persona id plus the privacy tier and permitted surfaces
  `MemoryRecordDisclosurePolicy` would compute. A proposal only merges into an
  active memory in its own scope. Two rows readable in different places are two
  rows, however alike they read. Supersession of the single-valued kinds
  (location/employment/identity) groups by scope AND kind for the same reason:
  "only one can be true" holds inside one persona and one disclosure scope, and
  the newest row in one scope never archives another scope's current fact.
- **Epochs.** Cosine is only meaningful inside ONE vector space, so consolidation
  compares two rows only when both carry the same non-empty `embedding_epoch`
  (duplicate selection, supersession, and active semantic dedup alike).
  Unstamped or cross-epoch rows are not compared at all: duplicate selection and
  supersession skip the pair, and the semantic dedup pass skips it too. The
  exact-text grouping that runs before them is not conditioned on epochs, so a
  row still merges there on identical text — the same discipline recall's
  candidate scan already applies.
- **Usage vetoes eviction, at swap time too.** The candidate archives rows that
  were unused when it was staged, and the fingerprint deliberately ignores
  `use_count`. The swap therefore keeps a row ACTIVE when the candidate archived
  it but its live use count grew since staging (`transactionalTableSwap` in
  `MemoryConsolidationGate+Database.swift`). The
  committed store then matches neither fingerprint in the manifest, so the swap
  writes an applied marker — one row per run in the live store's
  `consolidation_applied` table — INSIDE its own transaction, and the
  crash-window recovery treats that marker as proof the swap landed whatever
  the live fingerprint now says (2026-09-06). Without it a veto'd swap whose
  projection pass failed was refused as stale on the retry, the candidate
  discarded and the swap reported as nothing applied; with a marker written
  after the commit instead, a crash in between — or any canonical write landing
  before the retry — reopened the same hole. The projection reconcile the
  recovery re-runs is idempotent, so recognising an applied swap twice is safe.
- **Torn REM proposal feeds remain recoverable.** Appends separate an
  unterminated tail before writing the next row. Compaction skips feeds with
  malformed nonempty lines, preserving repair evidence instead of dropping it.
- **Dream/REM routing.** Both runners resolve their own surface preference,
  preserving explicit pins and the router's cheap unattended defaults. They
  no longer substitute Chat's selected model for an unpinned background lane.
- **REM target context.** Weekly REM keeps GROWTH in the full-persona system
  message and references that section from the user prompt when the target
  body matches. Standalone calls without that system context still include
  the target body, as do reads that differ from the system snapshot.
- **Failed standing-view holds remain unsaved on retry.** The substrate retains
  the pending hold and its capacity releases in memory. A repeated hold retries
  those writes before reporting success, without repeating lifecycle receipts
  or capacity calculations. Restore replaces this pending state with disk truth.
- **A distillation failure evicts nothing.** REM's GROWTH eviction
  (`REMConsolidator+GrowthEviction.swift`) throws on an empty model response instead of writing
  a placeholder node, so the source slice stays in `GROWTH.md` and the next
  weekly tick retries.
  Headingless entries are recognized by exact standalone approved lesson text
  from the proposal feed and compaction base. Text before the first evidenced
  lesson or non-Conventions entry heading remains the authored preamble; a
  missing approval record does not authorize guessing at paragraph boundaries.
- **Proposal staging is one transaction.** `propose`'s pending-dedup match,
  evidence merge and insert all run under one storage write lock
  (`MemoryStorage.stagePendingProposal`), so two observations of the same fact
  landing together cannot lose each other's sessions/recurrence or both insert.
  As of 2026-09-06, an unrepresentable numeric recurrence count or sum overflow
  throws before any staging write. The throwing merge is forwarded through the
  bridge into the existing SQLite transaction; the fallback also fails before
  updating metadata. Representable conversions, defaults and accrual stay the same.

Closed 2026-09-06 (was: the "deferred" stamp could be re-stamped "completed" on
the next pass, masking a skipped week). `reconcileAppliedMaintenanceTruth` in
`MemoryV2+ConsolidationGate.swift` replays every applied terminal receipt on
every reconciliation; it now refuses to overwrite a `hygiene_last_run.json`
record whose `createdAt` is NEWER than the receipt being replayed. An equal
stamp writes only when the record's `consolidationRunId` is the replaying run's
own — these stamps are second-resolution, so two different runs can share one,
and accepting every equal stamp let them overwrite each other on every pass.
Same-run equality is what crash-window and upgrade recovery need, and it is
unchanged.

Usage credit. `SwiftNativeMemoryV2.recall` bumps `use_count` for what it
RETURNS; a caller that retrieves wider than it delivers passes
`recordingUsage: false` and reports the delivered ids with `recordRecallHits`
(the Mac memory search does). Closed 2026-09-06 for the legacy turn lane too:
`SwiftNativeMemoryV2Recaller` retrieves without crediting and the turn engine
credits `deliveredRecalledMemoryIDs` — the rows left after REM-pin dedup and
after the renderer's row limit and block bound — through
`recordServedContextHits`, the same bump the Fluid Context packet lane uses.

## The agent's own curation

`SwiftToolDispatcher+MemoryCurationTools.swift`, registered in Dispatch,
SchemaBuilders, ToolCatalog (deliberate-pull set and core catalog), SecurityCenter
tool profiles (`safe_read` / `memory_write`, low).

| Tool | Does |
|---|---|
| `list_memories` | active rows, oldest first, pages of up to 100; `next_after_id` is a `created_at\|id` cursor, so a page resumes after that position even when the agent forgot the row it named |
| `rewrite_memory` | replace the text of one row |
| `forget_memory` | retire one row |
| `rebuild_knowledge_graph` | reproject the graph from the store |

The store is the agent's. Claude never edits rows; the agent distills them.
2026-09-05 pass by the agent: 80 kept, 107 rewritten, 138 dropped, graph rebuilt
to 136 facts, 172 active rows.

## Retry safety

`ProviderErrorAfterToolEffects.readOnlyToolNames` in
`ToolLoopSupport.swift` lists `inner_state` and `agent_introspect` as
effect-free so a provider drop right after them still allows a replay. Memory
write tools are effects. See [Turn resilience](TURN_RESILIENCE.md).

## History

- 2026-09-04: settings audit of the six keys; gate introduced so the card and the
  gate can never disagree about "unset".
- 2026-09-05: commit_memory contract; moment lane narration gate; extractor on
  the real mind; curation tools; graph tagger and vector fusion; index v5; the
  agent's full-store distillation.
- 2026-09-06: the graph switch is honoured by the indexing path itself; GC and
  the indexer share one known-people resolver; the rebuild owns by stamp, not by
  provenance value, and resets counts; epoch activation retries a stale
  snapshot and recall falls back to keywords on an epoch mismatch; the artifact
  digest is length-prefixed; `list_memories` pages by ordering key.
