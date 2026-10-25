import AppKit
import AuthenticationServices
import ProviderRouting
// Blueprint: | `NativeOAuthPlatform.swift` | `NativeOAuthPlatform`: `NativeOAuthPlatformPort` conformance and `isCanceledLogin` adapter |

enum NativeOAuthPlatform: NativeOAuthPlatformPort {
    static func isCanceledLogin(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
