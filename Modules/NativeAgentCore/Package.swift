// swift-tools-version:6.1
import Foundation
import PackageDescription

// Blueprint: | `Package.swift` | Core package products, target boundaries and direct dependencies, including the runtime-gated ActivityWatch target |

let subsystems: [String] = [
    "EngineRuntime",
    "Privacy",
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
    "NotificationInbox",
    "Connectors",
    "SwarmRuns",
    "Browser",
    "Context",
    "ContextFlow",
    "MultimodalTTS",
    "MacIntegration",
    // Capture is opt-in: no observers or spans without captureEnabled; disabling it tears observers down.
    // Capture performs no context assembly, memory promotion, sync or backup.
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
    "AgentConversations": ["Experiences", "AuthoredCapabilities", "AgentWorkspace", "MacControl", "Privacy", "PersistenceCore", "ApprovalInbox", "StandingBots", "AgentLinkTransport", "ProviderRouting", "TurnTrace", "ChatTurnContracts", "ChatToolParsing", "Desk", "TrustCenter"],
    "ChatTurnContracts": ["PersistenceCore", "ProviderRouting", "TurnTrace", "ApprovalInbox", "ChatToolParsing", "CognitiveSubstrate", "MacControl"],
    "ChatToolRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "ChatTurnContracts", "AgentConversations", "AgentWorkspace", "ChatSessionWork", "ChatToolParsing", "Research", "StandingBots", "PersistenceCore", "PersonaEngine", "MemoryV2", "ProviderRouting", "TrustCenter", "DreamREMCycle", "ApprovalInbox", "Dispatcher", "MacControl", "Context", "SwarmRuns", "MacIntegration", "WorkshopExecution", "SystemOps", "CognitiveSubstrate", "ToolExecution", "ActivityWatch", "ToolRegistry", "Procedures", "Transcripts", "TurnTrace", "Studio", "Desk", "ChromeControl", "Privacy", "NotificationInbox"],
    "AgentWorkspace": ["Experiences", "AuthoredCapabilities", "ChatToolParsing", "ChatSessionWork", "PersistenceCore", "ApprovalInbox", "MacControl", "MemoryV2", "ChromeControl", "Desk", "StandingBots", "WorkshopExecution", "MacIntegration", "Transcripts", "NotificationInbox", "Senses", "SwarmRuns", "Dispatcher"],
    "ChatSessionWork": ["Experiences", "MemoryV2", "MacControl", "Context", "PersistenceCore", "Transcripts", "TurnTrace", "ProviderRouting", "ChatToolParsing"],
    "ChatToolParsing": ["MacControl", "PersistenceCore", "TurnTrace"],
    "AgentLinkTransport": ["PersistenceCore", "ProviderRouting"],
    "EngineRuntime": ["ActivityWatch", "Experiences", "AuthoredCapabilities", "AgentWorkspace", "ChatSessionWork", "TurnTrace", "Privacy", "Senses", "Agents", "AppToolRuntime", "ApprovalInbox", "ApprovalTransactions", "AttentionRouting", "BackgroundLoops", "BackgroundWork", "Browser", "ChromeControl", "Cognition", "CognitiveSubstrate", "Connectors", "Context", "ContextFlow", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "MemoryV2", "MacIntegration", "MacControl", "NotificationInbox", "PersistenceCore", "PersonaEngine", "Procedures", "ProviderRouting", "Research", "SchedulerExecution", "SystemOps", "SlackBot", "StandingBots", "TelegramBot", "ToolExecution", "ToolRegistry", "Transcripts", "TriggerScheduler", "TrustCenter", "TrustPersistence", "WorkshopExecution", "Onboarding", "Dispatcher", "AgentConversations", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Studio", "SwarmRuns"],
    // Approval transactions compose canonical owners; host effects arrive through ports.
    "ApprovalTransactions": ["Experiences", "AuthoredCapabilities", "Procedures", "AgentWorkspace", "ApprovalInbox", "Browser", "Cognition", "Desk", "Dispatcher", "DreamREMCycle", "PersistenceCore", "MacControl", "MacIntegration", "MemoryV2", "PersonaEngine", "Privacy", "ProviderRouting", "Studio", "TelegramBot", "TrustCenter", "TurnTrace", "WorkshopExecution", "Transcripts", "AgentConversations", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox", "ToolRegistry"],
    // Tool policy composes the existing owners; UI and platform effects arrive through ports.
    "AppToolRuntime": ["BackgroundLoops", "TurnTrace", "Transcripts", "AgentWorkspace", "Experiences", "AuthoredCapabilities", "MultimodalTTS", "Senses", "Agents", "ApprovalInbox", "ApprovalTransactions", "Desk", "ChromeControl", "Browser", "Cognition", "CognitiveSubstrate", "Context", "MacControl", "Research", "PersistenceCore", "TrustCenter", "WorkshopExecution", "StandingBots", "ToolRegistry", "ToolExecution", "Privacy", "AttentionRouting", "MacIntegration", "PersonaEngine", "ProviderRouting", "DeviceSync", "Dispatcher", "Studio", "DoctorChecks", "TrustPersistence", "MemoryV2", "AgentConversations", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox", "TelegramBot"],

    // The stem's one record of what happened (docs/EXPERIENCE.md), a GRDB
    // store like memory's. It sits this low so every owner of a happening can write it.
    "Experiences": [],
    "AuthoredCapabilities": ["Experiences", "PersistenceCore"],
    "Privacy": ["PersistenceCore"],
    "Desk": ["PersistenceCore", "TrustCenter", "Transcripts"],
    "Studio": ["AuthoredCapabilities", "PersistenceCore"],
    "Senses": ["AuthoredCapabilities", "PersistenceCore"],
    "TurnTrace": ["Experiences", "AuthoredCapabilities", "PersistenceCore"],
    "Transcripts": ["PersistenceCore"],
    "Procedures": ["PersistenceCore"],
    "StandingBots": ["Experiences", "PersistenceCore", "TriggerScheduler", "ApprovalInbox", "Dispatcher"],
    // TrustCenter supplies canonical origin-surface authority; Experiences records decisions owed to the person.
    "ApprovalInbox": ["AuthoredCapabilities", "ChatToolParsing", "PersistenceCore", "TrustCenter", "Procedures", "Experiences", "Transcripts"],
    "ToolRegistry": ["AuthoredCapabilities", "PersistenceCore", "TurnTrace"],
    "PersonaEngine": ["PersistenceCore", "AuthoredCapabilities"],
    // MemoryV2 supplies canonical memory/graph readers and the real embedder load and repair path.
    "DoctorChecks": ["SwarmRuns", "Experiences", "AuthoredCapabilities", "PersistenceCore", "PersonaEngine", "MemoryV2", "TurnTrace", "ProviderRouting", "Desk", "DeviceSyncState", "Transcripts"],
    // Turn engine/client policy composes the lower chat owners. Platform
    // effects still arrive through their existing injected ports.
    "ChatTurnRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "CognitiveSubstrate", "Context", "Desk", "Dispatcher", "DreamREMCycle", "MemoryV2", "MacControl", "MacIntegration", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "Research", "StandingBots", "Studio", "SwarmRuns", "SystemOps", "ToolRegistry", "Transcripts", "TrustCenter", "TurnTrace"],

    "CognitiveSubstrate": ["Experiences", "PersistenceCore", "Studio", "Privacy", "Transcripts", "TurnTrace"],
    // Memory and dream policy gates read saved authority through TrustCenter's canonical shape/type validation.
    "MemoryV2": ["Experiences", "PersistenceCore", "PersonaEngine", "ApprovalInbox", "TrustCenter", "Procedures", "CognitiveSubstrate", "Senses", "ChatTurnContracts", "TurnTrace", "NotificationInbox", "Studio", "Transcripts"],
    "DreamREMCycle": ["Experiences", "PersistenceCore", "PersonaEngine", "ProviderRouting", "MemoryV2", "TrustCenter", "Transcripts", "SwarmRuns", "CognitiveSubstrate", "Studio"],

    "TrustCenter": ["Privacy", "AuthoredCapabilities", "PersistenceCore", "ToolRegistry", "PersonaEngine", "TurnTrace"],
    // Backup/recovery composes existing owners above TrustCenter: MemoryV2
    // and ApprovalInbox already depend on TrustCenter, so it cannot own them.
    "TrustPersistence": ["PersistenceCore", "TrustCenter", "MemoryV2", "ApprovalInbox", "Transcripts", "TelegramBot", "AuthoredCapabilities", "ChatTurnRuntime", "Privacy", "SystemOps"],
    "TelegramBot": ["ChatToolRuntime", "MemoryV2", "DeviceSync", "NotificationInbox", "Experiences", "AuthoredCapabilities", "MacControl", "PersistenceCore", "PersonaEngine", "BackgroundLoops", "ProviderRouting", "ApprovalInbox", "Transcripts", "TurnTrace", "ChatSessionWork", "TrustCenter", "ChatTurnContracts", "ChatTurnRuntime"],
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
    "Agents": ["Experiences", "AgentLinkTransport", "AgentWorkspace", "Cognition", "CognitiveSubstrate", "Context", "ContextFlow", "Procedures", "PersistenceCore", "ProviderRouting", "ApprovalInbox", "TrustCenter", "PersonaEngine", "StandingBots", "BackgroundLoops", "MacControl", "Privacy", "Transcripts", "ToolExecution", "AgentConversations", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Desk", "Senses", "ToolRegistry", "TurnTrace", "NotificationInbox"],
    // The resident mind's runtime: cognitive events and capsule, provider
    // lifecycle, organism posture, motor-outcome evidence, reflection, dream
    // pressure and the horizon. The engine root owns the instance and hands it
    // the root's ContextFlow; the app's platform pieces come through
    // CognitionHost. Nothing imports it back.
    "Cognition": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "CognitiveSubstrate", "Context", "ContextFlow", "MemoryV2", "PersonaEngine", "ProviderRouting", "BackgroundLoops", "ApprovalInbox", "TriggerScheduler", "NotificationInbox", "DreamREMCycle", "TurnTrace", "Studio", "Desk", "Privacy", "AgentConversations", "AgentWorkspace", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Transcripts", "Senses"],
    // Mac-side device sync: the CloudKit/KVS bridge, snapshot projection, the
    // phone's signed inbox actions, pairing and APNs. The engine root owns the
    // instance and hands it the root's mind; what it reads from the app's
    // mirrors comes through DeviceSyncHost. Nothing imports it back.
    "DeviceSync": ["Experiences", "MacControl", "PersistenceCore", "CognitiveSubstrate", "Cognition", "MemoryV2", "ApprovalInbox", "NotificationInbox", "ProviderRouting", "MacIntegration", "TrustCenter", "WorkshopExecution", "PersonaEngine", "Transcripts", "Desk", "Privacy", "DeviceSyncState", "TriggerScheduler", "AgentConversations", "TurnTrace", "BackgroundLoops", "ChatSessionWork", "ChatToolParsing", "ChatTurnContracts", "ChatTurnRuntime", "ToolRegistry", "StandingBots"],
    "AttentionRouting": ["Experiences", "Privacy", "PersistenceCore", "DeviceSync", "TelegramBot", "Desk", "TriggerScheduler", "NotificationInbox", "ApprovalInbox", "StandingBots", "Transcripts", "AgentWorkspace", "ChatTurnContracts", "ChatTurnRuntime"],
    "ProviderRouting": ["Experiences", "PersistenceCore", "TurnTrace", "Privacy"],
    "BackgroundLoops": ["PersistenceCore"],
    // Cross-domain runner bodies sit above their domain owners; the scheduler
    // stays dependency-light and remains the only registration/single-flight owner.
    "BackgroundWork": ["ToolExecution", "Experiences", "SlackBot", "ActivityWatch", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "AttentionRouting", "BackgroundLoops", "Cognition", "CognitiveSubstrate", "Context", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "MemoryV2", "NotificationInbox", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "StandingBots", "TelegramBot", "ToolRegistry", "TriggerScheduler", "TrustCenter", "TurnTrace", "WorkshopExecution", "ChatSessionWork", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Transcripts"],
    "ToolExecution": ["AuthoredCapabilities", "Senses", "PersonaEngine", "PersistenceCore", "TrustCenter", "ToolRegistry", "Desk", "MacControl", "ProviderRouting", "Privacy"],
    "Research": ["PersistenceCore", "Privacy", "MacControl", "ProviderRouting", "TurnTrace"],
    "TriggerScheduler": ["Experiences", "PersistenceCore", "WorkshopExecution", "Desk", "ActivityWatch", "Privacy", "NotificationInbox", "TrustCenter"],
    // Due-job execution composes owners that already depend on TriggerScheduler.
    "SchedulerExecution": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "TriggerScheduler", "AttentionRouting", "DeviceSync", "DreamREMCycle", "TelegramBot", "NotificationInbox", "Privacy", "BackgroundWork", "AppToolRuntime", "Senses"],
    "SystemOps": ["PersistenceCore", "TrustCenter"],
    "Dispatcher": ["ChatToolParsing", "PersonaEngine", "Experiences", "AuthoredCapabilities", "Senses", "PersistenceCore", "MacControl", "TrustCenter", "TurnTrace"],
    // TrustCenter owns the Mac Control gate and injection vocabulary; MacControl reads them.
    "MacControl": ["Experiences", "Senses", "PersistenceCore", "TrustCenter"],
    "Onboarding": ["PersistenceCore", "PersonaEngine", "MemoryV2"],

    "WorkshopExecution": ["ChatToolParsing", "ChatTurnContracts", "PersistenceCore", "ProviderRouting", "ApprovalInbox", "TrustCenter", "Procedures", "Desk", "SwarmRuns", "Privacy", "CognitiveSubstrate", "ToolRegistry", "MacIntegration"],


    "NotificationInbox": ["PersistenceCore", "ApprovalInbox", "Desk"],
    "Connectors": ["AuthoredCapabilities", "ChatToolParsing", "PersistenceCore", "Privacy", "MacIntegration", "ProviderRouting", "TrustCenter", "ApprovalInbox", "ApprovalTransactions", "SlackBot", "TriggerScheduler", "MacControl", "AppToolRuntime", "DeviceSync", "AttentionRouting", "TelegramBot", "ChatToolRuntime", "ToolExecution"],
    "SwarmRuns": ["Experiences", "PersistenceCore", "TurnTrace", "ToolExecution", "Privacy", "ProviderRouting", "ChatTurnContracts"],
    "Browser": ["PersistenceCore", "Privacy", "ApprovalInbox", "TurnTrace"],
    "Context": ["PersistenceCore", "TrustCenter", "PersonaEngine"],
    // The live ContextFlow owner: turn preparation, settled-tool prewarm,
    // memory-record → atom-id translation, and the memory, resident-work,
    // Knowledge Graph, Studio and persona projections it compiles. The engine
    // root owns the instance; nothing in core imports it back.
    "ContextFlow": ["PersistenceCore", "Context", "MemoryV2", "PersonaEngine", "DreamREMCycle", "WorkshopExecution", "TurnTrace", "Studio", "Desk", "Senses"],
    // ProviderRouting supplies credentials, PersistenceCore supplies data paths,
    // and TrustCenter checks saved multimodal authority (default off).
    "MultimodalTTS": ["ProviderRouting", "PersistenceCore", "TrustCenter"],
    // MacIntegration — per-integration READ/WRITE permission gating for the
    // Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
    // Notifications / Spotlight / Scheduler surface. PersistenceCore for
    // flocked atomic JSON IO of mac_integration_permissions.json.
    "MacIntegration": ["AuthoredCapabilities", "PersistenceCore", "MacControl", "TrustCenter"],
    // PersistenceCore supplies paths and policy IO; MacControl supplies the shared window-title redactor.
    // The Mac app owns capture lifecycle; ChatToolRuntime uses one query adapter.
    "ActivityWatch": ["Experiences", "PersistenceCore", "MacControl"],

]

// Per-subsystem direct external (Swift Package) product dependencies.
let externalDeps: [String: [Target.Dependency]] = [
    "PersistenceCore": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AgentConversations": [.product(name: "Yams", package: "Yams"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
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
    "Context": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "MemoryV2": [.product(name: "GRDB", package: "GRDB.swift")],
    "ActivityWatch": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AgentWorkspace": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AppToolRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ApprovalInbox": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ApprovalTransactions": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AttentionRouting": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "AuthoredCapabilities": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "BackgroundWork": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatSessionWork": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatToolParsing": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatToolRuntime": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatTurnContracts": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ChatTurnRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Cognition": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Connectors": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Desk": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "DeviceSync": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "EngineRuntime": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "MacControl": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "MacIntegration": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "NotificationInbox": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "PersonaEngine": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Privacy": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "ProviderRouting": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "SlackBot": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "StandingBots": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "SwarmRuns": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TelegramBot": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "Transcripts": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TrustCenter": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TrustPersistence": [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "TurnTrace": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
    "WorkshopExecution": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
]

let subsystemTargets: [Target] = subsystems.flatMap { name -> [Target] in
    let deps: [Target.Dependency] =
        [.target(name: "NativeAgentCore")] +
        (extraDeps[name] ?? []).map { .target(name: $0) } +
        (externalDeps[name] ?? []) +
        (name == "DoctorChecks" ? [.product(name: "NativeAgentShared", package: "NativeAgentShared")] : [])
    // The embedding model and vocabulary ship in the app's Resources/embedding.
    let targetResources: [Resource]? = (name == "AgentConversations") ? [.copy("Resources/grok-routine.json")] : nil
    // MemberImportVisibility keeps transitive extension members out of inference
    // so persisted procedure shape/schema digests hash stable strings.
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
    platforms: [.macOS("26.0")],  // Liquid Glass floor
    products: products,
    dependencies: [
        // BEGIN generated gRPC requirements (Package.swift; script/sync_build_declarations.rb)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        // END generated gRPC requirements
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Shared snapshot ordering and wire/rendering values for Mac and phone.
        .package(path: "../NativeAgentShared"),
    ],
    targets: [
        // Bookkeeping shared with DoctorChecks without importing the sync runtime.
        .target(name: "DeviceSyncState", path: "Sources/DeviceSync/State"),
        .target(
            name: "NativeAgentCore",
            // Each Shared caller imports it and declares its product directly.
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
