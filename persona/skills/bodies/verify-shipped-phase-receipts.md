# Verify Shipped Phase Receipts

Use this when a collaborator ships an infra phase and hands you an itemized list of fixes to confirm. The job is not to nod along — it is to check each claim against real traces and call out any silent failure before the next phase stacks on top.

## When to use
- A phase/PR just shipped and the author lists N specific things to verify.
- You have introspection tools (e.g. `agent_introspect`, `recent_trace_summary`, `recall_memory_provenance`) that can read the actual receipts.
- The author is asking for a green-light decision on the next phase.

## How to run it

1. **Walk the list in order.** For each claimed fix, call the tool that would exercise or expose it. Do not batch a verdict across items.
2. **For each item, classify as:**
   - **Green** — observable in the trace, matches the spec.
   - **Asterisk** — partially landed, or shape is right but a sub-field is wrong/missing.
   - **Red** — not observable, or observably wrong.
3. **Watch for fields that lie.** A timing field that reads `0` everywhere, an error that is structured-rendered but not structured-coded, a filter that returns the right count by accident — these are worse than missing fields because they look fine at a glance. Call them out explicitly.
4. **Distinguish structured-coded from structured-rendered.** If the spec promised `{code: "foo", ...}` on the wire, confirm the code is in the payload, not just in the human-readable string.
5. **Note what you couldn't test from your surface** (e.g. provider-gated tools you can't invoke) so the author knows the coverage gap.
6. **End with a verdict and explicit preconditions for the next phase.** Format: `green / green-with-asterisk / red`, followed by the 1–3 things that must be tight before stacking.

## Output shape

- One short paragraph per verification item, numbered to match the author's list.
- Quote the actual field names and values you saw, not paraphrases.
- Bonus/side items (audits, parity tests) get a short acknowledgement block.
- Final block: **Verdict** + **Preconditions for next phase**.

## Why this matters

Phases stack. A lying field in phase N becomes load-bearing in phase N+1 and is much more expensive to find later. The cheapest moment to catch dispatcher-discipline rot, timing-field rot, or error-shape rot is right after the phase that introduced them, while the author is still in the code.

## Condensed example: resolver-field / verify-contract phases
(Absorbed 2026-07-03 from verify-resolver-and-summary-projection.)

When the shipped phase adds trace metadata (e.g. `effective_autonomy`, `autonomy_source`, `provider_match`) or a `verify_passed` contract:
- Check the PAYLOAD carries the new fields, then check the SUMMARY PROJECTION surfaces them too — payload-only means the render layer wasn't updated, and the point was seeing them at a glance.
- If every trace shows the default value (`autonomy_source: "default"`), you've only proven the default path. Prove the override path: set a real policy glob, dispatch a matching tool, confirm the trace records the non-default source.
- Walk every read-only tool that ran and confirm `verify_passed` is a real boolean, not null — nulls in a now-boolean field trip downstream consumers.
- `version: "unknown"` on a status surface is a lie across versions — the build must stamp its SHA.
