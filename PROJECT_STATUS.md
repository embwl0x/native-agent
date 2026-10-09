# NativeAgent Project Status

Source status: 2026-10-02. This describes the checkout, not a release or
installed-app verification. Release history lives in [CHANGELOG.md](CHANGELOG.md)
and [release notes](docs/release-notes/).

## What it is

One brain, many doors. `NativeAgent.app` hosts the Swift runtime in-process.
The core's `EngineRuntime` composes it and `ChatTurnRuntime` owns turn
execution. Mac, iPhone, Telegram, Slack and local agent bridges reach that
shared engine.

The Mac has Simple, Advanced and Agent views. Simple presents chat, contacts
and helpers; Advanced exposes the full page rail; Agent shows the agent's own
desktop read-only.

## Where things stand

| Area | Current source contract |
|---|---|
| Releases | Mac v0.6.0 is the current public release as of 2026-10-09 (0.5.1 shipped 2026-10-04) (Developer ID signed, notarized, Sparkle). The 2026-10-02 source snapshot recorded iPhone 0.5.1 (19) in App Review. The [Releases page](https://github.com/embwl0x/native-agent/releases) is authoritative for what has shipped. |
| Agent interface | `app` is the only always-on tool. `app {}` is home; `page`, `item`, `find`, `action` and JavaScriptCore `script` reach capabilities through `AppActionRegistry`. |
| Discovery | Pages and actions arrive in tool results. Retired tool names are refused with a translated `app` call; there is nothing to load or unload. |
| Growth and MCP | `tool.propose` → `tool.approve` → `authored.<id>`; mounted MCP tools become `mcp.<server>.<tool>` actions. |
| Web search | `web.search` uses Codex with direct web-tool access for general queries and SearXNG for categories or Codex failures. Receipts retain the actual route and Codex failure reason; completed empty searches stay on their route. Time ranges travel with either route. |
| Memory | MemoryV2 stores durable memories; Fluid Context prepares bounded context. |
| Work | Desk holds durable work. Helpers run in their own conversations with saved model choices. |
| Providers | Chat, Work, and Memory and mind are the three routing groups; Work and Memory and mind inherit Chat unless configured. |
| Trust | Full Mac grants autonomy without a timer. macOS privacy permission resets still ask the owner; peer-steered deletes, irreversible acts, sends in the owner's name, persona writes and approvals retain cards, except for authenticated agents enabled in Trust → Connected agents. Those agents carry User's authority; ordinary Trust and domain checks remain. |

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
