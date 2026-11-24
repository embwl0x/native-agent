// swift-tools-version:6.2
import PackageDescription

// Blueprint: | `Package.swift` | Core products and direct owner dependencies, including recent-life turn provenance |

let libraries = [
    "NativeAgentCore",
    "NativeAgentChromeRelayCore",
    "PersistenceCore",
    "SenseCore",
    "DeskCore",
    "MacNerves",
    "ProviderRouting",
    "MindCore",
    "BodyRuntime",
]

let package = Package(
    name: "NativeAgentCore",
    platforms: [.macOS("26.0")],  // Liquid Glass floor
    products: libraries.map { .library(name: $0, targets: [$0]) }
        + [.executable(name: "task-ledger", targets: ["TaskLedgerCLI"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(path: "../NativeAgentShared"),
    ],
    targets: [
        .target(
            name: "NativeAgentCore",
            dependencies: [
                .product(name: "HashTreeCollections", package: "swift-collections"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
            ]
        ),
        .target(
            name: "NativeAgentChromeRelayCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "PersistenceCore",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
            ]
        ),
        .target(
            name: "SenseCore",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "DeskCore",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "SenseCore"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
            ]
        ),
        .target(
            name: "MacNerves",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "NativeAgentChromeRelayCore"),
                .target(name: "PersistenceCore"),
                .target(name: "SenseCore"),
                .target(name: "DeskCore"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "ProviderRouting",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "SenseCore"),
                .target(name: "DeskCore"),
                .target(name: "MacNerves"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
            ]
        ),
        .target(
            name: "MindCore",
            dependencies: [
                .product(name: "HashTreeCollections", package: "swift-collections"),
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "SenseCore"),
                .target(name: "DeskCore"),
                .target(name: "MacNerves"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "BodyRuntime",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "SenseCore"),
                .target(name: "DeskCore"),
                .target(name: "MacNerves"),
                .target(name: "ProviderRouting"),
                .target(name: "MindCore"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .copy("AgentConversations/Resources/grok-routine.json"),
                .copy("AgentConversations/Resources/agent-hosts.json"),
            ]
        ),
        .executableTarget(
            name: "TaskLedgerCLI",
            dependencies: [
                .target(name: "NativeAgentCore"),
                .target(name: "PersistenceCore"),
                .target(name: "DeskCore"),
            ]
        ),
    ]
)

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
for target in package.targets {
    target.swiftSettings = upcoming + [.strictMemorySafety()]
}
