# Structured Error Code Contract

Use when a tool wrapper maps failures to a structured `error_code` — designing the taxonomy, verifying the contract end-to-end, or hunting a code that vanishes between handler and receipt. (Merged 2026-07-03 from error-code-truthfulness + layer2-error-code-strip.)

## The taxonomy rule: one code per failure MODE, not per tool

Resist funneling every failure into one bucket like `<tool>_unavailable`. Downstream agents and humans reason from the code name. At minimum split:

- `<tool>_unavailable` — app/service genuinely absent (user fixes by installing/launching).
- `<tool>_permission_denied` — TCC/permission explicitly denied (distinct from not installed).
- `<tool>_script_error` — our script didn't compile or threw (our bug).
- `<tool>_timeout` — exceeded budget (transient; retry with longer budget).

Smell: an `_unavailable` code paired with stderr containing `syntax error`, `compile`, `-2741`, or `timeout` means the code is lying. Fix the taxonomy before stacking more tools on the wrapper.

## The two contract layers that drift

1. **The tool's own return envelope** — what the tool hands its caller.
2. **The trace normalization** — what gets written to receipts.

A correct trace does NOT prove a correct tool return. The tool can leak raw exception text while the trace wraps it as `code="legacy_text"`.

## Verify

- Trigger each documented failure mode deliberately (revoke permission, kill the app, inject a syntax error, stall past the timeout).
- Inspect the RAW tool return, not just the trace. Consumers must branch on a stable machine key, never substring-match English.
- Add a registry-wide test asserting every tool's failure path carries a non-empty `error_code` through the full envelope.

## When the code is set correctly but arrives missing: find the strip site

Between the handler that sets `error_code` and the surfaced receipt there is often an intermediate layer (tool loop, stream wrapper, dispatcher caller) doing `return {ok:false, error: receipt.errorText}` — rebuilding a bare envelope and discarding the code.

1. Pick one failing tool whose handler you trust.
2. Log the receipt at the dispatcher boundary — confirm the code is present there.
3. Log at the next layer up. Where it vanishes is the strip site.
4. Grep for bare `ok:false, error:` envelope constructions — each is a candidate, and the same wrapper pattern usually exists in 2+ near-identical sites (streaming vs non-streaming).
5. Fix by propagating the full structured shape, never rebuilding it.
