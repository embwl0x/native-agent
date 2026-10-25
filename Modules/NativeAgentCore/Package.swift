// swift-tools-version:6.1
import Foundation
import PackageDescription

// Blueprint: | `Package.swift` | Core package products, target boundaries and direct dependencies, including the runtime-gated ActivityWatch target |

let subsystems: [String] = [
    "EngineRuntime",
    "Privacy",
    "GrokLink",
    "PersistenceCore",
    "Experiences",
    "AuthoredCapabilities",
    "Desk",
    "Studio",
    "Senses",
    "TurnTrace",
    "Transcripts",
    "Procedures",
    "StandingBots",
    "ApprovalInbox",
    "ApprovalTransactions",
    "ToolRegistry",
    "PersonaEngine",
    "DoctorChecks",
    "ChatTurnRuntime",
    "ChatTurnContracts",
    "ChatToolRuntime",
    "AgentConversations",
    "ChatSessionWork",
    "AgentWorkspace",
    "ChatToolParsing",
    "AgentLinkTransport",
    "CognitiveSubstrate",
    "MemoryV2",
    "DreamREMCycle",
    "TrustCenter",
    "TrustPersistence",
    "TelegramBot",
    "SlackBot",
    "ChromeControl",
    "Agents",
    "Cognition",
    "DeviceSync",
    "AttentionRouting",
    "AppToolRuntime",
    "ProviderRouting",
    "BackgroundLoops",
    "BackgroundWork",
    "ToolExecution",
    "Research",
    "TriggerScheduler",
    "SchedulerExecution",
    "SystemOps",
    "Dispatcher",
    "MacControl",
    "ScreenVision",
    "Onboarding",
    "WorkshopExecution",
    "WorkflowOrchestration",
    "NotificationInbox",
    "Connectors",
    "SwarmRuns",
    "Browser",
    "Context",
    "ContextFlow",
    "MultimodalTTS",
    "MacIntegration",
    // Ambient activity watcher (W7/W8, 2026-08-14). Was fenced behind
    // NATIVEAGENT_DEV_ACTIVITY_PROBE=1 for the dev-only v0; the fence is LIFTED
    // now that the feature ships in-app. The compile-time guarantee it provided
    // ("this code cannot exist in a build") is replaced by a RUNTIME one that
    // is structurally enforced rather than conventional:
    //   * `ActivityWatcher.start()` installs no AX observer, no NSWorkspace
    //     observer and no lock observer, and opens no span, unless the Trust
    //     Center policy's `captureEnabled` is true;
    //   * the policy defaults to false and an unreadable/missing policy file
    //     decodes to false, so a fresh install captures nothing;
    //   * a policy flipped to false at runtime tears the observers down on the
    //     next capture-thread hop rather than at the next restart.
    // ActivityWatchArchitectureTests pins all of that, plus the egress
    // enumeration (no context assembly, no memory promotion, no sync/backup).
    "ActivityWatch",
]

let products: [Product] =
    [.library(name: "NativeAgentCore", targets: ["NativeAgentCore"])]
    + subsystems.map { .library(name: $0, targets: [$0]) }
    + [.library(name: "NativeAgentChromeRelayCore", targets: ["NativeAgentChromeRelayCore"])]
    + [.executable(name: "task-ledger", targets: ["TaskLedgerCLI"])]

