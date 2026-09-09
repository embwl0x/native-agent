# Memory system map

2026-09-09: Memories labels terminal proposal rejection “Don't keep”. Rejected
history reveals loaded records sixty at a time and opens the existing full-text
sheet from each row. Counts describe loaded history; retrieval, ordering,
identity, and the separate pending queue remain unchanged.

2026-09-09: Telegram voice notes awaiting speech permission remain transport
inbox entries, not accepted conversation or agent memory. They enter the normal
turn path only after transcription succeeds; no additional memory store exists.
2026-09-09: Providers' optional activity overrides expose the existing Memory,
Memory review and Personal growth model choices through the same routing owner.
Folding those controls changes no memory policy, default, saved pin or prompt.

Studio working shelf: `PersistenceCore/StudioWorkingShelf.swift` owns the private
`studio/working_shelf.json` ordered selection sidecar (zero to three slots).
`studio_shelf_set` replaces only this list, validating source-verbatim journal
sentences atomically (one complete terminated sentence, with a required chosen
short title and at least one entry or non-description-only consult work ref);
`studio_shelf_read` resolves all recorded work refs, including
linked consult pairs, and labels unavailable work without substitution. Relative
local paths use the native file resolver and report missing files as missing.
Shelf argument validation ignores dispatcher-internal keys. Neither
changes journal/canon nor publishes cognitive events. The existing Studio context
projection carries one bounded titles-only line when nonempty, including when
journal entries are unavailable; reads refuse content that secret redaction would
alter rather than mislabeling it as verbatim. The existing invalidation
namespace refreshes after an explicit set. Native image dispatch adds a stateless
optional `studio_journal` invitation with all saved paths after success.
No automatic filing, reads, counters, or Studio-hour changes.

2026-09-09: reviewed image execution receipts record provider, read-only sandbox,
allowlisted environment key names and the general-agent boundary, never inherited
secret values. Four-verb capture bindings and retained document windows are
call-local observation state; they create no agent memory or durable belief.
Structural-fusion and render-cap test captures explicitly confirm that same
call-local binding; the release-gate fixture repair adds no persistent state.

2026-09-08: iPhone `mobile.icloud.unverifiedRecords.v1` is a local transport
diagnostic/verification-deferral cache in UserDefaults, not agent memory or a
delivery receipt. It retains record metadata, reason, observed pairing version,
and a key digest; no message content or pairing secret is stored. Successful
verification removes the row. A version or key change permits another attempt.

2026-09-07: Telegram `/new` publishes its anchor only after index creation and
conversation-map update succeed; a failed map update rolls back the new index
row before retention runs. CloudKit inner authentication failures create only
digest-keyed quarantine evidence, never accepted transaction or response state.
Canonical memory, transcripts, and persona ownership are unchanged.
2026-09-07: iOS clarity closeout gives the Memories navigation bar opaque
canvas backing to mask large scrolled text beneath the title. Reading-secondary
ink is strengthened; search, snapshot, proposal and deletion owners are unchanged.
Before/after AX2 scrolled captures: `ios-shots/f1g/README.md`.

2026-09-07: iOS Memories search, connection status and Dynamic Type segment
buttons scroll with the rows, releasing the AX2 reading viewport. Snapshot,
filter and action owners are unchanged. Evidence: `ios-shots/f1f/README.md`.

2026-09-07: iOS Memories labels snapshot importance explicitly and groups
freshness, account/connection cause and recovery in one reading surface.
The account probe is read-only and entitlement-guarded. DEBUG layout fixtures
are view projections only; canonical memory, proposals and deletion remain
owned by the existing store/action transport. Evidence: `ios-shots/f1d/README.md`.
2026-09-07: `TelegramSessionStore` validates the complete `chats` map on reads
and locked mutations. Damaged session bindings and topic persona settings stay
byte-preserved and unavailable until repaired; only missing storage bootstraps.
Canonical transcript, memory, and persona ownership are unchanged.
2026-09-07: iOS secondary-screen design fixtures are DEBUG process-local view
projections. They never enter memory, persona, sync snapshots or action stores;
Knowledge Graph and Self-Improvement retain their canonical Mac data owners.

2026-09-07: CloudKit fallback drain checkpoints are transient transport read
progress only; incomplete or unreadable scans cannot acknowledge messages.
Canonical memory and persona ownership do not change.

