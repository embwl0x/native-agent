# NativeAgent capabilities

*Verified against the repository and release baseline on 2026-07-31.*

This document is the readable product map. It describes what NativeAgent
currently does without requiring a tour through every Swift target. Exact
source owners live in [ARCHITECTURE_BLUEPRINT.md](ARCHITECTURE_BLUEPRINT.md),
and incomplete work stays explicit in [../PROJECT_STATUS.md](../PROJECT_STATUS.md).

## The system in one sentence

NativeAgent is a local Swift runtime in which conversation, memory, context,
tools, background work, and an optional bounded inner state belong to one
continuous agent across Mac, phone, messaging surfaces, and authenticated local
bridges.

## Native runtime

`NativeAgent.app` owns the runtime in-process:

- shared chat orchestration and provider routing;
- session history and transactional Mac chat selection;
- MemoryV2, knowledge graph, and user-profile projection;
- Fluid Context generations and the resident context arena;
- TrustCenter, SecurityCenter, approvals, and Mac/file gates;
- lazy tools, MCP, connectors, browser, and workflows;
- Workshop planning and execution;
- background loops, notifications, dreams, REM, and maintenance;
- iCloud/CloudKit/APNS device coordination;
- optional CognitiveSubstrate and Organism Kernel state.

There is no live Python agent backend, launchd-owned brain, companion daemon,
or LAN HTTP fallback. Helper subprocesses may be launched by explicit tools,
but they do not own the agent.

## Conversation surfaces

### Mac

- Native SwiftUI chat with streaming responses and tool progress.
- Multiple named sessions, pinning, archive, transcript export, attachments,
  screen capture, voice input, and optional read-aloud.
- Enter remains available while Agent is working. New messages appear in a
  visible per-session send-next queue, run automatically in order, and can be
  removed or promoted with Steer while Stop remains independently available.
- Detached chat windows can continue independent sessions without replacing
  the main conversation.
- Provider, model, Think, Fast, context occupancy, transcript estimate, and
  compaction threshold are visible controls/readouts.
- A Today panel projects bounded organism posture, Workshop, approvals, dream,
  and needs-user status.
- Development and personal installs never create hidden greeting turns during
  startup, onboarding, provider changes, or session selection. A blank-slate
  public-release bundle may send one post-onboarding welcome after provider
  connection; both marker creation and delivery are release-gated.

### iPhone and iPad

- Signed iCloud/CloudKit chat with incremental text and progress events.
- Session lists, pinned chats, attachments, cancellation, and model controls.
- The same visible send-next queue is available while a reply is active;
  steering confirms Mac cancellation before the promoted message is sent.
- Activity, approvals, Workshop, memory, skills, connectors, provider status,
  runtime health, and organism living status through targeted snapshots.
- Signed remote actions with a durable transaction ledger and response
  read-back before success is shown.
- Real APNS notifications with environment derived from the signed iOS build.

### Telegram and Slack

- Shared orchestration, persona, Fluid Context, provider routing, tool policy,
  and transcript behavior.
- Surface-scoped sessions, progress updates, retries, and current provider
  preferences rather than startup-captured configuration.
- Telegram exposes model, Think, Fast, session, approval, voice, image, and
  attachment paths. Slack preserves the exact channel/thread origin.

### Local agent bridges

- Authenticated, loopback-only Codex and Claude Code bridges.
- Full shared chat turns or narrowly gated tool calls.
- Async handoffs preserve the originating Mac, Telegram, Slack, or iOS route
  and return Agent's completion assessment to that route.
- External MCP tools are denied on human-out-of-loop bridge calls; normal trust
  and approval rules remain in force.

## Fluid Context

Fluid Context is a rebuildable circulation system, not a second memory store.

- Canonical Markdown, bounded skill bodies, MemoryV2 projections, cognition,
  organism signals, and project knowledge compile into immutable SQLite
  generations.
- A bounded 32–256 MiB `ContextArena` keeps the active lexical index and exact
  required-document mirrors resident.
- Modes are `off`, `shadow`, and `active`. Public pre-onboarding state is forced
  off; local active mode retains a fail-visible legacy fallback.
