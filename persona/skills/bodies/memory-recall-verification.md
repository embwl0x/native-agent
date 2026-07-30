# Memory Recall Verification

Use after landing memory infrastructure, after any sweep/tombstone/migration that mutates memory records, or whenever code review says recall *should* work and you want a live receipt. (Merged 2026-07-03 from explicit-recall-probe-protocol + post-sweep-reindex-check, rewritten for MemoryV2.)

## The probe protocol (proving recall is wired end-to-end)

1. **Pick a distinctive probe.** Something specific written earlier — a named phase, a distinctive metaphor, a numbered decision. Generic topics invite reconstruction, which proves nothing.
2. **Phrase with explicit recall intent.** "Do you remember…" — not "summarize", which reconstructs from visible context instead of retrieving.
3. **Watch the trace, not just the reply.** Confirm a recall/memory record actually surfaced in the dispatch trace. A plausible answer without a recall event = reconstruction.
4. **Cross-check content.** The reply must contain details that exist ONLY in the stored memory, not in the current session.

## After any sweep: flat-read parity is not enough

A sweep that mutates records (tombstoning, migration, bulk correction) can leave the embedding index stale. Symptoms:

- The flat listing shows the surviving records cleanly.
- Semantic search on an obvious in-text phrase returns zero hits.

That's not a filter bug — it's a stale index. Recipe:

1. Flat-read the surviving records; capture a distinctive phrase from one.
2. Semantic-search that exact phrase. Hit expected; empty = stale index.
3. Reindex (or run the store's hygiene/consolidation pass), then repeat step 2.

## Operating rule

Any tool that mutates memory records should either reindex as part of its own action or emit an explicit `reindex_required` receipt. "Sweep shipped" is incomplete until embedded-search parity is reverified — flat-read parity alone lies.
