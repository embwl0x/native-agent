import ProviderRouting
import NativeAgentShared
import Foundation
import AppKit
import AuthenticationServices
import NativeAgentCore
// Blueprint: | `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession`; nonisolated callbacks, actor settlement |

@MainActor
private final class OAuthSessionResult {
    let done = ScopedWaiter()
    var outcome: Result<URL, Error>?

    func finish(_ outcome: Result<URL, Error>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        done.resume()
    }
}

extension NativeOAuthPlatform {
    // MARK: - ASWebAuthenticationSession runner

    nonisolated private static func authCompletion(
        response: OAuthSessionResult
    ) -> ASWebAuthenticationSession.CompletionHandler {
        { callbackURL, error in
            Task { @MainActor in
                if let error { response.finish(.failure(error)) }
                else if let callbackURL { response.finish(.success(callbackURL)) }
                else {
                    response.finish(.failure(NSError(
                        domain: "NativeOAuthFlow", code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "Auth session returned no URL and no error."])))
                }
            }
        }
    }

    @MainActor
    static func runAuthSession(authURL: URL,
                               expectedState: String,
                               providerId: String) async throws -> URL {
        print("[oauth] starting ASWebAuthenticationSession for \(providerId)")
        let response = OAuthSessionResult()
        var session: ASWebAuthenticationSession?
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(600)) }
            catch { return }
            response.finish(.failure(NSError(
                domain: "NativeOAuthFlow", code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Browser sign-in timed out after ten minutes."])))
        }
        let outcome: Result<URL, Error>
        do {
            let callback = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let authSession = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: NativeOAuthFlow.callbackURLScheme,
                    completionHandler: authCompletion(response: response)
                )
                session = authSession
                authSession.presentationContextProvider = OAuthSignInPresenter.shared
                // Keep existing browser-session cookies / autofill / 2FA.
                authSession.prefersEphemeralWebBrowserSession = false

                // The OS may route the redirect outside the ASWebAuth sheet.
                PendingCallbacks.shared.register(
                    state: expectedState,
                    resolver: { url in Task { @MainActor in response.finish(.success(url)) } }
                )

                if Task.isCancelled {
                    response.finish(.failure(CancellationError()))
                } else if !authSession.start() {
                    response.finish(.failure(NSError(
                        domain: "NativeOAuthFlow", code: -11,
                        userInfo: [NSLocalizedDescriptionKey:
                            "ASWebAuthenticationSession.start() returned false."])))
                }
                let done = response.done
                await Task { await done.park() }.value
                return response.outcome!
            } onCancel: {
                Task { @MainActor in response.finish(.failure(CancellationError())) }
            }
            outcome = callback
        } catch { outcome = .failure(error) }
        // Cancellation must await callback and session release through the same cleanup.
        await settle { @MainActor [session] in
            deadline.cancel()
            await deadline.value
            PendingCallbacks.shared.forget(state: expectedState)
            session?.cancel()
        }
        return try outcome.get()
    }
}
