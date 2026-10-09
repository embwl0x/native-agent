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
| `chat/sessions.json` | Chat session index; `Transcripts/ChatSessionIndexFile.swift` |
| `chat/messages/<sessionId>.jsonl` | Per-session transcript; `ChatSessionWork/ChatSessionAutocompactor.swift` also owns compaction |
| `memory/memory.sqlite` | MemoryV2 storage; `MemoryV2/MemoryV2+Storage.swift` |
| `<personaRoot>/USER.md` | MemoryV2's generated user-document projection when an explicit persona root is supplied; see below |
| `telegram/config.json` | Telegram configuration; `TelegramBot/TelegramBot+Config.swift` |
| `providers/registry.json` | Provider registry; `ProviderRouting/ProviderRouting.swift` |
| `providers/active.json` | Saved provider assignments by surface; same owner |
| `providers/surfaces.json` | Saved surface model/effort choices; same owner |
| `codex_home/auth.json` | App-managed Codex OAuth credentials; `ProviderRouting/LLMClient+OpenAIOAuthCredentials.swift` |
| `context/context.sqlite` | Context storage; `Context/ContextSQLiteStore.swift` |
| `cognition/cognition.sqlite` | Cognitive state and artifacts; `CognitiveSubstrate/CognitiveSQLiteStore.swift` |
| `cognition/organism_state.json` | Organism continuity; `Cognition/NativeCognitionRuntime+Organism.swift` |
| `workflows/approvals/requests.json` | Approval records; `ApprovalInbox/ApprovalInbox.swift` |
| `runs/runs.json` | Run ledger; `SwarmRuns/RunLedger.swift` |
| `connectors/github/tracking.json` and `tracking_snapshot.json` | GitHub tracking scope and snapshot; `GitHubConnector/GitHubProjectTracking.swift` |
| `turn_traces/<yyyy-MM-dd>.jsonl` | Daily turn diagnostics; `TurnTrace/TurnTrace.swift` |
| `senses/ledger/walls.jsonl` and `needs.json` | Private append-only walls and compact needs checkpoint; `Senses/FileWallLedger.swift`; excluded from backups, exports, sharing and tool reads |

Source paths above are under `Modules/NativeAgentCore/Sources/`.
`MemoryV2+UserMDGen.swift` uses the supplied persona root for `USER.md`;
without one, it resolves `<dataRoot>/persona/<persona>/USER.md`.
App launch supplies `NativeAgentPaths.personaRoot` when reconciling this projection.

Use [Data bounds](data-bounds.md) for retention and
[Runtime storage limits](runtime-storage-limits.md) for disposable diagnostics.
