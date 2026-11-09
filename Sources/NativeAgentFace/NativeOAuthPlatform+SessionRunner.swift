import Foundation
import AppKit
import AuthenticationServices
import NativeAgentShared
// Blueprint: | `NativeOAuthPlatform+SessionRunner.swift` | Authentication callbacks, explicit cancellation and one session settlement |

@MainActor
final class OAuthSessionResult {
    let done = ScopedWaiter()
    let expectedState: String
    var outcome: Result<URL, Error>?
    init(expectedState: String) { self.expectedState = expectedState }
    func finish(_ outcome: Result<URL, Error>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        done.resume()
    }
}

extension NativeOAuthPlatform {
    nonisolated private static func completion(_ response: OAuthSessionResult) -> ASWebAuthenticationSession.CompletionHandler {
        { callbackURL, error in
            Task { @MainActor in
                if let error { response.finish(.failure(error)) }
                else if let callbackURL { response.finish(.success(callbackURL)) }
                else { response.finish(.failure(PartCallError(code: "oauth_no_callback",
                    message: "The authentication session returned neither a callback nor an error."))) }
            }
        }
    }

    static func run(_ request: OAuthPresentationRequest) async throws -> FaceReply {
        guard let url = URL(string: request.authorizationURL), let scheme = url.scheme, ["https", "http"].contains(scheme),
              let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            throw PartCallError(code: "oauth_presentation_unavailable", message: "Open the account's sign-in window before signing in.")
        }
        guard sessions[request.operation] == nil else {
            throw PartCallError(code: "oauth_already_presented", message: "This sign-in operation already has an authentication session.")
        }
        let response = OAuthSessionResult(expectedState: request.expectedState)
        sessions[request.operation] = response
        let presenter = BodyOAuthSessionPresenter(window: window)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: request.callbackScheme,
            completionHandler: completion(response))
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        defer {
            withExtendedLifetime(presenter) { session.cancel() }
            sessions[request.operation] = nil
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard session.start() else {
                throw PartCallError(code: "oauth_start_failed", message: "macOS could not start the authentication session.")
            }
            await response.done.park()
            try Task.checkCancellation()
            guard let outcome = response.outcome else {
                throw PartCallError(code: "oauth_unconfirmed", message: "Authentication ended without a callback.")
            }
            return .oauthCallback(url: try outcome.get().absoluteString)
        } onCancel: {
            Task { @MainActor in response.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class BodyOAuthSessionPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: NSWindow

    init(window: NSWindow) { self.window = window }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