- Eligibility and mandatory identity coverage run before relevance scoring.
- One generation lease is pinned through the complete provider/tool loop.
- `context_expand` can retrieve only pointers offered in that same turn and
  generation; it is not an unrestricted search bypass.
- Event-driven prewarm lanes are advisory, pressure-aware, and unable to change
  authority or permissions.
- Bridge and Observatory health expose generation parity, degraded sources,
  resident bytes, leases, pressure, prewarm, reconciliation, and errors.

Fluid Context keeps the ordinary context path in tens of milliseconds without
removing tools or flattening identity. Large historical transcripts use bounded
head/tail/relevance projections while exact older wording remains available
through lazy session search.

## Memory, knowledge, and learning

MemoryV2 is the durable source of truth for user facts and agent memory.

- GRDB/SQLite persistence with lexical BM25 and semantic recall.
- User-authored durable facts, narrow structured auto-save, and review-only
  proposals for softer preferences or goals.
- Quality validation rejects fragments, duplicate noise, weak evidence, and
  time metadata that does not belong in user-facing prose.
- A generated `persona/USER.md` projection gives the persona compiler a compact
  current profile without turning Markdown into a second database.
- Knowledge-graph indexing and reconciliation stay aligned with approved
  memories.
- Hygiene, consolidation, confidence lifecycle, and approval-gated swaps keep
  the store bounded and auditable.
- Skills become procedural recall pointers; skill bodies stay lazy until a
  routed need calls for them.
- Dream and REM are slow-path consolidation systems, not prompt decorations.

## Cognitive substrate and Organism Kernel

Both systems are optional and bounded. They cooperate as one agent; neither can
become an alternate persona or bypass action policy.

### CognitiveSubstrate

- continuity nodes and activation;
- emotional tags, affect decay, and derived mood;
- a bounded workspace and thought seeds;
- standing views and reflection receipts;
- self-exemplar voice and a fitted felt capsule;
- SQLite-backed restore/persist with typed health.

### Organism Kernel

- somatic signals derived from real chat, tools, providers, approvals, phone,
  dreams, lifecycle, and runtime health;
- bounded chemistry and body schema;
- a plastic associative field and prediction ledger;
- bounded dream-repair state;
- repeated-pattern reflex candidates that require explicit review;
- a behavior posture that can make background work lighter, careful, or
  deferred under resource pressure;
- one sanitized body line and felt-color projection into conversation when
  useful.

The organism cannot write persona files, commit MemoryV2 facts, dispatch tools,
send notifications, or approve its own reflexes. It is default-off and forced
neutral before public onboarding.

## Workshop and directed work

Workshop is the single work surface for both user-directed tasks and the
agent's own bounded pursuits.

- Desk owns canonical item identity, hierarchy, origin, status, and terminal
  invariants.
- User-directed work can use a multi-step planner/executor with checkpoints,
  approval pauses, retries, and an outcome scoreboard.
- Agent pursuits use a restricted Workshop session and membrane rather than
  unrestricted normal chat tools.
- Durable leases and reservations prevent double execution.
- Terminal execution state synchronizes back to the same Desk item.
- Mac and iPhone use the same Workshop identity and receipts.
- Legacy Missions UI/tools/storage are retired; old serialized wire identifiers
  survive only where required to migrate existing local state safely.

## Tools and capability growth

NativeAgent does not inject its entire tool catalog into every turn.

- A small always-on core supports introspection, memory, skill reads, time,
  bridge messages, and tool loading.
- Discovery-only tools are selected by intent or loaded explicitly.
- Tools report `active`, `on demand`, blocked, approval-required, unavailable,
  or unimplemented honestly.
- Tool results are projected before reaching a provider. Large values are
  bounded by UTF-8 bytes, retained temporarily in owner-only storage, and can be
  paged losslessly inside the same turn.
- Every dispatch has a finite watchdog and exact no-progress recovery.
- Tools, skills, MCP servers, workflows, and signed capability packs retain
  distinct lifecycle and trust boundaries.

