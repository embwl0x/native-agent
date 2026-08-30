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
| Mac chat pre-compaction backups (`data/chat/sessions/<id>/messages.compact.*.jsonl`) | 5 per session | Newest filenames retained after the fresh backup is byte-verified; the fresh backup is explicitly protected | Cleanup is best-effort so recovery safety wins over retention on delete failure |
| Tool result truncation | 30k chars | Per-field cap, list breadth 100 | |
| CognitiveSubstrate active nodes | 256 default | Deterministic eviction by lowest salience/activation/age | Optional SQLite snapshot under `data/cognition/`; no MemoryV2 writes |
| CognitiveSubstrate artifacts | Derived from active-node/seed/reflection caps, minimum 64 (604 with the all-phases defaults) | Legacy receipt mirrors first; then rows outside protected family quotas; only then least-durable/oldest protected rows if an unusually small hard cap requires it | Thought-seed decay/cap changes replace the exact family and prune in one SQLite transaction; affect/disposition, seeds, episodes, schema/identity proposals, standing views, developmental timeline, reflection/cue receipts, and experiments each have bounded protected retention |
| Pairing token TTL | 90 days | Auto-expired | |
| Trace events (`data/traces/events.jsonl`) | 4 MiB soft trigger; newest 5000 lines after rotation | Oldest whole rows dropped under the append flock | Every writer uses PersistenceCore's path-owned cap |
| Harness benchmark runs (`data/harness/benchmark/runs.jsonl`) | 5000 lines | Oldest dropped after every append | PersistenceCore path-owned cap |
| Builder audit receipts (`data/builder_audit/<uuid>.json`) | 500 JSON receipts | Oldest modification time first; filename tie-break | Best-effort prune removes each retired receipt and its matching `<uuid>-*` sidecars; failures surface without changing tool success |
| Telegram errors (`data/telegram/errors.jsonl`) | 5 MiB live file + one rotated `.1` backup | Replace the prior backup, move the full live file, then resume appends | Byte-owned rotation; there is no 5,000-line cap |
| Run log (`data/runs/runs.jsonl`) | 10 000 lines | Oldest dropped by Swift runtime retention/startup maintenance | App-owned run retention |
| Memory proposals (`data/memory_proposals/*.json`) | 30-day TTL | Files deleted by Swift MemoryV2/proposal hygiene if older than 30 days | App-owned memory proposal retention |
