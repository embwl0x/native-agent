# Tool Registration Parity Check

Use this when a new tool has just been added to an agent's toolset and you want to confirm it's wired through the unified dispatcher rather than a fast path that bypasses it.

## When to apply
- A new tool (e.g. `commit_memory`) just appeared after an app/runtime relaunch or code ship.
- The project has previously suffered from a split between chat-path and mission-path tool execution (see `unify-tool-dispatcher`).
- You're being asked to confirm a phase is "green" before moving on.

## The check

1. **Confirm visibility**: verify the tool actually shows up in the live tool list. If not, stop and troubleshoot registration.
2. **Exercise it once** with a real (not smoke-test) payload so a trace receipt is generated.
3. **Parity test**: invoke the same tool with the same arguments from two surfaces — e.g. chat and a mission step — and compare the resulting trace receipts.
   - Identical structure (same fields, same shape) → dispatcher unification holds.
   - Divergent receipts (or one surface produces no receipt) → the tool was registered on a fast path. Phase is not done.
4. **Verify on disk / downstream**: have the human (or a follow-up read) confirm the side effect actually landed where expected, not just that the call returned.

## Related gap to flag
If `record_trace()` or equivalent still emits free-text errors, note that self-correction across runs is blocked until errors are structured (`{code, message, tool, args_hash, recoverable}`). Cheap to land alongside dispatcher work.

## Bonus audit
When a latent initializer ordering bug surfaces (lock used before init, etc.), sweep other constructors for the same pattern. These tend to cluster and stay masked by uptime until the next cold start.
