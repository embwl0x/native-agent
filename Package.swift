// swift-tools-version: 6.2

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
        .executable(name: "NativeAgentFace", targets: ["NativeAgentFace"]),
        .executable(name: "NativeAgentChromeRelay", targets: ["NativeAgentChromeRelay"]),
        .executable(name: "NativeAgentSenseHost", targets: ["NativeAgentSenseHost"])
    ],
    dependencies: [
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
            name: "NativeAgentFace",
            dependencies: [.product(name: "NativeAgentShared", package: "NativeAgentShared"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NativeAgentFace"
        ),
        .executableTarget(
            name: "NativeAgentSenseHost",
            dependencies: [.product(name: "SenseCore", package: "NativeAgentCore"),
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
            ],
            path: "Sources/NativeAgentChromeRelay"
        ),
        .executableTarget(
            name: "NativeAgentApp",
            // BEGIN generated app declarations (project.yml; script/sync_build_declarations.rb)
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NativeAgentShared", package: "NativeAgentShared"),
                .product(name: "NativeAgentCore", package: "NativeAgentCore"),
                .product(name: "PersistenceCore", package: "NativeAgentCore"),
                .product(name: "SenseCore", package: "NativeAgentCore"),
                .product(name: "DeskCore", package: "NativeAgentCore"),
                .product(name: "MacNerves", package: "NativeAgentCore"),
                .product(name: "ProviderRouting", package: "NativeAgentCore"),
                .product(name: "MindCore", package: "NativeAgentCore"),
                .product(name: "BodyRuntime", package: "NativeAgentCore"),
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

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
for target in package.targets {
    target.swiftSettings = upcoming + [.strictMemorySafety()]
}
