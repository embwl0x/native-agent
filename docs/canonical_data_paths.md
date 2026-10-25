# Canonical data paths

This is a map of selected stores and their source owners, not an inventory of
everything under the data root.

## Root resolution

`PersistenceCore/PersistenceDataRoot.swift` resolves the process data root:

1. A non-empty `NATIVE_AGENT_DATA_ROOT` override.
2. A development bundle's `REPO_PATH` stamp, followed by `/data`.
3. The install's Application Support directory.

`defaultPersonaRoot` uses `<repo>/persona` when the data root identifies a
source checkout; otherwise it uses `<dataRoot>/persona`. Do not infer the
running app's root from the current shell directory.

## CANONICAL STORES

Paths below are relative to `<dataRoot>` unless stated otherwise.

| Path | Purpose / source owner |
|---|---|
| `life-id` | `NativeAgentCore/DataRootLife.swift` owns the data root's life; written once when absent, replaced by the restore intent's new identity, retained in backup metadata |
| `chat/sessions.json` | Chat session index; `Transcripts/ChatSessionIndexFile.swift` owns every live commit |
| `chat/messages/<sessionId>.jsonl` | Per-session transcript; `Transcripts/TranscriptRows.swift` (`ContactThread`) owns byte mutations; `ChatSessionWork/ChatSessionAutocompactor.swift` selects compaction rows |
| `chat/sessions/<sessionId>/scratch.json` | Session scratch JSON object; `Transcripts/ChatSessionScratch.swift` owns path, locked mutation and reads for Mac, Telegram and tools; off-disk backup only; no local backup/export/phone sync |
| `chat/mac_turn_lifecycle.json` | `ChatTurnRuntime/MacChatTurnLifecycle.swift` owns lifecycle evidence and pending requests; local backup captures this file before attachment bytes; requests retain their life and Resume starts stopped requests fresh |
| `backups/restore-receipt.json` | `TrustPersistence/TrustBackupPersistence.swift` durably records the last completed restore and each unreadable piece, why it was omitted, and what was not kept; private local state, covered by the existing backups privacy category, outside backup scope and excluded from production export and phone sync |
| `memory/memory.sqlite` | MemoryV2 storage; `MemoryV2/MemoryV2+Storage.swift` |
| `<personaRoot>/USER.md` | MemoryV2's generated user-document projection when an explicit persona root is supplied; see below |
| `telegram/config.json` | Telegram configuration; `TelegramBot/TelegramBot+Config.swift` |
| `telegram/state.json` | `TelegramBot/TelegramPollLoop.readState` and `mutateState` own checked reads and locked mutations for polling, migration and status consumers; only missing state starts empty; unreadable/non-object state is unavailable, names this path, and is preserved |
| `connectors/registry.json` | `PersistenceCore/ConnectorOAuthRegistry` owns every checked durable publication, including bootstrap and Slack recovery, and the connectionDecision field: only the person's own connect/disconnect records connected/disconnected. Seeds, first reads and migrations are undecided; missing decisions read as undecided without inferring from enabled/authState. Credential migration reads only this decision: connected or undecided may migrate; a recorded person-disconnect never does |
| `connectors/actions/receipts.jsonl` | `PersistenceCore/ConnectorActionReceipt` owns the schema, path and capped append for connector actions and Slack HTTP proofs; `Connectors/ConnectorProofLedger` reads health evidence |
| `connectors/slack/auth.json` | Canonical Slack metadata and Keychain grant reference; `SlackBot/SlackCredentials.swift`; metadata and token migration obey `PersistenceCore/ConnectorOAuthRegistry.permitsCredentialMigration` under registry → auth locks: connected or undecided may migrate; only a recorded person-disconnect retires `oauth_tokens/slack.json` without import until explicit reconnect. Eligible missing canonical auth imports checked legacy metadata once and verifies publication before removing the source; file tokens move through verified Keychain writes before runtime credential reads and plaintext removal, canonical values winning over legacy input; runtime policy reads only canonical auth |
| `providers/registry.json` | Provider registry; `ProviderRouting/ProviderRouting.swift` |
| `providers/active.json` | Saved provider assignments by surface; same owner |
| `providers/surfaces.json` | Saved surface model/effort choices; same owner |
| `codex_home/auth.json` | App-managed Codex OAuth credentials; `ProviderRouting/LLMClient+OpenAIOAuthCredentials.swift` |
| `context/context.sqlite` | Context storage; `Context/ContextSQLiteStore.swift` |
| `cognition/cognition.sqlite` | Cognitive state and artifacts; `CognitiveSubstrate/CognitiveSQLiteStore.swift` |
| `cognition/organism_state.json` | Organism continuity; `Cognition/NativeCognitionRuntime+Organism.swift` |
| `workflows/approvals/requests.json` | Approval records; `ApprovalInbox/ApprovalInbox.swift` |
| `runs/runs.json` | Run ledger; `SwarmRuns/RunLedger.swift` |
| `turn_traces/<yyyy-MM-dd>.jsonl` | Daily turn diagnostics; `TurnTrace/TurnTrace.swift` |

Source paths above are under `Modules/NativeAgentCore/Sources/`.
`MemoryV2+UserMDGen.swift` uses the supplied persona root for `USER.md`;
without one, it resolves `<dataRoot>/persona/<persona>/USER.md`.
App launch supplies `NativeAgentPaths.personaRoot` when reconciling this projection.

Use [Data bounds](data-bounds.md) for retention and
[Runtime storage limits](runtime-storage-limits.md) for disposable diagnostics.

## Restore law

**A restore brings back what they had, never what they was doing.** Every
resumable record keeps the data-root life in which it began. Only that life may
resume it. Older or unstamped work reads **stopped**, reason **restored**;
the person's Resume starts fresh work in the new life, never saved effects.
`DataRootLife` owns this boundary for checkpoints, cards, queues, scheduler
claims, Desk continuations and bridge/peer sends. There is no per-kind restore
settlement or review flag.

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
