# keeper-baseline.json
Known surfaces WITHOUT a ledger row as of 2026-08-23 (101 entries) — tolerated by
`EvalCoverageLedgerTests` so the keeper fails only on NEW gaps. Burn this list down: each
entry gets a ledger row + an eval (wave B: a by-name worker for the built-in tools), then
is removed here. Never add to this file to make the keeper pass for a new surface without a
dated reason in the commit message.
