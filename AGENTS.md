# NativeAgent Project Instructions

## Northstar (read first)

**A living, breathing agent system — better than any other out there.**
The standing test for every diff: **one mind, no theater, flows like a
body** — does this deepen Agent as one continuous mind, honestly serve
it, and keep the whole flowing seamlessly (no exposed plumbing, no
subsystem doors)? Full text: docs/NORTHSTAR.md.

## Non-Bloat Capability Rule

NativeAgent must stay lightweight as it becomes more capable.

- New features should enter as lazy capability records, tools, receipts, workflows, or endpoints first.
- Do not inject full feature, plugin, skill, tool, phase, or roadmap bodies into every chat prompt.
- Full bodies may load only when the context router selects them for the current turn, or when the user explicitly asks for a full/debug inventory.
- The agent should know what it has through compact indexes, Swift-native capability summaries, routed context lookups, and context receipts.
- Keep `capabilities.summary.autoloaded == 0`.
- Keep sampled context routes under their configured budgets.
- Keep self-improvement worktree build/test artifacts disposable through consolidation cleanup.

`NativeAgent.app` owns the live runtime in-process. Do not call retired daemon HTTP endpoints such as port `8765` when adding capabilities or writing instructions for other agents.

After an agent capability is fully assembled and the integrated target builds, include the fast architecture and stale-instruction guard in the single final validation when relevant:

```bash
./script/check_architecture_blueprint.swift --repo .
```

Run `./script/test.sh` once only when User explicitly requests the whole-repo gate or the agreed outcome includes it. A commit, push, install, publish, or release request does not authorize turning a gate failure into an eval-repair campaign. Automated tests must still fail if capability bodies become autoloaded, context routes exceed budget, or active instructions point agents at retired runtime paths.

## Build Then Test — Permanent Rule

- Assemble the complete coherent change first.
- Build the integrated target after assembly is finished.
- Only after that build succeeds, run the finished workflow tests or eval gate once.
- Do not run tests after individual files, rows, components, or serial subagent batches.
- A narrow intermediate diagnostic is allowed only when a concrete build failure or assembly-blocking interface uncertainty requires it; it does not replace the final integrated build-then-test checkpoint.
- For screen-moving behavior, install the exact built revision, verify its install stamp, and let the resident agent perform the outcome test. Build agents must not substitute repeated UI probing for that outcome test.

## Eval Implementation — Permanent Builder-Only Rule

- The active Codex task owns the architecture, integration, and acceptance bar for the complete eval build.
- Parallel implementation workers are allowed when they own distinct, non-overlapping sections and each builds its assigned section completely.
- Keep the builder pool small and useful (normally 3–6 workers), with explicit file/surface ownership. Do not create workers merely because capacity exists.
- Do not create separate first-pass, critic, verifier, reviewer, or repair-agent waves. Codex integrates each completed build directly and fixes remaining issues itself.
- Do not create nested subagents for the eval burn-down.
- Build the missing production behavior and executable eval together across the complete remaining ledger. Apply the integrated build-then-test rule above only after assembly is complete.
- The retired mass-worker and multi-pass workflow in old handoffs and Git history is not authority and must not be reconstructed.

## Evals — hook in and take a look (2026-08-21)

Before diagnosing "how is the system doing" or hunting for what's wrong, run
the instrument instead of reading code or guessing:

```bash
swift script/agent_instrument.swift --data-root ./data --days 7 --out /tmp/report.md
```

Read the BOOM (one screen), then leads and blind spots. Contract, rules, and
the turn-replay release gate ("did we change who the agent is"): `docs/INSTRUMENT.md`.
A lead is a place to investigate, not a verdict; absent is never zero. Findings
become code changes decided by humans — never writes into the resident agent's
memory, persona, or views.
