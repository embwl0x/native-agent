# NativeAgent

<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128@2x.png" width="128" alt="NativeAgent app icon">
</p>

NativeAgent is a personal agent for Mac: conversation, memory and action in
one continuous mind. The Mac app owns the Swift runtime in-process; iPhone,
Telegram, Slack and local agent bridges reach that same runtime.

## First run

1. On a Mac running macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases), open it,
   drag NativeAgent to Applications, and open the app.
2. Enter your name and the agent's name.
3. Connect an AI account or add an API key. You can skip setup of the account
   and connect later in **Providers**; chat needs a connected account.

## Three views

- **Simple** — chat beside the agent, its contacts and helpers. Ask the agent
  to set things up. The panel's gear offers appearance controls and
  **More settings…**, which opens Settings in Advanced.
- **Advanced** — the full rail of pages: Chat, Today, Memories, Desk,
  Notifications, Helpers, Personality, Providers, Trust, Connectors,
  Capabilities, Diagnostics and Settings.
- **Agent** — a read-only view of the agent's own desktop.

A fresh install starts in Simple; an install with existing chats defaults to
Advanced. The [User and Agent Guide](docs/USER_GUIDE.md) covers setup and the
main pages.

## What exists today

| Area | Current behavior |
|---|---|
| Agent interface | One always-on `app` tool. `app {}` is home, “where I left off”; pages, items, search, actions and JavaScript reach the app's capabilities. |
| Memory and context | MemoryV2 stores durable memory with lexical and semantic recall. Fluid Context prepares bounded context from the underlying stores. |
| Work | Desk holds projects, dependencies, schedules, progress and outcomes; standing helpers have their own briefs, models and conversations. |
| Mac and web | App actions reach files, shell, Mac apps, screen control, the built-in browser and the optional Chrome extension. `web.search` tries Codex for general queries and SearXNG for code queries. |
| Connections | Connectors and agent contacts live under **Connectors**. Mounted MCP tools appear as `mcp.<server>.<tool>` actions inside `app`. |
| Growth | Skills provide reusable guidance. `tool.propose` files authored code; `tool.approve` activates it as `authored.<id>`. |
| Trust | Safe, Work mode, Builder and Full Mac govern access. Full Mac grants autonomy; macOS privacy permission resets still ask the owner. Peer-steered turns retain extra approval boundaries, except for authenticated agents enabled in Trust → Connected agents; ordinary Trust and domain checks still apply. |
| Inner life | Settings controls reflection, dreams and memory in replies; Diagnostics exposes cognition and organism state. |

The action registry is
[AppActionRegistry.swift](Modules/NativeAgentCore/Sources/AppToolRuntime/AppActionRegistry.swift).
The [app tool contract](docs/TOOL_LOADING.md) explains discovery and execution;
the [capability map](docs/CAPABILITIES.md) covers boundaries and source owners.

## Codex and Claude Code as specialist builders

The agent can delegate repository work to local coding sessions and receive
the result back. Users supply their own installed, signed-in coding products.
Local bridge clients read `~/.config/claude-bridge/bridge.json` for the actual
loopback address and bearer token. See the
[builder guide](docs/USER_GUIDE.md#codex-and-claude-code-as-specialist-builders).

## iPhone and iPad

The companion reaches the Mac through signed iCloud transport. On the Mac,
open **Connectors → iPhone**; on the phone, use the same Apple Account and
follow pairing. Keep the Mac awake with NativeAgent open for replies.
See [Mobile companion](docs/mobile_companion.md).

## Install

Download builds from the
[releases page](https://github.com/embwl0x/native-agent/releases).
See [Support](SUPPORT.md) for installation and updates.

### From source

The package requires macOS 26+ and Swift 6.1; app installation requires Xcode
and XcodeGen.

```bash
brew install xcodegen
git clone https://github.com/embwl0x/native-agent.git
cd native-agent
./script/install_app.sh
```

The installer builds, signs, installs to `~/Applications`, and launches the
app. See [Contributing](CONTRIBUTING.md) for the development workflow and
[Release setup](docs/release_setup.md) for distribution.

## Local data and privacy

The default work folder is
`~/Library/Application Support/NativeAgent/workspace` for an app-only install,
or the checkout's `workspace/` for a source-backed install. All surfaces use
the same workspace resolver.

Persona, chat, memory, credentials and work products are private local state.
Provider requests and configured services can send selected data off the Mac.
Trust does not grant Apple's privacy permissions. See [Privacy](PRIVACY.md),
[Security](SECURITY.md) and the [Threat model](docs/threat-model.md).

## Repository map

```text
Sources/NativeAgentApp/           macOS SwiftUI app and platform wiring
Modules/NativeAgentCore/          engine, turns, memory, actions, trust and work
Modules/NativeAgentShared/        Mac/iOS wire models and device transport
iOS/NativeAgentMobile/            iPhone and iPad companion
Extensions/NativeAgentChrome/     Chrome extension
Sources/NativeAgentChromeRelay*/  native-messaging transport
Resources/, distribution/         app resources and distribution configuration
docs/                             product, architecture, security and operations
script/                           build, install and release entry points
```

Start with [Project Status](PROJECT_STATUS.md), the
[documentation guide](docs/README.md) or the product intent in
[North Star](docs/NORTHSTAR.md).

## License

NativeAgent is available under the [MIT License](LICENSE).
