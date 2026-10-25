import Foundation
import PersistenceCore
// Blueprint: | `ProviderSignInHandoff.swift` | provider sign-in handoff state |

/// Only the handoff's request identity and outcome live here. NativeOAuthFlow
/// retains exclusive ownership of authentication, cancellation and credentials.
/// Never await a browser inside the shared iCloud action drain.
@MainActor
public final class ProviderSignInHandoff {
    public static let shared = ProviderSignInHandoff()
    public private(set) var states: [String: [String: String]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public func start(
        _ id: String, requestID: String,
        signIn: @escaping @MainActor () async -> Bool,
        publish: @escaping @MainActor () async -> Void
    ) -> [String: String] {
        if let running = states[id], running["state"] == "pending" {
            return receipt(id, requestID: running["request_id"] ?? requestID)
        }
        do {
            try NativeOAuthFlow.validateSignInDestination(providerId: id, dataRoot: PersistenceCore.defaultDataRoot())
        } catch {
            return ["status": "error", "ok": "false", "provider_id": id, "message": error.localizedDescription]
        }
        states[id] = ["request_id": requestID, "state": "pending"]
        tasks[id] = Task {
            let signedIn = await signIn()
            states[id] = ["request_id": requestID, "state": signedIn ? "signed_in" : "failed"]
            tasks[id] = nil
            await publish()
        }
        return receipt(id, requestID: requestID)
    }

    private func receipt(_ id: String, requestID: String) -> [String: String] {
        ["status": "ok", "ok": "true", "provider_id": id,
         "request_id": requestID, "connection_state": "pending"]
    }
}
