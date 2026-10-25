// swift-tools-version:5.9
import PackageDescription

// Blueprint: | `Package.swift` | Shared package manifest: Mac/iPhone library target, platform floors and shared source dependencies |

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
        )
    ]
)
