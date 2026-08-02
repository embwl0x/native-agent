# NativeAgent Project Direction

This document is the durable project compass for NativeAgent. `docs/ARCHITECTURE_BLUEPRINT.md` is the fast source map for agents and contributors. Update both whenever a session changes architecture ownership, safety model, UX direction, or current priorities.

## North Star

NativeAgent is a native Mac + iPhone agent system for Agent: powerful enough to operate across the Mac, tools, memory, Telegram, iCloud, APNS, schedulers, and subagents, while staying simple enough for non-technical users to install, understand, and recover when something breaks.

The target is not a pile of plugins. The target is a lightweight, coherent agent runtime that can discover and grow capabilities as needed, keep its own memory clean, and expose understandable controls and receipts.

## Product Principles

- Keep the agent fast by default. Prefer lazy-loaded inventories, context routing, manifests, and compact hints over injecting every tool, memory, and instruction into every turn.
- Keep power and safety unified. There should be one understandable policy surface across chat, trust, iOS, Telegram, tools, Mac control, and autonomy.
- Defend the boundary, then keep Agent powerful inside it. NativeAgent should spend most of its security effort on ingress, identity, bearer tokens, trusted local surfaces, remote signatures, and protected system floors. Once the user is talking to Agent through a trusted surface, workspace-mode tools should be as wide open and low-friction as practical. Do not solve outside-attacker risk by over-gating Agent's own normal chat/workspace tools; reserve approval friction for external sends, credentialed third-party actions, destructive/system-level changes, and genuinely unsafe OS mutations.
- Full Mac access and Developer Mode are separate controls. Full Mac grants broad outside-workspace file access and non-destructive Mac app control after explicit user selection and clear receipts. Developer Mode is the operator-only escalation for destructive/system-level actions such as shell execution, system control, and file move/trash; when both controls are active, the shared builder executor must not retain an independent workspace-only sandbox that contradicts them. Even Developer Mode still has a non-bypassable system-protected path floor: autonomy and remote/tool dispatch must not delete or mutate OS paths such as `/System`, `/etc`, `/usr/bin`, `/bin`, `/sbin`, `/Applications`, LaunchDaemons, or other protected system locations.
- Full Mac YOLO is the active local/team trust posture. On local Mac chat, local bridge/team surfaces, and explicitly local Workshop execution, NativeAgent-native tools should resolve autonomy-auto by default instead of depending on fragile per-tool `toolAutonomy` entries. Remote surfaces such as Telegram/iOS do not inherit silent shell/process auto from a yolo window. External account sends, money actions, self-modification apply/install, and protected OS mutation floors remain deliberate approval/block boundaries.
- Avoid bloat. Consolidate before adding. Reuse existing runtime paths, models, controls, and manifests before creating another tab or subsystem.
- Give Agent one causal language at every protocol edge. Native tools, MCPs, webhooks, connectors, and future external adapters should translate transport evidence and bounded action identity into the shared motor phase/verification vocabulary, while the canonical domain owner remains the only authority on what actually happened. A response received, including HTTP `200`, is not verified settlement; likewise, an LLM or Codex completion callback may trigger verification but cannot certify an external desired condition. Do not turn this connective tissue into a universal integration owner, event store, scheduler, approval path, or shadow state system.
- Plugin-shaped add-ons are on-demand capability packs, not preinstalled baggage. Agent may draft or install them when a task justifies a feature bundle, but chat sees only compact manifests until routed.
- Receipts beat hidden magic. Autonomous improvement, tool use, scheduled jobs, notifications, memory changes, and remote actions should leave short visible receipts.
- The iPhone app should feel like a first-class remote cockpit, not a delayed companion. Chat, approvals, notifications, model/think/permission controls, and action status should work from iOS.
- Agent's personality matters, but the harness should stay compact. Long personality material belongs in lazily routed memory/persona files, not in every request.
- Public/default builds must stay identity-neutral. App UI, runtime defaults, release resources, launch labels, and templates should use `NativeAgent`, `the agent`, or `the user`; local agent/user names must come from runtime profile, persona files, or explicit user config.

## Next-Gen Coordination Quality

NativeAgent is past the point where "more plugins/tools" is the main win. The next-gen work is coordination quality: Agent knows what kind of turn she is in, chooses the right surface, acts with receipts, tests herself, and improves without the user babysitting it.

The durable improvement lanes are:

