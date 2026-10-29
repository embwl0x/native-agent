# NativeAgent Project Status

Source status: 2026-10-20. This describes the checkout, not a release or
installed-app verification. Release history lives in [CHANGELOG.md](CHANGELOG.md)
and [release notes](docs/release-notes/).

## What it is

One brain, many doors. `NativeAgent.app` hosts the Swift runtime in-process.
The core's `EngineRuntime` composes it and `ChatTurnRuntime` owns resident turn
execution. StandingBots owns helpers' model/tool loops over their own transcripts.
Mac, iPhone, Telegram, Slack and local agent bridges reach that
shared engine.

The Mac has Simple, Advanced and Agent views. Simple presents chat, contacts
and helpers; Advanced exposes the full page rail; Agent shows the agent's own
desktop read-only.

## Where things stand

| Area | Current source contract |
|---|---|
| Releases | Mac v0.6.9 is the current public release as of 2026-10-20 (Developer ID signed, notarized, Sparkle). The iPhone companion ships through TestFlight. The [Releases page](https://github.com/embwl0x/native-agent/releases) is authoritative for what has shipped. |
| Agent interface | `app` is the only always-on tool. `app {}` is home; `page`, `item`, `find`, `action` and JavaScriptCore `script` reach capabilities through `AppActionRegistry`. |
| Discovery | Pages and actions arrive in tool results. Retired tool names are refused with a translated `app` call; there is nothing to load or unload. |
| Growth and MCP | Authored executable tools and legacy executable skills migrated into `data/abilities/` alongside senses and turns: one current file, optional previous/proposed files and independent run state, with exact admission/proof and explicit lifecycle actions. Built-in skill guidance remains in the persona's `skills/bodies/`, read and never run; the [manifest spec](docs/skill_manifest_spec.md) owns that distinction. An MCP server they wants is an ability they grows; NativeAgent keeps no MCP client. |
| Web search | `web.search` uses SearXNG for every query when configured or locally discovered; search and discovery/configuration failures retain their cause. A response requires a results array containing only objects; malformed results fail rather than report no matches. Only completed discovery finding no instance admits the browser route. With no SearXNG, it hands back the search to run in Chrome or their browser. Codex search is retired. Research Lab retains its SearXNG route; the editable `research-lab.js` part selects sources and writes the brief from explicit native evidence, while Swift commits locked capped history and receipts. |
| Web reads and maps | `web.read` returns the whole extracted text, or with `find` the matching paragraphs with surroundings (`full:true` asks for the whole text instead). Source receipts name their retained file and purpose; DNS, connection refusal and timeout keep distinct causes. `maps.search` splits an inline near/in/around location when `near` is absent/empty and reports it; `maps.route` returns every step with segment-distance meaning and `traffic:not_included` ideal-conditions timing. See [tool contract](docs/TOOL_LOADING.md). |
| Memory | MemoryV2 stores durable memories; Fluid Context prepares bounded context. |
| Work | Desk holds durable work. Helpers run their own model/tool loops with their names, personalities, jobs, transcripts and saved model choices; they reach the resident through the contact path. |
| Providers | Chat, Work, and Memory and mind are the three routing groups; Work and Memory and mind inherit Chat's model/account unless configured. Think and Fast use effort-only and tier-only group transactions: each changes its field across every member without pinning the resolved model/account or the other control. |
| Trust | Full Mac grants autonomy without a timer. macOS privacy permission resets still ask the owner. A turn an agent you have not trusted started with its message gets one card on its first effect, and the answer covers the rest of that turn; a read steers nothing. Agents enabled in Trust → Connected agents carry the owner's authority on authenticated turns; ordinary Trust and domain checks remain. |

## Known limits

- Mac permissions, explicit blocks, connector authentication and origin checks
  still apply under Full Mac.
- The iPhone companion needs the Mac awake with NativeAgent open.
- A configured connection or a returned tool result alone does not prove an
  external action completed; inspect the action's receipt and owning service.

## Where to read next

- [README](README.md) — install and first run.
- [User and Agent Guide](docs/USER_GUIDE.md) — pages and everyday operation.
- [Capabilities](docs/CAPABILITIES.md) — source-backed capability map.
- [App tool contract](docs/TOOL_LOADING.md) — the single tool interface.
- [Documentation guide](docs/README.md) — documents and their readers.
- [AGENTS.md](AGENTS.md) — repository working rules.
