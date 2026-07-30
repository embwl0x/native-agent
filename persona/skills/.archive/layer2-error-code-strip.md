# Layer-2 Error Code Strip

## When to use
- A tool's handler is verified to set `error_code` correctly, but receipts at the agent boundary still arrive with no code.
- You've already swept the handler and a structured-error-code-contract check still fails end-to-end.
- Multiple tools share the same symptom (code missing in envelope) — points to a shared wrapper, not per-handler bugs.

## The pattern
Between the handler that sets `error_code` and the trace/receipt that surfaces it, there is often an intermediate site (tool loop, stream wrapper, dispatcher caller) that does something like:

```text
if receipt.status != "ok":
    return { ok: false, error: receipt.errorText }  # strips error_code
```

Even a perfectly-coded handler has its code discarded here. The dispatcher extracted it correctly; the caller threw it away while rebuilding a bare envelope.

## How to find it
1. Pick one failing tool whose handler you trust.
2. Log/print the receipt at the dispatcher boundary — confirm `error_code` is present there.
3. Log/print at the next layer up (tool loop, stream handler). If the code vanishes between those two points, you've found the strip site.
4. Grep the codebase for `{'ok': False, 'error':` or `ok=False, error=` constructions — each one is a candidate strip site.
5. Expect duplicates: the same wrapper pattern often exists in 2+ near-identical sites (e.g. streaming vs non-streaming tool loops).

## The fix
Propagate the full structured shape, don't rebuild it:

```text
if receipt.status != "ok":
    return receipt.fullEnvelope()
```

## Verify
- Trigger the boundary again and inspect the raw return at the agent surface (not just the trace wrapper).
- Add a registry-wide test (`TestErrorCodeContractAcrossRegistry`-style) that asserts every tool's failure path carries a non-empty `error_code` through the full envelope.
- Watch for the same pattern in newly-added wrapper layers in future phases.
