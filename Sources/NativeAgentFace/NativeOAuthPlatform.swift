import Foundation
import NativeAgentShared
// Blueprint: | `NativeOAuthPlatform.swift` | Authentication-session presentation scoped to the body's operation |

@MainActor
enum NativeOAuthPlatform {
    static var sessions: [UUID: OAuthSessionResult] = [:]

    static func disconnect() {
        for response in sessions.values { response.finish(.failure(FaceWireError.disconnected)) }
    }

}
