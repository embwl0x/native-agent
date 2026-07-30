// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NativeAgentShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "NativeAgentShared", targets: ["NativeAgentShared"])
    ],
    targets: [
        .target(
            name: "NativeAgentShared",
            dependencies: [],
            path: "Sources/NativeAgentShared"
        ),
        .testTarget(
            name: "NativeAgentSharedTests",
            dependencies: ["NativeAgentShared"],
            path: "Tests/NativeAgentSharedTests"
        )
    ]
)
