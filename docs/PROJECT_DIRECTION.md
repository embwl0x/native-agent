# NativeAgent Project Direction

This is the durable project compass. [NORTHSTAR.md](NORTHSTAR.md) holds User's
intent; [the documentation guide](README.md) routes readers to current details.

## North Star

A living, breathing agent system: **one mind, no theater, flows like a body**.
Keep NativeAgent powerful enough for Agent to act and simple enough for people
to install, understand and recover. One download includes the embedding model.

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
| `app {find:"…"}` | Find pages and actions by intent; with `page:"home"`, search their work and conversations. |
| `app {action:"…", args:{…}}` | Run one registered action. |
| `app {script:"…"}` | Run JavaScriptCore code using the app's permitted actions, reads and search. Each action is checked separately. |

Scripts stop at a blocked action or approval; completed earlier actions stay
done. Standalone tool names are refused with a translated `app` call. There is
no tool-loading step.

Self-authored executable tools follow `tool.propose` → `tool.approve` →
`authored.<id>`, all through `app`. Mounted MCP actions appear as
`mcp.<server>.<tool>`. `web.search` tries Codex web search first for general
queries and SearXNG first for code queries. Unfiltered searches try the other
route if the first fails or returns no results; the result identifies it.
Non-general categories and time ranges use only SearXNG.
Procedure skills are guidance, read through `skill.read`; see the
[skill contract](skill_manifest_spec.md).

## Authority

Under Full Mac, Agent acts autonomously on admitted surfaces without routine
approval cards. Explicit blocks and security checks still apply; macOS grants
remain separate. **Resetting macOS privacy permissions always asks the owner.**

A peer-steered turn still asks User for deletes and irreversible acts, sends in
their name, persona writes and approvals. Peer conversation itself does not
require a new approval for each reply. These boundaries live in
`SecurityCenter.swift` and `PeerTurnEffectPolicy.swift`, not in prompt guesses.
Authenticated turns from agents enabled in Trust → Connected agents carry
User's authority and skip extra peer approvals; ordinary Trust and domain checks
still apply.

## Guardrails For Future Work

- Add capability through the existing app action registry and owners.
- Keep skill guidance separate from executable code and authority.
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
