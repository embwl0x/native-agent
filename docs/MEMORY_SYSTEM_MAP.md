# Memory system map

MemoryV2 owns durable memories, proposals and rejection tombstones. Context,
the knowledge graph and generated USER.md carry projections of that store.
Cognition and organism continuity have their own advisory state; they do not
replace canonical memory.

Source paths below are relative to `Modules/NativeAgentCore/Sources/`.
For the memory standard, see [What a good memory is](memory-quality.md).

## The pipeline in one line

Turn interpretation or an explicit save → MemoryV2 → canonical SQLite
transaction → derived projections → selected context or explicit recall.

Agent reaches memory through them one `app` tool:

```text
app {"page":"memories"}
app {"action":"memory.recall","args":{"query":"what to recall"}}
app {"action":"memory.list","args":{"limit":20}}
app {"action":"memory.moments","args":{"lane":"all"}}
```

`AppToolRuntime/AppActionRegistry.swift` registers these actions.
`memory.commit` saves a memory; `memory.review` accepts or rejects a proposal;
`memory.rewrite` edits, pins or restores a record; `memory.forget` forgets it.
Read the page for the current arguments and applicable action warnings.

## Ownership after the September splits

| Owner | Responsibility |
| --- | --- |
| `MemoryV2/MemoryV2+Storage.swift` | `MemoryStorage` actor and shared database pool; canonical writes, ordered graph/Spotlight hooks, USER.md regeneration and context invalidation. |
| `MemoryV2/MemoryStorage+Migrations.swift`, `MemoryStorage+Codecs.swift`, `MemoryStorage+Integrity.swift` | Schema, checked decoding and semantic integrity of the same store. |
| `MemoryV2/MemoryStorage+Proposals.swift`, `MemoryStorage+Tombstones.swift` | Proposal acceptance/rejection and suppression of rejected or forgotten content. |
| `MemoryV2/MemoryStorage+Recall.swift`, `MemoryRecallScoring.swift` | Cached recall candidates, vector and lexical scoring. |
| `MemoryV2/MemoryV2+AdaptivePromoter.swift` | Calls the shared interpretation, screens candidates and stages fact/moment proposals. |
| `ChatTurnRuntime/MindMemoryManager.swift` | One model interpretation returning memories, a possible moment, affect and a caring judgment. |
| `KnowledgeGraph/KnowledgeGraph+MemoryIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: ordered per-memory entity, edge and support projection into the shared SQLite database. |
| `ContextFlow/NativeMemoryContextProjection.swift` | Compiles eligible memory records into selectable context atoms. |
| `MemoryV2/MemoryV2+ConsolidationGate.swift` | Builds and stages a candidate, then reconciles approved application and derived projections. |

The storage extension filenames in this table share the `MemoryV2/` directory.

## Writing memories

### Explicit saves

`memory.commit` enters `ChatToolRuntime/SwiftToolDispatcher+MemoryTools.swift`
and calls `SwiftNativeMemoryV2.store`. Text must be nonempty. Kind, confidence,
importance, tags and supplied provenance travel as metadata. A deliberate
`kind: "moment"` save also carries valence and salience for later re-feeling.

`MemoryV2+Wiring.swift` handles quality screening, duplicate handling,
tombstones and embedding before storage. A tool result must be checked: a
refused save is not a remembered fact.

### The memory-manager lane

`AdaptiveMemoryPromoter` invokes `MindMemoryManager.interpret` with the
incoming message, available reply, bounded existing/pending memories and the
speaker's name. Bridge peers are named as peers; `bot-` sessions are skipped.
The model uses the Memory route when separately configured, otherwise Chat.

The interpretation returns four parts: fact decisions, a possible lived moment,
affect deltas and a caring judgment. `NativeCognitionRuntime.refreshConfiguration`
connects the cognition context and completion callbacks, so the same result
feeds memory and feeling. An unavailable or malformed interpretation is a
failure, distinct from a successful empty result.

Fact decisions are screened for confidence, duplicates, rejected content and
standing-rule evidence. An update must refer to a memory shown to the model.
Accepted candidates become **pending proposals**, not automatically accepted
facts. Standing corrections also retain their subject and originating turn
time.

### The moment lane

Moments have a separate enablement switch and daily capacity in
`MemoryV2+AdaptivePromoter.swift`. The shared interpretation can stage at most
one moment per exchange; it remains pending until review.

`memory.moments` reads the queue; `lane: "all"` includes other proposal kinds.
`memory.review` accepts or rejects a pending proposal. An optional `content`
edit applies only to moments. `acceptReviewedMoment` prepares final wording
and its embedding, then admits both in one storage transaction. A failed edit
does not accept the original wording as a substitute.

Owners: `ChatToolRuntime/SwiftToolDispatcher+MomentTools.swift`,
`MemoryV2/MemoryV2+Proposals.swift`, `ReviewedMomentAcceptance.swift`.

## Corrections, supersession and scope

A replacement and a denial have different consequences. An accepted update
retires its target through the atomic superseding-acceptance path. The target's
reviewed fingerprint must still match; otherwise the proposal stays pending
for review. Rejection/forgetting use tombstones to prevent unwanted content
from returning.

For explicit `memory.commit`, `corrects` names an existing record; the result
reports whether that correction applied. `context_topics` narrows a correction's
context scope. Other kinds ignore that field; valid correction topic strings
are bounded, and empty input supplies no scope. If no valid scope is supplied,
`CorrectionScopeAtIntake` may derive topics from tools actually dispatched in
that turn. With no derivable scope, the correction remains global.

Owners: `MemoryV2+Proposals.swift`, `MemoryStorage+Proposals.swift`,
`ChatToolRuntime/SwiftToolDispatcher+MemoryTools.swift`.

## The store

Canonical storage is `<dataRoot>/memory/memory.sqlite`. Memories, proposals,
tombstones and embedding-epoch state share the `MemoryStorage` pool.
Content mutations invalidate recall candidates and publish the exact database
locator to derived-state consumers. Recall-cache reuse also checks SQLite
`data_version`, so writes from another connection invalidate stale candidates.

`MemoryV2+UserMDGen.swift` regenerates USER.md under the target file lock from
canonical memory while preserving its human preamble. It refuses damaged
existing documents and gates generation on onboarding. USER.md is a projection,
not an independent place to repair memory facts.

## Embeddings

`MemoryV2+EmbeddingRuntime.swift` owns runtime embedding selection;
`MemoryV2+Embedding.swift` implements the bundled Core ML MiniLM provider.
The installed model descriptor can override the bundled model.

To supply an override, place `<dataRoot>/extras/coreml/embedding.json` beside
the Core ML model and its vocabulary, for example:

```json
{
  "model": "embedding.mlpackage",
  "vocab": "vocab.txt",
  "model_id": "custom-embedding-v1",
  "dimensions": 1024
}
```

Use the model's actual identifier and positive output dimension. The three
string fields must be nonempty. `model` and `vocab` must be filenames without
slashes; both must exist beside the manifest and resolve within that directory,
including through symlinks.

The model must accept `input_ids` and `attention_mask` as int32 tensors shaped
`[1, 128]`. It must return token vectors shaped `[1, 128, N]` or a pooled vector
shaped `[1, N]` or `[N]`, where `N` matches `dimensions`. The runtime mean-pools
token vectors using the attention mask and L2-normalizes the resulting vector
or the supplied pooled vector.

Vectors carry a `MemoryEmbeddingEpoch`. `MemoryStorage+EmbeddingEpoch.swift`
owns corpus activation, and recall checks compatibility before comparing
vectors. A cold embedder can use lexical recall; model corruption and dimension
errors propagate rather than masquerading as healthy semantic search.

## Knowledge graph

`SwiftNativeKnowledgeGraphIndexer` projects memory-derived entities, edges and
support into `kg_*` tables in the same `memory.sqlite`. MemoryStorage's
migrations own that schema. `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift`
owns deterministic extraction; it does not approve memories.

`KnowledgeGraphReader.swift` exposes checked reads. Once SQLite exists, an
unreadable database is an error. Legacy JSON is only a pre-SQLite compatibility
source. `graph.search` and `graph.rebuild` are actions on the Memories page;
the knowledge-graph policy gate applies to reading and rebuilding.

## Recall into a turn

`ChatTurnRuntime/ChatOrchestration+TurnEngine.swift` prepares the context.
On an active ContextFlow turn, memories arrive through the selected packet;
the separate recall list stays empty. Context preparation errors stop that
turn. When ContextFlow is off, the engine can use explicit MemoryV2 retrieval
for its automatic recall block.

`MemoryRecordDisclosurePolicy` filters records by status, lifecycle and allowed
surface; both explicit recall and automatic projection consume that policy.
`ContextBudgetPolicy` sizes the turn's memory/context allowance, while
`ContextSelectionContracts.swift` owns selector limits.

`ContextFlow/NativeContextMemoryProvenance.swift` attaches selected atom-to-record
identity to the exact prepared turn and its generation lease without changing
packet text. The turn accounts for delivered memory IDs, and
`ChatOrchestrationClient+MessagePersistence.swift` stamps `memoryRecordIds`
on cognitive events. Cognition can then reactivate those memories and re-feel
served moments using their stored valence and salience.

## Switches

`MemoryV2+PolicyGate.swift` reads the checked Trust policy at use time.
Damaged saved authority disables the affected gate.
Keys live under `memoryPolicy` in `<dataRoot>/trust/policy.json`.

| Policy key | Consumer |
| --- | --- |
| `cross_session_recall` | Automatic recall and the packet's memory row allowance. Explicit `memory.recall` remains available subject to normal policy. |
| `adaptive_promotion` | Fact proposal lane; moments have their own switch. |
| `knowledge_graph_enabled` | Graph indexing/read/rebuild admission. |
| `consolidation_enabled` | Gated consolidation. |
| `auto_promote_consolidated` | Defaults on. “Keep consolidated memories without asking” controls eligible proposal auto-acceptance during consolidation; it does not bypass approval of the candidate-to-live swap. |
| `hygiene_enabled` | Memory hygiene. |

Disabling cross-session recall excludes every MemoryV2 source from ContextFlow,
including automatic correction atoms. Explicit `memory.recall` remains
available subject to normal policy.

## Consolidation and hygiene

`BackgroundWork/MemoryConsolidationHygieneRunner.swift` invokes the memory
maintenance owners. `MemoryV2+ConsolidationGate.swift` works on a candidate
database and compares it with live memory before staging an approval card.
A staged candidate has **not** changed live memory.

Approved application rechecks fingerprints, backs up live storage and swaps
tables transactionally through `MemoryConsolidationGate+Database.swift`.
Reconciliation completes USER.md, Spotlight, graph and Context invalidation
before recording successful completion. `MemoryConsolidationGateContracts.swift`
keeps staging outcomes separate from applied, stale, denied and failed outcomes.

Dreams and REM have separate artifact owners in `DreamREMCycle/`; they are not
another MemoryV2 database. Their connections are mapped in
[COGNITION_WIRING.md](COGNITION_WIRING.md).
