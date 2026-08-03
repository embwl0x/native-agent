# NativeAgent Changelog

Reverse-chronological. Each phase: 1–2 lines.

---

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
matters to the agent from her own approved standing views (the shipped
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
