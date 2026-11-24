// swift-tools-version:6.2
import PackageDescription

// Blueprint: | `Package.swift` | Shared package manifest: Mac/iPhone library target, platform floors and shared source dependencies |

let package = Package(
    name: "NativeAgentShared",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "NativeAgentShared", targets: ["NativeAgentShared"])
    ],
    targets: [
        .target(
            name: "NativeAgentShared",
            path: "Sources/NativeAgentShared"
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
