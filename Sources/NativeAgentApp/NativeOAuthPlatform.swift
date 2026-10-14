import AppKit
import AuthenticationServices
import ProviderRouting

enum NativeOAuthPlatform: NativeOAuthPlatformPort {
    static func isCanceledLogin(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
