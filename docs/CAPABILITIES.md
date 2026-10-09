# NativeAgent capabilities

A map of the current source. This is not a release receipt or an installed-app
check. For operation, read [User and Agent Guide](USER_GUIDE.md); for exact
file ownership, use [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md).

## The system in one sentence

One brain, many doors: NativeAgent is a Swift runtime hosted by the Mac app,
with shared conversation, memory, context, action and Trust across its surfaces.

## Native runtime

The core's `EngineRuntime` composes the system through `NativeAgentEngine`.
It owns the facades for turns, transcripts, memory, context, providers, Trust,
Desk, cognition, agents and device sync. `ChatTurnRuntime` owns turn execution;
`MacChatTurnRuntime` owns Mac-session admission, queues, cancellation and
lifecycle state. The SwiftUI app supplies platform wiring and presentation.

Source: [NativeAgentEngine.swift](../Modules/NativeAgentCore/Sources/EngineRuntime/NativeAgentEngine.swift),
[MacChatTurnRuntime.swift](../Modules/NativeAgentCore/Sources/ChatTurnRuntime/MacChatTurnRuntime.swift).

## Conversation surfaces

- **Mac:** streaming chat, sessions and queued follow-ups; Simple, Advanced
  and Agent views. Agent view is read-only.
- **iPhone/iPad:** a companion using signed iCloud transport to the Mac.
  The Mac must remain awake with NativeAgent open to answer.
- **Telegram and Slack:** messaging surfaces with their own conversation
  origins and the shared engine's provider, context and action policy.
- **Local bridges and agent contacts:** authenticated conversations and coding
  handoffs. Local clients discover the loopback address and bearer token from
  `~/.config/claude-bridge/bridge.json`.

