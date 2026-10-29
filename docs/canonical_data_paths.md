# Canonical data paths

Selected stores and their source owners; this is not a complete inventory.

Model-catalog and dream-theme caches, memory repair/backfill receipts,
desktop-chat identities, pending welcomes, named-run Stop markers, gRPC
descriptors, abandoned-turn cursors, recovered builder inboxes and widget status
publish through `SwiftNativePersistenceCore.writeDataAtomicDurable`. Domain
owners retain paths, encodings, locks and failure handling; the byte owner
creates parent directories and durably publishes private replacements.

## Root resolution

`PersistenceCore/PersistenceDataRoot.swift`'s `defaultDataRoot` chooses, in order:
non-empty `NATIVE_AGENT_DATA_ROOT` literally (`~` stays literal), a dev bundle's `REPO_PATH` + `/data`, or the install's Application Support directory.

`defaultPersonaRoot(dataRoot:)` uses `<repo>/persona` for checkout data, otherwise
`<dataRoot>/persona`; `PersonaRootResolver.resolveIsolated` always uses the latter.

`PersistenceCore/NativeAgentWorkspaceRoot.resolve` chooses a trimmed, tilde-expanded
`NATIVE_AGENT_WORKSPACE_ROOT`, then checkout `workspace/`, then `<dataRoot>/workspace`.
Pass the owning engine's root URLs through dispatch and connector contexts;
never infer the app's root from shell cwd or reconstruct its literal spelling.

Page actions and observation use `appModel.engine.dataRoot`; Desk retains its
veto handler on that engine's `DeskFacade` alongside its displayed rows.

Chat opening-line projections are owned per standardized data root, including
their cached session revisions and `LatestRead` publication. `TranscriptsFacade.openingLines` resolves
`ChatShellOpeningLine.forRoot(_:)` for its root; index and command-palette
preparation, sidebar filtering, own-conversation classification and subtitles
all use that same owner. The sidebar cache includes the owner identity as well
as its revision, so identical session rows and revisions in different roots
cannot reuse a filtered list. Copied session IDs cannot reuse another root's
opening words or last-turn timestamp.

## CANONICAL STORES

Paths below are relative to `<dataRoot>` unless stated otherwise.

