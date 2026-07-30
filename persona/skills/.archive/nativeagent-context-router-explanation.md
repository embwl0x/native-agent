# NativeAgent Context Router Explanation

Use when the user asks how NativeAgent decides what context mode to select, why a turn used `minimal` or another route, or how the non-bloat routing rule works.

## Response Pattern

- Describe the router as a budgeted relevance filter.
- Say it considers the current user message, recent conversation, memory hints, capability summaries, skills, tools, and lazy lookup handles.
- Explain that it chooses the smallest context mode likely to answer the request.
- For simple explanations, capability questions, or normal chat, say `minimal` is expected because full bodies are not needed.
- For coding, debugging, testing, full inventory, or explicitly requested details, say the router may expand into richer context.
- Emphasize that compact summaries load before full bodies.
- State the non-bloat invariant: full capability, skill, tool, roadmap, or debug bodies should stay lazy unless selected, and `capabilities.summary.autoloaded` should remain `0`.

## Decision Flow To Explain

1. Classify the request type: chat, coding, debugging, testing, planning, memory/persona, capability lookup, or inventory.
2. Score relevant memories and capabilities against the request.
3. Load compact summaries first.
4. Expand into full bodies only when the selected route or explicit user request needs them.
5. Keep sampled context routes under configured budgets.
6. Preserve lazy capability loading so prompts do not become heavy or contaminated by irrelevant detail.

## Tone

Keep the explanation concrete and short. Avoid claiming the router loaded specific internals unless route receipts or runtime evidence are available.