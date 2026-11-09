import Foundation
import NativeAgentShared
// Blueprint: | `NativeOAuthPlatform.swift` | Authentication-session presentation scoped to the body's operation |

@MainActor
enum NativeOAuthPlatform {
    static var sessions: [UUID: OAuthSessionResult] = [:]

    static func disconnect() {
        for response in sessions.values { response.finish(.failure(FaceWireError.disconnected)) }
    }

    /// URL ingress routes to the active sheet; the body validates state and exchanges tokens.
    static func receiveCallback(_ url: URL) -> Bool {
        guard let state = callbackState(url),
              let pending = sessions.values.first(where: { $0.expectedState == state }) else { return false }
        pending.finish(.success(url))
        return true
    }

    static func receiveCallback(_ url: URL, operation: UUID) -> Bool {
        guard let pending = sessions[operation], let state = callbackState(url), pending.expectedState == state else { return false }
        pending.finish(.success(url))
        return true
    }

    private static func callbackState(_ url: URL) -> String? {
        guard url.scheme == "nativeagent", url.host == "oauth",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1 else { return nil }
        return states.first?.value
    }
}
