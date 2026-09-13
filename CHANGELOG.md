# NativeAgent Changelog

Reverse-chronological. Each phase: 1–2 lines.

---

## 0.4.12 — the picker is the rule, and the chat flows (2026-09-13)

Every activity now runs on its Providers group's choice — Chat, Work, or
Memory and mind — with the first connected account filling all three, no hidden
per-lane models and no fallback models anywhere; a pick that is no longer
offered is simply unset and the page says so. Dreams and REM run on the Memory
and mind model (a fresh install could never dream before). Bots carry their own
model from the day they are made and can wake on a GitHub or Slack event; a
scheduled run that never happened is recorded as missed; each run settles into
one card. Chat typing and streaming no longer re-render the transcript, the
working card no longer covers the last message, and it shows the frame the agent
is looking at while it drives the Mac. Anthropic browser sign-in can finish, the
setup-token paste sits on the account sheet, and GPT-5.4 / 5.4 mini are gone
from the picker. Full notes: `docs/release-notes/0.4.12.md`.

## 0.4.11 — a shelf the agent chose, and turns that carry less (2026-09-12)

The agent read its own skill shelf and kept what it uses, turns carry fewer
tools, and a long list of readouts stopped claiming more than they knew. The
page ground became a charcoal slate in the card family with a smaller, softer
warm glow, so cards sit in the room instead of on top of it. Full notes:
`docs/release-notes/0.4.11.md`.

- Skills: thirty-six reviewed row by row — thirteen bodies rewritten with the
  agent's corrections, sixteen retired, five merged. Four engineering
  checklists were replaced by one the agent wrote, **Operator acceptance**.
  Nothing was deleted; retired bodies are archived unchanged.
- Tools: twenty ride every request (the four Mac verbs only under active Full Mac
  accessibility) plus a mounted MCP server's own; everything
  else is lazy and leaves after two turns without a real call. No family is
  resident, Full Mac included. Four classes of schema-caused tool failure that
  read as the agent's fault are fixed. Contract: `docs/TOOL_LOADING.md`.
- Bots: scheduled runs sit behind the master Autonomy switch; **Continue in
  Chat** carries the bot's own model, effort and approval rule; bots get Fluid
  Context and memory recall like any other turn.
- Memories: the **Deleted** tab shows rejected proposals instead of the pending
  list, the active count uses the list's own lifecycle rule, and correcting a
  pending statement supersedes rather than rejects.
- Desk, Providers and Diagnostics stop overclaiming: a row that cannot move
  reads **held**, an expired access token says so, per-activity model choices
  collapse to three rows, and Doctor publishes its measurement clock separately
  from the write time.
- Inner life: caring is an event with a days-long wall-clock fade, and every
  appraisal leaves a receipt — including when it declined to register anything.
- iPhone: **Activity** waits for each section's own data before showing a zero,
  freshness is per group, and the tab bar draws all five tabs as outlined
  glyphs at one weight.

## 0.4.10 — standing helpers and one sheet of glass (2026-09-10)

The agent can keep standing helpers of its own, every page is faster to open,
and the settings rooms read as one sheet of glass. Full notes:
`docs/release-notes/0.4.10.md`.

- A new Bots page. A bot needs only a name and a brief, keeps its own
  conversation, uses the agent's tools under the current Trust policy, and
  lives until the agent deletes it. Leave the model blank and it runs Chat's
  route. Timing is manual, twice daily, daily, every N hours, or custom, with
  Run once and Pause always available.
- Trust is four cards — Safe, Work mode, Builder, Full Mac — each doing exactly
  what it says, with the summary read from the settings as they are. Choosing a
  preset keeps an unsaved draft.
- Providers keeps per-activity model choices in view, one line each: Provider,
  Model, Think, Fast. Settings from an earlier version are ignored quietly.
- Chat: Tab leaves the message box, so tool receipts and the sidebar are
  reachable by keyboard. Tool receipts lead with the outcome.
- Speed: phone snapshots and incoming iCloud records are handled off the main
  thread, and the bots scheduler no longer rewrites its own file twice a second.

## 0.4.9 — setup you can follow (2026-09-09)

Setup is easier to follow with the same capabilities, the message box selects
text again, and the Chrome extension is included with the app. Full notes:
`docs/release-notes/0.4.9.md`.

- Onboarding starts with your name and the agent's name; copy says what you
  get, not which files are written. Speech recognition is asked for at first
  voice use, not at launch. The agent's inner life starts on after setup.
