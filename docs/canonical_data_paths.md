# Canonical data paths

Selected stores and their source owners; this is not a complete inventory.

Model-catalog and dream-theme caches, memory repair/backfill receipts,
desktop-chat identities, pending welcomes, named-run Stop markers, gRPC
descriptors, abandoned-turn cursors, recovered builder inboxes and widget status
publish through `SwiftNativePersistenceCore.writeDataAtomicDurable`. Domain
owners retain paths, encodings, locks and failure handling; the byte owner
creates parent directories and durably publishes private replacements.
Durable regular-file contents require checked `F_FULLFSYNC`; parent namespace
changes use checked `fsync`, selected before the operation. An unsupported or
failed file flush reports unproven durability and never switches mechanisms.
A directory-sync failure after rename can mean the new bytes already committed;
the owner must reconcile that exact destination before repeating the write.

`JSONValue.parse` accepts valid JSON bytes without rewriting numeric tokens.
Bare NaN/Infinity tokens fail decoding; quoted words remain strings. Saved
workflow timestamps are optional ISO-8601 strings, validated before ordering
their stored strings by updatedAt or an omitted updatedAt's createdAt, descending.
Undated rows follow dated rows; equal strings retain stored order. Invalid supplied dates
fail the whole projection and preserve stored bytes.

`DeviceSecretKeychain` never restores or deletes an accepted secret write when
readback fails. It reports the exact service/account as accepted but unverified;
the authority owner rereads that item before a deliberate forward repair.

## Root resolution

`PersistenceCore/PersistenceDataRoot.swift`'s `defaultDataRoot` chooses, in order:
non-empty `NATIVE_AGENT_DATA_ROOT` literally (`~` stays literal), a dev bundle's `REPO_PATH` + `/data`, or the install's Application Support directory.

`defaultPersonaRoot(dataRoot:)` uses `<repo>/persona` for checkout data, otherwise
`<dataRoot>/persona`; `PersonaRootResolver.resolveIsolated` always uses the latter.

`PersistenceCore/NativeAgentWorkspaceRoot.resolve` chooses a trimmed, tilde-expanded
`NATIVE_AGENT_WORKSPACE_ROOT`, then checkout `workspace/`, then `<dataRoot>/workspace`.
Pass the owning engine's root URLs through dispatch and connector contexts;
never infer the app's root from shell cwd or reconstruct its literal spelling.
File path spellings preserve literal percent characters and absolute names:
`/documents` means that root-level directory. Use `~/Documents` explicitly for
the user's Documents directory. Only an explicit `file:` URL decodes URL
transport escaping; percent-encoded path strings are ordinary filenames.

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

### Conversation transcripts

`Transcripts/TranscriptRows.swift` (`ContactThread`) owns byte mutations and
checked slices in `chat/messages/<sessionId>.jsonl`. `ChatSessionWork/SentTurnContext.swift`
retains the exact public moment block once in user-row metadata, excluding
private held choices ([contract](conversation-context-history.md)).
Quiet never ends what they holds. A conversation is held whole until the request
reaches the input budget; then the oldest whole turns go in half-budget jumps.
The input budget is min(model window minus response allowance, 200,000 tokens).
History fitting uses the input budget; refusal and result pointers use model
window minus response allowance, the physical limit.
`SessionHistoryMessages.admission` admits the whole conversation;
`ChatSessionWork/SessionHistoryTail.swift` selects checkpoints without mutating
transcript rows. Displayed messages require saved id, role, content and
createdAt. Damaged rows acquire no invented identity or time; opening, last-turn
and context-statistic reads report unreadable sources rather than certifying
older or empty history.

### Conversation scratch

`Transcripts/ChatSessionScratch.swift` owns `chat/sessions/<sessionId>/scratch.json`,
a JSON object shared by session scratch and the reserved
`__private_working_memory` string (at most 1200 characters). Public scratch reads
exclude that slot. Empty private text explicitly removes it; unchanged values
write nothing. Kernel-locked durable mutation runs off the main actor. Lock
contention refuses with its cause, without a timed wait or retry. Only an absent
file bootstraps empty; malformed bytes and non-objects remain preserved and
unavailable. The file is included only in off-disk backup, with no local
backup, export or phone sync.

