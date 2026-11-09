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
    "NotificationInbox",
    "Connectors",
    "SwarmRuns",
    "Browser",
    "Context",
    "ContextFlow",
    "MultimodalTTS",
    "MacIntegration",
    // Capture is opt-in: no observers or spans without captureEnabled; disabling it tears observers down. Capture performs no context assembly, memory
    // promotion, sync or backup.
    "ActivityWatch",
]

let products: [Product] =
    [.library(name: "NativeAgentCore", targets: ["NativeAgentCore"])]
    + subsystems.map { .library(name: $0, targets: [$0]) }
    + [.library(name: "NativeAgentChromeRelayCore", targets: ["NativeAgentChromeRelayCore"])]
    + [.executable(name: "task-ledger", targets: ["TaskLedgerCLI"])]

// Every target needs runtime support; disk owners need PersistenceCore. Keep edges required for transitive extension visibility.
let extraDeps: [String: [String]] = [
    "AgentConversations": ["PersonaEngine", "Experiences", "AuthoredCapabilities", "AgentWorkspace", "MacControl", "Privacy", "PersistenceCore",
        "ApprovalInbox", "StandingBots", "AgentLinkTransport", "ProviderRouting", "TurnTrace", "ChatTurnContracts", "ChatToolParsing", "Desk", "TrustCenter",
        "Transcripts"],
    "ChatTurnContracts": ["PersistenceCore", "ProviderRouting", "TurnTrace", "ApprovalInbox", "ChatToolParsing", "CognitiveSubstrate", "MacControl"],
    "ChatToolRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "ChatTurnContracts", "AgentConversations", "AgentWorkspace", "ChatSessionWork",
        "ChatToolParsing", "Research", "StandingBots", "PersistenceCore", "PersonaEngine", "MemoryV2", "ProviderRouting", "TrustCenter", "DreamREMCycle",
        "ApprovalInbox", "Dispatcher", "MacControl", "Context", "SwarmRuns", "MacIntegration", "SystemOps", "CognitiveSubstrate",
        "ToolExecution", "ActivityWatch", "ToolRegistry", "Transcripts", "TurnTrace", "Studio", "Desk", "ChromeControl", "Privacy",
        "NotificationInbox"],
    "AgentWorkspace": ["Experiences", "AuthoredCapabilities", "ChatToolParsing", "ChatSessionWork", "PersistenceCore", "ApprovalInbox", "MacControl",
        "MemoryV2", "ChromeControl", "Desk", "StandingBots", "MacIntegration", "Transcripts", "NotificationInbox", "Senses", "SwarmRuns",
        "Dispatcher", "TriggerScheduler", "PersonaEngine"],
    "ChatSessionWork": ["Experiences", "MemoryV2", "MacControl", "Context", "PersistenceCore", "Transcripts", "TurnTrace", "ProviderRouting", "ChatToolParsing",
        "PersonaEngine", "CognitiveSubstrate"],
    "ChatToolParsing": ["MacControl", "PersistenceCore", "TurnTrace"],
    "AgentLinkTransport": ["Experiences", "PersistenceCore", "ProviderRouting"],
    "EngineRuntime": ["ActivityWatch", "Experiences", "AuthoredCapabilities", "AgentWorkspace", "ChatSessionWork", "TurnTrace", "Privacy", "Senses", "Agents",
        "AppToolRuntime", "ApprovalInbox", "ApprovalTransactions", "AttentionRouting", "BackgroundLoops", "BackgroundWork", "Browser", "ChromeControl",
        "Cognition", "CognitiveSubstrate", "Connectors", "Context", "ContextFlow", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "MemoryV2",
        "MacIntegration", "MacControl", "NotificationInbox", "PersistenceCore", "PersonaEngine", "ProviderRouting", "Research",
        "SchedulerExecution", "SystemOps", "SlackBot", "StandingBots", "TelegramBot", "ToolExecution", "ToolRegistry", "Transcripts", "TriggerScheduler",
        "TrustCenter", "TrustPersistence", "Onboarding", "Dispatcher", "AgentConversations", "ChatToolParsing", "ChatToolRuntime",
        "ChatTurnContracts", "ChatTurnRuntime", "Studio", "SwarmRuns"],
    // Approval transactions compose canonical owners; host effects arrive through ports.
    "ApprovalTransactions": ["Experiences", "AuthoredCapabilities", "AgentWorkspace", "ApprovalInbox", "Browser", "Cognition", "Desk",
        "Dispatcher", "DreamREMCycle", "PersistenceCore", "MacControl", "MacIntegration", "MemoryV2", "PersonaEngine", "Privacy", "ProviderRouting", "Studio",
        "TelegramBot", "TrustCenter", "TurnTrace", "Transcripts", "AgentConversations", "ChatSessionWork", "ChatToolParsing",
        "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox", "ToolRegistry"],
    // Tool policy composes the existing owners; UI and platform effects arrive through ports.
    "AppToolRuntime": ["TriggerScheduler", "BackgroundLoops", "TurnTrace", "Transcripts", "AgentWorkspace", "Experiences", "AuthoredCapabilities",
        "MultimodalTTS", "Senses", "Agents", "ApprovalInbox", "ApprovalTransactions", "Desk", "ChromeControl", "Browser", "Cognition", "CognitiveSubstrate",
        "Context", "MacControl", "Research", "PersistenceCore", "TrustCenter", "StandingBots", "ToolRegistry", "ToolExecution", "Privacy",
        "AttentionRouting", "MacIntegration", "PersonaEngine", "ProviderRouting", "DeviceSync", "Dispatcher", "Studio", "DoctorChecks", "TrustPersistence",
        "MemoryV2", "AgentConversations", "ChatSessionWork", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "NotificationInbox",
        "TelegramBot", "DreamREMCycle"],

    // Experiences sits below domain owners so each can record its own events in the shared GRDB store.
    "Experiences": [],
    "AuthoredCapabilities": ["Experiences", "PersistenceCore"],
    "Privacy": ["PersistenceCore"],
    "Desk": ["PersistenceCore", "TrustCenter", "Transcripts"],
    "Studio": ["Experiences", "AuthoredCapabilities", "PersistenceCore"],
    "Senses": ["Experiences", "AuthoredCapabilities", "PersistenceCore"],
    "TurnTrace": ["Experiences", "AuthoredCapabilities", "PersistenceCore"],
    "Transcripts": ["PersistenceCore"],
    "StandingBots": ["Experiences", "PersistenceCore", "TriggerScheduler", "ApprovalInbox", "Dispatcher"],
    // TrustCenter supplies canonical origin-surface authority; Experiences records decisions owed to the person.
    "ApprovalInbox": ["AuthoredCapabilities", "ChatToolParsing", "PersistenceCore", "TrustCenter", "Experiences", "Transcripts"],
    "ToolRegistry": ["AuthoredCapabilities", "PersistenceCore", "TurnTrace"],
    "PersonaEngine": ["PersistenceCore", "AuthoredCapabilities", "Experiences"],
    // MemoryV2 supplies canonical memory/graph readers and the real embedder load and repair path.
    "DoctorChecks": ["SwarmRuns", "Experiences", "AuthoredCapabilities", "PersistenceCore", "PersonaEngine", "MemoryV2", "TurnTrace", "ProviderRouting", "Desk",
        "DeviceSyncState", "Transcripts", "ChatSessionWork"],
    // Turn engine/client policy composes the lower chat owners. Platform effects still arrive through their existing injected ports.
    "ChatTurnRuntime": ["Experiences", "AuthoredCapabilities", "Senses", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "ChatSessionWork",
        "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts", "CognitiveSubstrate", "Context", "Desk", "Dispatcher", "DreamREMCycle", "MemoryV2",
        "MacControl", "MacIntegration", "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "Research", "StandingBots", "Studio", "SwarmRuns",
        "SystemOps", "ToolRegistry", "Transcripts", "TrustCenter", "TurnTrace"],

    "CognitiveSubstrate": ["Experiences", "PersistenceCore", "Studio", "Privacy", "Transcripts", "TurnTrace", "Context", "MacControl"],
    // Memory and dream policy gates read saved authority through TrustCenter's canonical shape/type validation.
    "MemoryV2": ["Experiences", "PersistenceCore", "PersonaEngine", "ApprovalInbox", "TrustCenter", "CognitiveSubstrate", "Senses",
        "ChatTurnContracts", "TurnTrace", "NotificationInbox", "Studio", "Transcripts", "Desk"],
    "DreamREMCycle": ["Experiences", "PersistenceCore", "PersonaEngine", "ProviderRouting", "MemoryV2", "TrustCenter", "Transcripts", "SwarmRuns",
        "CognitiveSubstrate", "Studio"],

    "TrustCenter": ["Experiences", "Privacy", "AuthoredCapabilities", "PersistenceCore", "ToolRegistry", "PersonaEngine", "TurnTrace"],
    // Backup/recovery composes existing owners above TrustCenter: MemoryV2 and ApprovalInbox already depend on TrustCenter, so it cannot own them.
    "TrustPersistence": ["PersistenceCore", "TrustCenter", "MemoryV2", "ApprovalInbox", "Transcripts", "TelegramBot", "AuthoredCapabilities", "ChatTurnRuntime",
        "Privacy", "SystemOps", "TriggerScheduler"],
    "TelegramBot": ["ChatToolRuntime", "MemoryV2", "DeviceSync", "NotificationInbox", "Experiences", "AuthoredCapabilities", "MacControl", "PersistenceCore",
        "PersonaEngine", "BackgroundLoops", "ProviderRouting", "ApprovalInbox", "Transcripts", "TurnTrace", "ChatSessionWork", "TrustCenter",
        "ChatTurnContracts", "ChatTurnRuntime"],
    // SlackBot stays below its engine, background and connector callers to avoid a dependency cycle.
    "SlackBot": ["AuthoredCapabilities", "PersistenceCore", "BackgroundLoops", "PersonaEngine", "ProviderRouting", "Transcripts", "MacControl", "TrustCenter",
        "ChatTurnContracts", "ChatTurnRuntime", "TurnTrace"],
    // Share relay transport with the executable; TrustCenter owns control authority and ChatToolRuntime reads only the connection mirror.
    "ChromeControl": ["PersistenceCore", "TrustCenter", "NativeAgentChromeRelayCore", "MacControl", "Transcripts"],
    // Contacts reach chat through engine clients; reverse imports would create a cycle.
    "Agents": ["Experiences", "AgentLinkTransport", "AgentWorkspace", "Cognition", "CognitiveSubstrate", "Context", "ContextFlow",
        "PersistenceCore", "ProviderRouting", "ApprovalInbox", "TrustCenter", "PersonaEngine", "StandingBots", "BackgroundLoops", "MacControl",
        "MacIntegration", "Privacy", "Transcripts", "ToolExecution", "AgentConversations", "ChatToolParsing", "ChatToolRuntime", "ChatTurnContracts",
        "ChatTurnRuntime", "Desk", "Senses", "ToolRegistry", "TurnTrace", "NotificationInbox"],
    // The engine owns cognition and injects ContextFlow; platform effects arrive through CognitionHost to avoid reverse imports.
    "Cognition": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "CognitiveSubstrate", "Context", "ContextFlow", "MemoryV2", "PersonaEngine",
        "ProviderRouting", "BackgroundLoops", "ApprovalInbox", "TriggerScheduler", "NotificationInbox", "DreamREMCycle", "TurnTrace", "Studio", "Desk",
        "Privacy", "AgentConversations", "AgentWorkspace", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Transcripts", "Senses",
        "MacControl"],
    // The engine owns device sync and injects its mind; app mirrors arrive through DeviceSyncHost to avoid reverse imports.
    "DeviceSync": ["MultimodalTTS", "Experiences", "MacControl", "PersistenceCore", "CognitiveSubstrate", "Cognition", "MemoryV2", "ApprovalInbox",
        "NotificationInbox", "ProviderRouting", "MacIntegration", "TrustCenter", "PersonaEngine", "Transcripts", "Desk", "Privacy",
        "DeviceSyncState", "TriggerScheduler", "AgentConversations", "TurnTrace", "BackgroundLoops", "ChatSessionWork", "ChatToolParsing", "ChatTurnContracts",
        "ChatTurnRuntime", "ToolRegistry", "StandingBots"],
    "AttentionRouting": ["Experiences", "MacControl", "Privacy", "PersistenceCore", "DeviceSync", "TelegramBot", "Desk", "TriggerScheduler",
        "NotificationInbox", "ApprovalInbox", "StandingBots", "Transcripts", "AgentWorkspace", "ChatTurnContracts", "ChatTurnRuntime"],
    "ProviderRouting": ["Experiences", "PersistenceCore", "TurnTrace", "Privacy"],
    "BackgroundLoops": ["Experiences", "PersistenceCore"],
    // Cross-domain runner bodies sit above their domain owners; the scheduler stays dependency-light and remains the only registration/single-flight owner.
    "BackgroundWork": ["ToolExecution", "Experiences", "SlackBot", "ActivityWatch", "AgentConversations", "AgentWorkspace", "ApprovalInbox", "AttentionRouting",
        "BackgroundLoops", "Cognition", "CognitiveSubstrate", "Context", "Desk", "DeviceSync", "DoctorChecks", "DreamREMCycle", "MemoryV2", "NotificationInbox",
        "PersistenceCore", "PersonaEngine", "Privacy", "ProviderRouting", "StandingBots", "TelegramBot", "ToolRegistry", "TriggerScheduler", "TrustCenter",
        "TurnTrace", "ChatSessionWork", "ChatToolRuntime", "ChatTurnContracts", "ChatTurnRuntime", "Transcripts"],
    "ToolExecution": ["Experiences", "AuthoredCapabilities", "Senses", "PersonaEngine", "PersistenceCore", "TrustCenter", "ToolRegistry", "Desk", "MacControl",
        "ProviderRouting", "Privacy", "TriggerScheduler"],
    "Research": ["PersistenceCore", "Privacy", "MacControl", "ProviderRouting", "TurnTrace"],
    "TriggerScheduler": ["Experiences", "PersistenceCore", "Desk", "ActivityWatch", "Privacy", "NotificationInbox", "TrustCenter", "ChatTurnContracts"],
    // Due-job execution composes owners that already depend on TriggerScheduler.
    "SchedulerExecution": ["Experiences", "AuthoredCapabilities", "PersistenceCore", "TriggerScheduler", "AttentionRouting", "DeviceSync", "DreamREMCycle",
        "TelegramBot", "NotificationInbox", "Privacy", "BackgroundWork", "AppToolRuntime", "Senses"],
    "SystemOps": ["PersistenceCore", "TrustCenter"],
    "Dispatcher": ["ChatToolParsing", "PersonaEngine", "Experiences", "AuthoredCapabilities", "Senses", "PersistenceCore", "MacControl", "TrustCenter",
        "TurnTrace"],
    // TrustCenter owns the Mac Control gate and injection vocabulary; MacControl reads them.
    "MacControl": ["Experiences", "Senses", "PersistenceCore", "TrustCenter", "TurnTrace"],
    "Onboarding": ["PersistenceCore", "PersonaEngine", "MemoryV2"],


    "NotificationInbox": ["PersistenceCore", "ApprovalInbox", "Desk"],
    "Connectors": ["AuthoredCapabilities", "ChatToolParsing", "PersistenceCore", "Privacy", "MacIntegration", "ProviderRouting", "TrustCenter", "ApprovalInbox",
        "ApprovalTransactions", "SlackBot", "TriggerScheduler", "MacControl", "AppToolRuntime", "DeviceSync", "AttentionRouting", "TelegramBot",
        "ChatToolRuntime", "ToolExecution"],
    "SwarmRuns": ["Experiences", "PersistenceCore", "TurnTrace", "ToolExecution", "Privacy", "ProviderRouting", "ChatTurnContracts"],
    "Browser": ["PersistenceCore", "Privacy", "ApprovalInbox", "TurnTrace", "Dispatcher"],
    "Context": ["PersistenceCore", "TrustCenter", "PersonaEngine"],
    // The engine owns ContextFlow and its projections; reverse imports would create a cycle.
    "ContextFlow": ["PersistenceCore", "Context", "MemoryV2", "PersonaEngine", "DreamREMCycle", "TurnTrace", "Studio", "Desk", "Senses", "Experiences"],
    // ProviderRouting supplies credentials, PersistenceCore supplies data paths, and TrustCenter checks saved multimodal authority (default off).
    "MultimodalTTS": ["ProviderRouting", "PersistenceCore", "TrustCenter"],
    // MacIntegration gates each surface's reads and writes; PersistenceCore provides locked atomic permission storage.
    "MacIntegration": ["AuthoredCapabilities", "PersistenceCore", "MacControl", "TrustCenter"],
    // PersistenceCore supplies paths and policy IO; MacControl supplies the shared window-title redactor. The Mac app owns capture lifecycle; ChatToolRuntime
    // uses one query adapter.
    "ActivityWatch": ["Experiences", "PersistenceCore", "MacControl"],

]

let externalDeps: [String: [Target.Dependency]] = [
    "SystemOps": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
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
    "Senses": [.product(name: "NativeAgentShared", package: "NativeAgentShared")],
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
]

let subsystemTargets: [Target] = subsystems.flatMap { name -> [Target] in
    let deps: [Target.Dependency] =
        [.target(name: "NativeAgentCore")] +
        (extraDeps[name] ?? []).map { .target(name: $0) } +
        (externalDeps[name] ?? []) +
        (name == "DoctorChecks" ? [.product(name: "NativeAgentShared", package: "NativeAgentShared")] : [])
    let targetResources: [Resource]? = (name == "AgentConversations")
        ? [.copy("Resources/grok-routine.json"), .copy("Resources/agent-hosts.json")] : nil
    return [.target(
        name: name,
        dependencies: deps,
        path: "Sources/\(name)",
        exclude: name == "DeviceSync" ? ["State"] : [],
        resources: targetResources
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
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
        // Dependency-free so the Chrome relay executable stays small. Trust the parent's checked code signature: anyone can write an Info.plist.
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
