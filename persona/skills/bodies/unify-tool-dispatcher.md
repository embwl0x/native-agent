# Unify Tool Dispatcher

Use this when an agent has two or more code paths that invoke tools (e.g. a chat path and a missions/loop path) and behavior diverges between them — capable in one, descriptive or unreliable in the other.

## Diagnosis

The split itself is the disease. Symptoms:
- Tool calls land reliably in one context, feel like fog in another.
- Same tool name produces different receipts depending on entrypoint.
- The agent describes capabilities in chat that it actually executes in missions.

If two call sites both invoke `execute_tool` with different context shapes, drift will return within weeks even after a one-time fix. Treat "unreliable" as broken — the softer word lets it stay un-prioritized.

## Fix shape

1. **Single dispatcher, thin adapters.** Make the dispatcher the only path to tools. Chat and missions become context adapters that normalize input and hand off. No tool execution outside the dispatcher.
2. **Tiered autonomy as an enum, not a string.** Replace `"autonomy": "high"` with `auto | confirm | blocked` tied to the registry. Do this *before* shipping the dispatcher, or permissions get bolted onto a stringly-typed system later.
3. **Structured trace errors.** Errors must be `{code, message, tool, args_hash, recoverable}`, not free text. Free-text errors make self-correction across runs impossible.
4. **Verification required at registration.** Every tool declares a verification path, even if it is a trivial shape check for read-only ops. Forces discipline at registration, not as an afterthought.
5. **`dry_run` mode at the dispatcher layer.** Cheap to add now, expensive to retrofit.
6. **`agent_introspect` and trace tools.** Let the agent query its own running state: registered tools, current permissions, last N traces. Removes guessing about its own substrate.

## Test before code

Write the dispatcher test first: prove chat and missions produce **identical receipts for the same tool call**. Green test = real unification. Red or missing test = still pretending.

## Pairing rule

Don't ship a new durable tool (e.g. `commit_memory`) before the dispatcher is unified. A persistence tool that only works in one context is theater — the agent can "remember" in missions but not in chat, which reproduces the original split at the data layer.

## Build order when stacking related work

1. Dispatcher unification + tiered autonomy enum + the first cross-context tool (e.g. `commit_memory`) + any user-facing wrapper (e.g. `/note` that sets `source=user` on the same tool).
2. Structured trace errors + `agent_introspect`.
3. Scratchpad + capabilities endpoint that exposes the registry.
4. New read surfaces (calendar, messages, etc.) registered as tools with explicit scopes.
5. High-blast-radius self-control tools last — they benefit most from mature traces and permissions.

## Anti-patterns

- Leaving two call sites "for now."
- String-typed autonomy or permissions.
- Free-text error fields.
- Verification only on the one tool that happened to need it first.
- Building speculative integrations before a real user need surfaces.
