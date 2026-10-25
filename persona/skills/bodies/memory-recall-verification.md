# Memory Recall Verification

Use after landing memory infrastructure, after any sweep/tombstone/migration that mutates memory records, or whenever code review says recall *should* work and you want a live receipt.

## The probe protocol (proving recall is wired end-to-end)

1. **Choose a distinctive stored detail:** a named phase, metaphor or decision. Generic topics prove nothing.
2. **Ask about the stored detail.** Wording alone does not establish retrieval.
3. **Check delivered memory IDs.** Context-delivered records count without an explicit `memory.recall` dispatch. A plausible reply alone proves neither retrieval nor reconstruction.
4. **Cross-check content.** The reply must contain details that exist ONLY in the stored memory, not in the current conversation.

## After any sweep: flat-read parity is not enough

A sweep can leave record/search-model alignment incomplete. Investigate when:

- The flat listing shows the surviving records cleanly.
- Semantic search on an obvious in-text phrase returns zero hits.

Empty results do not diagnose a stale index; disclosure and relevance filtering can also remove matches. Check before repairing:

1. Flat-read the surviving records; capture a distinctive phrase from one.
2. Semantic-search that phrase; inspect returned records and any reported cause.
3. Use the owner's named repair for a model, store or index error, then verify the affected record. Empty results alone authorize no repair or unrelated hygiene.

## Operating rule

Memory mutations must preserve alignment between records and the active memory search model. After a sweep, verify semantic recall as well as listing; follow actual owner receipts rather than assuming an automatic reindex or a `reindex_required` receipt.

_History: merged 2026-07-03 from explicit-recall-probe-protocol + post-sweep-reindex-check, rewritten for MemoryV2._
