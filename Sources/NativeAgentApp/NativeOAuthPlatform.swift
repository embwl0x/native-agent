import AppKit
import AuthenticationServices
import ProviderRouting

enum NativeOAuthPlatform: NativeOAuthPlatformPort {
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

    static func isCanceledLogin(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
