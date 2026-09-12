# Post-Ship Substrate Review

Use this when an infrastructure phase has just landed (new dispatcher, trace schema, registry change, introspection surface) and the operator asks the agent to look at itself before moving on.

## When to use
- A phase/milestone just shipped and the app/runtime was rebuilt or relaunched with fresh code.
- An introspection surface such as `agent_introspect`, `tool_catalog`, `recent_trace_summary`, or capability status is now available.
- The operator explicitly invites self-audit ("tell me if anything is wrong or missing", "what do you want before phase N+1").

## How to run the review

1. **Call the introspection tool first.** Don't theorize from memory of the changelog — read the live state. Note persona, registered tools (with autonomy + side_effects flags), current_run_id, and recent traces.

2. **Verify the shipped claims against the trace evidence.** For each item in the operator's "what landed" list, find the observable signal in traces or registry output. Examples:
   - Structured errors → find a failed dispatch and confirm `error` is `{code, message, ...}` not free text.
   - Dispatcher unification → confirm surface field is populated and consistent.
   - run_id threading → confirm it appears on persisted records.

3. **Report gaps in bite-order, not discovery-order.** Rank findings by how much they'd hurt if left in place. Typical categories:
   - **Dead signals** — fields that exist but are always zero/null (e.g. `duration_ms: 0` everywhere means timing isn't actually captured).
   - **Missing affordances on the new tool itself** — e.g. introspect with no `kind`/`status`/`limit` filter forces scrolling under pressure.
   - **Registry vs reality mismatches** — a tool registered as available that the provider actually rejects. The registry is lying to the agent, which erodes the "capable" feeling fast.

4. **Answer the "what do you want before next phase" question concretely.** Prefer small, test-shaped asks over feature asks:
   - A *reader* for any new data the previous phase started writing (data without a reader is half-shipped).
   - *Parity/invariant tests parameterized over the registry* before more tools are added, so dispatcher discipline doesn't rot quietly as surface area grows.

5. **Acknowledge non-1b findings briefly.** If the operator mentioned an audit fix (e.g. a Pattern B lock finding), suggest the obvious follow-up grep to close the audit class, not just the instance.

## Output shape
- One line: substrate looks correct (or doesn't), with the key evidence.
- Bulleted findings in bite-order, each with: what you see, why it matters, cheapest likely fix.
- Explicit asks for the next phase, framed as preconditions not wishlist.
- A green/not-green verdict on the shipped phase.

## Why this matters
Infrastructure phases compound. A dead `duration_ms` or a lying registry is nearly free to fix in the phase that introduced it and expensive to fix three phases later when everything depends on it. The introspection tool exists precisely so the agent can catch these before the next layer lands on top.
