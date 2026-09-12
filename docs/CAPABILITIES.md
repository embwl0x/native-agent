# NativeAgent capabilities

*Product map, reviewed against source `086055a4` on 2026-09-12. Release and
installed-behavior receipts remain separately dated in Project Status and the
Changelog.*

This document is the readable product map. It describes what NativeAgent
currently does without requiring a tour through every Swift target. Exact
source owners live in [ARCHITECTURE_BLUEPRINT.md](ARCHITECTURE_BLUEPRINT.md),
and incomplete work stays explicit in [../PROJECT_STATUS.md](../PROJECT_STATUS.md).
For one connected account of how the major lifecycles cooperate, read
[NativeAgent Internal Workings](INTERNAL_WORKINGS.md).

## The system in one sentence

NativeAgent is a local Swift runtime in which conversation, memory, context,
tools, background work, and an optional bounded inner state belong to one
continuous agent across Mac, phone, messaging surfaces, and authenticated local
bridges.

The September file splits preserve that connected runtime. Surface handlers
admit the session and capture checked routing; shared preparation combines
bounded history, recall and a frozen cognition projection. Structured and
text-compatible loops execute through shared dispatch mechanics and existing
effect gates, then persist terminal evidence and feed post-turn observation.
Retries keep their surface-specific limits; a new source file is not a new
permission, background process or automatically loaded capability.