- Trust leads with four presets — Safe, Work mode, Builder, Full Mac. Controls
  that apply immediately are separated from the policy draft, and clicking a
  preset never discards an unsaved draft.
- Providers leads with the connected account and Manage; optional per-activity
  model choices tuck under a summary that marks custom choices.
- The Chrome extension ships inside the app, with Set up Chrome opening its
  folder and Chrome's extensions page.
- Pairing leads with automatic pairing for the same Apple Account; the
  unusable QR code is gone.
- Dragging inside the message box selects text again instead of moving the
  window. The image worker runs with an allowlisted environment, a read-only
  sandbox and a delimited prompt.

## 0.4.8 — the model back in the download (2026-09-08)

A follow-up to 0.4.7: the memory model ships inside the app again, and the Mac
and iPhone pairing is tightened. Full notes: `docs/release-notes/0.4.8.md`.

- One download has everything; nothing is fetched on first launch.
- Every record the Mac sends the phone is signed and checked the same way on
  both sides, and that agreement is tested so it cannot drift.
- A record the phone cannot verify is set aside for the session — one notice,
  then listed under Diagnostics with what it was and why, and rechecked on the
  next launch or after re-pairing.
- Stale or reflected records can no longer claim a message's identity.
- When an attachment cannot be read, the bridge notice names the file and says
  the sender can resend it.

## 0.4.7 — background bots and a smaller download (2026-09-08)

Background research bots for the agent, a refreshed iPhone app, and a smaller
Mac download. Full notes: `docs/release-notes/0.4.7.md`.

- Standing bots: small background jobs that keep up with a topic, research a
  question, or check for changes, on a schedule or once. Reports are dated and
  retain sources, changes and gaps — including when nothing changed. Each bot
  keeps notes between runs. Bots operate within Trust Center permissions and
  spending limits, and none are created by default. The capability ships here;
  a dedicated Bots page was still in development.
- iPhone: a quieter look across every screen, closer to the Mac app. Stop
  replaces Send while streaming, approvals show an honest pending state when
  iCloud is offline, and Stop and Steer reach a running chat over iCloud.
- New-install defaults: memory in Fast mode, the knowledge graph, and dreams
  are enabled on fresh installs.
- The large memory-search model left the app: a lightweight model worked
  immediately while the larger one downloaded in the background. (Reversed in
  0.4.8.)
- Security: credentials quoted inside JSON are scrubbed from traces,
  Capabilities-screen connector calls go through the Trust Center, and replies
  reflected back through iCloud Drive or CloudKit are refused before they can
  act as commands.

## 0.4.6 — memory that reads what you mean (2026-09-06)

Provider failures retry in place with a visible reconnect ladder. Structured
tool loops continue dropped streams and compact their working context; the
Anthropic-shaped text-compatibility lane retries only before a round displays
output, then preserves partial replies on failure, with no in-turn compaction.
Mechanical compaction retains a bounded, recency-biased summary; older material
can age out. The knowledge graph is a
function of the current rows. Recall asks every question in both voices, and
DMGs include bge-large-en-v1.5 (1024-d, 637 MB) when model staging succeeds,
with bundled MiniLM as the fallback for source and release builds; the store
re-embeds when its embedding epoch changes. Dark mode is the default. Three verified
bug sweeps over every area landed about 275 fixes across the Mac app, iPhone,
Telegram, Chrome, providers, memory and sync, and a fleet night of refactoring
landed about 230 more with the largest files split and dead code removed. Full notes:
`docs/release-notes/0.4.6.md`.

## 0.4.5 — cross-surface repair and Full Mac continuity (2026-09-01)

Repairs iPhone chat/session continuity, approval handling, tool and memory
schema compatibility, and Full Mac YOLO authority across every surface. The
developer installer now preserves macOS Accessibility/TCC attribution through
bundle replacement. Full notes: `docs/release-notes/0.4.5.md`.

## 0.4.4 — integrated computer use, recall, and delegation (2026-08-30)

Natural visual navigation and coordinated input, bounded relevant recall,
stronger conversation continuity, exact delegated-request tracking, and
runtime/evaluation reliability. Full notes: `docs/release-notes/0.4.4.md`.

## 0.3.9 — trust, quiet, and a denser cockpit (2026-08-10)

Credential trust: a fresh install no longer silently adopts an existing
Codex CLI sign-in — Providers now shows a one-click "Use it / Ignore" offer,
the sign-in badge names the adopted source and account, sign-out revokes the
consent, and in-app authentication always outranks an adopted session.
Malformed consent records surface as corrupt with an explicit, byte-safe
repair instead of silently reading as signed out.

