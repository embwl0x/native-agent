## When to use

A search/recall tool over a unified index returns empty or wrong-typed results even though the records exist. Symptom: caller asks for `source=notes`, but the pipeline pulls top-k across *all* sources first and then filters — so a dense same-session source (e.g. today's chat turns mentioning the query term) crowds out the target source before the filter runs.

## The fix pattern

1. **Push the source filter down into the ranking step**, not after it. The retrieval function should accept `source_filter` (e.g. `"note" | "chat" | None`) and apply it *before* the top-k cut so each source competes only against its own kind.
2. **Give each source its own ranking pool.** Don't multiply k (e.g. `k*3`) and hope filtering survives — that's a band-aid that fails whenever one source dominates the embedding space.
3. **Add a substring fallback** that drops through when the embedding pool for the requested source is empty. Keeps the tool useful on cold or sparse indexes without masking ranking bugs (log/return `mode` so you can tell which path fired).

## How to verify

- Re-run the original failing query and confirm: (a) results are non-zero, (b) all results are the requested source, (c) `mode` field shows `embedding` (fallback didn't have to fire), (d) ranking order is sensible (top hit semantically matches the query).
- Pick a query term that's *also* dense in the other source (e.g. "dispatcher" when today's chat is full of it). If source isolation holds under that adversarial case, the filter is truly pre-rank.
- Check scores span a real range (not all near zero) — confirms the embedder is doing work within the filtered pool, not just returning arbitrary survivors.

## Why this matters

Post-filter top-k is a silent failure mode: the tool returns "no results" and looks like a memory/index bug, when really the right records were retrieved and then thrown away. The agent loses access to its own memory in exactly the sessions where it's talking about the topic most.