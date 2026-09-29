// swift-tools-version:6.1
import Foundation
import PackageDescription

let subsystems: [String] = [
    "EngineRuntime",
    "FeedPolicy",
    "Privacy",
    "GrokLink",
    "PersistenceCore",
    "Desk",
    "Studio",
    "TurnTrace",
    "Transcripts",
    "Procedures",
    "StandingBots",
    "ApprovalInbox",
    "ApprovalTransactions",
    "MCPDispatcher",
    "ToolRegistry",
    "PersonaEngine",
    "DoctorChecks",
    "ChatOrchestration",
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
    "SelfImprovement",
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
    "CommandPalette",
    "SystemOps",
    "Dispatcher",
    "MacControl",
    "ScreenVision",
    // MacVisionPerception v0 (2026-08-22) — the general screen's second half:
    // an AX-BLIND window perceived from PIXELS ONLY, emitting the same
    // MacLookPercept contract the AX lane emits. Pure CGImage → percept; no
    // capture and no mac_look wiring yet, which is what keeps it fully
    // testable headless.
    "VisionPerception",
    "Onboarding",
    "MacAssistantStatus",
    "WorkshopExecution",
    "WorkflowOrchestration",
    "KnowledgeGraph",
    "Skills",
    "NotificationInbox",
    "Connectors",
    "SwarmRuns",
    "Browser",
    "Context",
    "ContextFlow",
    "MultimodalTTS",
    "CapabilityFoundry",
    "XConnector",
    "GitHubConnector",
    "SlackConnector",
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
    + subsystems.filter { $0 != "CapabilityFoundry" && $0 != "SwarmRuns" }.map { .library(name: $0, targets: [$0]) }
    + [.library(name: "NativeAgentChromeRelayCore", targets: ["NativeAgentChromeRelayCore"])]
    + [.executable(name: "task-ledger", targets: ["TaskLedgerCLI"])]

// Per-subsystem extra dependencies on other subsystem libraries. Most
// subsystems depend only on the NativeAgentCore runtime support; subsystems
// that touch disk depend on PersistenceCore for atomic byte-compatible IO.
let extraDeps: [String: [String]] = [
    "AgentConversations": ["AgentWorkspace", "Privacy", "PersistenceCore", "ApprovalInbox", "StandingBots", "AgentLinkTransport", "ProviderRouting", "GrokLink", "TurnTrace", "ChatTurnContracts"],
    "ChatTurnContracts": ["PersistenceCore", "ProviderRouting", "TurnTrace", "ApprovalInbox", "ChatToolParsing", "CognitiveSubstrate"],
    "ChatToolRuntime": ["ChatTurnContracts", "AgentConversations", "AgentWorkspace", "ChatSessionWork", "ChatToolParsing", "Research", "StandingBots", "PersistenceCore", "PersonaEngine", "MemoryV2", "ProviderRouting", "TrustCenter", "DreamREMCycle", "ApprovalInbox", "MCPDispatcher", "KnowledgeGraph", "Dispatcher", "MacControl", "VisionPerception", "Context", "SwarmRuns", "XConnector", "GitHubConnector", "SlackConnector", "MacIntegration", "WorkshopExecution", "SystemOps", "CognitiveSubstrate", "ToolExecution", "Skills", "ActivityWatch", "ToolRegistry", "Procedures", "Transcripts", "TurnTrace", "Studio", "Desk", "ChromeControl", "GrokLink", "Privacy", "FeedPolicy"],
    "AgentWorkspace": ["ChatSessionWork", "PersistenceCore", "ApprovalInbox", "MacControl", "MemoryV2", "ChromeControl", "Desk", "StandingBots", "WorkshopExecution", "MacIntegration", "Transcripts"],
    "ChatSessionWork": ["MemoryV2", "MacControl", "MCPDispatcher", "Context", "PersistenceCore", "Transcripts", "TurnTrace", "ProviderRouting", "ChatToolParsing"],
    "ChatToolParsing": ["PersistenceCore"],
    "AgentLinkTransport": ["PersistenceCore", "ProviderRouting"],
    "EngineRuntime": ["Agents", "AppToolRuntime", "ApprovalInbox", "ApprovalTransactions", "AttentionRouting", "BackgroundLoops", "BackgroundWork", "Browser", "ChatOrchestration", "ChromeControl", "Cognition", "CognitiveSubstrate", "CommandPalette", "Connectors", "Context", "ContextFlow", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "GitHubConnector", "KnowledgeGraph", "MCPDispatcher", "MacAssistantStatus", "MacControl", "MemoryV2", "NotificationInbox", "PersistenceCore", "PersonaEngine", "ProviderRouting", "Research", "SelfImprovement", "SlackBot", "SlackConnector", "StandingBots", "TelegramBot", "ToolRegistry", "Transcripts", "TriggerScheduler", "TrustCenter", "TrustPersistence", "WorkshopExecution"],
    // Approval transactions compose canonical owners; host effects arrive through ports.
    "ApprovalTransactions": ["SelfImprovement", "Procedures", "ApprovalInbox", "Browser", "ChatOrchestration", "Cognition", "Dispatcher", "DreamREMCycle", "FeedPolicy", "MacControl", "MacIntegration", "MemoryV2", "PersistenceCore", "Privacy", "ProviderRouting", "Studio", "TelegramBot", "TrustCenter", "TurnTrace", "WorkshopExecution"],
    // Tool policy composes the existing owners; UI and platform effects arrive through ports.
    "AppToolRuntime": ["Agents", "ChatOrchestration", "ChromeControl", "Browser", "Cognition", "CognitiveSubstrate", "Context", "MacControl", "PersistenceCore", "TrustCenter", "WorkshopExecution", "StandingBots", "ToolRegistry", "Privacy", "AttentionRouting", "MacIntegration", "PersonaEngine", "ProviderRouting", "DeviceSync", "Dispatcher", "Studio", "DoctorChecks", "TrustPersistence", "Skills", "MemoryV2"],
    "PersistenceCore": ["FeedPolicy"],
    "Privacy": ["PersistenceCore"],
    "GrokLink": [],
    // The desk (items, ops, store, nag/notify/observation/cadence, projection)
    // and the cross-agent task ledger that shares its clock, moved out of
    // PersistenceCore (S11).
    "Desk": ["PersistenceCore", "FeedPolicy"],
    // Studio works, canon and the working shelf, moved out of PersistenceCore (S11).
    "Studio": ["PersistenceCore", "Desk", "FeedPolicy"],
    // Turn traces (events.jsonl bus, persist lane, recent reader, redactor),
    // their retention, abandoned-turn reconciliation and session-identity
    // instrumentation, moved out of PersistenceCore (S11).
    "TurnTrace": ["PersistenceCore", "FeedPolicy"],
    // Chat session index, retention, recollections, the conversation anchor,
    // session identity and the Stop marker, moved out of PersistenceCore (S11).
    "Transcripts": ["PersistenceCore", "TurnTrace"],
    // Procedure artifacts, compilation, exact activation and replay, moved out
    // of PersistenceCore (S11). Pure data + its own store; nothing below it.
    "Procedures": ["PersistenceCore"],
    "StandingBots": ["PersistenceCore", "TriggerScheduler", "ApprovalInbox"],
    // 2026-09-17: TrustCenter so the resolution-authority check can bind a
    // signed-iOS decision to the card's ORIGIN SURFACE through the canonical
    // `ConversationSurfaceProfile` rather than a second copy of its remote set.
    // No cycle — TrustCenter's closure is PersistenceCore / ToolRegistry and
    // neither depends on ApprovalInbox.
    "ApprovalInbox": ["PersistenceCore", "TrustCenter", "Procedures"],
    "MCPDispatcher": ["PersistenceCore", "Research", "KnowledgeGraph", "CapabilityFoundry", "TrustCenter", "Privacy"],
    "ToolRegistry": ["PersistenceCore"],
    "PersonaEngine": ["PersistenceCore"],
    // M5 (2026-07-09): KnowledgeGraph so MemoryStoreCheck can validate the real
    // KG store (memory.sqlite kg_entities/kg_relationships) through the existing
    // reader instead of a JSON file nothing reads. No cycle — KnowledgeGraph
    // depends only on PersistenceCore.
    // 2026-07-12: MemoryV2 so CoreMLEmbedderCheck can probe the real
    // bundled-model load path (compile cache + vocab) and repair by wiping the
    // poisoned compile cache. No cycle — MemoryV2 never imports DoctorChecks.
    "DoctorChecks": ["PersistenceCore", "PersonaEngine", "KnowledgeGraph", "MemoryV2", "TurnTrace", "GitHubConnector", "XConnector", "SlackConnector", "ProviderRouting", "Desk", "DeviceSyncState"],
    // Turn engine/client policy composes the lower chat owners. Platform
    // effects still arrive through their existing injected ports.
    "ChatTurnRuntime": ["AgentConversations", "AgentWorkspace", "ApprovalInbox", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "CognitiveSubstrate", "Context", "Dispatcher", "DreamREMCycle", "KnowledgeGraph", "MCPDispatcher", "MacControl", "MacIntegration", "MemoryV2", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "Research", "SlackConnector", "StandingBots", "Studio", "SwarmRuns", "SystemOps", "ToolRegistry", "Transcripts", "TrustCenter", "TurnTrace", "XConnector"],
    "ChatOrchestration": ["ChatTurnRuntime", "ChatTurnContracts", "ChatToolRuntime", "ChatSessionWork", "AgentWorkspace", "AgentConversations", "ChatToolParsing", "AgentLinkTransport"],
    "CognitiveSubstrate": ["PersistenceCore", "Studio", "Privacy"],
    "XConnector": ["PersistenceCore"],
    "GitHubConnector": ["PersistenceCore", "Desk"],
    "SlackConnector": ["PersistenceCore"],
    // U3w2 item 7: ApprovalInbox so the consolidation gate can stage its
    // swap-on-approve card from inside the module (no cycle — ApprovalInbox
    // depends only on PersistenceCore).
    // 2026-09-13: TrustCenter so every point-of-use policy gate reads saved
    // authority through the ONE predicate (SavedTrustPolicyAuthority) that runs
    // TrustCenter's own shape + known-field-type validation. No cycle —
    // TrustCenter's closure is PersistenceCore / ToolRegistry and neither
    // depends on these three.
    "MemoryV2": ["PersistenceCore", "KnowledgeGraph", "ApprovalInbox", "TrustCenter", "Procedures", "FeedPolicy"],
    "DreamREMCycle": ["PersistenceCore", "ProviderRouting", "KnowledgeGraph", "TrustCenter", "Transcripts", "SwarmRuns"],
    "SelfImprovement": ["PersistenceCore", "TrustCenter", "FeedPolicy", "ApprovalInbox", "NotificationInbox", "SystemOps", "DoctorChecks"],
    "TrustCenter": ["PersistenceCore", "ToolRegistry", "FeedPolicy"],
    // Backup/recovery composes existing owners above TrustCenter: MemoryV2
    // and ApprovalInbox already depend on TrustCenter, so it cannot own them.
    "TrustPersistence": ["PersistenceCore", "TrustCenter", "MemoryV2", "ApprovalInbox", "Transcripts"],
    "TelegramBot": ["PersistenceCore", "BackgroundLoops", "ProviderRouting", "ApprovalInbox", "Transcripts", "TurnTrace", "FeedPolicy"],
    // Slack Socket Mode surface. ChatOrchestration for the turn ingress
    // (TurnRequest, MultimodalAttachment); no cycle — nothing imports SlackBot.
    "SlackBot": ["PersistenceCore", "BackgroundLoops", "ChatOrchestration", "PersonaEngine", "ProviderRouting", "SlackConnector", "Transcripts", "FeedPolicy"],
    // Chrome control socket, handshake and native-host registration. The
    // relay core is shared with the NativeAgentChromeRelay executable;
    // TrustCenter answers the Chrome control switch. ChatOrchestration reads
    // only its connection mirror (the home screen's Chrome line).
    "ChromeControl": ["PersistenceCore", "TrustCenter", "NativeAgentChromeRelayCore"],
    // Agent contacts: A2A wire and tasks, peer identity and replay claims, the
    // desktop and Grok routes, completion delivery and the reply/notice
    // continuation. Chat turns come through the engine root's clients; nothing
    // imports it back.
    "Agents": ["Cognition", "CognitiveSubstrate", "Context", "ContextFlow", "Procedures", "PersistenceCore", "ChatOrchestration", "ProviderRouting", "ApprovalInbox", "TrustCenter", "PersonaEngine", "StandingBots", "BackgroundLoops", "MacControl", "GrokLink", "Privacy"],
    // The resident mind's runtime: cognitive events and capsule, provider
    // lifecycle, organism posture, motor-outcome evidence, reflection, dream
    // pressure and the horizon. The engine root owns the instance and hands it
    // the root's ContextFlow; the app's platform pieces come through
    // CognitionHost. Nothing imports it back.
    "Cognition": ["PersistenceCore", "CognitiveSubstrate", "ChatOrchestration", "Context", "ContextFlow", "MemoryV2", "PersonaEngine", "ProviderRouting", "BackgroundLoops", "ApprovalInbox", "TriggerScheduler", "NotificationInbox", "DreamREMCycle", "KnowledgeGraph", "TurnTrace", "Studio", "Desk", "Privacy"],
    // Mac-side device sync: the CloudKit/KVS bridge, snapshot projection, the
    // phone's signed inbox actions, pairing and APNs. The engine root owns the
    // instance and hands it the root's mind; what it reads from the app's
    // mirrors comes through DeviceSyncHost. Nothing imports it back.
    "DeviceSync": ["PersistenceCore", "CognitiveSubstrate", "Cognition", "ChatOrchestration", "KnowledgeGraph", "MemoryV2", "ApprovalInbox", "NotificationInbox", "ProviderRouting", "MacIntegration", "TrustCenter", "WorkshopExecution", "PersonaEngine", "Transcripts", "Desk", "Privacy", "DeviceSyncState", "TriggerScheduler", "AgentConversations"],
    "AttentionRouting": ["PersistenceCore", "FeedPolicy", "ChatOrchestration", "DeviceSync", "TelegramBot", "Desk", "TriggerScheduler"],
    "ProviderRouting": ["PersistenceCore", "TurnTrace"],
    "BackgroundLoops": ["PersistenceCore", "DoctorChecks", "DreamREMCycle", "ProviderRouting", "TriggerScheduler", "Studio", "FeedPolicy"],
    // Cross-domain runner bodies sit above their domain owners; the scheduler
    // stays dependency-light and remains the only registration/single-flight owner.
    "BackgroundWork": ["ActivityWatch", "ApprovalInbox", "AttentionRouting", "BackgroundLoops", "ChatOrchestration", "Cognition", "CognitiveSubstrate", "Context", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "GitHubConnector", "MemoryV2", "NotificationInbox", "PersistenceCore", "PersonaEngine", "ProviderRouting", "SelfImprovement", "StandingBots", "TelegramBot", "TriggerScheduler", "TrustCenter", "TurnTrace", "WorkshopExecution"],
    "ToolExecution": ["PersistenceCore", "TrustCenter", "ToolRegistry"],
    "Research": ["PersistenceCore", "Privacy", "FeedPolicy"],
    "TriggerScheduler": ["PersistenceCore", "WorkshopExecution", "Desk", "ActivityWatch", "Privacy", "FeedPolicy", "NotificationInbox"],
    // Due-job execution composes owners that already depend on TriggerScheduler.
    "SchedulerExecution": ["PersistenceCore", "TriggerScheduler", "AttentionRouting", "DeviceSync", "DreamREMCycle", "TelegramBot", "NotificationInbox", "Privacy", "BackgroundWork", "AppToolRuntime"],
    "SystemOps": ["PersistenceCore", "TrustCenter"],
    "Dispatcher": ["PersistenceCore", "MacControl"],
    // TrustCenter owns the Mac Control gate and injection vocabulary (S9);
    // MacControl reads them. No cycle — TrustCenter imports no executor.
    "MacControl": ["PersistenceCore", "TrustCenter", "FeedPolicy"],
    "Onboarding": ["PersistenceCore", "PersonaEngine"],
    "MacAssistantStatus": ["PersistenceCore", "TrustCenter"],
    // MemoryV2 (2026-08-02, NORTHSTAR clause 1): a finished Workshop execution
    // writes one prose memory of what it did, on the `missions` disclosure
    // surface the policy already carried but nothing ever filled. No cycle —
    // MemoryV2 depends on PersistenceCore/KnowledgeGraph/ApprovalInbox and
    // never imports WorkshopExecution. See WorkshopExecution+ExecutionMemory.swift.
    "WorkshopExecution": ["ChatTurnContracts", "PersistenceCore", "ProviderRouting", "ApprovalInbox", "MemoryV2", "TrustCenter", "Procedures", "Desk", "SwarmRuns", "Privacy", "CognitiveSubstrate"],
    // 2026-09-01: the workflow RUN engine was retired (User authorized). What is
    // left is the workflow registry (list + create), which reads and writes one
    // JSON file. Every execution-side dependency — ApprovalInbox, TrustCenter,
    // MCPDispatcher, MemoryV2, Research, SystemOps, ToolExecution — went with
    // the engine that used them.
    "WorkflowOrchestration": ["PersistenceCore", "Privacy", "FeedPolicy"],
    "KnowledgeGraph": ["PersistenceCore", "Studio"],
    "Skills": ["PersistenceCore", "Privacy"],
    "NotificationInbox": ["PersistenceCore", "FeedPolicy"],
    "Connectors": ["PersistenceCore", "Privacy", "FeedPolicy", "MacIntegration", "ProviderRouting", "XConnector", "GitHubConnector", "TrustCenter", "ApprovalInbox", "ApprovalTransactions", "ChatOrchestration", "SlackConnector", "TriggerScheduler", "MacControl", "AppToolRuntime", "DeviceSync", "AttentionRouting", "MacAssistantStatus", "TelegramBot"],
    "SwarmRuns": ["PersistenceCore", "TurnTrace"],
    "Browser": ["PersistenceCore", "FeedPolicy", "Privacy", "ApprovalInbox"],
    "Context": ["PersistenceCore", "TrustCenter"],
    // The live ContextFlow owner: turn preparation, settled-tool prewarm,
    // memory-record → atom-id translation, and the memory, resident-work,
    // Knowledge Graph, Studio and persona projections it compiles. The engine
    // root owns the instance; nothing in core imports it back.
    "ContextFlow": ["PersistenceCore", "Context", "MemoryV2", "KnowledgeGraph", "PersonaEngine", "DreamREMCycle", "WorkshopExecution", "TurnTrace", "Studio", "Desk"],
    // Subsystem #28 wave 35 W18 — SwiftNative POST /v1/multimodal/tts port.
    // Depends on ProviderRouting for LLMCredentialResolver (the OpenAI platform
    // key resolver that landed with the chat cutover — the dep that lifts the
    // wave-34 "Swift secret layer" blocker) and PersistenceCore for
    // defaultDataRoot() / readJSON to enforce the SAME multimodalPolicy.tts_openai
    // trust gate the daemon's _multimodal_policy_check applies (default OFF).
    "MultimodalTTS": ["ProviderRouting", "PersistenceCore"],
    // Subsystem #29 wave 41 W10 — CapabilityFoundry seam. Depends on
    // PersistenceCore for JSONValue (the result serializer) and Skills for the
    // installed-skill inventory. The SwiftNative
    // impl is a static structural contract — it does NOT touch the other
    // subsystem modules because their per-lane counts are NOT aggregated yet
    // (PORTED-DORMANT, default OFF).
    "CapabilityFoundry": ["PersistenceCore", "Skills"],
    // MacIntegration — per-integration READ/WRITE permission gating for the
    // Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
    // Notifications / Spotlight / Scheduler surface. PersistenceCore for
    // flocked atomic JSON IO of mac_integration_permissions.json.
    "MacIntegration": ["PersistenceCore"],
    // Ambient activity watcher — PersistenceCore for defaultDataRoot() and
    // atomic policy IO; MacControl for MacScreenViewTextRedaction, the SHARED
    // secret redactor every captured window title passes through (W5). We reuse
    // it rather than writing a second redactor: two copies drift, and the copy
    // that drifts is the one nobody re-reviews. No cycle — MacControl depends
    // only on PersistenceCore and TrustCenter. ChatOrchestration reaches ActivityWatch through
    // one pinned query adapter, and the Mac app owns the capture lifecycle.
    "ActivityWatch": ["PersistenceCore", "MacControl"],
    // VisionPerception — MacControl for the SHARED contract it emits
    // (MacLookPercept / MacLookAffordance / MacLookHandle) and for
    // MacScreenViewTextRedaction, the one secret redactor every text channel
    // passes through. Reused, never re-implemented: two redactors drift, and
    // the copy that drifts is the one nobody re-reviews (same reasoning as
    // ActivityWatch above). No cycle — MacControl depends only on
    // PersistenceCore and TrustCenter and imports nothing from here.
    "VisionPerception": ["MacControl", "PersistenceCore"],
]

// Per-subsystem external (Swift Package) product dependencies.
let externalDeps: [String: [Target.Dependency]] = [
    "AgentConversations": [.product(name: "Yams", package: "Yams")],
    "AgentLinkTransport": [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
    ],
    "CognitiveSubstrate": [.product(name: "GRDB", package: "GRDB.swift")],
    "Context": [.product(name: "GRDB", package: "GRDB.swift")],
    "MemoryV2": [.product(name: "GRDB", package: "GRDB.swift"), "FeedPolicy"],
    // F6 (eval E06 fix-2): KnowledgeGraph reader now queries the same
    // memory.sqlite the MemoryV2 actor writes (kg_entities + kg_relationships
    // tables added by the v2_knowledge_graph migration). One-time JSON import
    // from <root>/memory/knowledge_graph.json is gated by a sentinel.
    "KnowledgeGraph": [.product(name: "GRDB", package: "GRDB.swift")],
    "ActivityWatch": [.product(name: "GRDB", package: "GRDB.swift")],
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
    ] : nil
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
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
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
            // writing `import NativeAgentShared`.
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
