## When to use

After any sweep that marks, deletes, or rewrites records in a memory store that has both a flat-read path (e.g. `recall_list_recent`) and an embedded-search path (e.g. `recall_search` with `mode: "embedding"`). Especially relevant right after tombstoning fixtures, migrating personas, or changing a notes_base_dir hookup.

## The failure mode

The sweep mutates the source-of-truth records but does not rebuild the vector index. Symptoms:

- `recall_list_recent` cleanly returns the surviving real records.
- `recall_search` on an obvious in-text phrase returns `total: 0` with `mode: "embedding"`.
- Toggling `include_test_fixtures=true` does not change the result — because the index itself is empty/stale, not because a filter is hiding hits.

This is distinct from a filter bug. The tell is that `mode: "embedding"` is reported but zero vectors are live for the persona.

## Verification recipe

1. **Flat read first.** Call the listing tool (`recall_list_recent`) and capture the ids + a distinctive phrase from each surviving record.
2. **Search for that exact phrase.** Call `recall_search({query: <phrase>, k: 5})`. Expect a hit. Empty + `mode: "embedding"` = stale index.
3. **Toggle the fixture filter.** Re-run with `include_test_fixtures=true` on a phrase known to live in a tombstoned record.
   - Tombstones come back, real records don't → filter bug or notes_base_dir mismatch on the search side.
   - Both empty → index is empty/stale post-sweep. Reindex is the fix.
4. **Reindex and retry.** Trigger whatever rebuilds the embedded index for the affected persona, then repeat step 2.

## Operating rule

Any sweep tool that mutates records should either (a) reindex as part of its own action, or (b) emit an explicit `reindex_required: true` receipt so the next verification step knows to run it. Treat "sweep shipped" as incomplete until embedded-search parity is reverified, not just flat-read parity.