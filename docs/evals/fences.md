# Eval-coverage fences (phase 0, 2026-08-23)

One read-only inventory worker per fence; a second (critic) worker per fence hunts what the first missed. Paths are relative to the repo. `Core` = Modules/NativeAgentCore/Sources.

| id | scope |
|---|---|
| core.chat.engine | Core/ChatOrchestration — turn engine, tool loop, streaming, text-compat loop, turn planning, autonomy gate, provider admission |
| core.chat.tools | Core/ChatOrchestration — SwiftToolDispatcher family (+ToolCatalog/+Sandbox/+SchemaBuilders/+PersonaTools/+MemoryTools/+SwarmTools/+Dispatch), ConnectorActionsRegistry, tool manifests, reserved names |
| core.chat.persistence | Core/ChatOrchestration — message persistence, session history, compaction, turn trace emitters (ContextStageTrace, TurnContextSnapshotTrace), factories |
| core.substrate.affect | Core/CognitiveSubstrate — affect, appraisal (lexical + semantic), mood/disposition, felt fingerprint, capsule + cue authoring, delivery envelope, sound echo, settling |
| core.substrate.field | Core/CognitiveSubstrate — continuity field/workspace, thought seeds, reflection, standing views, attention signals, serialization, deadlines, GC, persistence |
| core.substrate.organism | Core/CognitiveSubstrate/Organism + Core/DreamREMCycle + organism/somatic adapters |
| core.persistence | Core/PersistenceCore — data-root resolution, file locks, TurnTrace persist lane, stores, hermetic seams |
| core.providers | Core/ProviderRouting — router, surface pins, adapters (all), coercion/substitution, LLM call telemetry, catalogs, vitals sensor |
| core.memory | Core/MemoryV2 + Core/KnowledgeGraph — stores, promotion, proposals, hygiene, KG index, tombstones, epochs |
| core.context | Core/Context + ContextSelectionABHarness — fluid context, selection, budgets, attention → context, packet assembly |
| core.trust | Core/TrustCenter — autonomy tiers, gates, security center classification, approvals wiring (INVENTORY ONLY — no changes) |
| core.telegram | Core/TelegramBot — commands, media ingest, approvals, delivery, offsets/state |
| core.maccontrol | Core/MacControl + Core/VisionPerception + Core/ScreenVision + Core/MacIntegration + Core/MacAssistantStatus — look/act/four verbs, hands, renderer, wake, attention, operations log |
| core.workshop | Core/WorkshopExecution + Core/WorkflowOrchestration + Core/TriggerScheduler — runner, planner, missions, workflows, scheduler, due-job integrity |
| core.loops | Core/BackgroundLoops + Core/SelfImprovement — loop scheduler, each loop's state/failures, weekly self-improvement, heartbeat |
| core.activity | Core/ActivityWatch + ActivityProbeCLI — spans, store, firewall, probes |
| core.connectors | Core/GitHubConnector + XConnector + SlackConnector + Connectors + Research + Browser — auth stores, tracking, commands, receipts |
| core.toolexec | Core/MCPDispatcher + ToolExecution + ToolRegistry + Dispatcher + Skills + Onboarding + MultimodalTTS + SwarmRuns — registries, MCP hub, file-system actions, skills index, swarm runs |
| core.misc | Core/NativeAgentCore + ApprovalInbox + NotificationInbox + SystemOps + DoctorChecks + PersonaEngine + NativeAgentEvaluation + CLIs (ChatDrive, DeskSweepCLI, TaskLedgerCLI) |
| app.chat | Sources/NativeAgentApp — ChatView, ChatHeader/MessageList/QueuedTurns/CodeBlock, DetachedChatPanel*, SessionDragSource, ContextReceiptView, InspectorView, TurnInspector*, command palette |
| app.desk | Sources/NativeAgentApp — DeskView, DeskNagsPanel, InboxView, InboxSettingsView, ApprovalsView, WorkshopHubView, WorkshopObservatoryPanel, RunsView, SchedulerView |
| app.mind | Sources/NativeAgentApp — CognitionObservatoryView, CognitionProposalsView, ContextFlowObservatoryPanel, DreamsView, PersonalityView, MemoryView, KnowledgeGraphView, SelfImprovementView, LivingStatusPanel |
| app.settings | Sources/NativeAgentApp — ProviderSettingsView, SlimSettingsView, TrustCenterView, SecurityCenterPanel, CapabilitiesView, ToolsView, SkillsToolsView, SkillLifecycleView, MCPHubView, ConnectorsView, ConnectorWizardView, TelegramView, StatusView, DoctorView, DiagnosticsView |
| app.mac | Sources/NativeAgentApp — MacIntegrationView, MacControlPermissionsView, MacPairingView, MacAssistantWatchSetupView, ActivityView, ActivityCapturePermissionsView, BrowserWindow, ResearchView, ContentView/navigation, menu bar/status item, Update |
| app.runtimes | Sources/NativeAgentApp — NativeCognitionRuntime*, NativeClient*, AppChatToolDispatcher, AppModel, turn presentation kernel, voice/TTS |
| app.bridges | Sources/NativeAgentApp — MacSyncEngine*, iCloudBridge, ClaudeBridge, MacControlBridge, Codex bridge, Slack/Telegram app glue, push delivery |
| app.background | Sources/NativeAgentApp — BackgroundLoopsAssembly*, scheduler glue, self-restart, updater, Sparkle, doctor glue, lifecycle |
| ios.screens | iOS/NativeAgentMobile — the 18 screens (Chat, Desk, Inbox, Memory, Workshop, Activity, Approvals, Autonomy, Pairing, Providers, Skills, MacTools, MacIntegration, KnowledgeGraph, TurnInspector, Advanced, Content, SkillLifecycle) |
| ios.sync | iOS/NativeAgentMobile — pairing, CloudKit/KVS sync, snapshots, push, remote actions; Modules/NativeAgentShared |
| relay | Sources/NativeAgentChromeRelay + NativeAgentChromeRelayCore — extension relay, browser IPC |
| feeds | data/ — every feed family the instrument's reach walk lists (covered + uncovered): writer module, reader eval, retention; plus traces/events.jsonl + turn_traces event kinds and schemas |
| turn.contract | what MUST be in every chat turn (persona docs, capsule, recall, tools, REM pins, history, hints, posture) and where each is traced (context.summary counts/flags, stageMs.*, llm.call, tool.dispatch, turn.terminal); the speed stages and a per-stage budget; existing TurnReplayBench + instrument (f) |
| scripts | script/ + tests/scripts — every check/eval/smoke/gate/install/release script: what it asserts, what it only prints |
| turn-regression | the END-TO-END turn regression harness (2026-09-02): the invariants that broke silently this week, asserted against an assembled turn rather than one organ. Modules/NativeAgentCore/Tests/ChatOrchestrationTests/TurnRegression, Modules/NativeAgentCore/Tests/CognitiveSubstrateTests/TurnRegression, tests/NativeAgentAppTests/TurnRegression |
