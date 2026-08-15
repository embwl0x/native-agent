# NativeAgent

<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128@2x.png" width="128" alt="NativeAgent app icon">
</p>

NativeAgent is a Swift-native living-agent runtime for macOS and iPhone. It is
not a chat window wrapped around an API: the app owns conversation, memory,
context circulation, tools, approvals, background work, an optional cognitive
substrate, and a bounded organism state in one local runtime.

The same agent can continue through Mac chat, detached conversations, iPhone,
Telegram, Slack, and authenticated local bridges. Provider, context, tool,
trust, transcript, and receipt rules converge on the same orchestration path.

> NativeAgent is an advanced single-operator project. The source, tests,
> personal install flow, public-export gate, Developer ID/notarization pipeline,
> and signed-update machinery are real. The public source repository and a
> notarized binary GitHub Release are live; connector depth varies, so see
> [Project Status](PROJECT_STATUS.md) for the honest capability ledger.
> Release history: [Changelog](docs/CHANGELOG.md).

## What exists today

| System | Current behavior |
|---|---|
| Native runtime | `NativeAgent.app` owns the complete Swift runtime in-process. There is no Python agent daemon, launchd-owned brain, or LAN fallback. |
| Fluid Context | Canonical persona, memory, skills, cognition, and project knowledge circulate through immutable SQLite generations and a bounded in-memory arena instead of being reread and stuffed into every prompt. Settings exposes Active, Observe Only, and Off without changing the selected conversation model. |
| Memory | MemoryV2 provides SQLite-backed durable memory, lexical and semantic recall, a knowledge graph, reviewed proposals, hygiene, consolidation, and a generated user-profile projection. |
| Cognitive substrate | Optional bounded continuity, affect, mood, thought seeds, standing views, self-exemplar voice, reflection receipts, and felt context. |
| Organism Kernel | Optional body state derived from real runtime events and health: chemistry, body schema, predictions, dream repair, review-gated reflexes, and pressure-aware background posture. |
| Desk | One durable work system for user-directed tasks and the agent's own pursuits, with large-project breakdowns, dependencies, bridge references, schedules, research, multi-step execution, checkpoints, approvals, receipts, and verified completion. |
| Tools and skills | Lazy, policy-aware tools cover files, shell, Mac apps, browser, memory, research, GitHub, workflows, notifications, images, MCP, and more. A compact skill manifest is always visible; one relevant procedure body is loaded only when needed, and the agent creates or updates procedures through the canonical skill writer rather than private files. Swarm workers default to read-only reasoning and may inherit the same gated tool path for real work without gaining new authority. Skills can guide behavior but never grant tools, permissions, approval bypasses, or safety authority. |
| Mac computer control | The agent perceives any app through the accessibility tree (`ax_tree`/`ax_find`), takes a fused numbered screen view (`mac_view`) and acts by reference — click, type, scroll, semantic AX actions — with every injected action bound to a one-time, non-forgeable approval capability. Displayed secrets (one-time codes, keys, card numbers, recovery phrases) are redacted by shape before any model sees the screen. `mac_wake`/`mac_nudge` dismiss a screensaver but fail closed on a locked screen. |
| Activity watcher | Optional, off by default: a local, metadata-only record of the frontmost app and redacted window title (no screenshots, no OCR, no model calls, event-driven ~0% CPU). Enabling is structural consent through Trust Center only; the store is excluded from every export, backup, and support bundle; `activity_query` answers "what was I working on" on allowlisted surfaces, and results never enter the agent's long-term memory. |
| Surfaces | Mac chat, detached chat windows, iPhone/iPad, Telegram, Slack, local Codex/Claude Code bridges, and background work share the same agent factory and policy boundaries. |
| Providers | ChatGPT OAuth, Codex CLI, OpenAI API, Anthropic OAuth/API, xAI OAuth, Moonshot API, and OpenRouter have distinct model/capability contracts. Current verified catalogs include GPT-5.6 variants, Claude 5/Fable/Opus, Grok 4.5, and Kimi K3. Moonshot keys stay Mac-local and refresh the account-visible Kimi model list. Swarms default to the provider/model selected for the Swarms surface; the agent may choose explicit worker models when useful. |
| Connectors | Telegram, Slack, GitHub, X, Gmail, Google Calendar, Notion, local workspaces, Mac apps, and the visible browser have explicit setup and proof boundaries. Gmail, Calendar, and Notion reads are bounded and lazy-loaded; public users provide their own OAuth app or integration token locally. |
| Trust | TrustCenter, SecurityCenter, Full Mac gates, connector proof, approval replay, exact receipts, signed iOS actions, and fail-closed persistence boundaries remain authoritative. |

