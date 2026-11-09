import AppKit
import Foundation
// Blueprint: | `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort`, `runAuthSession`, `isCanceledLogin`, `makeLoopbackSession`, `openBrowser`, `runLoopbackAuthSession` |

/// Only browser/session presentation uses MainActor; callback listeners and sign-in storage run off the UI actor.
public protocol NativeOAuthPlatformPort: Sendable {
    @MainActor static func runAuthSession(authURL: URL, expectedState: String, providerId: String) async throws -> URL
    static func isCanceledLogin(_ error: Error) -> Bool
}

public extension NativeOAuthPlatformPort {
    static func makeLoopbackSession(preferredPort: UInt16, path: String, displayName: String) throws -> NativeOAuthLoopbackCallbackServer {
        try NativeOAuthLoopbackCallbackServer(
            preferredPort: preferredPort, path: path, displayName: displayName
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