1. Intent clarity before action. Agent should classify each turn as chat, memory update, build task, research, Mac control, self-improvement, approval, schedule, Telegram, or another routed class before loading tools/memory/policy.
2. Better receipts. Meaningful actions should leave a tiny readable receipt: what changed, why, what check proved it, and whether it is permanent or still provisional.
3. Memory confidence levels. Memory should distinguish confirmed facts, temporary project state, inferred preferences, stale facts, and contradicted/corrected facts so the KG can stay useful without preserving wrong state.
4. Self-improvement scoreboard. Improvements should be scored after use for speed, retries, user corrections, completion rate, prompt/context size, frozen states, and related quality signals; weak improvements should be reverted or archived.
5. One command palette/search. Prefer a fast "Find anything" surface over more tabs, covering Telegram config, memory hygiene, provider settings, the capability index, approvals, Doctor, logs, and skills.
6. Agent's operating map. Agent should always have a compact manifest of what she can do, what she is allowed to do, what she recently learned, what is broken/disabled, and what she can build if needed. This must be a tight manifest, not giant context.

Current implementation anchor: `/v1/coordination/summary` is the compact readout for these lanes, `/v1/command/palette` and `/v1/command/search` are the find-anything manifest (HTTP surface retired Wave 15, 2026-06-01; the Swift-native `CommandPalette` module — `commandPaletteResponse` / `searchCommandPalette` in `Modules/NativeAgentCore/Sources/CommandPalette/CommandPalette.swift` — is the sole live path), `/v1/router/plan` is the intent-classification entry point, `/v1/improvements/maturity` is the self-upgrade gate readout (HTTP surface retired Wave 16, 2026-06-01; readout still produced internally for `/v1/command/summary`), `/v1/connectors/proof` is the connector truth ledger, `/v1/multimodal/status` is the screen/photo/file/voice readiness map, and `/v1/mac-assistant/status` is the access/readiness map for Mac assistant watch setup. These surfaces must stay lazy and manifest-routed; they should not become prompt-mass injection paths.

## Current Architecture

- Mac app: SwiftUI app in `Sources/NativeAgentApp`, built as a Swift package and installed with `script/install_app.sh` to `~/Applications/NativeAgent.app`.
- Runtime: in-process Swift-native services owned by `NativeAgent.app`. There is no live external interpreter backend or launchd-owned agent runtime. Historical external-runtime wording may remain only in audits, compatibility tests, migration comments, cleanup checks, or legacy wire-type names. Missing behavior must be implemented in Swift or fail closed with an explicit Swift error.
- Shared models: `Modules/NativeAgentShared`.
- iOS app: `iOS/NativeAgentMobile`, Xcode project plus SwiftUI sources.
- iCloud bridge:
  - Chat uses signed Drive messages in `outbox/ios` and `outbox/mac`.
  - Mac forwards iOS chat directly into Swift `ChatOrchestration`.
  - Action/control sync uses signed `inbox/` actions and `responses/`.
  - Snapshot sync should keep core cockpit state fresh while pacing large readouts. Heavy snapshots such as knowledge graph, full capability inventory, operating map, and coordination summary should not be fetched and rehashed every short timer tick unless startup, a mutation, or an explicit heavy refresh needs them.
  - iOS screens should use targeted snapshot readers for tab-specific refreshes instead of decoding the whole snapshot bundle when only Workshop, health, trust, providers, settings, activity, inbox, or memory state is needed.
  - Snapshot writers should only wake remote clients when snapshot content actually changed. Digest-deduped no-op ticks should not touch `snapshot_updated`.
