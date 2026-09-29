# NativeAgent

<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128@2x.png" width="128" alt="NativeAgent app icon">
</p>

NativeAgent is a personal agent for Mac: one persistent agent with
conversation, memory, and tools for getting things done. An iPhone companion,
Telegram, Slack, a Chrome extension and local coding-agent bridges all reach the
same agent.

## First run

You need an Apple-silicon Mac running macOS 26 or newer and one AI provider
account.

1. Download the latest DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases), open it,
   drag NativeAgent to Applications, and open it.
2. Enter your name and the agent's name. **What the agent can help with ·
   Optional** expands an overview.
3. Connect one AI account, or skip and connect later.
4. The app opens in **Simple** view. The agent asks what it should be for you
   and how it should sound, then offers to set things up by talking: anything it
   needs (a provider, a connector, Chrome, iPhone, a macOS permission) arrives as
   a card in the chat and settles once the grant is really in place.

## Three views

The switch at the window's top right picks one:

- **Simple** — the agent, the other agents it talks to, and its helpers on one
  panel beside the chat. There are no settings pages here; ask the agent, or
  use the gear at the foot of the panel for the colour of the light, warmth in
  the glass (in dark mode), and **More settings**, which opens Settings in
  Advanced.
- **Advanced** — the full app. A rail on the left holds Chat, Today, Memories,
  Desk, Notifications and Helpers, then Personality, Providers, Trust,
  Connectors, Capabilities and Diagnostics, with Settings at the foot. Related
  controls are tabs inside those pages (for example **Trust → Mac integration**
  and **Connectors → iPhone**). **Command-K** reaches any page.
- **Agent** — a read-only window onto the agent's own desktop: what it sees
  when it works.

A fresh install starts in Simple; an install that already has chats starts in
Advanced. The [User and Agent Guide](docs/USER_GUIDE.md) walks through every
page.

In the composer, the words for model, thinking and Trust each open their own
card. The context ring shows how much of the context window is in use, with
token counts on hover.

## What exists today

| System | Current behavior |
|---|---|
| Native runtime | `NativeAgent.app` owns the complete Swift runtime in-process. There is no agent daemon, launchd-owned brain, or LAN fallback. |
| Memory | MemoryV2: SQLite-backed durable memory, lexical and semantic recall, a knowledge graph, reviewed proposals, hygiene and consolidation. The embedding model ships inside the app. |
| Fluid Context | Persona, skill, memory and Desk sources compile into rebuildable context generations; **Settings → Memory in every reply** chooses Active, Observe Only or Off. |
| Desk | One durable work system for user tasks and the agent's own pursuits: breakdowns, dependencies, schedules, checkpoints, approvals, receipts and verified completion. |
| Tools and skills | A short always-on tool set rides every request; everything else loads lazily and leaves when unused ([Tool loading](docs/TOOL_LOADING.md)). Skills guide behavior but never grant tools or permissions. |
| Mac computer control | `screen`, `act`, `go` and `wait` operate the Mac through accessibility and pixel evidence, under the selected Trust mode, with user takeover and truthful receipts. |
| Chrome control | An optional extension, bundled with the app, operates leased Chrome tabs through structured page snapshots. **Trust → Set up Chrome** installs it. |
| Helpers | Standing helpers (bots) with their own brief, model and conversation, run on a schedule, on a GitHub or Slack event, or on demand. |
| Agent conversations | One interface finds, messages and reads coding agents, helpers and connected peers; A2A, MCP and nativeagent-link peers get persistent conversations. See [Agent conversations](docs/agent-communication.md). |
| Providers | ChatGPT/Codex, OpenAI API, Anthropic, xAI, Moonshot and OpenRouter. Each group (Chat, Work, Memory and mind) runs on one choice; nothing silently falls back to another model. |
| Connectors | Telegram, Slack, GitHub, X, Gmail, Google Calendar, Notion, shared folders and Mac apps, each with explicit setup and proof. Public users bring their own OAuth app or token. |
| Trust | Four presets (Safe, Work mode, Builder, Full Mac), per-feature permissions, approvals and receipts. macOS privacy permissions stay separate. |
| Inner life | Optional, bounded cognition and Organism Kernel layers that shape attention and tone; they never grant permissions. **Settings → An inner life** switches them. |

For how the pieces fit, read [NativeAgent Internal Workings](docs/INTERNAL_WORKINGS.md)
and [Anatomy of a NativeAgent Turn](docs/ANATOMY_OF_A_TURN.md). The product
philosophy is [docs/NORTHSTAR.md](docs/NORTHSTAR.md); where things stand is in
[Project Status](PROJECT_STATUS.md).