Built-in Codex/Claude Code bridge lanes deny external MCP tools. Built-in
loopback SearXNG is exempt; connected-peer turns follow the
[Trust rules](#trust-security-and-receipts), including the
exemption for authenticated agents enabled in Trust.

See [Mobile companion](mobile_companion.md) and
[Agent conversations](agent-communication.md).

## Tools and capability growth

`app` is the sole always-on model-facing tool. `app {}` returns home:
where the agent left off, open work, waiting items and arrivals, then the page
index. `page` reads a page; `item` follows a home reference; `find`
discovers actions; `action` with `args` executes one. Actions come from
`AppActionRegistry.swift`, including arguments and flags for ownership,
irreversibility, screen movement and script eligibility.

Pages and results carry detail without expanding the provider's tool list.
Retired names are refused with translated `app` calls. There is no tool
loading/unloading workflow or separate workspace tool; workspace items are
part of app home.

An action can be previewed without execution. Its `expected_version` can
require the page version returned by a read. A home item can itself act and
does not support those action-only options.

### Scripts

`app {script}` runs JavaScriptCore with `app.read`, `app.find`,
`app.log` and scriptable registry actions. Each call re-enters the action
checks and adds a ledger row. A blocked action or approval wait stops the
script without undoing earlier calls. The script has no direct network or
filesystem API; it cannot call every action merely because the action exists.

### Authored tools, skills and MCP

- `tool.propose` files Swift code and required input/expected-output cases as
  a proposal, with optional input schema and declared permissions.
- `tool.approve` activates the proposal under the applicable authority.
  Active authored code appears as `authored.<id>` on Diagnostics.
- Skills provide procedural guidance and optional admitted scripts, discovered
  and read through `app`. `skill.save`, `skill.enable`, `skill.run`,
  `skill.resume` and `skill.rollback` manage those procedures. They grant no
  new authority; see the [manifest spec](skill_manifest_spec.md).
- Mounted MCP tools appear as `mcp.<server>.<tool>` from the server's live
  list, without adding model-facing tool schemas. Remote tools are not
  scriptable.

Sources: [AppActionRegistry.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppActionRegistry.swift),
[app door](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+AppDoor.swift),
[AppScriptRunner.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppScriptRunner.swift).
The interface contract is [TOOL_LOADING.md](TOOL_LOADING.md).

## Mac, files and web

Mac Control public dispatch automatically mints a body-bound, expiring,
single-use injection capability when the caller supplies none; this does not
require per-call human approval, including for bridge callers. Explicit approved
replays supply a capability. Both paths retain policy, Full Mac, category, TCC
and driver checks. A capability is not proof that human approval occurred.

The app's pages expose files, shell, Mac apps, browser, screen control,
connectors and agent communication under the saved policy.

- **Files and shell:** a common workspace resolver for all surfaces.
  App-only installs default to
  `~/Library/Application Support/NativeAgent/workspace`; source-backed
  installs use the checkout's `workspace/`.
- **Mac control:** `mac.look`, `mac.act`, `mac.go` and `mac.wait`
  expose perception and action. Accessibility and Screen Recording grants
  remain macOS decisions.
- **Mac services:** Mail, Calendar, Reminders, Notes, Contacts, Messages and
  Music have app pages and actions. Service-specific permissions apply.
- **Browser:** the built-in browser and optional Chrome extension have their
  own app actions. Chrome requires the extension's connection and authority.
- **Web search:** `web.search` tries Codex for general queries and SearXNG
  for code queries. Unfiltered searches try the other route if the first fails
  or returns no results; the result reports the route, elapsed time and fallback
  reason. Non-general categories and time ranges use only SearXNG.
- **Activity:** capture has a separate consent control. Activity sharing is
  distinct from recording.

Sources: [page map](../Sources/NativeAgentApp/QuietSelfAdmin.swift),
[workspace resolver](../Modules/NativeAgentCore/Sources/PersistenceCore/NativeAgentWorkspaceRoot.swift),
[search routing](../Modules/NativeAgentCore/Sources/Research/Research+CodexSearch.swift).
Chrome setup is in the [extension guide](../Extensions/NativeAgentChrome/README.md).

## Memory, knowledge, and learning

MemoryV2 owns durable memories in SQLite, with lexical and semantic recall and
proposal review. The about-you persona document is generated from memory.
Knowledge-graph indexing derives from memory rather than becoming a second
fact store.

Skills hold reusable procedures. Dreams and REM consolidate experience through
their own memory and persona boundaries. These are separate from the turn's
temporary context.

See [Memory system map](MEMORY_SYSTEM_MAP.md) and
[What a good memory is](memory-quality.md).

## Fluid Context

Fluid Context prepares bounded material from persona, memory, skills and other
sources into rebuildable generations. A turn pins a generation; deeper
`context.expand` reads are limited to the pointers offered for that turn.
The source stores remain authoritative.

Settings exposes Active and Off through **Memory in every reply**.
See [Internal Workings](INTERNAL_WORKINGS.md) for context preparation.

## Cognitive substrate and Organism Kernel

Cognition and organism state support continuity, appraisal, reflection and
posture. They are observable through Diagnostics and controlled through the
inner-life settings. Their projections can inform a turn; they do not grant
permissions or replace persona and memory authority.

See [Cognition wiring](COGNITION_WIRING.md) and [Organism](ORGANISM.md).

## Desk and directed work

Desk holds durable work identity, hierarchy, dependencies, schedules, progress
and outcomes. Its execution path retains checkpoints, approvals and verification.
A held row reflects its current blocker or defer, rather than a new stored
task status.

Standing helpers run on their own persisted conversations and saved model
choices, with the live Trust policy. Scheduled and event-triggered work uses
the unattended-work gate. Explicit **Run once** requests and **Continue in
Chat** are available on the helper's page.

The core's `BackgroundLoopsManager` owns background lifecycle and execution.
See [Automated systems](AUTOMATED_SYSTEMS.md).

## Provider and model control

The provider page and routing code share three groups: **Chat**, **Work**, and
**Memory and mind**. Work and Memory and mind inherit Chat unless configured.
A group's choice includes the provider and model; the UI reports unusable
saved choices rather than presenting them as available. Helpers retain their
own saved choices.

The routing group table is in `ProviderRouting`; its UI projection is
[ProviderSettingsView.swift](../Sources/NativeAgentApp/ProviderSettingsView.swift).

## Trust, security, and receipts

TrustCenter owns policy; SecurityCenter evaluates the requested action and its
origin. The four presets are Safe, Work mode, Builder and Full Mac.

Full Mac grants autonomy for admitted turns without routine per-action
approval and has no expiry timer. Explicit user blocks, origin authentication,
macOS grants and hard domain refusals remain authoritative. **macOS privacy
permission resets always ask the owner first.**

Peer-steered turns keep additional owner decisions even under Full Mac:
deletes and irreversible acts, sends or posts in the owner's name, persona
writes and approvals. Routine peer conversation is exempt from that extra
approval requirement.
Authenticated turns from agents enabled in Trust → Connected agents carry
User's authority and skip extra peer approvals; ordinary Trust and domain checks
still apply.

A returned protocol response, approval or builder report is evidence, not
automatic proof that the requested effect completed. Inspect the receipt and
the owner of the external effect.

Sources: [Full Mac policy](../Modules/NativeAgentCore/Sources/TrustCenter/SecurityCenter+FullMacPolicy.swift),
[SecurityCenter.swift](../Modules/NativeAgentCore/Sources/TrustCenter/SecurityCenter.swift),
[PeerTurnEffectPolicy.swift](../Modules/NativeAgentCore/Sources/TrustCenter/PeerTurnEffectPolicy.swift).

## Honest limits

Available actions still depend on permissions, platform support, connections
and credentials. Provider requests and configured services may send selected
data off the Mac. A source checkout does not establish App Store review status,
release publication or installed behavior.

Read [Project Status](../PROJECT_STATUS.md) for the current source summary,
[Privacy](../PRIVACY.md) for data handling and
[Threat model](threat-model.md) for security boundaries.
