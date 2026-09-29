import ProviderRouting
import Foundation
import AppKit
import AuthenticationServices

extension NativeOAuthPlatform {
    // MARK: - ASWebAuthenticationSession runner

    @MainActor
    static func runAuthSession(authURL: URL,
                                       expectedState: String,
                                       providerId: String) async throws -> URL {
        print("[oauth] starting ASWebAuthenticationSession for \(providerId)")
        let gate = OAuthContinuationGate()
        let sessionBox = OAuthSessionBox()
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            gate.install(cont)
            let completion = makeAuthSessionCompletion(
                expectedState: expectedState,
                gate: gate,
                sessionBox: sessionBox
            )
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: NativeOAuthFlow.callbackURLScheme,
                completionHandler: completion
            )
            sessionBox.set(session)
            session.presentationContextProvider = OAuthSignInPresenter.shared
            // Keep existing browser-session cookies / autofill / 2FA.
            session.prefersEphemeralWebBrowserSession = false

            // Register a fallback so onOpenURL can resolve the continuation if
            // the OS routes the redirect outside the ASWebAuth sheet.
            PendingCallbacks.shared.register(
                state: expectedState,
                resolver: makeCallbackFallback(gate: gate, sessionBox: sessionBox)
            )

            OAuthSignInPresenter.shared.retain(session)
            if !session.start() {
                PendingCallbacks.shared.forget(state: expectedState)
                OAuthSignInPresenter.shared.release(session)
                gate.resume(throwing: NSError(
                    domain: "NativeOAuthFlow", code: -11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "ASWebAuthenticationSession.start() returned false."]))
            }
          }
        } onCancel: {
            gate.resume(throwing: CancellationError())
            Task { @MainActor in
                PendingCallbacks.shared.forget(state: expectedState)
                if let session = sessionBox.session() {
                    session.cancel()
                    OAuthSignInPresenter.shared.release(session)
                }
            }
        }
    }

    private static func makeAuthSessionCompletion(
        expectedState: String,
        gate: OAuthContinuationGate,
        sessionBox: OAuthSessionBox
    ) -> (URL?, Error?) -> Void {
        { callbackURL, error in
            PendingCallbacks.shared.forget(state: expectedState)
            releaseAuthSession(sessionBox)
            if let error = error {
                gate.resume(throwing: error)
                return
            }
            guard let callbackURL = callbackURL else {
                gate.resume(throwing: NSError(
                    domain: "NativeOAuthFlow", code: -10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Auth session returned no URL and no error."]))
                return
            }
            gate.resume(returning: callbackURL)
        }
    }

    private static func makeCallbackFallback(
        gate: OAuthContinuationGate,
        sessionBox: OAuthSessionBox
    ) -> (URL) -> Void {
        { url in
            // Claim the callback before cancel() can report canceledLogin.
            gate.resume(returning: url)
            if let session = sessionBox.session() {
                Task { @MainActor in
                    session.cancel()
                    OAuthSignInPresenter.shared.release(session)
                }
            }
        }
    }

    private static func releaseAuthSession(_ sessionBox: OAuthSessionBox) {
        guard let session = sessionBox.session() else { return }
        Task { @MainActor in
            OAuthSignInPresenter.shared.release(session)
        }
    }

}
