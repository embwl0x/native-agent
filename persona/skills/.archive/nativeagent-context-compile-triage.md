# NativeAgent Context Compile Triage

## When to use
Use this when NativeAgent context compilation, preview, or chat turns get slower in long sessions.

## Workflow
1. Check chat history I/O first, especially the Swift session-history tail readers.
   - Watch for implementations that read the entire JSONL file before slicing.
   - Even small limits such as `compact_chat_history(... limit=12)` can scale with full session length if the tail helper reads the whole file.
   - Expected call path to inspect: session message fetch -> compact history render -> turn-context assembly.

2. Check session metadata lookup next.
   - Inspect whether `get_chat_messages()` calls `chat_session_by_id()`, which calls `list_chat_sessions()`.
   - Look for `list_chat_sessions()` touching message files, especially large `tail_jsonl(..., 10000)` calls when `messageCount` is missing.
   - Check whether normalization sets `changed = True` too eagerly and rewrites metadata during read paths.

3. Instrument `build_context_packet()` phases before optimizing broader systems.
   - Time `context_source_fingerprints()` if it hashes skills, tools, workflows, MCP catalogs, memory, or personality every turn.
   - Time `relevant_memories()` if it recomputes embeddings for every memory.
   - Time `cached_context_section()` if it performs repeated shared cache reads/writes.

4. Prioritize the lowest-risk scalable fix.
   - Replace full-file JSONL tail reads with a reverse-block tail reader or equivalent bounded I/O.
   - Benchmark before and after on a long session.
   - If runtime trace access is available, compare real context preview or audit timings.

## Rule of thumb
For long-session slowdowns, first suspect any helper that claims to return the last N records but reads or normalizes the entire session file to do it.