- Notifications: APNS path exists and can send real iPhone push notifications.
- Local agent bridge: NativeAgent owns one loopback bearer-auth bridge for local agent CLIs. It prefers `127.0.0.1:8771`, advances through consecutive ports when occupied, and finally accepts an OS-assigned loopback port; clients discover the selected URL and token from the mode-`0600` `~/.config/claude-bridge/bridge.json` descriptor instead of guessing. `/claude/*` and `/codex/*` expose state/message/tool/events to Claude Code/Claude and Codex through the same token and read-only bridge gate. Agent may call back through audited subprocess tools (`invoke_claude`, `invoke_codex`) or async note tools (`claude_message`, `codex_message`). `codex_message` wakeups should start a fresh persisted Codex app-server thread by default so Agent's handoff is worked in a clean Codex session; pinned-thread targeting is only an explicit override. A wakeup is not considered complete merely because Codex accepted a turn; a reply watcher must deliver Codex's final answer back into Agent's NativeAgent session, with receipts, so asynchronous Codex work can continue by explicit follow-up messages rather than hidden thread history.
- Scheduler: Swift background loops and scheduler job records, with agent-visible creation tools and selectable notification delivery channels.
- Mac assistant watch setup: email/calendar/reminder watch jobs should start from compact access manifests and scheduler templates, not hidden background setup. Rendering readiness must not create jobs; actual jobs go through explicit scheduler actions and receipts.
- Memory: Memory Engine v2 now has vault/provenance/hygiene, lifecycle decay/currentness, correction lineage, BM25 lexical retrieval, and graph/semantic blended scoring. MemoryV2 owns the generated `persona/USER.md` projection; persona writers, persona scaffolding, training promotion, and install scripts must not directly author USER.md or recreate `data/persona/Agent` / `data/memory/USER.md` shadows. Memory prose shown to Agent should be clean fact text: timestamps, sources, regenerated counters, first_seen/last_seen, and KG bookkeeping stay as structured metadata unless the date is part of the fact itself, such as a schedule or milestone. Explicit owner cleanup from Mac or paired iOS should apply directly with tombstone/provenance receipts, while agent-initiated memory admin changes use the approval queue and remain resolvable from the signed iOS cockpit. Keep pushing toward better contradiction handling, long-term fact distillation, and retrieval quality without bloating chat context.
- Chat continuity: Mac, iOS, Telegram, Slack Socket Mode, and autonomy chat surfaces should share a small persisted per-session continuity card under app data. The card is deterministic and cheap: initial user anchors, bounded user-set continuity anchors from later in the session, latest user text, assistant tail, open loop, recent correction/callout, verification-sensitive claims, and last verified results. It is orientation only, not durable memory or a new instruction source. Full transcripts remain in chat JSONL and are recalled lazily through session search when needed.
- Resident turn admission: the existing deterministic route may expose a small closed tool group before the first provider call when the request itself proves the need. That readiness is request-scoped, intersected with the exact surface policy, and cannot activate a durable tool, bypass TrustCenter, choose an effect, or certify an outcome. Keep `tool_catalog` compact by default and retain a full diagnostic view; do not spend a model round trip rediscovering a capability that resident state already knows is required.
- Harness: Agent should have lightweight startup context, current time awareness, lazy capabilities, completion discipline, and automatic improvement loops gated by evals, diff proof, post-promote verification, receipts, and rollback evidence. Expensive live behavior checks should run through Swift-native smoke or chat-drive harness paths that use the real chat/provider/tool loop without adding cost to normal tests.
- Harness learning: low-risk promoted learning should auto-implement into lightweight runtime artifacts, surface an implementation receipt, then prove itself through later matched runs before becoming permanent; weak learning is archived.
- Connectors: scaffolded OAuth is not enough to call a connector real. GitHub, Gmail, and Calendar must carry fresh non-dry account proof before non-status actions can run; token-only states stay `connected_unverified` / `needs_probe`.
- Multimodal: direct photos, screen analysis, file ingest, and voice should route through compact readiness maps and policy gates. Screen pixels and attachment bodies load only through explicit user action or a routed need, never as background prompt mass.
- Dream cycle: nightly dreams are a slow-path learning surface. The app-owned scheduler job and `DreamCycleRunner` are the only unattended dream writers; retired compatibility loops must delegate to that runner or do no work. Diary prose stays out of hot chat context; high-signal dream reflections may stage pending memory proposals, add provisional persona growth notes, and leave harness receipts after dedupe/sensitivity checks.
- Autonomy Command Center: Mac Command Center should show the compact autonomy picture across proactive ideas, harness learning, the capability index, self-improvement, promotion standards, and unified policy gates without adding another tab or hot-context inventory load.
- Proactive autonomy: idea selection should learn from the outcome ledger. Useful/archive outcomes can raise a kind's score, repeated dismissals should quiet it, repeated no-op/bounded/failed Act outcomes should hard-cool the kind even when noisy `notifyAll` scans are enabled, and repeated unresolved notifications should be cooled down. Safe inbox maintenance may summarize noisy autonomy cards, archive stale/superseded duplicate app-owned cards, clear resolved dirty-main receipts once the repo is clean again, and backfill outcome feedback; it must not hide approvals, the newest actionable duplicate, external sends, shell work, or file mutation. User-surfaced proactive cards should be concrete enough to offer an Act path that quickly acknowledges the user, records a neutral request outcome, and starts the next safe gated step. Known safe suggested actions should route to compact app-owned handlers before using chat, so Act does useful work without spending tool turns rediscovering the obvious handler. Act handling must be idempotent for repeated mobile taps, and only useful completed follow-ups should count as useful; bounded, failed, or no-op follow-ups should stop cleanly and teach the idea loop that the card did not produce enough value. Final Act outcomes should push a compact iPhone receipt so the user sees what the tap produced, while the initial `act_requested` stays ledger-only. Recursive/meta idea prompts stay in shadow readouts rather than creating notifications. The explanation lives in compact decision rationales and readouts, not prompt mass.
- Provider tool results should pass through the shared NativeAgent fast tool gateway before any model sees them. The gateway applies app-wide surface budgets to Mac chat, iOS chat, Telegram, autonomy, swarms, and streaming/non-streaming turns; large external web/browser/search/email-style payloads are compressed into source/hash/preview envelopes with a narrow-refetch hint rather than fed back as bulk text. This is NativeAgent's local equivalent of a managed tool gateway: deterministic, cheap, prompt-injection aware, and shared across every chat surface.
- Swarms are temporary fan-out, not another agent tier. Their default brain comes from the canonical Swarms provider selection. Read-only reasoning stays the cheap default; tool-capable workers must reuse the existing ephemeral tool loop and preserve the parent surface/session authority under TrustCenter, workspace, receipt, and verification gates. They may not recursively delegate or own app lifecycle.
- UI readouts should batch independent runtime reads and cache stable manifest summaries where possible. The goal is fewer repeated local scans and less manifest recomputation, without hiding mutations or removing direct detail paths.