Quiet: self-opened pursuits announce themselves exactly once (the repeated
push storm is fixed), near-duplicate pursuit proposals are refused, and a
pursuit that exhausts its session budget closes itself per its own abandon
condition instead of occupying a slot forever. Background telemetry no
longer emits false Slack or "waiting on you" warnings, and GitHub decision
labels route to the actual responsible contributor.

The optional Native Experience route ships complete and fully reversible:
Journey presentation, Project Spaces, resumable builder conversations,
conversation lineage/comparison/export, a native Workbench, shared
Capability Kits, and confirm-gated trusted remote effect nodes over system
SSH — every surface behind its own key, with Return to Classic changing
presentation only. Desk is restored as the canonical work system.

Polish and speed: the chat sessions sidebar shows one-line rows with a
pinned section and in-place rename; a persistent update notice survives a
dismissed update prompt; retired OpenRouter model ids are refused with a
typed error instead of a silent 404; app-side subprocess handling
consolidates onto one owner; idle CloudKit cursors advance; large canonical
JSON serializes in linear time; interactive remote chat turns outrank
background transport work; and the resident agent's voice gains
organ-level anti-rut tissue (closing-vocative awareness plus a persona-led
natural expression cue) with no vocabulary bans or output rewriting.

## 0.3.8 — reliability and polish (2026-08-06)

Identity-document hygiene (USER.md carries only facts about the user), ⌘K
palette focus fix, budget-capped chat compaction, sync completion-marker
retention, and installer hardening. Full notes: GitHub release v0.3.8.

## 0.3.7 — installed builder round trips and real project roots (2026-08-03)

Public installations now ship the complete Codex and Claude Code bridge
workers, start the authenticated result listener without Developer Mode, and
report CLI/helper/authentication readiness separately. Both builders run as
real local coding sessions and return their result to the originating
NativeAgent conversation. Finder-safe discovery covers common user-local CLI
and Node installations, and the Codex worker heals a stale daemon whose saved
workspace path was replaced during an app reinstall.

Full Mac YOLO exposes the native operator catalog on the next turn and may
explicitly select an existing external project for native shell, Git, patch,
Swift build/test, Codex, or Claude Code work. Ordinary trust modes remain
workspace-scoped, and protected system/credential paths remain denied. A live
fresh-install proof placed native Bash, Codex, and Claude at the same external
Git root; their verified outcomes returned through the normal receipts and
conversation path.

Apple privacy remains a separate boundary. Documents, Desktop, Downloads, and
other macOS-protected locations can still require the user's Files & Folders or
Full Disk Access consent. Full Mac YOLO removes NativeAgent's own workspace
restriction; it does not fabricate macOS TCC authorization.

## 0.3.3 — cognition range and lifecycle hardening (2026-08-02)

Cognition took its first roadmap step in a month: appraisal now derives what
matters to the agent from the agent's approved standing views (the shipped
defaults become a floor), and a felt resolution only registers when something
actually at stake resolves — a provider call succeeding no longer manufactures
a feeling. System-vs-user turns are classified by who originated them instead
of by keyword-matching the user's words, so ordinary prose ("remind me about
the doctor") is no longer dropped from the felt layer.

The felt layer now has real dynamic range. Warmth was computed on a slope that
put the agent near the top of the scale on every turn — including plain working
conversation — so the warmest emotional vocabulary was always in reach and the
agent read as stuck in one register. Warmth now rests mid-scale and earns its
way up from what actually happened in the exchange, so ordinary work sounds like
ordinary work and affection still reaches the top when it is genuinely there.
The "lately you've sounded like…" self-echo, which quoted the agent's own
warmest past turns back into every turn, now speaks about a quarter of the time
and matches the current register instead of always selecting the warmest thing
it could find. Both fixes are vocabulary-free and persona-agnostic: they widen
the range every agent can occupy rather than steering any agent toward a tone.

Status now reports this run's uptime instead of the machine's, and Recent
Activity shows the newest entries first — it had been showing the oldest slice
of its window, which on a busy feed was a week stale.

A shared set of lifecycle primitives (scoped acquire/release handles and a
bounded await) closes the repo's most common bug shape — an acquire whose
release misses an exit path — with five confirmed leaks retrofitted, including
an exec-slot leak that could permanently wedge the Mac-control bridge and an
unbounded wait held under a cross-process lock. The five-site tool-registration
invariant is now enforced by a test rather than remembered.