2026-09-07: iOS reply/pairing recovery changes only transport verification and
local chat handoff ownership. It observes the original reply/transcript without
re-executing the request and does not write canonical memory or persona.
2026-09-07: Mac CloudKit run-scoped cancellation admission changes receive
scheduling only. It uses the existing MacSync active-run registry and durable
action responses; canonical memory and the chat terminal receipt owner are
unchanged. See `docs/TURN_RESILIENCE.md` for receive/cursor ownership.
Slack conversation continuity (2026-09-07): `SlackSessionStore` validates
`slack/session_map.json` under the mutation lock and atomically binds a newly
opened channel reply thread to the originating canonical chat session. Follow-up
messages reuse that session rather than a copied transcript. Malformed maps
remain byte-preserved, with a `.damaged` quarantine copy, and unavailable until
repaired; neither an invalid entry nor a missing original with quarantine
evidence authorizes new bindings. Canonical memory ownership is unchanged.
Attachment HTTP failures and MCP UI approvals (2026-09-07) retain existing
delivery-journal, ApprovalInbox and security-audit ownership. Permanent Slack
4xx failures settle through the unreadable notice; MCP confirm requests use
canonical chat-tool approval replay. No new memory store or prompt data.
2026-09-07: PersistenceCore's reporting JSONL reader counts invalid UTF-8 as
malformed even on an unterminated final line. Telegram compaction's existing
malformed-read refusal therefore preserves the original bytes; read-only tail
consumers retain tolerant decoding. No canonical memory ownership changed.
2026-09-07: Telegram `/compact` now distills all replaced transcript rows in
chronological batches, carrying prior recollections without prefix clipping.
The newest 20 rows stay verbatim. Invalid or unavailable summaries refuse the
replacement; no canonical memory/persona writes are part of this operation.

2026-09-07: `EmbeddingModelDownload` in MemoryV2 installs the standalone public
embedding release into `<dataRoot>/extras/coreml`. Digest-keyed partial ranges
survive launches; SHA-256 and manifest validation precede replacement. App
launch reads `Bundle.main`'s `embedding-download.json` even in Balanced/Low
memory modes; its URL, `byte_length` and SHA-256 are the download authority.
Missing descriptors or `distribution: bundled` skip downloading; no GitHub
metadata lookup remains. Changed descriptor digests update only installations
with a valid downloader-owned `release.sha256` marker. Unmarked or malformed-marker
directories are preserved, with a custom-model status and no forced convergence;
absent installations still download. Ownership is rechecked before replacement.
`EmbeddingModelDownloadRow` is hidden when no download is required and shares progress,
pause and resume between Memory and Diagnostics. After install, the controller
releases the provider and invokes the existing epoch/corpus reconciliation.