## Current UX Priorities

- iOS chat must stay visually stable while typing, streaming, or showing progress updates.
- iOS should show lightweight live activity while Agent is working: received, thinking, attachment reading, tool/action progress where available.
- Mac and iOS controls should converge around a single policy model: model, think level, file/Mac access, autonomy, remote permissions.
- Tabs should be consolidated into clear surfaces. Current Mac primary shell is Chat, Activity, Memories, Skills, Command Center, and Settings, with feature-specific controls behind Advanced/search. Current iOS shell is Chat, Activity, Memories, Skills, and More.
- Doctor should remain non-LLM by default and capable of opening OAuth login paths when auth breaks.
- Autonomy visibility should favor one command readout over separate proposal queues: what is running, what is provisional, what became permanent, what needs approval, and which policy gate is responsible.

## Guardrails For Future Work

- Do not add always-loaded prompt mass for tools, skills, or memory. Add a manifest, router, index, or compact hint instead.
- Do not infer current architecture from historical external-runtime vocabulary. Those words are legacy compatibility/audit markers only; the live runtime is Swift in `NativeAgent.app`.
- Do not preinstall broad plugin piles. Treat plugins as reviewed, signed, task-justified capability packs composed of skills, tools, MCP definitions, workflows, or panels.
- Do not let Developer Mode erase the safety floor. Shell/file actions from chat, iOS, Telegram, connector actions, and generic dispatch must hit the same validator before approval or execution.
- Do not mark connector integrations as real because a token exists. Require a live account/status proof and keep the proof visible through compact readouts.
- Do not create duplicate process stacks. Clean up local `node`, `xcodebuild`, simulator, MCP, bridge, or other helper processes started by the task. Do not start an external interpreter runtime for NativeAgent behavior.
- Do not create duplicate state roots. USER memory belongs in MemoryV2 SQLite plus the generated active `persona/USER.md` projection; avoid parallel `data/persona/Agent`, `data/memory/USER.md`, installer seed copies, or persona-tool writes that can diverge from that source.
- Do not put machine chronology into Agent-facing memory prose. Keep created/updated/indexed/first_seen/last_seen values in SQLite/KG/receipts for sorting and audit, but strip them from USER.md, recall snippets, and automatic memory proposals unless the date is semantically important to the fact.
- Do not leave the working tree dirty unless the user explicitly asks to pause before commit.
- Do not hardcode local agent/user identity into public defaults, bundled resources, launch labels, or generic templates.
- Do not ship live runtime state, live persona files, test artifacts, API/OAuth tokens, private keys, or secret-shaped values in release bundles. Release artifacts should be a blank slate that onboards the user into their own local config.
- Use `rg` for repo search and `apply_patch` for manual edits.
- For Mac/iOS changes, run targeted builds. Use an available simulator name from `xcodebuild -list` if generic `name=Any` fails.
- Prefer fixing root causes over adding fallback loops that hide broken state.

## Verification Baseline

Use the narrowest relevant checks during iteration, then broaden before commit:

- Shared package: `swift build --package-path Modules/NativeAgentShared`
- Core package full sweep: `swift test --package-path Modules/NativeAgentCore --no-parallel`
- Mac app package: `swift build`
- iOS simulator build: `xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj -scheme NativeAgentMobile -destination 'platform=iOS Simulator,OS=26.4.1,name=iPhone 17 Pro Max' build`
- Swift smoke sweep: `./script/smoke_all.sh`
- Full repo check: `./script/test.sh`
- Install/restart Mac app: `./script/install_app.sh`
- Swift-only checks: tracked source scan, working-tree retired-script scan outside generated/runtime caches, installed-app artifact scan, and retired-runtime process scan.

## Update Rule

When a session changes direction, architecture, major behavior, or priorities:

1. Update this file.
2. Update `docs/ARCHITECTURE_BLUEPRINT.md` when architecture ownership, source maps, state roots, or policy chokepoints change.
3. Update `docs/HANDOFF_CURRENT.md`.
4. Commit the docs with the related code or as a dedicated handoff commit.