<a id="speech-claims"></a>
Speech claims retain `recentKeys` and their exact `destinations`, without a
quota timestamp. Only an absent store starts empty; existing root, key and
destination fields must decode before a write. Missing destinations fail
rather than guessing where a message belongs. Damaged claim bytes are
preserved and posting throws a storage error.

| Path | Purpose / source owner |
|---|---|
| `body/` | The body's REM reservation (`.rem_run.lock`), weekly claim (`last_weekly_rem_run`) and rejection authority (`.rem_tombstones.json`, with its sibling lock); `DreamREMCycle/REMConsolidator.swift` and `DreamREMCycle+HeavyLogic.swift`. Retained `learning_receipts.jsonl` is selected only for support export; `benchmark/` has no live reader or writer. Privacy inventory and off-disk backup exclusion use this same directory. |
| `abilities/.night-fold.json` | `AuthoredCapabilities/AbilityAccounting.swift` owns one prepared surprise window: exact bounds, part/version counts and unattributed totals, at most 8 MiB. It survives restart and trace retention until every version's idempotent fold and the completed night cursor are durable. Missing means no prepared batch; unreadable bytes stay preserved and hold folding. Version run evidence keeps its `surprise_through` watermark in `abilities/state.json`; pending versions survive ordinary run pruning. No prose or secrets, no phone sync. |
| `ui/layout.json`, `ui/layout.previous.json` | `AgentWorkspace/SurfaceLayoutStore.swift` owns the layout and replaced bytes. Every document write, including restoring previous content, checks the caller's current version token after refreshing inside the writer lock; matching previous content never bypasses that check. A failed layout read publishes unavailable with its file path and repair instruction, never a cached layout or in-memory seed. Mac content remains reachable from the shipped surface vocabulary alongside that repair, under shipped profile visibility and the independent Helpers switch; no substitute layout or editable fold state is supplied. The app page index, find and parts ranking use the shipped page set independently of layout. The phone renders the checked availability; `ui_layout.json` carries `SurfaceLayoutAvailability`, including the owner's failure. Only checked file absence permits first creation. |
| `workspace_desktops/<scope-sha256>.json` | `AgentWorkspace/AgentWorkspaceDesktopStore.swift` reads and writes one version-2 desktop shape. `path`, `drafts`, `observations`, `keptPlaces`, `focusedWork` and `placeActions` are required; nested saved desktops require `path`, `keptPlaces`, `focusedWork` and `placeActions`. References and notes the writer omits remain optional. Missing/malformed structural fields fail the read and prevent replacement of existing bytes. `AgentWorkspaceDesktopNavigation.swift` restores the validated saved Back path (up to eight positions) unchanged; only an explicitly empty path opens the saved current place with Home. |
| `notifications/publications/<eventId>.json` | `DeviceSync/MacSyncMobileNotificationRelay.swift` owns immutable notification title/body/userInfo/timestamp retained before transport under a per-event lock. Retries reuse it, including after restart; unreadable or conflicting content stays preserved and fails through `ToolFailureError`. Covered by the notifications privacy scope, excluded from local backup/export; only the signed wire envelope goes to the phone. |
| `chat/sessions.json` | Chat session index; `Transcripts/ChatSessionIndexFile.swift` owns every live commit, including transport row restoration/creation, binding-failure cleanup and retention under one index lock |
| `chat/pinned_session_ids.json` | `Transcripts/ChatSessionRetention+PinnedChats.swift` owns the ordered pin list for Mac navigation, retention protection and phone projection. Only absence means no pins; malformed/unreadable bytes halt retention and preserve the last UI publication. No defaults mirror. Off-disk backup only; no local backup, data export or raw phone sync. |
| `life-id` | `PersistenceCore/DataRootLife.swift` owns the data root's life through the durable writer and exclusive first-life link; written once when absent, replaced by the restore intent's new identity, retained in backup metadata |
| `.onboarded` | Onboarding's durable completion evidence; pending completion/reset still blocks admission. Carried by local/off-disk backup and production export with identity data, never raw phone sync. Restore installs the captured marker; a snapshot without it leaves the live marker unchanged and never creates one from missing evidence. |
| `chat/proactive_speech.json` | `ChatTurnRuntime/ProactiveAssistantSpeech.swift` owns [speech claims](#speech-claims). |
| `chat/messages/<sessionId>.jsonl` | Per-session transcript; [owners and evidence](#conversation-transcripts). |
| `chat/index/history.sqlite` | Derived history projections owned by `ChatToolRuntime/ChatHistoryIndex.swift`; SQLite retains cold rows/receipts, reads materialize the requested transcript, and manifest replacement changes only added/departed references and reclaims departures. Each batch of at most 64 new rows holds one checked action catalog through nested receipt redaction, including lookup misses ([turn anatomy](ANATOMY_OF_A_TURN.md#2-the-user-message-becomes-durable)). The launch catalog sweep reconciles missing files once. Projection semantics, rather than app builds, version rows; schema 2 migrates its manifest references once to schema 3. Excluded from backup, export and phone sync. |
| `chat/tool_results/<turn-hash>/<result-hash>.txt` | Exact overflowing provider-facing result bodies, durably written by `ChatToolRuntime/ProviderToolResultRecovery.swift` before its pointer is admitted. The pointer names a live `result.page` handle and `saved_result_path`; files remain with chat after turn-scoped handles are released. |
| `chat/sessions/<sessionId>/scratch.json` | Conversation scratch and private choice; [owner and privacy](#conversation-scratch). |
| `backups/restore-receipt.json` | `TrustPersistence/TrustBackupRestore.swift` durably records the last completed restore and each unreadable piece, why it was omitted, and what was not kept; private local state, covered by the existing backups privacy category, outside backup scope and excluded from production export and phone sync |
| `chat/mac_turn_lifecycle.json` | `ChatTurnRuntime/MacChatTurnLifecycleStore.swift` owns lifecycle evidence and pending requests; local backup captures this file before attachment bytes; requests retain their life and Resume starts stopped requests fresh |
| `backups/index.json` | TrustBackupPersistence's sole catalog for creation, listing and cleanup: an array of backup records, with optional per-row pins. An absent index starts empty; unreadable/malformed existing bytes fail the operation. No registry merge, wrapped catalog or path substitution. |
| `memory/memory.sqlite` | MemoryV2 storage; `MemoryV2/MemoryV2+Storage.swift` |
| `agents/a2a-receipts/outcomes.sqlite` | `Agents/AgentContactTaskReceipts.swift` keeps payload-bearing and compacted inbound contact/builder tasks in the existing `outcomes(key, receipt)` table. The finished per-reply JSON importer is removed after the old directory was verified empty against this store. Payload expiry updates the same row and excludes unresolved payload-recovery debt; launch recovery and owed callbacks read this store. Ordinary builder ingress writes here, retaining selected-session bindings for queued recovery; historical builder JSONL receipts remain readable where no canonical task exists. Covered by the agents privacy scope; no local backup, production export or raw phone sync. |
| `expansion/record.json` | Each mind's practice at the door (phase 4): per mind (`self`, `helper:<id>`, `agent:<id>`), and authority (its own turns, or turns the same untrusted principals steered, kept apart), its field-free situations' last 8 next calls, including the first reads after `start woke:<kind>` (the call as written, never one carrying a `:secret` argument, with the paths each value flowed from, the gap before it and its run time) and per prediction its record (tries, hits, unknown, changes, delivered, prepared, withheld, the stem's own run times); `ChatTurnRuntime/Expansion.swift` writes it atomically off every call's path, one checked write at a time (changes made during a write go in the next). Failed saves retain unsaved practice as unavailable and owe the exact file's repair, without automatic retry; the [manifest](skill_manifest_spec.md#expansion-a-part-is-a-prediction) owns acknowledgement and closure. Record v3 folds retained v2 model-separated practices on load, keeping the newest bounded examples and pooling counters only for identical historical signatures; v2 backup records were still present in the 2026-11-01 read-only inventory, so this reader remains owed until explicit conversion. Only a missing file starts empty; an unsupported version remains unavailable with its bytes preserved. Local only; no phone sync. |
| `memory/after_turn_surprise.jsonl` | Append-only record (version 3) of each turn's complete no-op prediction, whether it was deferred, and its label (what the judgment, live or batch, said per channel), keyed by agent, memory model and detector; `MemoryV2/AfterTurnSurpriseLedger.swift`. Precedent vectors are stored once per turn, on its prediction row; a recovery attempt that judged nothing adds no row. Numeric evidence and source IDs, no conversation/memory prose. Covered by the existing memory privacy scope; no raw phone sync. |
| `<personaRoot>/USER.md` | MemoryV2's generated user-document projection when an explicit persona root is supplied; see below |
| `telegram/config.json` | Telegram configuration; `TelegramBot/TelegramBot+Config.swift`; credentials use only `bot_token_keychain_ref`, voice size is a positive integer `voice_max_bytes`, and ProviderRouting alone owns model/effort. One locked status read separates checked metadata from the actual credential failure; disconnect reads metadata without resolving the credential and preserves allowlists, mention and voice settings. `ownerUserId` is the single owner identity used by sessions, restart, approvals, model controls, command-memory telling, notifications and rhythm history. Model writes carry that owner's exact `provider.choose` call; other command senders retain their Telegram principal. No plaintext import, retired allowlist parsing or monolithic-config cleanup runs on load |
| `telegram/state.json` | `TelegramBot/TelegramPollLoop.readState` and `mutateState` own checked reads and locked mutations for polling and status consumers; only missing state starts empty; unreadable/non-object state is unavailable, names this path, and is preserved |
| `telegram/update_inbox/*.json`, `claims_index.json` | `TelegramBot/TelegramUpdateInbox.swift` owns ingress and synthetic outbound claims. Empty `previewPending` reservations wait for the canonical answer. Successors publish recovery eligibility before their claim under the same lock and retain the prior run's verdict. Read arrivals and silent completions persist `noRecoverableAnswer:true` atomically with completion, including recovered silence. The claim's derived `isSettled` recognizes that terminal disposition even with a pending preview reservation; pruning and life-change reads use it, so retention can prune once no checkpoint references the claim. The same journal retains prose, images and failure notices; unknown sends do not authorize replay. Existing bot-scoped `.inbox` directories use this same schema/owner. Private local Telegram state; not a phone wire model |
| `telegram/receipts.jsonl`, `blocked.jsonl`, `errors.jsonl`, `errors.jsonl.1` | Diagnostic writers record required event `id` values; readers never synthesize composite identities. Status carries each feed's availability and withholds counts/history verdicts for unavailable feeds. Error rotation and append share one lock; a failed bound/rotation check throws before append. Private Telegram diagnostics; no credential content |
| `connectors/registry.json` | `PersistenceCore/ConnectorOAuthRegistry` returns checked rows from `readRegistry` and owns every checked durable publication, including bootstrap and Slack recovery, and the connectionDecision field: only the person's own connect/disconnect records connected/disconnected. Seeds and first reads are undecided; missing decisions remain readable as undecided for retained data without inferring from enabled/authState. Registry failure is unavailable readiness and never admits another proof ledger as a substitute |
| `connectors/actions/receipts.jsonl` | `PersistenceCore/ConnectorActionReceipt` owns the schema, path and capped append for connector actions and Slack HTTP proofs; `Connectors/ConnectorProofLedger` reads health evidence |
| `connectors/slack/auth.json` | Canonical Slack metadata and immutable Keychain grant reference; `SlackBot/SlackCredentials.swift`. Snapshots and pending-save recovery retain registry → auth lock order. Retired file imports and plaintext token migration are removed. The older per-token Data Protection Keychain reader remains until its owning app can verify those items; the command-line login-keychain inventory cannot prove them absent. Missing canonical metadata means no saved configuration; unreadable existing metadata or grant remains unavailable |
| `providers/registry.json` | Provider registry; `ProviderRouting/ProviderRouting.swift` |
| `providers/active.json` | Saved provider assignments by surface; same owner |
| `providers/surfaces.json` | Saved surface model/effort choices; same owner |
| `codex_home/auth.json` | App-managed Codex OAuth credentials; `ProviderRouting/LLMClient+OpenAIOAuthCredentials.swift` |
| `context/context.sqlite` | Context storage; `Context/ContextSQLiteStore.swift` |
| `cognition/cognition.sqlite` | Cognitive state and artifacts; `CognitiveSubstrate/CognitiveSQLiteStore.swift`. Also holds, outside what Clear deletes and outside the restore bundle: `cognitive_epochs` (the mind's forgetting epoch and the fold-seq allocation) and `lived_moments`, the settled-turn journal (`CognitiveSQLiteStore+LivedMoments.swift`; rows stamped with their `DataRootLife`, owed → meant → lived or refused; ordinary settlement drops payloads, retains identities and prunes rows after 30 days; damaged rows are refused individually with reason and repair debt, payloads preserved outside pruning; unsettled rows never pruned by age; [SUBCONSCIOUS.md](SUBCONSCIOUS.md#lived-moments)). Clear and Reset are owner transactions, outside this journal. Continuity nodes carry `lived_seq` |
| `cognition/organism_state.json` | Organism continuity, with the body's forgetting epoch (`epoch`), its lived-moment watermark (`lived`) and its recently-dosed encounters; `Cognition/NativeCognitionRuntime+BodyContinuity.swift` (one atomic writer, the persistence drain; persists only after its restore finished) |
| `clock/times.json` | The one clock's saved Time fields (`id` as `<owner>:<key>`, `rhythm`, `next`, `payload`, optional `delivered` occurrence and `ended` flag); declarations, consumption and local/off-disk capture share its file lock. Ended times retain delivery/withdrawal evidence but are absent from pending listings and deadlines. Both backup forms and production export carry current clock declarations; engine launch does not read a carry-over marker or retired scheduler format. No projection zone or civil occurrence identity is saved, so a time-zone change while quit remains deferred ([clock limitation](AUTOMATED_SYSTEMS.md#8-bounded-inspection)); `TriggerScheduler/OneClock.swift` |
| `desk/my-queue-carried.json` | MY QUEUE's current run and owed-settlement ledger. Only an absent current file begins an empty ledger; unreadable bytes throw. No retired arrival ledger is read; `AgentWorkspace/MyQueueCarried.swift` |
| `attention/notebook.json` | The turn program's notebook, which `weigh` reads as `felt.notebook`; `ChatTurnRuntime/TurnPart.swift` |
| `cognition/user_turn.json` | The person's last turn stamp (`at`, `previous`, `key`, optional `door`) read by Since gap and rhythm; `ChatTurnRuntime/ChatTurnEvidence.swift` (`UserTurnStamp`) holds its sidecar file lock across the read/update and writes atomically; a delayed older timestamp cannot replace a newer stamp. Only a missing file bootstraps; unreadable/invalid bytes stay intact and owe repair through Experiences, including unavailable reads |
| `mind/rhythm.json` | Timestamp/door-only evidence for the person's day: 24 seven-day forgetting bins, 30 days of hourly first activities and starts, standing claims and once-per-kind/local-day break identities. `Cognition/NativeCognitionRuntime+Rhythm.swift` is the sole writer, using `CognitiveSubstrate/PersonRhythm.swift`; only absence cold-starts from indexed owner history, corrupt bytes remain intact with repair owed. [Rhythm](RHYTHM.md) owns the evidence and admission rules |
| `mind/self.json` | Their existing dream's evidence-linked self-reading: at most five if-then traits, five story lines and 128 person lines, bounded to 256,000 bytes. `CognitiveSubstrate/CognitiveSelfKnowledge.swift` owns the schema and atomic durable write; the substrate is the sole writer/cache owner. Versioned by schema, committed diary source, write time and mind epoch. No persona or memory content is seeded here; corrupt bytes remain intact with repair owed, Clear removes the file and pre-Clear epochs cannot return. [Becoming](BECOMING.md) owns the material windows and turn admission |
| `cognition/dream_themes.json` | Derived dream-theme cache (root, canonical embedding epoch, diary, stamp, phrases with vectors); `Cognition/NativeCognitionRuntime+Continuity.swift`; rebuildable, single-flight writer per root; old or mismatched caches rebuild, including equal-width model changes. Query vectors share the root/epoch key and use the canonical query embedding form. |
| `experiences/experiences.sqlite` | Caring appraisals, dosing responses and feedback reactions are immutable details of their turn; see below. |
| `memory/moments_held.json` | Empty retired held-turn file left untouched; no reader or writer. The lived-moment journal owns all owed turns. |
| `workflows/approvals/requests.json` | Approval records; `ApprovalInbox/ApprovalInbox.swift` |
| `workflows/approvals/telegram-deliveries.json` | Telegram approval/inline prompt dispatch and returned-send receipts; `ApprovalTransactions/TelegramApprovalCoordinator.swift`. A dispatch without a returned receipt is unknown and cannot authorize a resend. Local approval backup/export scope; not a phone snapshot. |
| `runs/runs.json` | Run ledger; `SwarmRuns/RunLedger.swift` |
| `improvements/gauntlet/runs.json` | Bounded run array (latest 200); `AppToolRuntime/NativeRegistryEvaluation.swift` appends under the file lock. Only absence starts empty; an existing non-array root raises a schema error and preserves the file. |
| `turn_traces/<yyyy-MM-dd>.jsonl`, `traces/events.jsonl` | Retired: turn events and standalone receipts are details in the record (`experiences/experiences.sqlite`, [Storage](EXPERIENCE.md#storage)), written by `TurnTrace/TurnTracePersistLane.swift` and read through it. Existing files are untouched and no code reads or writes them; `~/.claude`-side tooling may import their last two weeks once. |
| `ability_fetches/<uuid>.json` | `ToolExecution/ToolExecution+RunSandbox.swift` saves each admitted modifying fetch's (any method but GET/HEAD) complete redacted transport receipt once, after actual exit; a read keeps no receipt or experience and is safe to repeat. Excluded from off-disk backup. Its `fetch:<uuid>` experience references this file and owns the `finish` obligation; caller expiry/Stop/run close never removes the request or its late result. Missing/unreadable receipts are unavailable evidence requiring service reconciliation, never automatic replay. No age-based cleanup is currently applied. |
| `turn_traces/practice/<agent>.json`, `turn_traces/practice/<agent>.tape.jsonl` | Retired nightly candidate ledger and nominated-call tape ([Habits H4](HABITS.md#h4--one-crystallizer)); no live reader or writer. Existing files are untouched and remain under turn-trace privacy exclusions (no backup, archive input or phone sync). Existing abilities' embedded tape fixtures stay with the ability owner and its replay/admission checks. |

Source paths above are under `Modules/NativeAgentCore/Sources/`.

Telegram claim mutations compare retained fields before changing `updatedAt`.
Index upserts compare the stored update ID and phase before writing or publishing
a delivery change.

`AgentWorkspace/BodyQueue.swift` files and settles self-findings through the
canonical Desk store with `project: "body"`; findings keep their producer's key,
handle, ownership and references. Home projects these as `body:desk.<alias>`
rows of kind `body`, drawn by `Resources/abilities/native-home.js`. The contact's
send receipt names its finding with `body_item`.
`ChatToolRuntime/BodyDecidedRow.swift` records decision rollups in the existing
experience store with `body_decided.<requester>.<tool>.<uuid>` identities and
`face.from: "body_decided"`; the matter's row badge owns its count.

`Cognition/CaringReceiptLog.swift` writes `caring.appraisal` and the body's later
`caring.dosing` response. `ChatSessionWork/OutcomeFeedbackStore.swift` writes and
reads transcript-anchored `feedback.reaction` details. The experience record owns
their two-week horizon. Local backup, export and raw phone sync exclude the whole
record. Off-disk backup includes its experiences and events, removing only the
detail table from the staged copy; the live record is unchanged. Retired trail files stay
untouched. The inbox, its archive shelf and the delivery ledger are readings of the experiences addressed to them
(`Experiences/ForPerson.swift`); their old files are converted once offline and leave the data root.

Proactive claims, transcript reconciliation and append share the claim-store
lock. A duplicate result requires the exact assistant row at the recorded
destination/run, source and idempotency key. A pending claim with clean absence
completes at that same destination/run; unreadable or damaged transcript evidence
keeps the outcome unknown and blocks another append. Append failures retain the
claim for that reconciliation, replacing the former claim compensation path.
Claims predating serialized append require positive transcript proof: absence
alone cannot prove their earlier append has ended, so it leaves them unknown.
Scheduled-read create/list/cancel actions and work-journal project selection
retain the requesting engine's data root, the same root used for admission and
receipts. They do not reselect the process default during execution.

The Codex handoff has one identity: `NATIVE_AGENT_CODEX_HANDOFF_PATH` when
explicitly configured, otherwise `~/CODEX_HANDOFF_FOR_AGENT.md`.
`PersistenceCore/CodexHandoff.swift` owns this path for connector reads,
cognition and file wakes. Readers do not search for another file when it is
missing or unreadable. A direct handoff read propagates its read failure.
The work journal retains collected project evidence when the handoff is
unreadable, naming its canonical path and actual error in an unavailable
handoff row. Either an unavailable or missing handoff makes the journal partial.

Research owns `research/config.json` (an object with an optional string
`searxng_base_url`) and `research/lab/runs.json` (an array of complete current
runs). Missing files mean unconfigured search and empty history respectively;
damaged existing files fail without replacement. Every saved run requires
`id`, `objective`, `status`, `query`, `sources`, `brief`, `createdAt`, `connector`
and nullable `error`; unavailable historical fields are not reconstructed.
Receipt retention checks regular-file metadata and modification times before
deleting beyond the newest 200 mixed receipts. Its per-directory owner retains
failures in memory, reports them in `receipt_retention` on fetch readouts and
logs `[Research.retention]`; a future fetch requests another pass without
clearing an outstanding fault until a pass succeeds. A pending or unmeasured
pass is not evidence that the cap was met. Issued filesystem work finishes
under VolumeIO after its caller's wait ends and releases the directory only
on physical completion; completed source reads remain valid independently.

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

Slack's policy in `connectors/slack/auth.json` has one checked shape, owned by
`TransportAllowlist.SlackPolicy`: `allowed_channel_ids` and `allowed_user_ids`
are arrays of nonempty strings; `require_mention` and `socket_mode_enabled` are
Booleans; `user_id` and `team_id`, when present, are nonempty strings. Missing
lists admit nobody; missing options retain setup defaults (mention required,
Socket Mode enabled), without establishing a credential grant. Alternate field
names and scalar coercions confer no authority. Setup publishes a fresh current
metadata object and exactly the submitted lists. Ingress, settings and
SecurityCenter consume this same policy reader. The connector registry records
Slack's connection time only as `connectedAt`; `client_id_present` is its setup
marker, with no camel-case alias or registration-time fields.

During a Slack turn, each notice kind retains its send claim after acceptance
or an uncertain outcome. Only a proven Slack rejection releases the claim for
another notice of that kind; a transport error or missing response does not.

`slack/inbound_delivery_journal.json` alone owns accepted inbound delivery
evidence: `completed_without_post` retains the reading/silent turn ID; posted
replies retain confirmed text-part and image progress. Each text part has its
own fingerprint under the saved reply. Explicit `/retry resend` resumes the same
answer and run from its first unconfirmed part; confirmed text and images are
never resent. Only a new successor answer resets that progress.
A truncation warning settles unconfirmed,
and reconciliation requires one matching bot/thread post with the next part's
echoed event/fingerprint metadata before continuing. Slack's URL and emoji text
rendering does not change that identity. Missing means no saved journal; a
malformed or unreadable existing file stays in place and makes recovery
unavailable. Status no longer discovers
retired `.stale-*` journals. Slack thread retention bounds only the hot binding
set (200 bindings, 30 days); archived cold locators remain durable and unbounded,
so a returning thread can resolve its retained conversation.

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
Only validated `copied` members of the selected snapshot are replaced; the
capture allowlist never authorizes deletion of an uncaptured live path.
Its SQLite copier opens sources read-only and closes them before replacement;
it never opens a live MemoryV2 owner against the life being replaced.
If it cannot be written, no scope is replaced and the failure says why. It is
the source for selected readable continuity facts; the restore never reinstalls
it as a rollback. The restore intent's UUID becomes the new life, also across
interrupted installation.

Local capture and restore both resolve persona through `defaultPersonaRoot`:
the checkout's sibling `persona/`, or `persona/` inside a public data root.
The manifest records that absolute destination as `personaRoot`; staging and
launch require it to equal the current owner. Integrity version 2, scope version
4, a canonical `lifeID`, explicit `links`, captured `persona/` with a regular
`SOUL.md`, the current `abilities/` directory and a readable `chat/sessions.json`
with current nonnegative, advanceable integer generations form the restorable
contract. Validation and the live transcript-floor read finish before any
intent is written. No old manifest is accepted or resealed. Off-disk copies
remain credential-excluded recovery copies, never local restore targets. Scope
version 3 is retired: its local snapshots did not capture the canonical clock.
Existing backups are preserved, never converted or resealed.

Capture is sequential, not a whole-root transaction. Local memory files use
their per-file writer locks and each SQLite database uses a read-only online
backup. Both local and off-disk chat capture hold the session-index lock across
the hot index, hot transcripts and archive, with nested per-file locks; retention
cannot move a conversation between tiers during that group capture. Clock times
share the times-file lock with both capture forms. Local scope `clock` replaces
the whole captured directory on restore. Launch consumes only its current times.
Make uses its directory lock. Ordinary scopes, including persona, Trust,
abilities, workflows and connectors, use filesystem copies without a shared
writer lock; senses filters its top-level children, then copies nested
directories directly. Files in those scopes may reflect different
instants. Hashes prove the staged bytes, not cross-scope atomicity. Integrity,
link and SQLite-conversion inventories throw traversal errors rather than
returning a successful prefix.

The selected backup's queues, conversations, attachments and clock times
(including rhythms and payloads) remain its own;
there is no current-work overlay. The life being left keeps its work in the
normal safety backup. Domain owners select only credential/consumption facts,
and the phone version floor for continuity. Both the safety and target copies of
`chat/sessions.json` and `chat/archive/sessions.jsonl`, together with retained
`chat/transcript_restore_epoch.json`, supply one maximum generation floor before
the first replacement. Archiving moves current generations out of the hot index;
it cannot lower this floor. Unreadable, malformed or exhausted generations and a
missing hot index are errors, never omissions in `notCarried`. A checked empty
index contributes no counters; only a truly absent archive or epoch contributes
none from that source. These checks also run on an interrupted installation. The
current restore contract above is the only restore form. Registry-based tool/skill/sense reconstruction and
current-ability overlay for older backups are removed.
`ClockRestoreFence.merge` keeps the later next occurrence for shared ids and
the latest recorded delivery for every id. A restored occurrence already
consumed remains ended, including a one-shot. Current-only delivery evidence
is retained as ended times, so a later restore cannot erase it; current-only
pending work is not imported. An unreadable clock fails restore rather than
discarding its consumption evidence. Older rows without `delivered`/`ended` still decode;
deliveries made before this evidence existed cannot be reconstructed from absence.
Unreadable selections are omitted with piece, cause and loss in the receipt;
invalid approved backups, an unavailable safety backup and write failures remain
errors. Interrupted intents install the approved target forward.
