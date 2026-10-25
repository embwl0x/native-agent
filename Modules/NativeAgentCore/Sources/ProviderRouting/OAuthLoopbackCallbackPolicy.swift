import Foundation
// Blueprint: | `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |

public enum OAuthLoopbackCallbackError: LocalizedError {
    case timedOut
    case canceled
    case alreadyWaiting
    case socket(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "oauth_callback_timeout: No browser callback arrived before the sign-in deadline. Start a new sign-in from its original control and finish it before the deadline."
        case .canceled:
            return "oauth_sign_in_cancelled: The sign-in listener was cancelled. Leave sign-in stopped; no further action is needed."
        case .alreadyWaiting:
            return "oauth_callback_already_waiting: This sign-in already has a callback listener waiting. Complete the sign-in already open in the browser."
        case .socket(let message):
            return "oauth_callback_socket_failed: \(message) Inspect this local socket error and correct the loopback listener before starting a new sign-in from its original control."
        }
    }
}


public enum OAuthLoopbackCallbackPolicy {
    /// Only the exact state issued for this attempt may consume its listener.
    public static func callbackMatchesState(_ url: URL, expectedState: String) -> Bool {
        !expectedState.isEmpty && NativeOAuthFlow.parseCallback(url).state == expectedState
    }

    public static func validCallbackURL(
        target: String,
        path: String,
        port: UInt16
    ) -> URL? {
        guard target.hasPrefix("/"),
              let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              url.path == path, hasResult(url) else {
            return nil
        }
        return url
    }

    public static func hasResult(_ url: URL) -> Bool {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains {
            ($0.name == "code" || $0.name == "error")
                && !($0.value ?? "").isEmpty
        }
    }

}
