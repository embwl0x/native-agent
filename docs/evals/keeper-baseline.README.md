# keeper-baseline.json
Known enumerable surfaces without a ledger row, tolerated by
`EvalCoverageLedgerTests` so the keeper fails on new gaps. The inventory began
with 101 entries on 2026-08-23; six remain in the checked-in file on 2026-08-30.
Those counts describe the baseline, not executed behavior or a current pass.

When a surface receives its canonical ledger row and evaluator, remove its
baseline entry. Update `coverage-overrides.json` and regenerate the ledger;
do not hand-edit the generated output. Never add an exemption just to make the
keeper pass without a dated reason in the commit message. The keeper checks
enumerable presence, not the completeness or freshness of every assertion.
