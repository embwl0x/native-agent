# NativeAgent Project Status

Last updated: 2026-09-26

This page says what NativeAgent is and where it stands today. History lives in
git (`git log`), the [Changelog](CHANGELOG.md), and the per-version
[release notes](docs/release-notes/). A statement here is not a release
receipt: the [Releases page](https://github.com/embwl0x/native-agent/releases)
is authoritative for what has shipped.

## What it is

One persistent agent that lives in a macOS app. `NativeAgent.app` owns the
whole Swift runtime in-process: conversation, memory, context, tools, trust,
background work and cognition. There is no daemon and no second brain. The
iPhone app, Telegram, Slack, the Chrome extension and the Codex/Claude Code
bridges are surfaces onto that same agent.

The Mac window has three views, switched at the top right:

- **Simple** — the agent, the agents it talks to and its helpers on one panel
  beside the chat. No settings pages; setup happens by asking the agent, which
  answers with cards in the chat. A fresh install opens here.
- **Advanced** — the full app: a rail of pages (Chat, Today, Memories, Desk,
  Notifications, Helpers, Personality, Providers, Trust, Connectors,
  Capabilities, Diagnostics, Settings). Installs that already had chats open
  here.
- **Agent** — a read-only window onto the agent's own desktop.

The old classic sidebar is retired; anyone still on it lands in the current
shell.

## Where things stand

| Area | State |
|---|---|
| Mac app | 0.4.18 is the current release (2026-09-25): Developer ID signed, notarized, Sparkle-updatable. |
| iPhone app | 0.5.0 (build 15) is validated in App Store Connect and ready for review; not yet submitted. |
| Unreleased on `main` | See the **Unreleased** section of the [Changelog](CHANGELOG.md). |
| Providers | ChatGPT/Codex, OpenAI API, Anthropic, xAI, Moonshot and OpenRouter. One choice per group (Chat, Work, Memory and mind); no silent fallback models. |
| Tools | A short always-on set rides every request, plus any mounted MCP server; everything else loads lazily and leaves when unused. Contract: [docs/TOOL_LOADING.md](docs/TOOL_LOADING.md). |
| Memory | MemoryV2 (SQLite, lexical + semantic recall, knowledge graph, reviewed proposals). The embedding model ships in the app. |
| Trust | Four presets (Safe, Work mode, Builder, Full Mac); Full Mac has no timer. macOS privacy permissions stay separate. |
| Experimental | Cognitive substrate and Organism Kernel: bounded, advisory, observable in Diagnostics. |

## Known limits

- Connector depth varies; a configured OAuth flow is not automatically a
  complete integration.
- The Mac must be on and reachable for the iPhone app, Telegram and Slack to get
  replies.
- Computer control acts through accessibility and screen evidence; it is not
  perfect perception.
- NativeAgent is a single-operator project and should not be the sole control
  for safety-critical decisions.

## Where to read next

- [README](README.md) — install, first run, what exists.
- [User and Agent Guide](docs/USER_GUIDE.md) — every page and setting.
- [Documentation guide](docs/README.md) — the map of every current doc.
- [AGENTS.md](AGENTS.md) — rules for agents working on this repository.