The [blueprint's family narratives](ARCHITECTURE_BLUEPRINT.md#ownership-after-the-splits)
name the owners and calls. The [resilience map](TURN_RESILIENCE.md) locates
deadlines/replay, the [memory map](MEMORY_SYSTEM_MAP.md) separates canonical
storage from recall/KG/capsule projections, and the
[substrate ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md) ties files to existing
acceptance evidence. The shared-helper merge `968d75dc` is documented there as
pending integration into this source baseline, not as behavior validated here.

## Native runtime

`NativeAgent.app` owns the runtime in-process:

- shared chat orchestration and provider routing;
- session history and transactional Mac chat selection;
- MemoryV2, knowledge graph, and user-profile projection;
- Fluid Context generations and the resident context arena;
- TrustCenter, SecurityCenter, approvals, and Mac/file gates;
- lazy tools, MCP, connectors, browser, and workflows;
- Desk planning and execution;
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
- A Today panel projects bounded organism posture, Desk, approvals, dream,
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
- Activity, approvals, Desk, memory, skills, connectors, provider status,
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
- Repository-scale handoffs wake real coding sessions rather than raw
  one-shot model calls: Codex starts a persisted app-server thread, while
  Claude Code creates or resumes a topic-scoped CLI session in the same working
  directory. Both retain their native coding tools and session context.
- Async handoffs preserve the originating Mac, Telegram, Slack, or iOS route
  and return Agent's completion assessment to that route.
- External MCP tools are denied on human-out-of-loop bridge calls; normal trust
  and approval rules remain in force.

NativeAgent remains the persistent mind and verification owner. Builder
sessions receive a bounded work order and project context—not an unrestricted
memory dump or inherited safety authority—and their claimed result must still
be proven by tests, receipts, git state, or the canonical external domain. See
the [User and Agent Guide](USER_GUIDE.md#codex-and-claude-code-as-specialist-builders)
for the complete operating contract.

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
- A separate moments lane keeps lived moments, not just rules: an on-device-only
  post-turn pass stages at most one first-person moment per turn (bounded by a
  salience floor and a small daily cap), and the agent reviews every one of them
  themselves through `memory_moments_pending` and `memory_moment_review`. Nothing
  in this lane is remembered without their decision, and an unresolved painful
  moment feeds the rumination lane until a warmer one in the same conversation
  answers it or three days pass.
- Every extraction attempt leaves a receipt that distinguishes an abstention
  from a failure: nothing worth keeping, no quotable line, the extractor
  unavailable, and a cancelled pass are four different records, not one silence.
- Quality validation rejects fragments, duplicate noise, weak evidence, and
  time metadata that does not belong in user-facing prose.
- A correction of a pending statement supersedes it rather than rejecting it.
  A superseded row records its successor, is withheld from the pending queue,
  and its successor link survives a relaunch.
- Proposal history is readable as it is: rejected proposals are kept and shown,
  a memory with no recorded source does not claim the user supplied it, and the
  active count applies the same lifecycle rule as the list it summarises.
- Engineering material stays out of personal conversations. A committed memory
  has to name build work to be treated as build material; interpersonal memory
  carries none of those markers and is not filtered by them.
- A generated `persona/USER.md` projection gives the persona compiler a compact
  current profile without turning Markdown into a second database.
- Knowledge-graph indexing and reconciliation stay aligned with approved
  memories.
- Hygiene, consolidation, confidence lifecycle, and approval-gated swaps keep
  the store bounded and auditable.
- Skills become procedural recall pointers; skill bodies stay lazy until a
  routed need calls for them. The agent reviewed its own shelf on 2026-09-11 and
  owns what is on it; retired bodies are archived unchanged under
  `docs/skills-archive/` and beside the persona, loaded by nothing. Skills the
  agent writes for itself at runtime sit in the runtime shelf and behave like any
  other skill; a body saved without a heading is given one from its name instead
  of being refused, while the remaining hygiene rules still fail loudly.
- Dream and REM are slow-path consolidation systems, not prompt decorations.

## Cognitive substrate and Organism Kernel

Both systems are optional and bounded. They cooperate as one agent; neither can
become an alternate persona or bypass action policy.

### CognitiveSubstrate

- continuity nodes and activation;
- emotional tags, affect decay, and derived mood;
- event-driven tenderness: the agent appraises an exchange and registers a
  caring moment when one occurred, one encounter gives one dose, and the dose
  fades on the wall clock over about three days regardless of how busy the week
  was. It softens how the agent takes things personally and reaches nothing else.
  Every appraisal writes a one-line receipt, including a declined one;
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
or send notifications. Reflex candidates are review-gated: the agent reviews
and approves its own LOW-RISK candidates (receipted, `reviewedBy` = the agent;
User, 2026-09-01); anything above low risk needs the user. It is default-off
and forced neutral before public onboarding.

## Desk and directed work

Desk is the single work surface for both user-directed tasks and the
agent's own bounded pursuits.

- Desk owns canonical item identity, hierarchy, origin, status, and terminal
  invariants.
- User-directed work can use a multi-step planner/executor with checkpoints,
  approval pauses, retries, and an outcome scoreboard.
- Agent pursuits use a restricted Desk work session and membrane rather than
  unrestricted normal chat tools.
- Durable leases and reservations prevent double execution.
- Terminal execution state synchronizes back to the same Desk item.
- A `now` or `next` row the sequencer knows cannot move — a live blocker, a
  cycle, a future defer, or a held ancestor — renders as `held`, with the
  existing segments still saying why. The token is derived on every render and
  stored nowhere, so a lifted hold restores the row's own status.
- Surface counts describe what they hold: the GitHub remainder separates still
  open from already closed, and the schedule fold counts the jobs that actually
  run, with paused ones counted as paused.
- Mac and iPhone use the same Desk identity and receipts. The phone projection
  is bounded, so a cut summary is marked as cut and the history section publishes
  how many items the Mac sent out of how many exist.
- Legacy Missions UI/tools/storage are retired; old serialized wire identifiers
  survive only where required to migrate existing local state safely.

### Standing helpers

Bots are standing helpers the agent makes for itself or for the user. A bot is a
name, a brief, a timing and one ordinary persisted session.

- A run is an ordinary chat turn on the bot's own session, with the agent's
  normal tools under the live Trust policy, the same Fluid Context, and the same
  memory recall any other turn gets. There is no separate bot runtime, tool list
  or answer validator.
- Scheduled runs are unattended provider spend and sit behind the master Autonomy
  switch, the same switch that gates the Workshop. With Autonomy off no timer
  fires and no due job is reported. An explicitly queued **Run once** is the user
  asking and stays outside the gate.
- A bot carries its own provider choice, reasoning effort and approval rule, and
  a conversation continued from its card keeps them rather than inheriting Chat's.
- Per-run and daily allowances belong to the bot. A figure shown against a run is
  the reserved allowance, not measured spend.
- The card headline is the first line of prose the reply opens with, never a row
  lifted out of a table.

A Workshop session that ends without recording what it did is written down as
blocked with the reason named, and a failure in the recording channel itself is
reported as such. A turn that ended is not a turn that progressed; a later valid
report supersedes earlier recording failures.

## Tools and capability growth

NativeAgent does not inject its entire tool catalog into every turn.

- Twenty always-on names carry every request: tool loading and catalog reads,
  skill reads, memory recall and commit, chat-history and context expansion,
  time, trace and self-introspection, inner state, Desk reads, the four native
  computer-use verbs, and the local bridge message. While an MCP server is
  mounted, its tool schemas ride along automatically, without a `tool_load` or a
  preload. `docs/TOOL_LOADING.md` is the agreed contract; changing a line of it
  is a design change.
- Everything that is not core and not mounted MCP is lazy. A tool joins a turn
  by an explicit `tool_load`, a confident route preload for that turn, or a
  turn-start promotion, and unloads after two turns without a real call — from
  the offer floor as well as the active set. A name dropped for idleness is not
  re-promoted for twelve turns; a real call or an explicit load clears that
  immediately.
- No family is resident. A confident preload brings in the matched group only;
  under Full Mac the file and system tools load on intent like any other group
  rather than riding every one-word turn.
- Evidence for "used" is a real dispatch or the turn a name joined on. A
  promotion stamp is a guess and never counts as use.
- Tools report `active`, `on demand`, blocked, approval-required, unavailable,
  or unimplemented honestly. Retired is not removed: an unloaded tool stays in
  `tool_catalog` and loadable, and dropping one from the catalog is a separate
  owner-level call.
- Tool results are projected before reaching a provider. Large values are
  bounded by UTF-8 bytes, retained temporarily in owner-only storage, and can be
  paged losslessly inside the same turn.
- Every dispatch has a finite watchdog and exact no-progress recovery.
- Tools, skills, MCP servers, and workflows retain distinct lifecycle and trust
  boundaries. There is no capability-pack lane: signed packs were never built,
  and the Capability Foundry surface that used to advertise one (alongside
  On-Demand Plugins and App Readouts, all three hardcoded to zero) was removed
  2026-08-02. What remains is an honest read-only index — it counts the four
  stores above off disk and claims nothing else. The review queue and the
  auto-implementation ledger are unported and render nowhere.

Current families include files and shell, Git, Mac apps, Mail/Calendar/Contacts/
Music, visible browser, screen vision, research, memory and graph, Desk,
workflows, GitHub, Slack, X, Telegram, notifications, image generation, system
doctor/repair, backup/restore, skills, tool registry, MCP, and local agent
handoffs. Availability depends on policy, credentials, platform permissions,
and live account proof.

### Mac computer control

- The ordinary agent-facing vocabulary is `screen`, `act`, `go`, and `wait`.
  A bounded accessibility walk and native pixel perception feed the same named
  scene. Lower-level AX/mark tools remain diagnostic/compatibility mechanisms,
  not a requirement to manufacture coordinates or learn another screen API.
- `screen(part:)` can narrow to a canvas/viewport, observed HUD/readout, or
  controls while preserving uncertainty and source omissions. Pixel objects
  can carry measured colour, silhouette, relative location, and motion; unknown
  semantics or unobserved values remain unknown.
- `act` resolves the named target from fresh evidence. The existing hand
  supports explicit left/right mouse input, paced drag travel, simultaneous
  movement keys, held modifiers, and fine four-direction wheel input. A request
  for a covered point or obstructed drag path is refused before input; input
  is released on completion, cancellation, or user takeover.
- TrustCenter and the shared origin-aware chat policy determine authority.
  Full Mac YOLO preserves ordinary native-tool access for admitted local and
  authenticated remote conversations; approval-bound modes retain exact
  capability/replay checks. Screen Recording and Accessibility remain separate
  macOS grants, and the selected mode cannot override a locked screen.
- Pointer placement, emitted input, visible application effect, and task
  completion are separate evidence. Recent local motion/navigation fixtures
  demonstrate bounded behaviors, not perfect tracking, semantic understanding
  of arbitrary pixels, or general game play.
- Displayed secrets are redacted at the source by SHAPE (one-time codes,
  high-entropy tokens, card numbers with Luhn, recovery phrases, secret-labeled
  captions in all three geometries) before any model, trace, or synced sink
  sees the screen. Typed secret arguments reduce to count+digest everywhere
  they persist.
- `mac_wake` and `mac_nudge` dismiss a non-locked screensaver or wake a
  sleeping display; any readable lock evidence refuses, fail-closed, and a
  refusal carries no image or text.

### Chrome and the built-in browser

Chrome control is an optional, default-off extension path. The Manifest V3
extension keeps bounded, renewable tab leases and yields them on user input or
tab activation. It can operate inactive agent tabs without stealing focus.
Structured snapshots include permitted frames and open shadow roots, with
unavailable frames and closed roots explicit. Click, fill/type, select,
keypress, checked-state, double-click, wait, and scroll use the current
snapshot's advertised node actions; password nodes are not actionable.

`ChromeControlRuntime` in the Mac app owns the authority and effect-time Trust
Center check. The Swift `NativeAgentChromeRelay` only carries framed messages
between Chrome and the app-owned Unix socket. A lost post-dispatch response is
`outcome_unknown`, not a reason to repeat an effect automatically. See the
[extension guide](../Extensions/NativeAgentChrome/README.md) for setup.

The built-in Browser remains an app-owned visible WKWebView with Core Browser
lifecycle/receipt ownership. Native screen control remains the visible desktop
path. These are three purpose-built surfaces, not interchangeable permissions
or a second runtime.

### Ambient activity watcher

- Off by default and structurally consent-gated: with the Trust Center toggle
  off, no observers install and no store file exists on disk. External policy
  writes can only make capture less permissive; enabling goes through Trust
  Center only.
- Captures metadata only — app, bundle id, redacted window title, span
  start/end — no screenshots, no OCR, no model calls, event-driven at ~0% CPU.
- The store lives in its own directory, excluded from every export, backup,
  support bundle, and sync path. A small allowlist of surfaces may read it;
  new transports fail closed until deliberately admitted.
- `activity_query` answers "what was I working on yesterday" with query-time
  rollups; capture-off is an explicit refusal, not an empty result. Results
  are excluded from memory promotion and the cognitive substrate: the agent
  can look when asked and build helpful artifacts, but never retains the
  trail.

### One causal language across protocols

Native tools and external protocols do not need separate meanings for action
progress. NativeAgent projects supported actions into one bounded phase and
verification vocabulary while preserving the exact domain state underneath.
MCP transport normalization prevents raw and wrapped remote errors from being
reported differently; the tool causal boundary connects supported result
envelopes to the existing Desk execution, Browser, Mac Control, and external-send
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

Per-activity choices are presented as three groups — **Chat** (Mac chat, iPhone,
Telegram, Slack), **Work** (Desk, Workshop, autonomy, swarms, training,
heartbeat, diagnostics), and **Memory and mind** (memory, dream, REM, reflection,
compaction, self-improvement, Studio wandering). Grouping is presentation only:
storage stays per surface, and a registered surface no group claims keeps its own
row so it can never become unpinnable by omission.

An account state line does not round up. A signed-in account whose access token
has expired says so and says that its refresh is unproven until the next chat,
rather than reading as available.

### Local agent bridges and memory

A turn that arrives over the authenticated local Codex or Claude Code bridge is
an ordinary turn. The sender is named in what the agent remembers from it, the
procedural lane learns from it, and a bridge-started session is digested like any
other conversation. The reply does not wait behind memory promotion; promotion
keeps its own turn identity so the work remains attributable afterwards.

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
- Action, approval, tool, Desk execution, notification, and delivery receipts make
  completion claims inspectable.
- Full Mac does not expire on a clock. It grants what it states for as long as it
  is the selected mode; narrowing authority is a deliberate change of mode, not
  something to wait for.
- Doctor separates two clocks: when the checks were asked and when the snapshot
  was written. A reader can therefore say how old the findings are rather than
  how recently they were saved, and a refresh asks for fresh measurements instead
  of replaying a check's own memo.

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