Local bridge clients should read `~/.config/claude-bridge/bridge.json`. NativeAgent prefers port 8771, advances when it is occupied, and publishes the actual loopback URL and bearer token together rather than requiring clients to assume a fixed port.
The authenticated return listener is normal app infrastructure and starts on
every launch; it is not hidden behind Developer Mode. Loopback-only binding,
the private per-launch bearer, TrustCenter, approvals, and effect-time checks
remain the authority boundaries.

For serious repository work, the Codex and Claude Code bridges wake real,
context-bearing coding sessions—not raw one-shot model calls—then return the
builder's result to the originating NativeAgent session for canonical
verification. The [builder bridge guide](docs/USER_GUIDE.md#codex-and-claude-code-as-specialist-builders)
explains the division of labor, session continuity, permissions, and receipts.
NativeAgent ships the bridge workers themselves. Each user installs and signs
into Codex CLI and/or Claude Code on that Mac; Node.js is the small local
runtime those bundled workers use. NativeAgent discovers common user-local
install locations even when a Finder-launched app receives a minimal shell
`PATH`. The catalog reports execution prerequisites and the live return path
separately, so an installed CLI is never mistaken for a working round trip. It
never copies another computer's builder history or credentials.

With Full Mac YOLO active, the agent can explicitly place native tools, Codex,
or Claude Code in an existing project outside NativeAgent's default workspace.
This removes NativeAgent's workspace confinement; it does not bypass Apple's
separate privacy controls. Projects under Documents, Desktop, Downloads, or
other protected locations may first require approval in macOS **Privacy &
Security → Files & Folders** or **Full Disk Access**.

The detailed, evidence-backed inventory lives in
[docs/CAPABILITIES.md](docs/CAPABILITIES.md).
For a compact operational map—including every main page, trust modes, mobile
pairing, connectors, lazy skills/tools, and how to enable the Subconscious and
Organism—read the [User and Agent Guide](docs/USER_GUIDE.md).

## One runtime, one mind

```text
Mac / iPhone / Telegram / Slack / local bridge
  -> shared chat and provider orchestration
  -> Fluid Context packet + bounded continuity
  -> model + lazy tool loop
  -> TrustCenter / approvals / file and Mac gates
  -> transcript, receipts, memory, cognition, organism feedback
  -> Desk, notifications, and cross-surface delivery
```

The architectural rule is simple: durable identity stays in persona and
MemoryV2; Fluid Context is rebuildable circulation; cognition and organism
state are bounded advisory layers; all actions still cross trust and approval
boundaries. No subsystem becomes a second hidden agent.

Read [docs/NORTHSTAR.md](docs/NORTHSTAR.md) for the product philosophy and
[docs/ARCHITECTURE_BLUEPRINT.md](docs/ARCHITECTURE_BLUEPRINT.md) for the source
ownership map.

## One causal language for the outside world

NativeAgent gives the configured agent one stable way to understand actions and outcomes even
when the wire protocol changes:

```text
native tool / MCP / webhook / connector
  -> transport evidence + bounded action identity
  -> canonical domain owner
  -> shared phase and verification readout
  -> receipt + replay-safe resident consequence
```

This is a translation contract, not a universal integration owner. A received
MCP response or HTTP `200` proves that a protocol exchange occurred; it does
not by itself prove that a message was delivered, a file changed, or an
external action settled. Desk execution, Browser, Mac Control, messaging, GitHub, and
other domains retain authority over their own state and verification.
Completion callbacks are correlation evidence, not settlement: for example,
GitHub Command binds work to the observed actionable event and accepts only a
later authoritative GitHub read that clears that event.

The result is one causal vocabulary across Mac, iPhone, messaging surfaces,
tools, and future external adapters without creating another agent, event
store, scheduler, approval path, or shadow source of truth. For integrated
actions, the agent can interpret `proposed`, `running`, `waiting_external`,
`verifying`, `succeeded`, `failed`,
and the separate verification state consistently, while TrustCenter,
approvals, effect-time validation, receipts, and domain verification keep their
existing authority.

## Requirements

- Apple-silicon Mac
- macOS 14 or newer
- Xcode or the matching Swift 6 command-line toolchain
- Git
- An AI provider account; ChatGPT OAuth can use an existing subscription
- Optional: `gitleaks` for the repository privacy guard
- Optional: Xcode signing, iCloud, and APNS configuration for the iPhone app

## Install the app (recommended)

Download the latest notarized DMG from the
[releases page](https://github.com/embwl0x/native-agent/releases), open it,
and drag NativeAgent to Applications. The app is Developer ID signed and
notarized; installed copies update in place via **Check for Updates…**
(Sparkle, EdDSA-signed feed). See the [Changelog](docs/CHANGELOG.md) for
what each release contains.

## Install from source

```bash
git clone https://github.com/embwl0x/native-agent.git
cd native-agent

# Recommended for contributors: installs the staged-secret/privacy hook.
bash script/hooks/install.sh

# Builds, signs with the available local configuration, installs to
# ~/Applications/NativeAgent.app, and launches the Swift runtime.
./script/install_app.sh
```

The installer creates blank-slate local persona/data/workspace roots when
needed. An app-only/public install keeps all agent work under
`~/Library/Application Support/NativeAgent/workspace`; a verified source-backed
development install uses the checkout's `workspace/`. Runtime state,
credentials, generated images, private persona material, and work products are
ignored by Git and must never be committed.

After launch:

1. Complete onboarding.
2. Open the Providers tab in the sidebar and connect ChatGPT, Anthropic, xAI, OpenAI, Moonshot, or
   another supported route.
3. Select a provider, model, Think level, and Fast mode per surface.
4. Start the conversation yourself. Development and personal installs never
   synthesize startup greetings. A blank-slate public-release install may send
   one post-onboarding welcome after a provider is connected.
5. Optional: **Settings → Advanced → Subconscious** is the single user-facing
   master for the cognitive substrate and organism. Its Fluid Context picker controls whether resident
   selection is active, observe-only, or off. The Cognition Observatory keeps
   granular research controls and reports the effective runtime state.

The personal installer is not the public distribution pipeline. Signed and
notarized DMG work is documented in
[docs/release_setup.md](docs/release_setup.md).

## Public releases and updates

NativeAgent's permanent Apple distribution family is
`io.github.embwl0x.nativeagent.mac` for Mac,
`io.github.embwl0x.nativeagent.ios` for iPhone/iPad, and
`iCloud.io.github.embwl0x.nativeagent` for their shared CloudKit continuity.
The visible product and configured agent names remain independent of these
internal identifiers.

Public installs use Sparkle 2 with an EdDSA-signed appcast. The application menu
and Settings → About expose the same update controller. A published release
checks automatically and offers **Check for Updates…**; a local or feedless
build says **About Software Updates…** and explains why it cannot update instead
of contacting a placeholder URL.

Updating GitHub source does not silently replace installed applications. After
reviewing and publishing a new source commit, the maintainer bumps `VERSION` and
runs the production release command from the scrubbed public export:

```bash
NATIVEAGENT_GITHUB_REPOSITORY=embwl0x/native-agent \
NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE=NativeAgent-notarytool \
./script/release_github.sh
```

That command builds and Developer-ID signs the app, notarizes and staples it,
signs the update with the offline Sparkle key, uploads the exact DMG and appcast
to a draft GitHub Release, reads both assets back, publishes the release, and
verifies the unauthenticated URLs installed clients will use. It refuses a
private repository, unpushed source, dirty tree, missing notarization identity,
or mismatched update bytes. `./script/release_github.sh --preflight` reports
what remains before doing any release work.

Mac Integration keeps NativeAgent's read/write gates separate from macOS
privacy consent. Calendar, Reminders, and Contacts are granted explicitly in
the app; Calendar-capable hardened builds carry Apple's required Calendar
entitlement, and the release verifier checks the signed artifact so a fresh
install can appear in Privacy & Security and request the correct access level.

## iPhone and iPad

The companion is a real remote cockpit rather than a web wrapper. It supports
signed chat and actions, streamed progress, session continuity, Desk,
approvals, activity, memory, skills, provider controls, organism status, and
APNS notifications.

Device communication is Apple-native and has no LAN HTTP fallback:

- personal builds can use iCloud KVS plus iCloud Drive;
- entitled builds can select the CloudKit transport;
- public lock-screen alerts use a dedicated CloudKit notification record and
  the user's own iCloud account—no NativeAgent-hosted APNS service or bundled
  provider credential is required;
- HMAC-signed envelopes, durable transaction receipts, and entitlement-aware
  APNS keep remote actions explicit and auditable.

See [docs/mobile_companion.md](docs/mobile_companion.md) for setup and the exact
transport model.

## Build and test

```bash
# Compile the Mac app and all local packages.
swift build --jobs 4

# Focused or package-level tests.
swift test --filter '<suite-or-test>'
swift test --package-path Modules/NativeAgentCore --no-parallel

# Canonical whole-repository gate.
./script/test.sh

# Isolated and installed-runtime sweeps.
./script/smoke_all.sh
./script/smoke_all.sh --live

# Signed personal install and live health proof.
./script/install_app.sh
./script/organism_doctor.sh --strict
```

The test suite covers provider routing, chat/session transactions, memory,
context generations, tools, approvals, Desk execution, cognitive and
organism bounds, iCloud/CloudKit transport, release privacy, and architectural
drift.

## Local data and privacy

| Path | Purpose |
|---|---|
| `persona/` | Private identity, voice, growth, and generated user profile |
| `data/` | Chat, MemoryV2, context generations, cognition, Desk/execution state, receipts, provider state, and local runtime ledgers |
| `workspace/` (source install) or `~/Library/Application Support/NativeAgent/workspace` (app-only install) | Canonical safe default for drafts, projects, exports, and agent work product shared by every chat surface and the Desk. Full Mac YOLO may explicitly target another existing project directory for native shell/build or Codex/Claude Code work; ordinary modes remain workspace-scoped. |
| `.runtime/` | Build, evaluation, and transient runtime artifacts |

NativeAgent is local-first, but local does not mean unguarded. OAuth tokens,
pairing secrets, connector credentials, and Mac permissions remain sensitive.
The GitHub connector stores its PAT in the macOS Keychain; other sensitive
file-backed stores use owner-only permissions. External content is untrusted
input, and external sends or protected mutations remain gated.

Read [SECURITY.md](SECURITY.md) and
[docs/threat-model.md](docs/threat-model.md) before granting broad Mac access.
The public-facing [Privacy Policy](PRIVACY.md) and [Support Guide](SUPPORT.md)
explain external-provider processing, iCloud continuity, permissions, deletion,
and support boundaries.

## Repository map

```text
Sources/NativeAgentApp/           macOS SwiftUI app and runtime assembly
Modules/NativeAgentCore/          agent, memory, tools, trust, cognition, Desk execution
Modules/NativeAgentShared/        Mac/iOS wire models and device transport
iOS/NativeAgentMobile/            iPhone and iPad companion
Resources/                        app resources
docs/                             product, architecture, security, and operations
script/                           build, test, install, evaluation, and release gates
```

## Documentation

- [User and Agent Guide](docs/USER_GUIDE.md) — compact setup and complete operating map
- [Capabilities](docs/CAPABILITIES.md) — readable current system tour
- [North Star](docs/NORTHSTAR.md) — one mind, no theater, fluid digital processes
- [Project Status](PROJECT_STATUS.md) — honest shipped/partial/experimental ledger
- [Architecture Blueprint](docs/ARCHITECTURE_BLUEPRINT.md) — source and ownership map
- [Project Direction](docs/PROJECT_DIRECTION.md) — durable product and safety rules
- [Fluid Context](docs/build_plans/fluid-context-as-built-map.md) — current circulation architecture
- [Organism Kernel](docs/ORGANISM.md) — bounded app-body behavior and safeguards
- [Mobile Companion](docs/mobile_companion.md) — iCloud/CloudKit/APNS architecture
- [Data Bounds](docs/data-bounds.md) — caps and retention behavior
- [Threat Model](docs/threat-model.md) — defended and non-defended boundaries
- [Privacy Policy](PRIVACY.md) — local data, external services, permissions, and deletion
- [Support](SUPPORT.md) — installation, pairing, updates, troubleshooting, and safe reporting
- [Contributing](CONTRIBUTING.md) — development and privacy workflow
- [Release Setup](docs/release_setup.md) — signing, notarization, GitHub Releases, and in-app updates
- [App Store Submission Kit](docs/app_store_submission.md) — metadata drafts, review notes, screenshots, and release gates

## License

NativeAgent is available under the [MIT License](LICENSE).
