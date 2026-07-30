# Explicit Recall Probe Protocol

Use this when you need to verify that an agent's memory/recall pipeline is actually wired end-to-end (notes.jsonl → consolidator → embedder → recall surface) rather than just inspecting code paths.

## When to use
- After landing memory infrastructure (commit_memory, MemoryConsolidator, notes_base_dir hookup).
- When code review says recall *should* work but you want a live receipt.
- When the agent's own file-reading tools can't reach `~/Library/.../notes.jsonl` (sandboxed) and bash is provider-gated, so direct file inspection isn't viable from inside the agent.

## Why explicit phrasing matters
Phrases like "do you remember" or "remember when" should trigger the real Swift MemoryV2 recall path and embedding index, not a code-reading shortcut. The agent has to surface a stored note or memory record, not reason about whether one exists.

## Procedure
1. **Pick a distinctive probe.** Choose something specific the agent wrote earlier — a named phase, a distinctive metaphor ("the disease"), a numbered decision. Generic topics produce generic answers that don't prove recall.
2. **Phrase with explicit recall intent.** Lead with "do you remember…" or "remember when…". Avoid asking the agent to summarize or explain — that invites reconstruction from context, not retrieval.
3. **Watch the trace, not just the reply.** Confirm a `kind=note` (or equivalent) record actually surfaced in the dispatch trace. A plausible-sounding answer without a recall trace event means the model reconstructed from the current conversation.
4. **Cross-check the content.** The reply should include details that were *only* in the stored note, not in the current session's visible context.

## Known gaps this probe exposes
- Agent can't `read_file` its own per-persona notes file (sandbox blocks paths outside repo).
- `max_iterations` ceilings (e.g. 12) are too short for file-system verification loops.
- Test fixtures writing into real persona memory dirs (`memory/<persona>/notes.jsonl`) — if the recall surfaces fixture rows mixed with real ones, test isolation is broken and a tombstone sweep is needed, not just a cleanup.

## Anti-pattern
Don't try to verify recall by having the agent read its own notes.jsonl directly. The sandbox will block it, you'll burn tool iterations, and even success only proves the file exists — not that the recall pipeline reads it.
