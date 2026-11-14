# NativeAgent Data Bounds

Selected live limits enforced by the Swift runtime. These are store-specific
policies, not a global disk quota. Paths are relative to the app's data root.

Quiet never ends what they holds. A conversation is held whole until the request
reaches the input budget; then the oldest whole turns go in half-budget jumps.
The input budget is min(model window minus response allowance, 200,000 tokens).
History fitting uses the input budget; refusal and result pointers use model
window minus response allowance, the physical limit.

| Store | Limit | Enforcement / owner |
|---|---|---|
| Phone presence evidence | 64 place events and 64 sense/setup events; each organ's latest setup and observation and the first movement since physical Mac input retained within the cap | Atomic histories in `mobile/place-events.json` and `mobile/sense-events.json`; bridge-only writers. Motion, Focus, charging, battery, app audio route, network path, Music metadata, scoped photo count and Places setup use the same sense owner. Current inference requires evidence within 15 minutes; history is not current presence. The sense owner holds one pending reading per slot (each source's observation and setup) and sends every slot each publication; the Places owner holds at most 128 pending changes and sends at most 8 per publication. See [mobile presence](mobile_companion.md#where-the-person-is). |
| MemoryV2 memories | 2,000 rows by default | Value/lifecycle rank, then least recent use; pinned/identity rows evicted last. `MemoryV2+Storage.swift` |
| Approvals | 300 records | On overflow, orphan pending requests unanswered for 24 hours since their last request (creation if never re-asked), then evict oldest eligible terminal records; refuse creation if insufficient space remains. `ApprovalStorage.swift` |
| Chat hot index | 200 sessions by default, protected sessions excepted | Canonical transcripts and locator rows move to durable `chat/archive/`; no automatic expiry. `ChatSessionRetention.swift` |
| Chat streaming tail boxes | Cache target 8; active or consumer-held boxes protected regardless of count | On cache demand, `TranscriptsFacade` prunes only unreferenced boxes outside active streaming rows. Mounted bubbles and scroll observers retain the same box through their observation lifetime. `ChatStreamingTail.swift` |
| Held conversation | Input budget above; whole-turn jumps | `ContextBudgetPolicy`, `SessionHistoryTail`; current input may use the physical limit; [contract](conversation-context-history.md). |
| Cognitive active nodes | 256 by default | Configured by `CognitiveConfiguration.swift` |
| Cognitive artifacts | Derived from node and reflection budgets; minimum 64. Cares, their migration marker, retired preserved families and reflection receipts still owing effects or dream-journal acknowledgment are excluded. Owed receipts also bypass the settled reflection restore cap. | `CognitiveSubstrate+Persistence.swift` computes the cap; `CognitiveSQLiteStore.swift` prunes by artifact family |
| Turn evidence and receipts | 14 days | `ExperienceStore` details in `experiences/experiences.sqlite`; forgotten after writes, no retention loop |
| Activity events | 5,000-row trigger → 4,000 retained | `activity/events.jsonl`; retains a sample of rare event kinds |
| Shared-folder search | 50 results overall; 2,000 files per workspace; content search up to 512,000 bytes per file | `Connectors.swift`; `unexamined` names the current workspace's unsearched remainder when a bound stops its walk, and each later workspace skipped at the result cap. The same coverage makes the activity receipt `partial`; a per-workspace scan cap still permits searching later workspaces. |
| Browser observations | 128 MiB, 256 capture groups, 7 days | Enforced on capture writes by `BrowserCaptureCache.swift` |

Row triggers on the amortized trace/activity feeds can overshoot by up to 127
rows between checks. Browser artifacts and diagnostic traces can expire;
recapture or reread the source when needed.
