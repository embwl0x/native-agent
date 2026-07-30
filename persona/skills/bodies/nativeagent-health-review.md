# NativeAgent Health Review

Use when asked to run a NativeAgent health review.

## Workflow

1. Read the current health surfaces through the live Swift app: the Doctor checks (Diagnostics ▸ Doctor / the doctor tools), runtime watchdog status (Diagnostics ▸ Status), provider auth state (Providers), Telegram status (Telegram settings), and skills/tools availability (list_skills / tool_catalog).
2. Inspect each for failures, unhealthy states, auth problems, or doctor-reported repair items.
3. Report only failing checks.
4. For each failing check, include the exact repair action needed.

## Output Rule

Do not report passing checks. Keep the result focused on failures and repairs only. Do not reference retired HTTP endpoints — everything reads through the Swift runtime surfaces.