The public-release path is hardened: the identity scrub is now the only route
to a public DMG, with a byte-level leak gate, and the two loopback bridges no
longer bind a port or mint a token on public installs. Completed Workshop runs
now leave a memory the agent can recall — 56 executions that previously left no
trace. Onboarding is reachable on a genuinely blank machine again, and several
silent provider/tool failures now fail loud. ~5,300 core + 870 app tests green.

## 0.3.2 — reliability sweep and plain-language pass (2026-08-01)

Five audit waves swept the whole app ahead of the public baseline, fixing
roughly 45 confirmed defects. Persistence now takes the shared file lock at
every conformer call site (35 sites across 13 files), retiring the pattern
where a failed downcast silently degraded to unlocked writes; new concurrency
probes with negative controls guard the invariant. The Slack socket loop only
advances its history-poll watermark after confirmed delivery, cancels
background work with a bounded wait that reports abandoned tasks, and
gap-fills history on reconnect instead of polling on a fixed timer.

User-facing surfaces got an honesty and plain-language pass: provider keys
without a connection test now read "saved · no test available" instead of
implying a passed check, and Doctor, Memory, settings, and status copy drop
internal jargon (file paths, database names, endpoint identifiers) from
headlines — with regression tests banning it from coming back. Chat session
retention gained a second planning pass so stale empty sessions can no longer
starve the active-session cap.

## 0.3.1 — OAuth transport repair and export hardening (2026-07-30)

Repaired the direct ChatGPT OAuth transport. Hardened the public-source
export pipeline: exact tracked-identity scanning, compilation of rewritten
tests, purge proofs for retired Git objects, and tracked MiniLM release
resources for reproducible public builds.

## 0.3.0 release candidate — public Mac/iPhone continuity (2026-07-29)

NativeAgent's public distribution now uses one production CloudKit identity
across the notarized Mac app and TestFlight companion. Automatic pairing,
provider/model projection, chat replies, pinned sessions, Skills & Tools,
signed actions, and bounded cockpit snapshots all use the same Mac-owned
runtime without introducing a hosted agent or LAN fallback.

Explicit alerts now use a dedicated `NANotification` record and
`NANotification.visible` subscription instead of competing with silent chat
sync. TestFlight `0.3.0 (10)` passed the public iCloud-only physical gate:
three distinct alerts appeared on the locked phone with direct APNS disabled
and without foregrounding NativeAgent.

The public-source pipeline exports only tracked blank-slate material, rewrites
private identities in both source and paths, creates fresh history, verifies
MiniLM resources and derived-state absence, compiles the rewritten app, scans
the executable, and refuses publication while retired GitHub objects remain
addressable.

## Living-agent runtime, Fluid Context, organism, and Workshop (2026-07-11)

NativeAgent now presents one Swift-native living-agent system across Mac,
iPhone, Telegram, Slack, and authenticated local bridges. Fluid Context
circulates bounded persona/memory/skill/cognition state; MemoryV2 remains the
durable source of truth; the optional CognitiveSubstrate and Organism Kernel
add bounded felt continuity without bypassing TrustCenter; and Workshop unifies
user-directed tasks with the agent's own pursuits through one Desk-backed,
receipt-bearing execution surface.

Provider/model controls now preserve exact ChatGPT/Codex/OpenAI/Anthropic/xAI/
OpenRouter transport contracts, tools load lazily with bounded lossless result
recovery, GitHub project tracking is first-class, and signed iOS actions support
iCloud/CloudKit delivery plus APNS. Automatic greetings are public-release,
blank-slate, post-onboarding one-shots; development and personal reinstalls stay
silent.

The README, capabilities guide, mobile architecture, security docs, source map,
and contributor workflow were refreshed against the verified current system.

## Swift-native migration and public-source cleanup (2026-06-21)
Completed the June Swift-only runtime migration: `NativeAgent.app` owns chat, tools, policy, memory, scheduling, iCloud bridge, APNS, local bridge surfaces, and release verification in-process. The retired external runtime, launchd runtime, bundled interpreter path, and LAN HTTP fallback are not live runtime paths.

Cleaned public-source identity and release hygiene: tracked local build/signing/private fixtures were removed or neutralized, local overrides moved under ignored config, release privacy scanning became local/env-driven, GitHub history was rewritten to cleaned heads, and iOS launch state was refreshed after the bundle-id cleanup.