| Path | Purpose / source owner |
|---|---|
| `chat/sessions.json` | Chat session index; `Transcripts/ChatSessionIndexFile.swift` owns every live commit, including transport row restoration/creation, binding-failure cleanup and retention under one index lock |
| `life-id` | `PersistenceCore/DataRootLife.swift` owns the data root's life through the durable writer and exclusive first-life link; written once when absent, replaced by the restore intent's new identity, retained in backup metadata |
| `chat/proactive_speech.json` | `ChatTurnRuntime/ProactiveAssistantSpeech.swift` owns claims and hourly quota. Only an absent store starts empty; existing root, caller, key, timestamp and destination fields must decode before a write. Damaged bytes are preserved and posting throws a storage error. Legacy missing destinations remain eligible for transcript reconciliation. |
| `chat/messages/<sessionId>.jsonl` | Per-session transcript; `Transcripts/TranscriptRows.swift` (`ContactThread`) owns byte mutations; `ChatSessionWork/SentTurnContext.swift` stores exact user-leading context in row metadata ([contract](conversation-context-history.md)); `ChatSessionWork/ChatSessionAutocompactor.swift` selects compaction rows |
| `chat/index/history.sqlite` | Derived history projections owned by `ChatToolRuntime/ChatHistoryIndex.swift`; SQLite retains cold rows/receipts, reads materialize the requested transcript, and manifest replacement changes only added/departed references and reclaims departures. The launch catalog sweep reconciles missing files once. Projection semantics, rather than app builds, version rows; schema 2 migrates its manifest references once to schema 3. Excluded from backup, export and phone sync. |
| `chat/sessions/<sessionId>/scratch.json` | Session scratch JSON object; `Transcripts/ChatSessionScratch.swift` owns path, locked mutation and reads for Mac, Telegram and tools; only an absent file bootstraps empty, and an existing non-object refuses writes with its bytes preserved; off-disk backup only; no local backup/export/phone sync |
| `backups/restore-receipt.json` | `TrustPersistence/TrustBackupRestore.swift` durably records the last completed restore and each unreadable piece, why it was omitted, and what was not kept; private local state, covered by the existing backups privacy category, outside backup scope and excluded from production export and phone sync |
| `chat/mac_turn_lifecycle.json` | `ChatTurnRuntime/MacChatTurnLifecycleStore.swift` owns lifecycle evidence and pending requests; local backup captures this file before attachment bytes; requests retain their life and Resume starts stopped requests fresh |
| `backups/index.json` | TrustBackupPersistence's sole catalog for new backups and cleanup; `registry.json` remains read-only legacy input. Readers merge existing legacy snapshots with index records taking precedence, retaining the existing array/wrapped-row formats |
| `memory/memory.sqlite` | MemoryV2 storage; `MemoryV2/MemoryV2+Storage.swift` |
| `agents/a2a-receipts/outcomes.sqlite` | `Agents/AgentContactTaskReceipts.swift` keeps payload-bearing and compacted contact tasks in the existing `outcomes(key, receipt)` table. Reads import file-first `agents/a2a-replies/*.json` records before removing them; damaged files stay preserved and unavailable. Payload expiry updates the same row; launch recovery and owed callbacks read this store. Covered by the agents privacy scope; no local backup, production export or raw phone sync. |
| `expansion/record.json` | Each mind's practice at the door (phase 4): per mind (`self`, `helper:<id>`, `agent:<id>`), model and authority (its own turns, or turns the same untrusted principals steered, kept apart), its situations' last 8 next calls (the call as written, never one carrying a `:secret` argument, with the paths each value flowed from, the gap before it and its run time) and per prediction its record (tries, hits, unknown, changes, delivered, prepared, withheld, the stem's own run times); `ChatTurnRuntime/Expansion.swift` writes it atomically off every call's path, one write at a time (changes made during a write go in the next). Only a missing file starts empty; an unsupported version remains unavailable with its bytes preserved. Local only; no phone sync. |
| `memory/after_turn_surprise.jsonl` | Append-only record (version 3) of each turn's complete no-op prediction, whether it was deferred, and its label (what the judgment, live or batch, said per channel), keyed by agent, memory model and detector; `MemoryV2/AfterTurnSurpriseLedger.swift`. Numeric evidence and source IDs, no conversation/memory prose. Covered by the existing memory privacy scope; no raw phone sync. |
| `<personaRoot>/USER.md` | MemoryV2's generated user-document projection when an explicit persona root is supplied; see below |
| `telegram/config.json` | Telegram configuration; `TelegramBot/TelegramBot+Config.swift` |
| `telegram/state.json` | `TelegramBot/TelegramPollLoop.readState` and `mutateState` own checked reads and locked mutations for polling, migration and status consumers; only missing state starts empty; unreadable/non-object state is unavailable, names this path, and is preserved |
| `connectors/registry.json` | `PersistenceCore/ConnectorOAuthRegistry` returns checked rows from `readRegistry` and owns every checked durable publication, including bootstrap and Slack recovery, and the connectionDecision field: only the person's own connect/disconnect records connected/disconnected. Seeds, first reads and migrations are undecided; missing decisions read as undecided without inferring from enabled/authState. Credential migration reads only this decision: connected or undecided may migrate; a recorded person-disconnect never does |
| `connectors/actions/receipts.jsonl` | `PersistenceCore/ConnectorActionReceipt` owns the schema, path and capped append for connector actions and Slack HTTP proofs; `Connectors/ConnectorProofLedger` reads health evidence |
| `connectors/slack/auth.json` | Canonical Slack metadata and Keychain grant reference; `SlackBot/SlackCredentials.swift`; metadata and token migration obey `PersistenceCore/ConnectorOAuthRegistry.permitsCredentialMigration` under registry → auth locks: connected or undecided may migrate; only a recorded person-disconnect retires `oauth_tokens/slack.json` without import until explicit reconnect. Eligible missing canonical auth imports checked legacy metadata once and verifies publication before removing the source; file tokens move through verified Keychain writes before runtime credential reads and plaintext removal, canonical values winning over legacy input; runtime policy reads only canonical auth |
| `providers/registry.json` | Provider registry; `ProviderRouting/ProviderRouting.swift` |
| `providers/active.json` | Saved provider assignments by surface; same owner |
| `providers/surfaces.json` | Saved surface model/effort choices; same owner |
| `codex_home/auth.json` | App-managed Codex OAuth credentials; `ProviderRouting/LLMClient+OpenAIOAuthCredentials.swift` |
| `context/context.sqlite` | Context storage; `Context/ContextSQLiteStore.swift` |
| `cognition/cognition.sqlite` | Cognitive state and artifacts; `CognitiveSubstrate/CognitiveSQLiteStore.swift`. Also holds, outside what Clear deletes and outside the restore bundle: `cognitive_epochs` (the mind's forgetting epoch and the fold-seq allocation) and `lived_moments`, the settled-turn journal (`CognitiveSQLiteStore+LivedMoments.swift`; rows stamped with their `DataRootLife`, owed → meant → lived or refused; ordinary settlement drops payloads, retains identities and prunes rows after 30 days; damaged rows are refused individually with reason and repair debt, payloads preserved outside pruning; unsettled rows never pruned by age; [SUBCONSCIOUS.md](SUBCONSCIOUS.md#lived-moments)). Clear and Reset are owner transactions, outside this journal. Continuity nodes carry `lived_seq` |
| `cognition/organism_state.json` | Organism continuity, with the body's forgetting epoch (`epoch`), its lived-moment watermark (`lived`) and its recently-dosed encounters; `Cognition/NativeCognitionRuntime+BodyContinuity.swift` (one atomic writer, the persistence drain; persists only after its restore finished) |
| `cognition/reach.json` | Reach offers and whether each landed; `Cognition/ReachLedger.swift`, written atomically by the runtime actor; an unreadable ledger blocks outreach |
| `cognition/user_turn.json` | The person's last turn stamp (`at`, `previous`, `key`) read by Since gap, Reach timing and source wakes; `ChatTurnRuntime/ChatTurnEvidence.swift` (`UserTurnStamp`) holds its sidecar file lock across the read/update and writes atomically; a delayed older timestamp cannot replace a newer stamp. Only a missing file bootstraps; unreadable/invalid bytes stay intact and owe repair through Experiences, including unavailable reads |
| `cognition/dream_themes.json` | Derived dream-theme cache (root, canonical embedding epoch, diary, stamp, phrases with vectors); `Cognition/NativeCognitionRuntime+Continuity.swift`; rebuildable, single-flight writer per root; old or mismatched caches rebuild, including equal-width model changes. Query vectors share the root/epoch key and use the canonical query embedding form. |
| `cognition/caring_appraisals.jsonl` | One typed interpretation receipt, amended with what the body did; `Cognition/CaringReceiptLog.swift`; a projection of the lived moment's first fold, never read back into their mind; off-disk backup only |
| `memory/moments_held.json` | Retired held-turn queue: imported once into the lived-moment journal as owed moments and emptied; never written again; `MemoryV2/AdaptiveMemoryPromoter+Migrations.swift` |
| `workflows/approvals/requests.json` | Approval records; `ApprovalInbox/ApprovalInbox.swift` |
| `runs/runs.json` | Run ledger; `SwarmRuns/RunLedger.swift` |
| `improvements/gauntlet/runs.json` | Bounded run array (latest 200); `AppToolRuntime/NativeRegistryEvaluation.swift` appends under the file lock. Only absence starts empty; an existing non-array root raises a schema error and preserves the file. |
| `turn_traces/<yyyy-MM-dd>.jsonl` | Turn-correlated diagnostics; `TurnTrace/TurnTracePersistLane.swift` also owns standalone `traces/events.jsonl` receipts; `TurnTrace/TurnTraceRecentReader.swift` reconciles retained historical rows through `traceEvidence`. |
| `turn_traces/practice/<agent>.json`, `turn_traces/practice/<agent>.tape.jsonl` | Each agent's practice ([as built](AGENT_IS_THE_APP.md#practice-compiles-the-night-as-built-10-27)), `resident` or `helper-<id>`: the ledger (nominated sequences, their state, coverage and ability) written by the night (`EngineRuntime/EnginePractice.swift`) and read by the dispatch tracer for its recording set; the tape, redacted rows of only the calls whose operation a nominated sequence still learning uses, each keeping its arguments when exact and of its result every path redaction left unchanged within the bound, the left-out paths named (`omitted`: path and `redacted` or `over_bound`), appended by `ChatToolRuntime/ChatToolDispatchTrace.swift`, each with its call-end sequence (`seq`, the order the trim keeps), 64 KiB a row and 8 MiB an agent (the oldest half dropped). `TurnTrace/TurnPractice.swift` owns both; they share the traces' privacy: excluded from all backups and archive inputs, no phone sync. |

Source paths above are under `Modules/NativeAgentCore/Sources/`.

Proactive claims, transcript reconciliation and append share the claim-store
lock. A duplicate result requires the exact assistant row at the recorded
destination/run, source and idempotency key. A pending claim with clean absence
completes at that same destination/run; unreadable or damaged transcript evidence
keeps the outcome unknown and blocks another append. Append failures retain the
claim for that reconciliation, replacing the former claim compensation path.
Claims predating serialized append require positive transcript proof: absence
alone cannot prove their earlier append has ended, so it leaves them unknown.
Connector scheduler create/list/cancel actions and work-journal project selection
retain the requesting engine's data root, the same root used for admission and
receipts. They do not reselect the process default during execution.

Embedding assets live beside `<dataRoot>/extras/coreml/embedding.json` or bundled `Resources/embedding/embedding.json`;
[MEMORY_SYSTEM_MAP](MEMORY_SYSTEM_MAP.md#embeddings) owns installation and epoch convergence.

`MemoryV2+UserMDGen.swift` uses the supplied persona root for `USER.md`;
without one, it resolves `<dataRoot>/persona/<persona>/USER.md`.
App launch supplies `PersistenceCore.defaultPersonaRoot(dataRoot:)` for this projection.
Onboarding recognizes only a single ordered autogen body and an optional empty
preamble as reproducible. Foreign headings, comments, preamble content and
malformed markers are authored content and require the backup-preserving reset path.

Task-ledger compaction bases require faithful decoding, including retained owners,
reference entries and unknown fields. Only the historical `agent` owner spelling
and an absent compaction count have explicit decode migrations; failed reads
preserve the snapshot rather than rewriting a reduced projection.

Use [Data bounds](data-bounds.md) for retention and
[Runtime storage limits](runtime-storage-limits.md) for disposable diagnostics.

## Restore law

**A restore brings back what they had, never what they was doing.** Every
resumable record keeps the data-root life in which it began. Only that life may
resume it. A missing stamp means the first life, so an upgrade alone does not
stop unstamped work. Work from another life reads **stopped**, reason **restored**;
the person's Resume starts fresh work in the new life, never saved effects.
`DataRootLife` owns this boundary for resumable work. Nonempty completion and task
collections share one current-life read; standalone operations read it fresh.
There is no per-kind restore settlement or review flag.

Before replacing scopes, `TrustBackupPersistence` writes and retains a normal
backup through the existing writer, reason `before restore of <backup name>`.
Its SQLite copier opens sources read-only and closes them before replacement;
it never opens a live MemoryV2 owner against the life being replaced.
If it cannot be written, no scope is replaced and the failure says why. It is
the source for selected readable continuity facts; the restore never reinstalls
it as a rollback. The restore intent's UUID becomes the new life, also across
interrupted installation.

The selected backup's queues, conversations and attachments remain its own;
there is no current-work overlay. The life being left keeps its work in the
normal safety backup. Domain owners select only credential/consumption facts,
the phone version floor and ability kinds absent from older backups for continuity.
Unreadable selections are omitted with piece, cause and loss in the receipt;
invalid approved backups, an unavailable safety backup and write failures remain
errors. Interrupted intents install the approved target forward.
