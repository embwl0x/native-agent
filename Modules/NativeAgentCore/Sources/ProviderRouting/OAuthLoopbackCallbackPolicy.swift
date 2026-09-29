import Foundation

public enum OAuthLoopbackCallbackError: LocalizedError {
    case timedOut
    case canceled
    case socket(String)
    case malformedRequest

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Timed out waiting for the OAuth callback."
        case .canceled:
            return "OAuth callback listener was canceled."
        case .socket(let message):
            return message
        case .malformedRequest:
            return "Browser callback request was malformed."
        }
    }
}


public enum OAuthLoopbackCallbackPolicy {
    /// Only the exact state issued for this attempt may consume its listener.
    public static func callbackMatchesState(_ url: URL, expectedState: String) -> Bool {
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "state" } ?? []
        return !expectedState.isEmpty && states.count == 1 && states[0].value == expectedState
    }

    public static func validCallbackURL(
        target: String,
        path: String,
        port: UInt16
    ) -> URL? {
        guard target.hasPrefix("/"),
              let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              url.path == path,
              let items = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.queryItems else {
            return nil
        }
        let hasResult = items.contains {
            ($0.name == "code" || $0.name == "error")
                && !($0.value ?? "").isEmpty
        }
        return hasResult ? url : nil
    }

}
