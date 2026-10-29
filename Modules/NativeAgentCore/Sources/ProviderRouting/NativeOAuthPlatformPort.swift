import AppKit
import Foundation
// Blueprint: | `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort` protocol; `runAuthSession`, `isCanceledLogin`; shared `makeLoopbackSession` returns the concrete callback server; `openBrowser`, `runLoopbackAuthSession` defaults |

/// Platform effects used by the Core sign-in policy. Session entry points
/// retain their MainActor isolation; listeners retain their own cancellation.
public protocol NativeOAuthPlatformPort: Sendable {
    @MainActor static func runAuthSession(authURL: URL, expectedState: String, providerId: String) async throws -> URL
    static func isCanceledLogin(_ error: Error) -> Bool
}

public extension NativeOAuthPlatformPort {
    @MainActor
    static func makeLoopbackSession(preferredPort: UInt16, path: String, displayName: String, allowsPortFallback: Bool) throws -> NativeOAuthLoopbackCallbackServer {
        try NativeOAuthLoopbackCallbackServer(
            preferredPort: preferredPort, path: path, displayName: displayName,
            allowsPortFallback: allowsPortFallback
        )
    }

    @MainActor
    static func openBrowser(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    static func runLoopbackAuthSession(authURL: URL, port: UInt16, expectedState: String) async throws -> URL {
        try await NativeOAuthLoopbackCallbackServer.runOpenAIAuthSession(
            authURL: authURL, port: port, expectedState: expectedState
        )
    }
}
