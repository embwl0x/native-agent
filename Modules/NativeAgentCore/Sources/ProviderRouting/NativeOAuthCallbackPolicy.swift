import Foundation
// Blueprint: | `NativeOAuthCallbackPolicy.swift` | Shared callback validation with exactly one state and caller-specific messages; handleCallbackURL, validateCallback, parseCallback |

extension NativeOAuthFlow {
    /// Fallback path: forwarded from the SwiftUI `onOpenURL` handler when the
    /// OS hands the app a `nativeagent://oauth/...` URL directly (e.g. the
    /// browser opened the URL after the ASWebAuth sheet was dismissed).
    /// Resolves any pending callback continuation for this state.
    public static func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme == callbackURLScheme, url.host == "oauth" else {
            return false
        }
        let (_, returnedState, _) = parseCallback(url)
        guard let s = returnedState else { return false }
        return PendingCallbacks.shared.resolve(state: s, with: url)
    }

    public enum CallbackValidation {
        case code(String)
        case failure(String)
    }

    public static func validateCallback(
        _ url: URL, expectedState: String,
        providerErrorMessage: (String) -> String = { "Provider returned error: \($0)" },
        missingCodeMessage: String = "Provider did not return an authorization code."
    ) -> CallbackValidation {
        let (code, returnedState, providerError) = parseCallback(url)
        if let providerError = providerError {
            return .failure(providerErrorMessage(providerError))
        }
        guard let code = code, !code.isEmpty else {
            return .failure(missingCodeMessage)
        }
        guard !expectedState.isEmpty, returnedState == expectedState else {
            return .failure("OAuth state mismatch — possible CSRF; aborting.")
        }
        return .code(code)
    }

    public static func parseCallback(_ url: URL)
        -> (code: String?, state: String?, error: String?)
    {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil, "Invalid callback URL")
        }
        var code: String?
        let states = (comps.queryItems ?? []).filter { $0.name == "state" }
        let state = states.count == 1 ? states[0].value : nil
        var providerErr: String?
        var providerErrDetail: String?
        for item in comps.queryItems ?? [] {
            switch item.name {
            case "code":              code = item.value
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
