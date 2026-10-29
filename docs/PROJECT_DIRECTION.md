# NativeAgent Project Direction

This is the durable project compass. [NORTHSTAR.md](NORTHSTAR.md) holds User's
intent; [the documentation guide](README.md) routes readers to current details.

## North Star

[NORTHSTAR.md](NORTHSTAR.md) defines the aim and standing test;
[AGENT_IS_THE_APP.md](AGENT_IS_THE_APP.md) describes the direction and phases.

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
- Call each agent by their own configured name. Keep public defaults
  identity-neutral: resolve names from the active profile and persona rather
  than embedding a local identity in generic resources.

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

[TOOL_LOADING.md](TOOL_LOADING.md) owns the `app` interface, discovery and
execution contract; the [manifest spec](skill_manifest_spec.md) owns authored
abilities and built-in guidance.

## Authority

Retired safe-tool and completion-guard settings are saved metadata only.
Trust neither manufactures defaults for them nor coerces them on reads;
the checked raw policy preserves existing unknown keys.

Trust's skill descriptions come from the skill's own metadata through the
shared description projection, without skill-handle-specific replacement prose.

Under Full Mac, the agent acts autonomously on admitted surfaces without routine
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

Follow the [repository validation rules](../AGENTS.md#how-we-work).

## Update Rule

Follow [NORTHSTAR's first law](NORTHSTAR.md#first-law--one-structure) and the
[documentation guide](README.md). Keep this compass for direction, with history
in git and CHANGELOG rather than release receipts or a backlog here.