Where every part of the memory pipeline lives, which switch controls it, how to see
it working, and what a regression looks like. The standard the pieces are held to is
[What a good memory is](memory-quality.md). The lifecycle narrative is
[Internal Workings, anatomy of a memory](INTERNAL_WORKINGS.md#2-anatomy-of-a-memory).

## The pipeline in one line

StandingBots' shelf is **NOT memory**. Run-once and scheduled checks now share
the same runner and shelf; accepted run-once UUIDs are the shelf entry IDs.
Only explicit shelf tool reads return evidence to the requesting turn. No book
is automatically injected into chat, memory, or user notifications; scheduling
signals carry no book content. `nothingNew` and `failed` survive index/drill-down
unchanged, and failed checks preserve last-good evidence.
`BotDefinitionStore` persists only bot
configuration/audit; `ShelfStore` persists untrusted books under `<dataRoot>/bots/`.
Shelf append and last-good access use per-entry files and a recoverable index;
legacy daily books migrate once without deletion. Runs retain a per-bot kernel
file lock through shelf/continuity settlement across processes. Provisional
partial receipts precede continuity publication, then finalize with elapsed
storage time and honest failed/partial budget overruns. Every redirect and OAuth
401 retry rechecks fresh bot authority; invalid legacy cron affects only its bot.
`BotRunner` writes that shelf from isolated unattended checks. Typed tool sources
use the existing structured engine through `StandingBotToolLoop`, with no memory
promoter or automatic recall/persona/chat context. Any available catalog tool
can be selected as a source; every actual call still passes live Trust admission
and the existing read-only file-access gate. Selection grants no permission.
The person-owned Bots page cadence floor defaults to 15 minutes and can reach
1 minute; daily and per-run ceilings are unchanged. Tool results are untrusted evidence, and checked `tool:name`
references join HTTP links in the unchanged book envelope. Optional `outputFormat`
controls the body and may request named kept reports. No book is promoted by the structured loop.
Scheduled and queued checks share effect-time Trust Center admission, public-only
HTTP/redirect admission (numeric connection pinning with original-host TLS trust
and connected-peer verification) and durable daily fleet token reservations. Rejected
checks append failure reasons to the shelf, never to memory. Cadence starts at
completion with a 15-minute minimum; per-run limits are 32,000 tokens/120 seconds
and the aggregate UTC-day ceiling is 256,000 reserved tokens.
Each bot also owns bounded working notes in `bots/<id>/context.json` and up to
eight named kept reports, with immutable linked revisions in `bots/<id>/documents/`.
Working notes cap at 12,000 UTF-8 bytes; each report caps at 32,000 bytes. The
current manifest stays bounded while prior report versions remain history.
The app supplies the existing in-flight mechanical compactor through
`StandingBotContinuity`; it runs entirely in memory without a distiller call or
resident memory sink. Runs receive bounded, explicitly truncated projections and
report only changed findings. Nonfailed completed runs publish context/report
updates after the shelf append; persistence failure is explicit and prior state
remains available. Failed or timed-out runs do not replace working material.
`bot_ask` is on demand, source-free, and uses only that bot's retained material
with the same autonomy admission, cheap provider, deadline and token ceilings.
Its enclosing settled deadline starts at ask entry, includes claim/admission/spend,
and gives provider work only the remaining time while retaining the claim until settlement.
The dispatcher forwards the app-assembled lifecycle observer into these calls
so provider vitals observe the same request lifecycle as scheduled bot runs.
It changes only fleet spend, returning the answer solely as the tool result.
`shelf_documents` lists current named reports; `shelf_document` reads bounded
character pages by name/version and exposes previous revision IDs. Neither
acknowledges run entries. Nothing from these stores pushes into the agent.
Only the configured brief/format, source list, explicitly collected untrusted
evidence, bounded bot-owned working material and last good book enter the fresh session. No automatic persona, memory
or chat context is read or written. The scheduler emits no notification. Books remain available only by
explicit shelf reads; the runner does not acknowledge them on anyone's behalf.
Neither store calls MemoryV2, recall, context assembly, providers or notifications.
Bot storage reads and writes reject existing symlinks beneath the canonical data
root, including kept-report directories and run claims. Tool sources exclude known
Mac Integration writes even when a tool name contains a read-like word.
Books never enter context by themselves. Lazy `shelf_read` explicitly pulls compact
cross-bot index rows (240-character headline/change previews); `shelf_entry`
drills down by ID. ChatOrchestration acknowledges exactly the returned IDs as
reader `agent`, after constructing the result. Agent acknowledgements and UI read state
use distinct caller-supplied reader IDs in `bots/cursors.json`; neither promotes
evidence or advances the other's state. The tools add no preset bots, automatic
readers, memory promotion, or always-on prompt content.

turn → moment extractor / commit_memory → MemoryV2 store → knowledge graph
projection (+ vectors) → recall into the next turn → weekly consolidation and
hygiene → the agent's own curation tools.

## Ownership after the September splits

Reviewed against `13006f73` on 2026-09-07. These files extend existing owners;
none adds a second fact store. Core paths are under `Modules/NativeAgentCore/Sources/`.

```text
commit / reviewed proposal / accepted moment
  → MemoryV2 → MemoryStorage canonical transaction
  → ordered mutation hook → KG indexer → same memory.sqlite projection
  → recall candidates + scoring → TurnEngine / Fluid Context

redacted turn evidence → substrate ingress → bounded continuity
  → frozen read + organism projection → fitted capsule → presentation commit
Dream/REM output → app replay adapter → substrate episodes/proposals/lineage
```

| Owner | Responsibility and next call |
| --- | --- |
| `MemoryV2+Storage.swift` | `MemoryStorage` actor owns the pool, canonical writes, recall-cache generation and ordered mutation delivery. Content writes invalidate derived recall state and feed the graph hook; counter-only writes use the version-probe connection and recall refreshes usage columns separately. |
| `MemoryStorageModels.swift` | Stored memories/proposals/tombstones, patches, lifecycle factors, defaults, errors and embedding-epoch values. These are contracts, not a database. |
| `MemoryStorage+Migrations.swift` | Storage initialization calls the GRDB migration chain, including KG schema lineage and narrowly validated ledgerless-KG adoption. The graph indexer must not create a competing database. |
| `MemoryStorage+Codecs.swift` | Checked row/embedding/metadata decoding and temporal validation used by storage reads/writes. Malformed required row values throw rather than trapping or becoming healthy emptiness. |
| `MemoryStorage+Recall.swift`, `MemoryRecallScoring.swift` | Recall caches decoded vectors, norms and lexical term counts/lengths; scoring preserves persona-scoped BM25 document frequency, timestamp decay, use-count weighting and bounded selection. External commits still invalidate via data_version. Ranking does not rewrite facts. |
| `MemoryStorage+Proposals.swift`, `MemoryStorage+Tombstones.swift`, `MemoryStorage+EmbeddingEpoch.swift` | Proposal lifecycle, suppression and atomic embedding-corpus activation remain extensions of the same actor/pool. `InMemoryMemoryStorage.swift` is the retained fixture implementation. |
| `KnowledgeGraph+MemoryIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer` owns pool lookup, per-memory update ordering and transactional entity/edge/support projection. Calls the extractor with the resolved known-person vocabulary. |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | Pure bounded extraction, canonical naming and credibility filters. Cannot approve memory, create the database or independently publish graph facts. |
| `MemoryV2+ConsolidationGate.swift` | Candidate preparation and reviewed application with the actual policy root. Calls database helpers and writes gate evidence through `MemoryConsolidationGate+Receipts.swift`; contracts live in `MemoryConsolidationGateContracts.swift`. |
| `MemoryConsolidationGate+Database.swift` | Online backup, candidate/live fingerprints, diff counts, retention and transactional table replacement. The write-transaction fingerprint refuses intervening canonical changes; a candidate is not live memory until application succeeds. |

`Onboarding/Onboarding.swift` retains `SwiftNativeOnboardingClient`, which owns
transactional onboarding/reset/resume, profile repair, and canonical file writes.
The client calls internal `Onboarding/PersonaTemplates.swift` only for baseline
SOUL/VOICE/USER/GROWTH document values, type validation, ordered substitutions,
and the initial timestamp. The generator owns no persistent state and is not
PersonaEngine or a second identity store; PersonaEngine and MemoryV2 authority
remain unchanged.

`PersonaRootResolver` and PersistenceCore's `defaultPersonaRoot` call the
package-scoped `firstSeededPersonaDirectory` in `PersistenceDataRoot.swift` for
lexically sorted, non-hidden child discovery with SOUL.md existence checks.
PersonaRootResolver retains persona selection/migration precedence, while
PersistenceCore retains its distinct persistence-root fallback contract.
The shared primitive owns no state and moves no canonical persona or memory authority.

`WorkshopExecution/WorkshopExecutorContracts.swift` owns only injected approval,
LLM, tool-dispatch and terminal-sink signatures and step receipt values.
`WorkshopExecutorLoop` retains terminal settlement and its lazy execution-memory
queue; `WorkshopExecution+ExecutionMemory.swift` retains recording into canonical
MemoryV2. App `BackgroundLoopsAssembly+WorkshopExecution.swift` supplies the
concrete adapters. Moving the contracts changes neither terminal-memory authority
nor receipt accounting, including unknown versus zero provider counts.

The recall-to-turn boundary is `ChatOrchestration+TurnEngine.swift`, with recall
and post-turn promotion protocols/adapters in `TurnEngineContracts.swift`.
`ChatOrchestration+SessionHistory.swift` supplies session rows;
`SessionHistoryPromptRenderer.swift` derives bounded history/continuity and
recall queries. History rendering does not move transcript truth into MemoryV2.
Existing cross-session-recall and correction rules below still apply.

The substrate stores advisory continuity in cognition SQLite, not
`memory.sqlite`. `CognitiveSubstrate.swift` retains actor state and persistence
health; `CognitiveSubstrateContracts.swift` provides clock, UUID, dynamics,
moment-recall and attention-output seams. `CognitiveSubstrate+Ingest.swift`
deduplicates before mutation, uses the pure `+ConversationalAppraisal.swift`
scan through relational appraisal, then updates continuity/affect/semantic
tags and pending completion. Resident ingress defers writes to its dirty
microcycle; direct ingress waits for its persistence path.

`CognitiveSubstrate+Restore.swift` validates the bundle before applying it;
failed restoration blocks persistence instead of overwriting damaged evidence.
`+Persistence.swift` coordinates writes with `CognitiveSQLiteStore`. App
`NativeCognitionRuntime+Replay.swift` reads existing Dream/REM output and calls
`CognitiveSubstrate+Replay.swift` to integrate deduplicated episode, proposal and
developmental lineage evidence. Replay does not schedule dreams or auto-commit
canonical identity/facts.

`CognitiveSubstrate+Capsule.swift` consumes the frozen read and delegates felt
selection to `+CapsuleFeltSignals.swift`, Sound selection to `+CapsuleSoundEcho.swift`
and repetition/session-bridge wording to `+CapsuleCadence.swift`. It fits the
budget before offering a separate presentation commit; preview or omitted
content must not spend surfaced bookkeeping. `+Values.swift` supplies shared
coercion/text/bounding helpers. `+Research.swift` exports measurements and
no-provider experiments, not canonical memory. App `NativeCognitionRuntimeModels.swift`
carries read/preview/status values; the runtime actor still coordinates the
owners. See the [substrate ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md#source-ownership-after-the-splits)
for phase-to-file traceability and the blueprint for organism prediction owners.

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
unparsable file fails closed. Non-following entry inspection distinguishes a
genuinely absent policy from a dangling symlink or inspection failure: only
absence receives defaults; unavailable saved authority denies access without
changing the entry or its target. An absent block/key retains its documented
default. The Settings cards in
`Sources/NativeAgentApp/SetupFeatureRows.swift` write the same keys.

| Key | Default | Settings card | Gates |
|---|---|---|---|
| `knowledge_graph_enabled` | on | Knowledge graph | projection hook (a delete, and a write while off, always reach the graph — as a retirement, never as an index), backfill, recall enrichment, `search_kg`, `rebuild_knowledge_graph`, hygiene backfill |
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

Fresh installations use Fast (`performance`) memory mode through
`ManagedEmbeddingProvider`: the model stays resident after its first use, with
no idle unload. Saved Balanced and Low choices retain their existing behavior.
The TrustCenter fresh policy enables dreams and the knowledge graph; saved
opt-outs win, and corrupt-policy fail-closed values remain unchanged.

`Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Embedding.swift` and
`MemoryV2+EmbeddingRuntime.swift`. A CoreML sentence embedder on the Neural Engine, run
from Swift; the WordPiece tokenizer is Swift too. Nothing else is involved at
runtime.

- **Bundled floor**: `minilm.mlpackage` + `minilm_vocab.txt` in the MemoryV2
  resource bundle, all-MiniLM-L6-v2, 384 dimensions, 43 MB. Always present.
- **Large-model release packaging** (2026-09-07): `release.sh` packages a local
  `extras/embedding/` as `NativeAgent-<version>.embedding.zip`, independently of
  the DMG. The signed bundle carries `Resources/embedding-download.json`, which
  pins the asset URL, SHA-256, byte length and original model manifest. The
  receipt and attestation carry the same `model_asset` object. Packaging never
  fetches missing resources. `NATIVEAGENT_EMBEDDING_DISTRIBUTION=bundled` retains
  `Resources/embedding/` for the transition release; `separate-download` omits
  it and depends on the app-side downloader consuming the descriptor. See
  `docs/release_setup.md` for the integration contract. `install_app.sh` skips
  model fetching/staging by default and can accept a release descriptor for
  development. Direct `build_and_run.sh` retains its legacy fetching behavior.
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

Shared `KnowledgeGraphEdgeWireSnapshot.swift` owns only common edge wire decoding:
required String endpoints, String `kind` (including empty text) with required
`type` fallback for absent/null/malformed kind, and nil for missing/bad weight.
Mac `KnowledgeGraphModels.swift` and iOS `KnowledgeGraphView.swift` call it from
their local `KGEdge` decoders and retain their computed UI IDs. Mac additionally
decodes optional `mention_count`; iOS ignores it. Entity validation and parent
envelopes stay separate. Canonical `KnowledgeGraph` remains the graph reader/store
owner; Mac publishes the iCloud projection and mobile reads it. This shared value
creates no new graph store or fallback to legacy JSON.

`Modules/NativeAgentCore/Sources/KnowledgeGraph/KnowledgeGraph+MemoryIndexing.swift`
owns indexer state, ordering and incremental projection;
`KnowledgeGraph+CanonicalRebuild.swift` implements canonical-store rebuilds.
Entity extraction and `taggedNameIsCredible` live
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
`MemoryConsolidationGate+Receipts.swift`, called by the consolidation gate,
replays applied terminal receipts without overwriting newer
`hygiene_last_run.json` evidence. An equal
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
# Diagnostic credential boundary (2026-09-07)

Turn diagnostics use `TurnTraceRedactor.redactValue` to recursively remove
credential-named fields before preview serialization. Embedded quoted/escaped
credentials pass through `TurnSecretRedactor`; this changes diagnostic projection
only, not tool inputs/results delivered to the model or canonical memory.
## 2026-09-07 snapshot loading boundary

Mobile memory snapshots use the shared snapshot loader's asynchronous,
cancellation-aware current-version wait, then bounded coordinated I/O on its
dedicated queue. Timeout/cancellation preserves last-good state. Delegation's
process-local parsed receipt cache is rebuildable read acceleration, not memory
or a new settlement authority; older authoritative receipts are retained.
