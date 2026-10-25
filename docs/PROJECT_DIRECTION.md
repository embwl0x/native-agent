# NativeAgent Project Direction

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

This is the durable project compass. [NORTHSTAR.md](NORTHSTAR.md) holds User's
intent; [the documentation guide](README.md) routes readers to current details.

## North Star

A living, breathing agent system: **one mind, no theater, flows like a body**.
Keep NativeAgent powerful enough for Agent to act and simple enough for people
to install, understand and recover. One download includes the embedding model.

**Where it is going (2026-10-14): the agent is the app.** They are the program
and the model is one of their organs; everything they are made of is a part on one
law, and the Swift stem has no features. The design and its phases:
[AGENT_IS_THE_APP.md](AGENT_IS_THE_APP.md). Every pass from here is measured
against it: a feature they *has* loses to a part they *is*.

## Product Principles

- Keep their mind clear. Make capabilities and deeper context reachable without
  putting every action, skill body or memory into each prompt.
- Keep one authority model across surfaces. Authenticate who is asking, then
  honor the authority the owner granted.
- Consolidate before adding. Reuse the existing owner of a fact, action or
  outcome; do not add parallel memory, approval or execution systems.
- Verify outcomes at their source. A successful dispatch or provider response
  does not by itself prove a file was saved or a message delivered. Report
  uncertainty and partial progress plainly.
- Make recovery understandable. Give the person or agent a useful result,
  a clear decision or a concrete next step; keep technical detail available
  when needed.
- Keep public defaults identity-neutral. Resolve names from the active profile
  and persona rather than embedding a local identity in generic resources.

## Current Architecture

**One brain, many doors.** `NativeAgent.app` owns the Swift runtime in-process.
The Mac and remote conversation surfaces use the shared core:

- [EngineRuntime/NativeAgentEngine.swift](../Modules/NativeAgentCore/Sources/EngineRuntime/NativeAgentEngine.swift)
  composes chat clients, tool chains and runtime services from one data root
  and the app's platform ports.
- [ChatTurnRuntime](../Modules/NativeAgentCore/Sources/ChatTurnRuntime/)
  owns turn orchestration.
- [AppActionRegistry.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppActionRegistry.swift)
  defines the actions exposed through `app`.
- [TrustCenter](../Modules/NativeAgentCore/Sources/TrustCenter/) owns policy;
  SecurityCenter checks each dispatch. The app supplies platform effects.

See [ARCHITECTURE_BLUEPRINT.md](ARCHITECTURE_BLUEPRINT.md) for source ownership.

## Agent Interface

Agent has one always-on tool: `app`.

| Call | Purpose |
| --- | --- |
| `app {}` | Home: where they left off, open work, waiting items and arrivals, followed by the pages. |
| `app {page:"providers"}` | Read a page's state, settings, version and available actions. |
| `app {item:"…"}` | Open a name or reference returned by home; some items act immediately. |
| `app {find:"…"}` | Find pages, actions and skills by intent, from any page including home. |
| `app {action:"…", args:{…}}` | Run one registered action. |
| `app {script:"…"}` | Run JavaScriptCore code using the app's permitted actions, reads and search. Each action is checked separately. |

Scripts stop at a blocked action and wait at a card for the answer; completed
earlier actions stay done. Standalone tool names are refused with a translated `app` call. There is
no tool-loading step.

Their abilities follow `ability.save` → kept (theirs under Full Mac, else the owner's
card) → `authored.<id>`, all through `app`. `web.search` searches SearXNG, every engine it has, and returns its results or its failure said plainly (no fallback; Doctor names a broken SearXNG); on a Mac without SearXNG the result hands their `browser_search`, the same search in a browser (Chrome through the extension when it is connected, else their own browser), which they runs and reads; a time range travels with either.
An ability they grows is one file in `abilities/` with the one header, whatever
door made it: read through `ability.read` and run as `authored.<id>`. A skill is
built-in guidance from the persona, read and never run; see the
[part header and skill contract](skill_manifest_spec.md).

## Authority

Under Full Mac, Agent acts autonomously on admitted surfaces without routine
approval cards. Explicit blocks and security checks still apply; macOS grants
remain separate. **Resetting macOS privacy permissions always asks the owner.**

A turn is peer-steered only when an agent you have not trusted started it with its message; that turn's first effect of any kind files one card quoting what the agent asked, and your answer covers the rest of the turn. Reading any agent's words steers nothing; conversing with agents and telling them what to do asks nothing. These boundaries live in
`SecurityCenter.swift` and `PeerTurnEffectPolicy.swift`, not in prompt guesses.
Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns; ordinary Trust and domain checks still apply.

## Guardrails For Future Work

- Add capability through the existing app action registry and owners.
- A part (tool, skill, sense, their turn) never carries authority: every effect
  it makes goes through Trust at effect time.
- Preserve canonical state and truthful receipts; do not hide broken state
  with fallback loops or duplicate stores.
- Keep private runtime state, credentials and live persona material out of
  release artifacts.
- Check the current code and git history before treating an old plan as work.

## Verification Baseline

For runtime changes, assemble the coherent change, build the actual app,
install it, then check the requested behavior in that installed app. Keep the
check bounded. Do not create or run separate test suites, harnesses or load
campaigns. Documentation-only changes need a direct text readback.

## Update Rule

Update the smallest document whose contract changed. Keep source ownership in
the architecture map and history in git and CHANGELOG; do not turn this compass
into a release receipt or backlog.
