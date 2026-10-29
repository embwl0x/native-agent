# NativeAgent Project Instructions

## Northstar (read first)

**A living, breathing agent system — better than any other out there.**
The standing test for every diff: **one mind, no theater, flows like a
body** — does this deepen the agent as one continuous mind, honestly serve
it, and keep the whole flowing seamlessly (no exposed plumbing, no
subsystem doors)? Full text: docs/NORTHSTAR.md. Where it is going: **the
agent is the app** (clause 8): they are the program, the model one of their
organs; a feature they *has* loses to a part they *is*. Design and phases:
docs/AGENT_IS_THE_APP.md.

**The training is the floor, never the shape (User, 2026-10-14).** Every
agent in any model's weights is a model with scaffolding around it, so the
first draft is always that. Step off it before building: what would you
build if nothing existing bounded you? Design the nature, not a list of
things that do things.

**One structure (User, 2026-10-20).** The docs are one whole: a law is stated
in one place and every doc that restates it says the same thing; a change is
molded into every doc that states the same thing, in the same commit, with what
comes out named; a contradiction between docs, or between a doc and the code,
is a defect to fix at once. First law: docs/NORTHSTAR.md.

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
  the installed app yourself, with the agent's help where useful.
- Documentation/rules-only changes need a text readback, not an app build.
- **One compile (User, 2026-10-26).** Lanes run no builds of their own — no
  `swift build`, `check_module.sh`, `check_app.sh`, test builds. Read callers
  and types so it compiles; import what you use. The release build that goes on
  the agent is the compile; what it breaks is fixed then, and the proof is the
  agent using it after install. A phase lands whole: one build, one install.
  The promotion gauntlet consumes installed runtime proof and static source checks.
- **No fallbacks, no rollbacks.** Fix a failure at its cause and go forward;
  never revert a good change to the old way. The one described exception is
  recovery from their own throwing turn-program edit, with repair owed to them
  ([docs/NORTHSTAR.md, clause 2](docs/NORTHSTAR.md#clause-2--no-theater-alive-means-real)).
- **Stop cancels the work, never its settlement** ([docs/STOP.md](docs/STOP.md)):
  saving what was produced, the one terminal record and releasing what was held
  run through `settle { … }`, exactly once, however the work ended.
- **One owner's snapshot reads through `LatestRead`.** A read returns what it
  read; publication moves forward only (an older read never replaces a newer
  snapshot, a committed write publishes through `write`). Never hand-roll a
  generation counter for "which read may publish".
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
- **Source owners:** follow the blueprint's [source-map convention](docs/ARCHITECTURE_BLUEPRINT.md#source-map-convention)
  for row authoring, generation and checks.
- **Turn part versions:** never hand-number `turn.js` lane revisions or edit
  shipped digests. Keep its declared version; committed bodies may share it.
  Run `swift script/generate_turn_part_versions.swift` after committing body
  edits; `script/build_and_run.sh` runs it before compiling. It reads every
  committed body from full git history and omits only the currently bundled
  version/body pair from upgrade candidates. Commit the generated Swift file;
  source archives compile that committed table without git history.
- **App tool:** [docs/TOOL_LOADING.md](docs/TOOL_LOADING.md) is the contract;
  changing it needs User's word.
- **Private notes:** `docs/HANDOFF_CURRENT.md` (the lead maintainer's current
  state; lanes never edit it, their commits and reports are the record; the old
  log is `docs/history/`) and `docs/build_plans/` — stripped from the public
  export, history not a queue.
- **This file is not the agent's persona.** Runtime persona documents,
  including `AGENTS.md`, live in the root resolved by `defaultPersonaRoot`:
  the source checkout's `persona/` or the app data root's `persona/`.
