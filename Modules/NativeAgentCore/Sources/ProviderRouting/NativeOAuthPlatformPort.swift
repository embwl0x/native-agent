import AppKit
import Foundation

/// Platform effects used by the Core sign-in policy. Session entry points
/// retain their MainActor isolation; listeners retain their own cancellation.
public protocol NativeOAuthPlatformPort: Sendable {
    @MainActor static func runAuthSession(authURL: URL, expectedState: String, providerId: String) async throws -> URL
    static func isCanceledLogin(_ error: Error) -> Bool
}

public protocol OAuthLoopbackSession: Sendable {
    var redirectURI: URL { get }
    func wait(timeoutSeconds: TimeInterval, expectedState: String) async throws -> URL
    func cancel()
}

public extension NativeOAuthPlatformPort {
    @MainActor
    static func makeLoopbackSession(preferredPort: UInt16, path: String, displayName: String, allowsPortFallback: Bool) throws -> any OAuthLoopbackSession {
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