// Direct dependencies between subsystem libraries. NativeAgentCore runtime
// support is common to every target; disk owners also depend on PersistenceCore.
// Keep edges needed for extension visibility even without a direct source import.
let extraDeps: [String: [String]] = [
    "AgentConversations": ["Experiences", "AuthoredCapabilities", "AgentWorkspace", "MacControl", "Privacy", "PersistenceCore", "ApprovalInbox", "StandingBots", "AgentLinkTransport", "ProviderRouting", "GrokLink", "TurnTrace", "ChatTurnContracts", "Desk", "TrustCenter"],
    "ChatTurnContracts": ["PersistenceCore", "ProviderRouting", "TurnTrace", "ApprovalInbox", "ChatToolParsing", "CognitiveSubstrate", "MacControl"],
    "ChatToolRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "ChatTurnContracts", "AgentConversations", "AgentWorkspace", "ChatSessionWork", "ChatToolParsing", "Research", "StandingBots", "PersistenceCore", "PersonaEngine", "MemoryV2", "ProviderRouting", "TrustCenter", "DreamREMCycle", "ApprovalInbox", "Dispatcher", "MacControl", "Context", "SwarmRuns", "MacIntegration", "WorkshopExecution", "SystemOps", "CognitiveSubstrate", "ToolExecution", "ActivityWatch", "ToolRegistry", "Procedures", "Transcripts", "TurnTrace", "Studio", "Desk", "ChromeControl", "GrokLink", "Privacy", "NotificationInbox"],
    "AgentWorkspace": ["Experiences", "AuthoredCapabilities", "ChatSessionWork", "PersistenceCore", "ApprovalInbox", "MacControl", "MemoryV2", "ChromeControl", "Desk", "StandingBots", "WorkshopExecution", "MacIntegration", "Transcripts", "NotificationInbox", "Senses", "SwarmRuns"],
    "ChatSessionWork": ["Experiences", "MemoryV2", "MacControl", "Context", "PersistenceCore", "Transcripts", "TurnTrace", "ProviderRouting", "ChatToolParsing"],
    "ChatToolParsing": ["MacControl", "PersistenceCore", "TurnTrace"],
    "AgentLinkTransport": ["PersistenceCore", "ProviderRouting"],
    "EngineRuntime": ["ActivityWatch", "Experiences", "AuthoredCapabilities", "AgentWorkspace", "ChatSessionWork", "TurnTrace", "Privacy", "Senses", "Agents", "AppToolRuntime", "ApprovalInbox", "ApprovalTransactions", "AttentionRouting", "BackgroundLoops", "BackgroundWork", "Browser", "ChromeControl", "Cognition", "CognitiveSubstrate", "Connectors", "Context", "ContextFlow", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "GrokLink", "MemoryV2", "MacIntegration", "MacControl", "NotificationInbox", "PersistenceCore", "PersonaEngine", "Procedures", "ProviderRouting", "Research", "SchedulerExecution", "SystemOps", "SlackBot", "StandingBots", "TelegramBot", "ToolExecution", "ToolRegistry", "Transcripts", "TriggerScheduler", "TrustCenter", "TrustPersistence", "WorkshopExecution", "Onboarding", "Dispatcher", "AgentConversations", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Studio", "SwarmRuns", "WorkflowOrchestration"],
    // Approval transactions compose canonical owners; host effects arrive through ports.
    "ApprovalTransactions": ["Experiences", "AuthoredCapabilities", "Procedures", "AgentWorkspace", "ApprovalInbox", "Browser", "Cognition", "Desk", "Dispatcher", "DreamREMCycle", "PersistenceCore", "MacControl", "MacIntegration", "MemoryV2", "PersonaEngine", "Privacy", "ProviderRouting", "Studio", "TelegramBot", "TrustCenter", "TurnTrace", "WorkshopExecution", "Transcripts", "AgentConversations", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox", "ToolRegistry"],
    // Tool policy composes the existing owners; UI and platform effects arrive through ports.
    "AppToolRuntime": ["TurnTrace", "AgentWorkspace", "Experiences", "AuthoredCapabilities", "MultimodalTTS", "Senses", "Agents", "ApprovalInbox", "ApprovalTransactions", "Desk", "ChromeControl", "Browser", "Cognition", "CognitiveSubstrate", "Context", "MacControl", "Research", "PersistenceCore", "TrustCenter", "WorkshopExecution", "StandingBots", "ToolRegistry", "ToolExecution", "Privacy", "AttentionRouting", "MacIntegration", "PersonaEngine", "ProviderRouting", "DeviceSync", "Dispatcher", "Studio", "DoctorChecks", "TrustPersistence", "MemoryV2", "AgentConversations", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox", "TelegramBot"],

    // The stem's one record of what happened (docs/EXPERIENCE.md), a GRDB
    // store like memory's. It sits this low so every owner of a happening can write it.
    "Experiences": [],
    "AuthoredCapabilities": ["Experiences", "PersistenceCore"],
    "Privacy": ["PersistenceCore"],
    "GrokLink": [],
    // The desk (items, ops, store, nag/notify/observation/cadence, projection)
    // and the cross-agent task ledger that shares its clock, moved out of
    // PersistenceCore (S11).
    "Desk": ["PersistenceCore", "TrustCenter"],
    // Studio works, canon and the working shelf, moved out of PersistenceCore (S11).
    "Studio": ["AuthoredCapabilities", "PersistenceCore"],
    "Senses": ["AuthoredCapabilities", "PersistenceCore"],
    // Turn traces (events.jsonl bus, persist lane, recent reader, redactor),
    // their retention, abandoned-turn reconciliation and session-identity
    // instrumentation, moved out of PersistenceCore (S11).
    "TurnTrace": ["Experiences", "AuthoredCapabilities", "PersistenceCore"],
    // Chat session index, retention, recollections, the conversation anchor,
    // session identity and the Stop marker, moved out of PersistenceCore (S11).
    "Transcripts": ["PersistenceCore", "TurnTrace"],
    // Procedure artifacts, compilation, exact activation and replay, moved out
    // of PersistenceCore (S11). Pure data + its own store; nothing below it.
    "Procedures": ["PersistenceCore"],
    "StandingBots": ["Experiences", "PersistenceCore", "TriggerScheduler", "ApprovalInbox", "Dispatcher"],
    // 2026-09-17: TrustCenter so the resolution-authority check can bind a
    // signed-iOS decision to the card's ORIGIN SURFACE through the canonical
    // `ConversationSurfaceProfile` rather than a second copy of its remote set.
    // No cycle — TrustCenter's closure is PersistenceCore / ToolRegistry and
    // neither depends on ApprovalInbox.
    // Experiences: a filed approval is a decision owed to the person. No cycle.
    "ApprovalInbox": ["AuthoredCapabilities", "ChatToolParsing", "PersistenceCore", "TrustCenter", "Procedures", "Experiences", "Transcripts"],
    "ToolRegistry": ["AuthoredCapabilities", "PersistenceCore", "TurnTrace"],
    "PersonaEngine": ["PersistenceCore", "AuthoredCapabilities"],
    // MemoryV2 owns the canonical memory and graph readers used by Doctor.
    // 2026-07-12: MemoryV2 so CoreMLEmbedderCheck can probe the real
    // bundled-model load path (compile cache + vocab) and repair by wiping the
    // poisoned compile cache. No cycle — MemoryV2 never imports DoctorChecks.
    "DoctorChecks": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "PersonaEngine", "MemoryV2", "TurnTrace", "ProviderRouting", "Desk", "DeviceSyncState", "Transcripts"],
    // Turn engine/client policy composes the lower chat owners. Platform
    // effects still arrive through their existing injected ports.
    "ChatTurnRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "CognitiveSubstrate", "Context", "Desk", "Dispatcher", "DreamREMCycle", "MemoryV2", "MacControl", "MacIntegration", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "Research", "StandingBots", "Studio", "SwarmRuns", "SystemOps", "ToolRegistry", "Transcripts", "TrustCenter", "TurnTrace"],

    "CognitiveSubstrate": ["Experiences", "PersistenceCore", "Studio", "Privacy", "Transcripts", "TurnTrace"],
    // U3w2 item 7: ApprovalInbox so the consolidation gate can stage its
    // swap-on-approve card from inside the module (no cycle — ApprovalInbox
    // depends only on PersistenceCore).
    // 2026-09-13: TrustCenter so every point-of-use policy gate reads saved
    // authority through the ONE predicate (SavedTrustPolicyAuthority) that runs
    // TrustCenter's own shape + known-field-type validation. No cycle —
    // TrustCenter's closure is PersistenceCore / ToolRegistry and neither
    // depends on these three.
    "MemoryV2": ["Experiences", "PersistenceCore", "PersonaEngine", "ApprovalInbox", "TrustCenter", "Procedures", "CognitiveSubstrate", "Senses", "ChatTurnContracts", "TurnTrace", "NotificationInbox", "Studio"],
    "DreamREMCycle": ["Experiences", "PersistenceCore", "PersonaEngine", "ProviderRouting", "MemoryV2", "TrustCenter", "Transcripts", "SwarmRuns", "CognitiveSubstrate", "Studio"],

    "TrustCenter": ["Privacy", "AuthoredCapabilities", "PersistenceCore", "ToolRegistry", "PersonaEngine", "WorkflowOrchestration"],
    // Backup/recovery composes existing owners above TrustCenter: MemoryV2
    // and ApprovalInbox already depend on TrustCenter, so it cannot own them.
    "TrustPersistence": ["PersistenceCore", "TrustCenter", "MemoryV2", "ApprovalInbox", "Transcripts", "TelegramBot", "AuthoredCapabilities", "ChatTurnRuntime", "Privacy", "SystemOps"],
    "TelegramBot": ["Experiences", "AuthoredCapabilities", "MacControl", "PersistenceCore", "PersonaEngine", "BackgroundLoops", "ProviderRouting", "ApprovalInbox", "Transcripts", "TurnTrace", "ChatSessionWork", "TrustCenter", "ChatTurnContracts", "ChatTurnRuntime"],
    // Slack Socket Mode surface, with its tokens and its Web API calls.
    // ChatTurnRuntime / ChatTurnContracts for turn ingress;
    // no cycle — only the engine, background work and Connectors' Slack setup import SlackBot.
    "SlackBot": ["AuthoredCapabilities", "PersistenceCore", "BackgroundLoops", "PersonaEngine", "ProviderRouting", "Transcripts", "MacControl", "TrustCenter", "ChatTurnContracts", "ChatTurnRuntime", "TurnTrace"],
    // Chrome control socket, handshake and native-host registration. The
    // relay core is shared with the NativeAgentChromeRelay executable;
    // TrustCenter answers the Chrome control switch. ChatToolRuntime reads
    // only its connection mirror (the home screen's Chrome line).
    "ChromeControl": ["PersistenceCore", "TrustCenter", "NativeAgentChromeRelayCore", "MacControl", "Transcripts"],
    // Agent contacts: A2A wire and tasks, peer identity and replay claims, the
    // desktop and Grok routes, completion delivery and the reply/notice
    // continuation. Chat turns come through the engine root's clients; nothing
    // imports it back.
    "Agents": ["Experiences", "AgentLinkTransport", "AgentWorkspace", "Cognition", "CognitiveSubstrate", "Context", "ContextFlow", "Procedures", "PersistenceCore", "ProviderRouting", "ApprovalInbox", "TrustCenter", "PersonaEngine", "StandingBots", "BackgroundLoops", "MacControl", "GrokLink", "Privacy", "Transcripts", "ToolExecution", "AgentConversations", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Desk", "Senses", "ToolRegistry", "TurnTrace"],
    // The resident mind's runtime: cognitive events and capsule, provider
    // lifecycle, organism posture, motor-outcome evidence, reflection, dream
    // pressure and the horizon. The engine root owns the instance and hands it
    // the root's ContextFlow; the app's platform pieces come through
    // CognitionHost. Nothing imports it back.
    "Cognition": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "CognitiveSubstrate", "Context", "ContextFlow", "MemoryV2", "PersonaEngine", "ProviderRouting", "BackgroundLoops", "ApprovalInbox", "TriggerScheduler", "NotificationInbox", "DreamREMCycle", "TurnTrace", "Studio", "Desk", "Privacy", "AgentConversations", "AgentWorkspace", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Transcripts"],
    // Mac-side device sync: the CloudKit/KVS bridge, snapshot projection, the
    // phone's signed inbox actions, pairing and APNs. The engine root owns the
    // instance and hands it the root's mind; what it reads from the app's
    // mirrors comes through DeviceSyncHost. Nothing imports it back.
    "DeviceSync": ["Experiences", "MacControl", "PersistenceCore", "CognitiveSubstrate", "Cognition", "MemoryV2", "ApprovalInbox", "NotificationInbox", "ProviderRouting", "MacIntegration", "TrustCenter", "WorkshopExecution", "PersonaEngine", "Transcripts", "Desk", "Privacy", "DeviceSyncState", "TriggerScheduler", "AgentConversations", "TurnTrace", "BackgroundLoops", "ChatSessionWork", "ChatToolParsing", "ChatTurnContracts", "ChatTurnRuntime", "ToolRegistry"],
    "AttentionRouting": ["Experiences", "Privacy", "PersistenceCore", "DeviceSync", "TelegramBot", "Desk", "TriggerScheduler", "NotificationInbox", "ApprovalInbox", "StandingBots", "Transcripts", "AgentWorkspace", "ChatTurnContracts", "ChatTurnRuntime"],
    "ProviderRouting": ["Experiences", "PersistenceCore", "TurnTrace", "Privacy"],
    "BackgroundLoops": ["PersistenceCore"],
    // Cross-domain runner bodies sit above their domain owners; the scheduler
    // stays dependency-light and remains the only registration/single-flight owner.
    "BackgroundWork": ["ToolExecution", "Experiences", "SlackBot", "ActivityWatch", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "AttentionRouting", "BackgroundLoops", "Cognition", "CognitiveSubstrate", "Context", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "MemoryV2", "NotificationInbox", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "StandingBots", "TelegramBot", "ToolRegistry", "TriggerScheduler", "TrustCenter", "TurnTrace", "WorkshopExecution", "ChatSessionWork", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime"],
    "ToolExecution": ["AuthoredCapabilities", "Senses", "PersonaEngine", "PersistenceCore", "TrustCenter", "ToolRegistry", "Desk", "MacControl", "ProviderRouting", "Privacy"],
    "Research": ["PersistenceCore", "Privacy", "MacControl", "ProviderRouting"],
    "TriggerScheduler": ["Experiences", "PersistenceCore", "WorkshopExecution", "Desk", "ActivityWatch", "Privacy", "NotificationInbox", "TrustCenter"],
    // Due-job execution composes owners that already depend on TriggerScheduler.
    "SchedulerExecution": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "TriggerScheduler", "AttentionRouting", "DeviceSync", "DreamREMCycle", "TelegramBot", "NotificationInbox", "Privacy", "BackgroundWork", "AppToolRuntime"],
    "SystemOps": ["PersistenceCore", "TrustCenter"],
    "Dispatcher": ["ChatToolParsing", "PersonaEngine", "Experiences", "AuthoredCapabilities", "Senses", "PersistenceCore", "MacControl", "TrustCenter"],
    // TrustCenter owns the Mac Control gate and injection vocabulary (S9);
    // MacControl reads them. No cycle — TrustCenter imports no executor.
    "MacControl": ["Experiences", "Senses", "PersistenceCore", "TrustCenter"],
    "Onboarding": ["PersistenceCore", "PersonaEngine", "MemoryV2"],

    "WorkshopExecution": ["ChatTurnContracts", "PersistenceCore", "ProviderRouting", "ApprovalInbox", "TrustCenter", "Procedures", "Desk", "SwarmRuns", "Privacy", "CognitiveSubstrate", "ToolRegistry", "MacIntegration"],
    // 2026-09-01: the workflow RUN engine was retired (User authorized). What is
    // left is the workflow registry (list + create), which reads and writes one
    // JSON file. Every execution-side dependency — ApprovalInbox, TrustCenter,
    // MCPDispatcher, MemoryV2, Research, SystemOps, ToolExecution — went with
    // the engine that used them.
    "WorkflowOrchestration": ["PersistenceCore", "Privacy"],


    "NotificationInbox": ["PersistenceCore", "ApprovalInbox", "Desk"],
    "Connectors": ["AuthoredCapabilities", "PersistenceCore", "Privacy", "MacIntegration", "ProviderRouting", "TrustCenter", "ApprovalInbox", "ApprovalTransactions", "SlackBot", "TriggerScheduler", "MacControl", "AppToolRuntime", "DeviceSync", "AttentionRouting", "TelegramBot", "ChatToolRuntime", "ToolExecution"],
    "SwarmRuns": ["Experiences", "PersistenceCore", "TurnTrace", "ToolExecution", "Privacy"],
    "Browser": ["PersistenceCore", "Privacy", "ApprovalInbox"],
    "Context": ["PersistenceCore", "TrustCenter", "PersonaEngine"],
    // The live ContextFlow owner: turn preparation, settled-tool prewarm,
    // memory-record → atom-id translation, and the memory, resident-work,
    // Knowledge Graph, Studio and persona projections it compiles. The engine
    // root owns the instance; nothing in core imports it back.
    "ContextFlow": ["PersistenceCore", "Context", "MemoryV2", "PersonaEngine", "DreamREMCycle", "WorkshopExecution", "TurnTrace", "Studio", "Desk", "Senses"],
    // Subsystem #28 wave 35 W18 — SwiftNative POST /v1/multimodal/tts port.
    // Depends on ProviderRouting for LLMCredentialResolver (the OpenAI platform
    // key resolver that landed with the chat cutover — the dep that lifts the
    // wave-34 "Swift secret layer" blocker), PersistenceCore for defaultDataRoot(),
    // and TrustCenter for checked saved multimodal authority (default OFF).
    "MultimodalTTS": ["ProviderRouting", "PersistenceCore", "TrustCenter"],
    // MacIntegration — per-integration READ/WRITE permission gating for the
    // Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
    // Notifications / Spotlight / Scheduler surface. PersistenceCore for
    // flocked atomic JSON IO of mac_integration_permissions.json.
    "MacIntegration": ["AuthoredCapabilities", "PersistenceCore", "MacControl", "TrustCenter"],
    // Ambient activity watcher — PersistenceCore for defaultDataRoot() and
    // atomic policy IO; MacControl for MacScreenViewTextRedaction, the SHARED
    // secret redactor every captured window title passes through (W5). We reuse
    // it rather than writing a second redactor: two copies drift, and the copy
    // that drifts is the one nobody re-reviews. No cycle — MacControl depends
    // only on PersistenceCore and TrustCenter. ChatToolRuntime reaches ActivityWatch through
    // one pinned query adapter, and the Mac app owns the capture lifecycle.
    "ActivityWatch": ["Experiences", "PersistenceCore", "MacControl"],

]

// Per-subsystem direct external (Swift Package) product dependencies.
let externalDeps: [String: [Target.Dependency]] = [
    "AgentConversations": [.product(name: "Yams", package: "Yams")],
    "AgentLinkTransport": [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
    ],
    "Agents": [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "NativeAgentShared", package: "NativeAgentShared"),
    ],
    "CognitiveSubstrate": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Experiences": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Context": [.product(name: "GRDB", package: "GRDB.swift")],
    "MemoryV2": [.product(name: "GRDB", package: "GRDB.swift")],
    "ActivityWatch": [.product(name: "GRDB", package: "GRDB.swift")],
    "AgentWorkspace": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AppToolRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ApprovalInbox": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ApprovalTransactions": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AttentionRouting": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AuthoredCapabilities": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatSessionWork": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatToolParsing": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatToolRuntime": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatTurnContracts": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatTurnRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Cognition": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Connectors": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "DeviceSync": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "EngineRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "MacIntegration": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "NotificationInbox": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "PersonaEngine": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ProviderRouting": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "SwarmRuns": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TelegramBot": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Transcripts": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TrustCenter": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TrustPersistence": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TurnTrace": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
]

let subsystemTargets: [Target] = subsystems.flatMap { name -> [Target] in
    let deps: [Target.Dependency] =
        [.target(name: "NativeAgentCore")] +
        (extraDeps[name] ?? []).map { .target(name: $0) } +
        (externalDeps[name] ?? []) +
        (name == "DoctorChecks" ? [.product(name: "NativeAgentShared", package: "NativeAgentShared")] : [])
    // Per-subsystem resources (e.g. MemoryV2 ships the WordPiece vocab).
    let targetResources: [Resource]? = (name == "MemoryV2") ? [
        .process("Resources/minilm_vocab.txt"),
        .copy("Resources/minilm.mlpackage"),
    ] : (name == "AgentConversations") ? [.copy("Resources/grok-routine.json")] : nil
    // WorkshopExecution persists content-addressed identities (procedure
    // shape/schema digests). Transitively visible extension members — e.g.
    // GRDB's SQL interpolation via MemoryV2 — must never participate in type
    // inference there: an inference flip silently hashes an unstable debug
    // description instead of the intended string (2026-08-05 preflight bug).
    let targetSwiftSettings: [SwiftSetting]? = (name == "WorkshopExecution")
        ? [.enableUpcomingFeature("MemberImportVisibility")]
        : nil
    return [.target(
        name: name,
        dependencies: deps,
        path: "Sources/\(name)",
        exclude: name == "DeviceSync" ? ["State"] : [],
        resources: targetResources,
        swiftSettings: targetSwiftSettings
    )]
}

let package = Package(
    name: "NativeAgentCore",
    platforms: [.macOS("26.0")],  // USER 2026-08-16: Liquid Glass floor
    products: products,
    dependencies: [
        // BEGIN generated gRPC requirements (Package.swift; script/sync_build_declarations.rb)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        // END generated gRPC requirements
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Inline interactions (the cards) are ONE value read by three parties
        // that never talk to each other: the core dispatch boundary that
        // raises the need, the Mac app that renders and resolves it, and the
        // phone. The app and the phone already share NativeAgentShared; core
        // joins them rather than keeping a second copy of the type in sync.
        // Shared has no dependencies of its own and a lower platform floor,
        // so this edge adds nothing to the build graph but the module.
        .package(path: "../NativeAgentShared"),
    ],
    targets: [
        // Bookkeeping shared with DoctorChecks without importing the sync runtime.
        .target(name: "DeviceSyncState", path: "Sources/DeviceSync/State"),
        .target(
            name: "NativeAgentCore",
            // Transitive to every subsystem (they all depend on this target),
            // but nothing imports it implicitly: a file sees the type only by
            // writing `import NativeAgentShared`. Subsystems that import it
            // also declare that product directly in externalDeps above.
            dependencies: [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
            path: "Sources/NativeAgentCore"
        ),
        // Dependency-free so the Chrome relay executable stays small.
        // ChromeHostIdentity decides "is this a browser" from the parent's
        // code signature (SecStaticCodeCheckValidity), not from an Info.plist
        // anyone can write.
        .target(
            name: "NativeAgentChromeRelayCore",
            path: "Sources/NativeAgentChromeRelayCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        // Proof tool for the permissions-law phase, not a test suite: prints
        // every tool's and door action's decision under each posture, steer
        // and integration switch, so a change is diffed against a baseline.
        // Nothing the app builds depends on it.
        .executableTarget(
            name: "PermissionsSnapshot",
            dependencies: ["AppToolRuntime", "Agents", "ApprovalInbox", "ApprovalTransactions", "ChatToolRuntime",
                           "ChatTurnContracts", "ChatTurnRuntime", "MacIntegration", "NativeAgentCore", "PersistenceCore",
                           "StandingBots", "ToolRegistry", "TrustCenter", "WorkshopExecution"].map { .target(name: $0) },
            path: "Sources/PermissionsSnapshot"
        ),
        .executableTarget(
            name: "TaskLedgerCLI",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "Desk"),
            ],
            path: "Sources/TaskLedgerCLI"
        ),
    ] + subsystemTargets
)
