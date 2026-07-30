# NativeAgent Changelog

Reverse-chronological. Each phase: 1–2 lines.

---

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
