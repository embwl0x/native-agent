# NativeAgent Data Bounds

Runtime pruning is owned by the app-owned Swift runtime. Do not attribute current pruning, TTL, or startup-maintenance behavior to retired runtime paths.

| Subsystem | Cap | Eviction | Notes |
|-----------|-----|----------|-------|
| Memory facts | 2000 | Lifecycle/value class, then least-recently-used (`lastUsedAt`/`updatedAt`); pinned/identity evicted only after ordinary rows | Enforced transactionally on direct insert, proposal acceptance, approved consolidation swap, and store open; overflow emits bounded retention receipts and removes stale derived projections |
| Chat drafts (Swift app) | 50 | LRU by lastTouched | |
| Toast queue (UI) | 10 | Drop oldest | |
| Approvals | 300 | Drop oldest resolved | |
| Improvement runs | 500 | Drop oldest by createdAt | Receipt files unlinked |
| Inbox items | 1000 | Drop oldest | |
| Crash reports | 50 | Drop oldest | |
| Auto-compact trigger | 4000 messages/session | Summarize older | |
| Tool result truncation | 30k chars | Per-field cap, list breadth 100 | |
| CognitiveSubstrate active nodes | 256 default | Deterministic eviction by lowest salience/activation/age | Optional SQLite snapshot under `data/cognition/`; no MemoryV2 writes |
| CognitiveSubstrate artifacts | Derived from active-node/seed/reflection caps, minimum 64 (604 with the all-phases defaults) | Legacy receipt mirrors first; then rows outside protected family quotas; only then least-durable/oldest protected rows if an unusually small hard cap requires it | Thought-seed decay/cap changes replace the exact family and prune in one SQLite transaction; affect/disposition, seeds, episodes, schema/identity proposals, standing views, developmental timeline, reflection/cue receipts, and experiments each have bounded protected retention |
| Pairing token TTL | 90 days | Auto-expired | |
| Trace events (`data/traces/events.jsonl`) | 10 000 lines | Oldest dropped by Swift runtime retention/startup maintenance | App-owned trace retention |
| Run log (`data/runs/runs.jsonl`) | 10 000 lines | Oldest dropped by Swift runtime retention/startup maintenance | App-owned run retention |
| Memory proposals (`data/memory_proposals/*.json`) | 30-day TTL | Files deleted by Swift MemoryV2/proposal hygiene if older than 30 days | App-owned memory proposal retention |