Current families include files and shell, Git, Mac apps, Mail/Calendar/Contacts/
Music, visible browser, screen vision, research, memory and graph, Workshop,
workflows, GitHub, Slack, X, Telegram, notifications, image generation, system
doctor/repair, backup/restore, skills, tool registry, MCP, and local agent
handoffs. Availability depends on policy, credentials, platform permissions,
and live account proof.

### One causal language across protocols

Native tools and external protocols do not need separate meanings for action
progress. NativeAgent projects supported actions into one bounded phase and
verification vocabulary while preserving the exact domain state underneath.
MCP transport normalization prevents raw and wrapped remote errors from being
reported differently; the tool causal boundary connects supported result
envelopes to the existing Workshop, Browser, Mac Control, and external-send
owners.

This does not make a transport response authoritative. A successful MCP call,
webhook exchange, or HTTP response is still only protocol evidence until the
domain that owns the real effect verifies it. Future external adapters should
reuse this language and bind to a canonical owner rather than creating a
second integration runtime or generic settlement store.

The same rule applies to delegated cognition. A Codex completion can wake the
existing verification path, but it cannot self-certify that GitHub review work
is finished. GitHub Command settles only when its canonical reread clears the
exact actionable event; unresolved thread identity and generation remain open.

## Provider and model control

NativeAgent preserves exact transport identity instead of collapsing providers
into one model family.

| Route | Current contract |
|---|---|
| ChatGPT OAuth | Subscription-backed direct Responses path with account-scoped model catalog and GPT-5.6 presets. |
| Codex CLI | Account-backed CLI route; retains client-side reasoning presets such as Ultra where the CLI owns them. |
| OpenAI API | Public API catalog and controls, distinct from account-only presets. |
| Anthropic OAuth/API | Claude catalog with model-specific effort controls reaching the real request body. |
| xAI OAuth | Grok catalog with supported reasoning levels and provider priority Fast mode. |
| OpenRouter | Cache-first catalog; capability claims remain conservative where adapter support is incomplete. |

Provider/model/Think/Fast preferences exist per canonical surface. Mac,
iPhone, and Telegram controls update shared preferences without silently
changing the chosen authentication route.

## Trust, security, and receipts

- TrustCenter owns policy and autonomy decisions.
- SecurityCenter owns risk classification and path/input scanning.
- Full Mac and Developer Mode do not erase protected floors.
- External sends, money actions, self-modification application, and protected
  OS mutations remain deliberate approval or block boundaries.
- Connector token presence is not enough: non-status actions require live
  account proof where applicable.
- GitHub PAT storage is Keychain-backed; signed iOS pairing and actions use
  HMAC-SHA256.
- Loopback bridges bind to the loopback interface and also require bearer auth.
- Session indexes and critical transaction ledgers fail closed on malformed
  state rather than treating corruption as an empty fresh install.
- Action, approval, tool, Workshop, notification, and delivery receipts make
  completion claims inspectable.

NativeAgent is still a single-operator system. Its shell deny list is
defense-in-depth, not a containment boundary. Read
[threat-model.md](threat-model.md) before granting broad access.

## Honest limits

- The Organism Kernel and CognitiveSubstrate are experimental and default-off;
  **Settings → Advanced → Subconscious** enables their shared master path.
- Connector depth varies; a configured OAuth flow is not automatically a
  complete integration.
- The public Mac release is notarized, Sparkle-updatable, and published through
  GitHub Releases. NativeAgent Mobile `0.3.0 (10)` is submitted to Apple and is
  currently waiting for App Review; TestFlight remains the verified mobile
  distribution until Apple approves the public listing.
- iCloud/CloudKit/APNS require correct Apple signing, containers, entitlements,
  and provisioning; the repository cannot supply those credentials.
- NativeAgent is optimized for one operator and does not claim multi-tenant
  isolation.

See [../PROJECT_STATUS.md](../PROJECT_STATUS.md) for the current ledger and
[build_plans/gpt56-whole-system-audit-2026-07-09.md](build_plans/gpt56-whole-system-audit-2026-07-09.md)
for verified remaining engineering debt.
