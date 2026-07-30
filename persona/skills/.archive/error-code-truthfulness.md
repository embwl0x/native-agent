# Error code truthfulness

When a tool wrapper catches exceptions and maps them to a structured `error_code`, resist the urge to funnel every failure into one bucket like `<app>_unavailable`. Distinct failure modes deserve distinct codes, because downstream agents and humans reason from the code name.

## When this applies

- An AppleScript / subprocess / IPC tool returns a single error_code like `reminders_unavailable` or `mail_unavailable` for any failure.
- The actual failures span very different causes: TCC permission denial, app not running, script compile error (OSA -2741), runtime timeout, network unreachable.
- A receipt-based trust system relies on error codes to drive retry, escalation, or policy decisions.

## The rule

One code per failure *mode*, not per *tool*. At minimum split:

- `<tool>_unavailable` — app/service genuinely not present or TCC-denied (the user can fix by granting permission or launching the app).
- `<tool>_script_error` — the script we sent didn't compile or threw (we have a bug to fix on our side).
- `<tool>_timeout` — the call exceeded its budget (transient, may retry with longer budget).
- `<tool>_permission_denied` — TCC explicitly denied (distinct from "app not installed").

## Why it matters

Lumping codes is the same shape of bug as silent default fallthrough in a policy map: the system *looks* like it's reporting truthfully, but the code is lying about what happened. Agents downstream will pick wrong recovery strategies — e.g. prompting the user to grant permission when actually the AppleScript has a malformed `repeat` block.

## How to verify

Trigger each failure mode deliberately (kill the app, revoke TCC, inject a syntax error, stall the script) and confirm each surfaces a distinct `error_code` in the raw tool return — not just in the trace wrapper. Cross-reference with `structured-error-code-contract`.

## Smell to watch for

If you ever see a `_unavailable` error_code paired with stderr containing `syntax error`, `compile`, `-2741`, or `timeout`, the code is lying. Fix the taxonomy before stacking more tools on the same wrapper pattern.