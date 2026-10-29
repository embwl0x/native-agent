import ProviderRouting
import NativeAgentShared
import Foundation
import AppKit
import AuthenticationServices
import NativeAgentCore
// Blueprint: | `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession` |

extension NativeOAuthPlatform {
    // MARK: - ASWebAuthenticationSession runner

    @MainActor
    static func runAuthSession(authURL: URL,
                               expectedState: String,
                               providerId: String) async throws -> URL {
        print("[oauth] starting ASWebAuthenticationSession for \(providerId)")
        let gate = ContinuationOnce<Result<URL, Error>>()
        var session: ASWebAuthenticationSession?
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(600)) }
            catch { return }
            gate.resume(.failure(NSError(
                domain: "NativeOAuthFlow", code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Browser sign-in timed out after ten minutes."])))
        }
        let outcome: Result<URL, Error>
        do {
            let callback = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return await withCheckedContinuation { (cont: CheckedContinuation<Result<URL, Error>, Never>) in
                    gate.install(cont)
                    let authSession = ASWebAuthenticationSession(
                        url: authURL,
                        callbackURLScheme: NativeOAuthFlow.callbackURLScheme,
                        completionHandler: { callbackURL, error in
                            if let error { gate.resume(.failure(error)) }
                            else if let callbackURL { gate.resume(.success(callbackURL)) }
                            else {
                                gate.resume(.failure(NSError(
                                    domain: "NativeOAuthFlow", code: -10,
                                    userInfo: [NSLocalizedDescriptionKey: "Auth session returned no URL and no error."])))
                            }
                        }
                    )
                    session = authSession
                    authSession.presentationContextProvider = OAuthSignInPresenter.shared
                    // Keep existing browser-session cookies / autofill / 2FA.
                    authSession.prefersEphemeralWebBrowserSession = false

                    // Let onOpenURL resolve the same outcome if
                    // the OS routes the redirect outside the ASWebAuth sheet.
                    PendingCallbacks.shared.register(
                        state: expectedState,
                        resolver: { gate.resume(.success($0)) }
                    )

                    guard !Task.isCancelled else {
                        gate.resume(.failure(CancellationError()))
                        return
                    }
                    if !authSession.start() {
                        gate.resume(.failure(NSError(
                            domain: "NativeOAuthFlow", code: -11,
                            userInfo: [NSLocalizedDescriptionKey:
                                "ASWebAuthenticationSession.start() returned false."])))
                    }
                }
            } onCancel: {
                gate.resume(.failure(CancellationError()))
            }
            outcome = callback
        } catch { outcome = .failure(error) }
        // All exits join the same cleanup. Cancellation selects an outcome;
        // it cannot let the caller return ahead of callback/session release.
        await settle { @MainActor [session] in
            deadline.cancel()
            await deadline.value
            PendingCallbacks.shared.forget(state: expectedState)
            session?.cancel()
        }
        return try outcome.get()
    }
}
