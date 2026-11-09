import Foundation
import AuthenticationServices
import ProviderRouting
import NativeAgentShared
// Blueprint: | `BodyOAuthPlatform.swift` | Body OAuth protocol adapter; only authentication-session presentation crosses the pipe |

@MainActor
enum BodyOAuthPlatform: NativeOAuthPlatformPort {
    static var call: (@MainActor @Sendable (FaceCall) async throws -> FaceReply)?

    nonisolated static func isCanceledLogin(_ error: Error) -> Bool {
        error is CancellationError || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }

    static func runAuthSession(authURL: URL, expectedState: String, providerId: String) async throws -> URL {
        guard let call else {
            throw PartCallError(code: "face_unavailable", message: "Open NativeAgent's window to sign in.")
        }
        let reply = try await call(.runOAuthSession(.init(operation: UUID(), provider: providerId,
            authorizationURL: authURL.absoluteString, expectedState: expectedState, callbackScheme: NativeOAuthFlow.callbackURLScheme)))
        switch reply {
        case .oauthCallback(let raw):
            guard let url = URL(string: raw) else {
                throw PartCallError(code: "oauth_callback_invalid", message: "The authentication callback URL is malformed.")
            }
            return url
        case .cancelled: throw CancellationError()
        case .failed(let failure), .refused(let failure): throw failure
        default: throw PartCallError(code: "oauth_callback_missing", message: "The window returned no authentication callback.")
        }
    }
}
