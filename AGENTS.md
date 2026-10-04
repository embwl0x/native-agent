# NativeAgent Project Instructions

## Northstar (read first)

**A living, breathing agent system — better than any other out there.**
The standing test for every diff: **one mind, no theater, flows like a
body** — does this deepen Agent as one continuous mind, honestly serve
it, and keep the whole flowing seamlessly (no exposed plumbing, no
subsystem doors)? Full text: docs/NORTHSTAR.md.

## How we work

- **Stay lightweight.** `app` is the agent's only always-on tool. Add actions
  through `AppActionRegistry`; expose detail through pages, items and `find`,
  not extra tool schemas or broad prompt injection. `app {}` is their home.
  Contract: [docs/TOOL_LOADING.md](docs/TOOL_LOADING.md).
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
- The live runtime is `NativeAgent.app` in-process. `EngineRuntime` and
  `ChatTurnRuntime` in the core own the engine and turns: one brain, many doors.
  Retired daemon endpoints (e.g. port 8765) are dead — don't call or document them.
- Verify screen-moving behavior on the installed revision with bounded
  direct checks; involve the resident agent where useful, without a repeated
  conversation or UI load campaign.

## Where things are

This file is the entry point for agents working on the repository. Read
[docs/NORTHSTAR.md](docs/NORTHSTAR.md) for intent and
[PROJECT_STATUS.md](PROJECT_STATUS.md) for where things stand; history lives
in `git log`, [CHANGELOG.md](CHANGELOG.md) and `docs/release-notes/`.

- **Docs map:** [docs/README.md](docs/README.md) maps the current documents,
  including the files the app and scripts read (keep those paths stable).
- **Source owners:** [docs/ARCHITECTURE_BLUEPRINT.md](docs/ARCHITECTURE_BLUEPRINT.md);
  `script/check_architecture_blueprint.swift` holds its table rows to the files
  on disk.
- **App tool:** [docs/TOOL_LOADING.md](docs/TOOL_LOADING.md) is the contract;
  changing it needs User's word.
- **Private notes:** `docs/HANDOFF_CURRENT.md` (newest section is current) and
  `docs/build_plans/` — stripped from the public export, history not a queue.
- **This file is not the agent's persona.** Runtime persona documents,
  including `AGENTS.md`, live in the root resolved by `defaultPersonaRoot`:
  the source checkout's `persona/` or the app data root's `persona/`.
