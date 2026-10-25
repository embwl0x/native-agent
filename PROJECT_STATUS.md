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
| Growth and MCP | Tools, skills and senses share `data/abilities/`: one current file, optional previous/proposed files and independent run state; exact admission/proof, previous-version rollback and final drop. An MCP server they wants is an ability they grows; NativeAgent keeps no MCP client. |
| Web search | `web.search` uses SearXNG for every query when configured or locally discovered; a failed SearXNG search stays a failure. With no SearXNG, it hands back the search to run in Chrome or their browser. Codex search is retired. Research Lab retains its SearXNG route; the editable `research-lab.js` part selects sources and writes the brief from explicit native evidence, while Swift commits locked capped history and receipts. |
| Memory | MemoryV2 stores durable memories; Fluid Context prepares bounded context. |
| Work | Desk holds durable work. Helpers run their own model/tool loops with their names, personalities, jobs, transcripts and saved model choices; they reach the resident through the contact path. |
| Providers | Chat, Work, and Memory and mind are the three routing groups; Work and Memory and mind inherit Chat's model/account unless configured; effort can be set independently. |
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
