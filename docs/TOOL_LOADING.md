# Tool loading: the contract

NativeAgent is Agent's only tool: one always-on `app` schema. Pages, action
arguments and results travel through that tool. This is a design contract;
changing it requires User's authorization.

## One tool, every action

`SwiftToolDispatcher.alwaysOnCoreNames` contains only `app`. Ordinary chat
requests offer it alone. The schema is defined in
`AppToolExecutor+ToolSchemas.swift`; `AppActionRegistry.swift` owns the
`AppActions` registry behind it.

| Call | Meaning |
|---|---|
| `app {}` | Home first—where they left off—then the page index and action IDs. |
| `app {"page":"home"}` | Their work, arrivals, conversations and places. |
| `app {"item":"<name or ref>","args":{…}}` | Open or act on a name returned by home or one of its rooms. Home arguments are `text` and `fields`. |
| `app {"page":"home","find":"<words>"}` | Search their work and conversations. |
| `app {"page":"<page>","item":"<optional item>"}` | Read a page or one of that page's items. Page reads return a version and available actions. |
| `app {"find":"<words>"}` | Discover matching pages, actions and skills. |
| `app {"action":"<id>","args":{…}}` | Run one registered action. |
| `app {"script":"<JavaScript>"}` | Compose permitted app calls in JavaScriptCore. |

Home names belong under `item`; registry action IDs belong under `action`.
A home item can change state or send a message immediately. Read its room to
understand it first: home items do not support `preview` or
`expected_version`.

For actions, `preview:true` describes the call without executing it.
`expected_version` can guard against a page changing after it was read.
Unknown keys, invalid arguments and stale versions refuse with a remedy.

## No loading lifecycle

There is no model-facing catalog/load/unload flow, turn-start schema preload
or per-session active-tools store. An installed schema update is available on
the next turn.

Legacy model-facing tool names run nothing. `ToolNameAliases` returns an
equivalent `app` call where one exists, or directs the caller to `app`.
The former `workspace` interface is home; a catalog query becomes `find`.

Internal executors and saved Trust keys still exist where actions need them.
A folded action re-enters the gated dispatcher under its underlying tool name;
home likewise re-enters its internal executor. Saved blocks and domain gates
continue to apply. Internal names are not additional tools offered to Agent.

Workshop, studio-wander, swarm and bridge execution paths can have their own
declared tool lists. Their internal dispatch contracts do not enlarge the
ordinary chat request. The Tools UI reads the manifest rather than calling a
discovery tool.

## Extending their reach

- Built-in capabilities are registered app actions, not additional request
  schemas.
- Mounted MCP tools appear as `mcp.<server>.<tool>`, generated from the live
  server list. The built-in search/fetch actions appear as `web.search` and
  `web.fetch`.
- Self-authored tools follow `tool.propose` → `tool.approve` →
  `authored.<id>`. A proposal supplies Swift code and input/expected cases,
  with optional permissions and input schema. Only active registry entries
  become authored actions; approval follows the current Trust policy.
- Skills remain guidance: discovery can return a `skill.read` call for a
  relevant body.

`web.search` tries Codex web search first for general queries. Code-shaped
queries try SearXNG first. Unfiltered searches try the other route if the first
fails or returns no results; the result identifies the route and any fallback
reason. Explicit time ranges and non-general categories use only SearXNG.
Cancellation stops the search.

## Scripts

`AppScriptRunner` creates a fresh JavaScriptCore context with
`app.<action>(args)`, `app.read`, `app.find` and `app.log`. It exposes no
direct filesystem, network, process or timer API. Every nested app call
re-enters the same gate chain.

The registry's `scriptable` flag decides which actions may run. Home may be
read, but home items cannot be opened from a script. Sends, shell commands,
Mac control and MCP calls are examples of actions that must be separate app
calls. Secret arguments must also be passed through a single action.

The runner bounds source size, reads, actions, call duration and total time.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.

## Authority and receipts

Under Full Mac, Agent can also perform actions otherwise marked User's.
Explicit blocks, checked policy, actual macOS grants and connector
authentication still apply. macOS privacy permission resets always require
the owner's approval. Peer-steered turns additionally ask User for deletes and
irreversible acts, sends in their name, persona writes and protected approvals.
`SecurityCenter` and `PeerTurnEffectPolicy` own those decisions.
Authenticated turns from agents enabled in Trust → Connected agents carry
User's authority and skip extra peer approvals; ordinary Trust and domain checks
still apply.

`tools.contract` records the actual wire schema count and bytes.
`turn.terminal` includes `discoveryToolDispatchCount` for executed
`app {find}` discovery calls. Action receipts distinguish refusal, waiting,
failure and observed effects; a response alone is not proof of an external
outcome.

## Source owners

All paths below are under `Modules/NativeAgentCore/Sources/`.

| Owner | Contract |
|---|---|
| `AppToolRuntime/AppActionRegistry.swift` | Actions, arguments, ownership and scriptability. |
| `AppToolRuntime/AppToolExecutor+AppDoor.swift` | Home, pages, discovery, previews and action dispatch. |
| `AppToolRuntime/AppScriptRunner.swift` | JavaScript execution and bounds. |
| `ToolRegistry/ToolNameAliases.swift` | Action translations and underlying dispatch identity. |
| `ChatToolRuntime/SwiftToolDispatcher+ToolCatalog.swift` | The single always-on name. |
| `ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` | Request filtering and tool-contract traces. |
| `Research/Research+CodexSearch.swift` | Search routing and fallback. |

See [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for the surrounding lifecycle.
