# NativeAgent Data Bounds

Selected live limits enforced by the Swift runtime. These are store-specific
policies, not a global disk quota. Paths are relative to the app's data root.

| Store | Limit | Enforcement / owner |
|---|---|---|
| MemoryV2 memories | 2,000 rows by default | Value/lifecycle rank, then least recent use; pinned/identity rows evicted last. `MemoryV2+Storage.swift` |
| Approvals | 300 records | On overflow, orphan pending requests unanswered for 24 hours since their last request (creation if never re-asked), then evict oldest eligible terminal records; refuse creation if insufficient space remains. `ApprovalStorage.swift` |
| Chat hot index | 200 sessions by default, protected sessions excepted | Canonical transcripts and locator rows move to durable `chat/archive/`; no automatic expiry. `ChatSessionRetention.swift` |
| Chat compaction recovery copies | 5 per session; recent tier 30 days, 200 sessions, 128 MiB | Pending distillation sources are protected. Admissible retiring copies share one exact-line union, durable write and verification in `chat/archive/originals/<id>.jsonl` per session operation. Unknown/corrupt sources stay in recovery; deletion requires verified coverage. `ChatCompactionStorage.swift`, `ChatCompactionBackupRetention.swift` |
| Chat recollection blocks | Each body targets 1/5 of its rendered source chunk (at most 32,000 source characters), accepts 1/10–1/3 (at most 10,666 body characters), plus block-local receipt/card notes; legacy history read allowance 40,000 characters | Aging starts at 85%; folds leave ~55% of the effective threshold raw. Chunks distill concurrently and append in order atomically after unchanged earlier blocks. At a needed compaction pass, a leading recollection run above 10% of the effective window and 8,000 characters may roll up one dream-safe group larger than 8,000 characters using the same proportional chunks. See [Turn resilience](https://github.com/embwl0x/native-agent/blob/main/docs/TURN_RESILIENCE.md#8-context-compaction). |
| Cognitive active nodes | 256 by default | Configured by `CognitiveConfiguration.swift` |
| Cognitive artifacts | Derived from node and reflection budgets; minimum 64. Cares, their migration marker and retired preserved families are excluded. | `CognitiveSubstrate+Persistence.swift` computes the cap; `CognitiveSQLiteStore.swift` prunes by artifact family |
| Shared traces | 5,000-row trigger → 4,000 retained; 8 MiB → 4 MiB | `traces/events.jsonl`; path-owned append policy |
| Activity events | 5,000-row trigger → 4,000 retained | `activity/events.jsonl`; retains a sample of rare event kinds |
| Daily turn traces | 12 MiB → 8 MiB; 14 days | `TurnTrace` append and date-based retention |
| Browser observations | 128 MiB, 256 capture groups, 7 days | Enforced on capture writes by `BrowserCaptureCache.swift` |

Row triggers on the amortized trace/activity feeds can overshoot by up to 127
rows between checks. Browser artifacts and diagnostic traces can expire;
recapture or reread the source when needed.
