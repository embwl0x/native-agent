// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NativeAgentShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "NativeAgentShared", targets: ["NativeAgentShared"]),
        // Reusable by Mac and iPhone tests; production apps depend only on Shared.
        .library(name: "NativeAgentSharedTestSupport", targets: ["NativeAgentSharedTestSupport"])
    ],
    targets: [
        .target(
            name: "NativeAgentShared",
            dependencies: [],
            path: "Sources/NativeAgentShared"
        ),
        .target(
            name: "NativeAgentSharedTestSupport",
            dependencies: ["NativeAgentShared"],
            path: "Tests/NativeAgentSharedTestSupport"
        ),
        .testTarget(
            name: "NativeAgentSharedTests",
            dependencies: ["NativeAgentShared", "NativeAgentSharedTestSupport"],
            path: "Tests/NativeAgentSharedTests"
        )
    ]
)
