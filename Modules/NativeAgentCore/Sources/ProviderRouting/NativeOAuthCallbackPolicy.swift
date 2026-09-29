import Foundation

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

    public static func validateCallback(_ url: URL, expectedState: String) -> CallbackValidation {
        let (code, returnedState, providerError) = parseCallback(url)
        if let providerError = providerError {
            return .failure("Provider returned error: \(providerError)")
        }
        guard let code = code, !code.isEmpty else {
            return .failure("Provider did not return an authorization code.")
        }
        guard returnedState == expectedState else {
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
