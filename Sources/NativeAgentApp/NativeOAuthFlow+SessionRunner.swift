import Foundation
import AppKit
import AuthenticationServices

extension NativeOAuthFlow {
    /// Fallback path: forwarded from the SwiftUI `onOpenURL` handler when the
    /// OS hands the app a `nativeagent://oauth/...` URL directly (e.g. the
    /// browser opened the URL after the ASWebAuth sheet was dismissed).
    /// Resolves any pending callback continuation for this state.
    static func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme == callbackURLScheme, url.host == "oauth" else {
            return false
        }
        let (_, returnedState, _) = parseCallback(url)
        guard let s = returnedState else { return false }
        return PendingCallbacks.shared.resolve(state: s, with: url)
    }

    // MARK: - ASWebAuthenticationSession runner

    @MainActor
    static func runAuthSession(authURL: URL,
                                       expectedState: String,
                                       providerId: String) async throws -> URL {
        print("[oauth] starting ASWebAuthenticationSession for \(providerId)")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let gate = OAuthContinuationGate(cont)
            let sessionBox = OAuthSessionBox()
            let completion = makeAuthSessionCompletion(
                expectedState: expectedState,
                gate: gate,
                sessionBox: sessionBox
            )
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackURLScheme,
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
            if let session = sessionBox.session() {
                Task { @MainActor in
                    session.cancel()
                    OAuthSignInPresenter.shared.release(session)
                }
            }
            gate.resume(returning: url)
        }
    }

    private static func releaseAuthSession(_ sessionBox: OAuthSessionBox) {
        guard let session = sessionBox.session() else { return }
        Task { @MainActor in
            OAuthSignInPresenter.shared.release(session)
        }
    }

    static func parseCallback(_ url: URL)
        -> (code: String?, state: String?, error: String?)
    {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil, "Invalid callback URL")
        }
        var code: String?
        var state: String?
        var providerErr: String?
        var providerErrDetail: String?
        for item in comps.queryItems ?? [] {
            switch item.name {
            case "code":              code = item.value
            case "state":             state = item.value
            case "error":             providerErr = item.value
            case "error_description": providerErrDetail = item.value
            default: break
            }
        }
        if let providerErr = providerErr {
            let combined = (providerErrDetail.map { "\(providerErr): \($0)" })
                ?? providerErr
            return (nil, state, combined)
        }
        return (code, state, nil)
    }
}
