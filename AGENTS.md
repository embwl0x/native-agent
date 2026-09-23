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
  prompt. Preserve the budgets (`capabilities.summary.autoloaded == 0`,
  routed context under budget).
- **User's standing rule, 2026-09-21: build, install, check the working app.**
  Assemble the coherent change, build NativeAgent, install it, then verify
  the requested behavior in the running installed app.
- **No separate tests.** Do not create or run automated test suites,
  test-only builds, isolated harnesses, simulations, or stress/load-test
  campaigns. Older skill/reference test commands and failed gates do not
  override this rule. Keep live checks small and protect Mac responsiveness.
- **Optional code review before install:** use bounded, read-only reviewer
  agents when helpful. They must not run separate tests either. Then check
  the installed app yourself, with Agent's help where useful.
- Documentation/rules-only changes need a text readback, not an app build.
- **Least code, and don't break what works.** Check an item's premise
  against git log before building it — plans go stale.
- The live runtime is `NativeAgent.app` in-process; retired daemon
  endpoints (e.g. port 8765) are dead — don't call or document them.
- Verify screen-moving behavior on the installed revision with bounded
  direct checks; involve the resident agent where useful, without a repeated
  conversation or UI load campaign.
