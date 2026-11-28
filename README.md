# NativeAgent

<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128@2x.png" width="128" alt="NativeAgent app icon">
</p>

NativeAgent is a personal agent for Mac: conversation, memory and action in
one continuous mind. The Mac app owns the Swift runtime in-process; iPhone,
Telegram, Slack and local agent bridges reach that same runtime.

## Get started

Follow [Getting started](docs/GETTING_STARTED.md) to install NativeAgent,
connect a model, and start your first conversation.

## Three views

- **Simple** — chat beside the agent's card, four places (Together, Table, the
  agent's place under its name, and Control) and folded Agents and Helpers
  lists. Choosing a place opens its tabs and pages in place; Settings lives on
  Control's Settings tab (and **Settings…**, ⌘,).
- **Advanced** — all five grouped places on the rail: Chat; Desk (Today, Desk,
  Notifications, Helpers); the agent's place (Memories, Personality,
  Capabilities and any page of the agent's own); Control (Providers, Trust,
  Connectors, Settings); and Diagnostics.
- **Agent** — the agent's read-only Home and rooms. A conversation opened there shows in Simple.

A view preference that was never set starts in Simple, whatever chats exist. The [User and Agent Guide](docs/USER_GUIDE.md) covers setup and the
main pages.

## What exists today

| Area | Current behavior |
|---|---|
| Agent interface | The agent's one door, `app`, always on. `app {}` is home, “where I left off”; pages, items, search, actions and JavaScript reach the app's capabilities. |
| Memory and context | MemoryV2 stores durable memory with lexical and semantic recall. Fluid Context prepares bounded context from the underlying stores. |
| Work | Desk holds projects, dependencies, schedules, progress and outcomes; standing helpers have their own briefs, models and conversations. |
| Mac and web | App actions reach files, shell, Mac apps, screen control, the built-in browser and the optional Chrome extension. `web.search` searches through SearXNG: set Search service (`research.search_url`) to its address, or to `auto` to find one running on this Mac. With none set it fails and names that setting; it never falls back to a browser. |
| Connections | Connectors and agent contacts live under **Connectors**. An MCP server they wants is an ability they grows. |
| Growth | What they works out they keeps as their own abilities: `ability.save`, kept by their under Full Mac or by the owner's card, runs as `authored.<id>`; `ability.read`, `ability.enable`, `ability.resume` and `ability.restore` are its lifecycle. Parts grant no new authority; see the [manifest spec](docs/skill_manifest_spec.md). Skills are built-in guidance to read. |
| Trust | Safe, Work mode, Builder and Full Mac govern access. Full Mac grants autonomy; macOS privacy permission resets still ask the owner. Peer-steered turns retain extra approval boundaries, except for authenticated agents enabled in Trust → Connected agents; ordinary Trust and domain checks still apply. |
| Inner life | Settings controls reflection, dreams and memory in replies; Diagnostics exposes cognition and organism state. |

The action registry is
[AppActionRegistry.swift](Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppActionRegistry.swift).
The [one-door contract](docs/ONE_DOOR.md) explains discovery and execution;
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

Building from source requires an Apple silicon Mac, macOS 26+, Xcode and
XcodeGen. The manifests require Swift tools 6.2. The packages and Mac app
enable strict memory safety, caller-isolated nonisolated async functions,
isolated conformance inference and member import visibility.

```bash
brew install xcodegen
git clone https://github.com/embwl0x/native-agent.git
cd native-agent
./script/install_app.sh
```

The installer builds, signs, installs to `~/Applications`, and launches the
app. Signing defaults to `development`, which needs an Apple Development
identity, a matching provisioning profile and local entitlements; without them
it stops. A clone with no Apple developer account runs
`NATIVEAGENT_SIGNING_MODE=adhoc ./script/install_app.sh`: ad-hoc signed, with
iCloud off, so there is no phone link. See [Contributing](CONTRIBUTING.md) for the development workflow and
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
