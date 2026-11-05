// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "NativeAgent",
    platforms: [
        // Liquid Glass requires this platform floor; the public DMG minimum must match.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "nativeagent-link", targets: ["NativeAgentLink"]),
        .executable(name: "NativeAgentApp", targets: ["NativeAgentApp"]),
        .executable(name: "NativeAgentChromeRelay", targets: ["NativeAgentChromeRelay"]),
        .executable(name: "NativeAgentSenseHost", targets: ["NativeAgentSenseHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            // 2.9.6 is the security floor: it fixes the installer path race in GHSA-3x7w-j75x-ppq5 (versions through 2.9.5 are affected).
            from: "2.9.6"
        ),
        .package(path: "Modules/NativeAgentShared"),
        .package(path: "Modules/NativeAgentCore")
    ],
    targets: [
        .executableTarget(
            name: "NativeAgentSenseHost",
            dependencies: [.product(name: "Senses", package: "NativeAgentCore"),
                           .product(name: "NativeAgentCore", package: "NativeAgentCore"),
                           .product(name: "PersistenceCore", package: "NativeAgentCore")],
            path: "Sources/NativeAgentSenseHost",
            resources: [.copy("../../Resources/Senses")]
        ),
        .executableTarget(name: "NativeAgentLink", dependencies: [.product(name: "PersistenceCore", package: "NativeAgentCore"),
            .product(name: "NativeAgentCore", package: "NativeAgentCore")], path: "Sources/NativeAgentLink"),
        .executableTarget(
            name: "NativeAgentChromeRelay",
            dependencies: [
                .product(name: "NativeAgentChromeRelayCore", package: "NativeAgentCore"),
                .product(name: "PersistenceCore", package: "NativeAgentCore"),
                .product(name: "Privacy", package: "NativeAgentCore"),
            ],
            path: "Sources/NativeAgentChromeRelay"
        ),
        .executableTarget(
            name: "NativeAgentApp",
            // BEGIN generated app declarations (project.yml; script/sync_build_declarations.rb)
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "NativeAgentCore", package: "NativeAgentCore"),
                .product(name: "ApprovalInbox", package: "NativeAgentCore"),
                .product(name: "MemoryV2", package: "NativeAgentCore"),
                .product(name: "Context", package: "NativeAgentCore"),
                .product(name: "ToolRegistry", package: "NativeAgentCore"),
                .product(name: "ToolExecution", package: "NativeAgentCore"),
                .product(name: "AuthoredCapabilities", package: "NativeAgentCore"),
                .product(name: "PersonaEngine", package: "NativeAgentCore"),
                .product(name: "TrustCenter", package: "NativeAgentCore"),
                .product(name: "TrustPersistence", package: "NativeAgentCore"),
                .product(name: "PersistenceCore", package: "NativeAgentCore"),
                .product(name: "Privacy", package: "NativeAgentCore"),
                .product(name: "Desk", package: "NativeAgentCore"),
                .product(name: "Studio", package: "NativeAgentCore"),
                .product(name: "Senses", package: "NativeAgentCore"),
                .product(name: "TurnTrace", package: "NativeAgentCore"),
                .product(name: "Transcripts", package: "NativeAgentCore"),
                .product(name: "BackgroundLoops", package: "NativeAgentCore"),
                .product(name: "BackgroundWork", package: "NativeAgentCore"),
                .product(name: "DoctorChecks", package: "NativeAgentCore"),
                .product(name: "ProviderRouting", package: "NativeAgentCore"),
                .product(name: "DreamREMCycle", package: "NativeAgentCore"),
                .product(name: "TriggerScheduler", package: "NativeAgentCore"),
                .product(name: "SchedulerExecution", package: "NativeAgentCore"),
                .product(name: "StandingBots", package: "NativeAgentCore"),
                .product(name: "SwarmRuns", package: "NativeAgentCore"),
                .product(name: "NotificationInbox", package: "NativeAgentCore"),
                .product(name: "Research", package: "NativeAgentCore"),
                .product(name: "SystemOps", package: "NativeAgentCore"),
                .product(name: "Dispatcher", package: "NativeAgentCore"),
                .product(name: "MacControl", package: "NativeAgentCore"),
                .product(name: "ScreenVision", package: "NativeAgentCore"),
                .product(name: "Onboarding", package: "NativeAgentCore"),
                .product(name: "CognitiveSubstrate", package: "NativeAgentCore"),
                .product(name: "Connectors", package: "NativeAgentCore"),
                .product(name: "TelegramBot", package: "NativeAgentCore"),
                .product(name: "SlackBot", package: "NativeAgentCore"),
                .product(name: "ChromeControl", package: "NativeAgentCore"),
                .product(name: "Agents", package: "NativeAgentCore"),
                .product(name: "ContextFlow", package: "NativeAgentCore"),
                .product(name: "Cognition", package: "NativeAgentCore"),
                .product(name: "DeviceSync", package: "NativeAgentCore"),
                .product(name: "AttentionRouting", package: "NativeAgentCore"),
                .product(name: "EngineRuntime", package: "NativeAgentCore"),
                .product(name: "ChatSessionWork", package: "NativeAgentCore"),
                .product(name: "AgentConversations", package: "NativeAgentCore"),
                .product(name: "AgentWorkspace", package: "NativeAgentCore"),
                .product(name: "ChatToolParsing", package: "NativeAgentCore"),
                .product(name: "ChatToolRuntime", package: "NativeAgentCore"),
                .product(name: "ChatTurnContracts", package: "NativeAgentCore"),
                .product(name: "ChatTurnRuntime", package: "NativeAgentCore"),
                .product(name: "AppToolRuntime", package: "NativeAgentCore"),
                .product(name: "ApprovalTransactions", package: "NativeAgentCore"),
                .product(name: "Browser", package: "NativeAgentCore"),
                .product(name: "MultimodalTTS", package: "NativeAgentCore"),
                .product(name: "MacIntegration", package: "NativeAgentCore"),
                .product(name: "ActivityWatch", package: "NativeAgentCore"),
            ],
            path: "Sources/NativeAgentApp",
            resources: [
                .copy("../../docs/data-bounds.md"),
                .copy("../../script/chatgpt_dot_ipc.js"),
            ]
            // END generated app declarations
        )
    ]
)