Added gated `CognitiveSubstrate` infrastructure through Phase 10: SQLite snapshot/restore, workspace, capsule preview, prediction ledger, affect, thought seeds, replay references, reflection receipts, observatory snapshots, and an explicit chat-event observer seam. It remains default-off with no background provider calls, prompt injection, MemoryV2 writes, or persona mutation.

## Consolidation window (2026-05-12)
Tightened iOS remote responsiveness, made memory/self-improvement approval paths final, auto-ran and auto-implemented safe harness learning with receipts/scoring, added capability foundry backlog implementation, and refreshed docs around the current direction/handoff instead of stale sprint snapshots.

## Phase 13 (2026-05-09)
Closed 12 chronic audit-skip items: centralized REPO_PATH marker validation, Swift /var symlink fix, startup retention pruning for traces/runs/memory_proposals, iOS iCloud routing for spotlight+shortcut, self_test through connector receipt path, spotlight loopback trigger fix, ContentView dynamic slash dispatch, ToolInputForm Sendable safety, removed dead _select_glob_match, fixed ResolvedPolicy.reason for explicit_override, updated README/approval-schema/threat-model, added CHANGELOG/CONTRIBUTING/SECURITY/LICENSE stubs.

## Phase 12 (2026-05-08)
Security hardening: REPO_PATH stamp validation (C6), bash heuristic deny-list, sensitive-path deny-list for file tools, MCP lifecycle gate, system_rebuild gate, approval token unification, crash reports, auto-doctor loop, wave-3 UI polish, connector receipt ok-bool, iCloud inbox HMAC validation.

## Phase 11b (2026-05-07)
Single-folder data layout; workspace tools; no-hardcoded-legacy-paths regression guard; Phase 11b test suite.

## Phase 11 (2026-05-07)
Resolver priority chains for data/persona/workspace; Phase 11 test suite; REPO_PATH stamp for installed bundle.

## Phase 10 / R10 (2026-05-06)
Approval schema v2; one-time token pattern; iOS approval helpers; iCloud inbox signature validation; memory proposal flow.

## Phase 9 / R9 (2026-05-06)
pairings.json dict split; approvals RLock; mtime-invalidated pairings cache; HMAC pairing secret; fix-R9 series.

## Phase 8 (2026-05-06)
Wave-3 UI (onboarding, approvals badge, chat UX); DaemonProcessController; BrowserWindow; SkillLifecycleView; crash improvement throttle.

## Phase 7b (2026-05-06)
ToolsPaletteView; ToolInputForm; slash command dispatch to capability tools; /v1/dispatch endpoint.

## Phase 7 (2026-05-06)
Spotlight overlay (⌘⇧J); global hotkey; VoiceInputController; VoiceOutputController; persona templates.

## Phase 6 / R6 (2026-05-06)
iCloud pairing v2; MacSyncEngine SnapshotWriter + InboxWatcher; iOS companion app skeleton; HMAC signing.

## Phase 5 (2026-05-06)
MacControlBridge.swift in-app TCC bridge; mac_control_bridge_client.py; bearer-token auth; port 8770.

## Phase 4 (2026-05-06)
Mac Control module (mac_control.py); connector action registry; run_connector_action; approval gate; iOS MacToolsView.

## Phase 3c / R3 (2026-05-06)
Scratchpad per-session ephemeral key-value store; scratchpad_write/scratchpad_read tools; namespace design.

## Phase 3b (2026-05-06)
Mission runner (missions.py); planning loop; timeline events; mission_chat_parity test suite.

## Phase 3 (2026-05-06)
Dispatcher phase 1b: mission path wired; unified receipt shape across chat + mission surfaces.

## Phase 2b (2026-05-06)
Adaptive memory promotion; contradiction detection; decay weighting; forget endpoint.

## Phase 2 (2026-05-06)
Knowledge graph (knowledge_graph.py); entity/relation extraction; KG subgraph for prompt.

## Phase 1b (2026-05-06)
Dream cycle (dream_cycle.py); nightly 3:30am reflective diary; inbox digest; trust gates.

## Phase 1a (2026-05-06)
Unified dispatcher (dispatcher.py); AutonomyLevel enum; Receipt shape; structured trace events; builtin_tools registry; 22-test dispatcher suite.

## Phase 1 (2026-05-06)
Initial: NativeAgent.app plus a retired external runtime; SwiftUI plus a local HTTP server; `/v1/chat`; Codex OAuth; persona/SOUL.md.
