# Verify Resolver Fields and Summary Projection

Use this when a shipped phase claims to add resolver/autonomy metadata to traces, a verify_passed contract for read-only tools, or new self-introspection surfaces. Run the checks in this order and look for these specific failure modes.

## When to use

- A phase shipped that adds resolver fields (`effective_autonomy`, `autonomy_source`, `provider_match`) to dispatch traces.
- A verify_passed boolean contract was extended to read-only tools.
- New runtime self-control surfaces (status, logs, introspection) were added or changed.

## Checks

1. **Runtime status sanity.** Confirm persona, pid, uptime, tool count, and provider/model state match the ship notes. **Specifically check `version` is not `"unknown"`** - status surfaces must stamp the build SHA or release tag, otherwise they lie politely across versions during ops debugging. Treat recent error counts as informational only if they track known runtime noise.

2. **Runtime log visibility.** The win is being able to read the current app/runtime error stream from inside the agent. Scan for recurring non-fatal decode/read-before-write errors and for healthy background loops with non-zero progress counters.

3. **Resolver fields in dispatch traces - payload vs summary.** This is the most common miss. Fetch a fresh dispatch trace through `agent_introspect` or `recent_trace_summary`. Confirm the **payload** carries `effective_autonomy`, `autonomy_source`, `provider_match`. Then confirm the **summary projection** also surfaces them alongside `duration_us`, `args_hash`, `verify_passed`. If they are in payload but not summary, the render layer was not updated. The whole point of locking resolver order is to *see* `autonomy_source != "default"` at a glance.

4. **End-to-end glob proof.** If every trace shows `autonomy_source: "default"`, you have not actually proven globs reach through - you have only proven the default path. To prove it: write a `trust_policy_tool_autonomy` glob for a safe matching tool, dispatch it, and confirm the trace shows `autonomy_source: "trust_policy"` with the matched glob recorded. Add this to the next phase's verification list.

5. **verify_passed contract coverage.** Walk every read-only tool that ran this session and confirm `verify_passed: true` (not null). Stragglers usually mean the tool either has no registered verify() or shortcuts to None on a particular result shape (e.g. `found: true` returns early). Fix: read tools should verify the result *shape* (has `ok`, has `found`, has `value` when `found=true`) and return true. Don't leave any tool out — nulls in a field that's now supposed to be boolean trip downstream consumers reading the trace stream.

## Reporting shape

Report per-check green/off, then a numbered "what's off" summary at the end. For each off-item, name the fix concretely (stamp the SHA, add the empty-string guard, add fields to summary projector, register verify for tool X). Cheap, specific, actionable beats vague.

## Related

- `verify-shipped-phase-receipts` — parent pattern, this is the resolver/verify-contract-specific instance.
- `post-ship-substrate-review` — use after this to surface what's *missing* from the substrate beyond what was claimed.
