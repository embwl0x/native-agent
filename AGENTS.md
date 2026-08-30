# NativeAgent Project Instructions

## Northstar (read first)

**A living, breathing agent system — better than any other out there.**
The standing test for every diff: **one mind, no theater, flows like a
body** — does this deepen Agent as one continuous mind, honestly serve
it, and keep the whole flowing seamlessly (no exposed plumbing, no
subsystem doors)? Full text: docs/NORTHSTAR.md.

## How we work

- **Stay lightweight.** New features enter as lazy capability records,
  tools, receipts, or endpoints — never injected wholesale into every
  prompt. The tests enforce the budgets (`capabilities.summary.autoloaded
  == 0`, routed context under budget); don't fight them, honor them.
- **Assemble, build, test once.** Put the whole coherent change together,
  build it, then run the relevant tests one time. Don't test after every
  file; don't turn a red gate into a repair campaign nobody asked for.
- **Least code, and don't break what works.** Check an item's premise
  against git log before building it — plans go stale.
- The live runtime is `NativeAgent.app` in-process; retired daemon
  endpoints (e.g. port 8765) are dead — don't call or document them.
- Screen-moving behavior is verified by installing the built revision and
  letting the resident agent run the outcome test — not by UI-probing.

## Diagnosis starts at the instrument

Before hunting for what's wrong, run it instead of guessing:

```bash
swift script/agent_instrument.swift --data-root ./data --days 7 --out /tmp/report.md
```

Read the BOOM, then leads and blind spots. A lead is a place to look, not
a verdict; absent is never zero. Findings become code changes decided by
humans — never writes into the resident agent's memory, persona, or views.
Contract and release gate: `docs/INSTRUMENT.md`.