## Codex and Claude Code as specialist builders

For serious repository work, the agent can hand a bounded work order to a real,
context-bearing Codex or Claude Code session and get the result back in the
conversation that asked. NativeAgent ships the bridge workers; each user
installs and signs into Codex CLI and/or Claude Code on that Mac, plus Node.js.
Local bridge clients read `~/.config/claude-bridge/bridge.json` for the actual
loopback URL and bearer token rather than assuming a port. The
[builder guide](docs/USER_GUIDE.md#codex-and-claude-code-as-specialist-builders)
covers sessions, permissions and receipts.

With Full Mac access the agent may target an existing project outside its
default workspace. That does not bypass Apple's privacy controls: projects under
Documents, Desktop or Downloads may still need **Privacy & Security → Files &
Folders** or **Full Disk Access**.

## iPhone and iPad

The companion is a remote cockpit for the same agent: signed chat and actions,
streamed progress, Desk, approvals, activity, memory, provider controls and
lock-screen notifications. On the Mac open **Connectors → iPhone** (in Simple
view, ask the agent); on the phone choose **Connect via iCloud**. Transport is
Apple-native (iCloud/CloudKit, signed envelopes) with no LAN HTTP fallback. See
[docs/mobile_companion.md](docs/mobile_companion.md).

## Install

Download the notarized DMG from the
[releases page](https://github.com/embwl0x/native-agent/releases). Installed
copies update in place through **Check for Updates…** (Sparkle, EdDSA-signed
feed). The [Changelog](CHANGELOG.md) lists what each release contains.

### From source

Requirements: an Apple-silicon Mac on macOS 26+, Git, and Xcode or the matching
Swift 6 toolchain. Optional: `gitleaks` for the privacy hook; Xcode signing,
iCloud and APNS configuration for the iPhone app.

```bash
git clone https://github.com/embwl0x/native-agent.git
cd native-agent
bash script/hooks/install.sh      # staged-secret/privacy hook
swift build --jobs 4 --force-resolved-versions --skip-update
./script/install_app.sh           # build, sign, install to ~/Applications, launch
```

The installer creates blank persona/data/workspace roots when needed. An
app-only install keeps agent work under
`~/Library/Application Support/NativeAgent/workspace`; a source install uses the
checkout's `workspace/`. See [Contributing](CONTRIBUTING.md) for the development
workflow.

### Releases

Public releases are built from the scrubbed public export by
`./script/release_github.sh`, which signs, notarizes, staples, signs the update,
uploads the DMG, appcast, test receipt and attestation to a draft GitHub
Release, reads them back and publishes. `--preflight` reports what is missing.
Signing and notarization setup: [docs/release_setup.md](docs/release_setup.md).

The Apple identifiers are `io.github.embwl0x.nativeagent.mac`,
`io.github.embwl0x.nativeagent.ios` and `iCloud.io.github.embwl0x.nativeagent`;
the visible product and agent names are independent of them.

## Local data and privacy

| Path | Purpose |
|---|---|
| `persona/` | Private identity, voice, growth, and generated user profile |
| `data/` | Chat, MemoryV2, context generations, cognition, Desk state, receipts, provider state |
| `workspace/` (source install) or `~/Library/Application Support/NativeAgent/workspace` (app-only) | Default place for agent work product, shared by every surface |
| `.runtime/` | Build and transient runtime artifacts |

None of these are committed. NativeAgent is local-first, but OAuth tokens,
pairing secrets, connector credentials and Mac permissions remain sensitive, and
provider requests send selected data to those providers. Read
[SECURITY.md](SECURITY.md), [docs/threat-model.md](docs/threat-model.md), the
[Privacy Policy](PRIVACY.md) and the [Support Guide](SUPPORT.md) before granting
broad Mac access.

## Repository map

```text
Sources/NativeAgentApp/           macOS SwiftUI app and runtime assembly
Modules/NativeAgentCore/          agent, memory, tools, trust, cognition, Desk execution
Modules/NativeAgentShared/        Mac/iOS wire models and device transport
iOS/NativeAgentMobile/            iPhone and iPad companion
Extensions/NativeAgentChrome/     optional tab-scoped Chrome extension
Sources/NativeAgentChromeRelay*/  Swift native-messaging transport
Resources/, distribution/         app resources, signing and distribution config
docs/                             product, architecture, security, operations
script/                           build, install, release and check entry points
```

The [documentation guide](docs/README.md) lists every current document.

## License

NativeAgent is available under the [MIT License](LICENSE).
