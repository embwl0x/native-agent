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

Before and after adding agent capabilities, run the fast architecture and stale-instruction guard:

```bash
./script/check_architecture_blueprint.swift --repo .
```

Before committing broader capability work, run `./script/test.sh`. Automated tests must fail if capability bodies become autoloaded, context routes exceed budget, or active instructions point agents at retired runtime paths.
