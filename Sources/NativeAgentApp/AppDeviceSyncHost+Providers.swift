import Foundation
import PersistenceCore
import ProviderRouting

extension AppDeviceSyncHost {
    @MainActor
    func startProviderSignIn(_ id: String, requestID: String) -> [String: String] {
        ProviderSignInHandoff.shared.start(id, requestID: requestID)
    }

    @MainActor
    func providerSignInStates() -> [String: [String: String]] { ProviderSignInHandoff.shared.states }
}

/// Only the handoff's request identity and outcome live here. NativeOAuthFlow
/// retains exclusive ownership of authentication, cancellation and credentials.
/// Never await a browser inside the shared iCloud action drain.
@MainActor
private final class ProviderSignInHandoff {
    static let shared = ProviderSignInHandoff()
    private(set) var states: [String: [String: String]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(_ id: String, requestID: String) -> [String: String] {
        if let running = states[id], running["state"] == "pending" {
            return receipt(id, requestID: running["request_id"] ?? requestID)
        }
        do {
            try NativeOAuthFlow.validateSignInDestination(providerId: id, dataRoot: PersistenceCore.defaultDataRoot())
        } catch {
            return ["status": "error", "ok": "false", "provider_id": id,
                    "message": "Saved sign-in settings are damaged or unreadable. Repair them on the Mac before signing in."]
        }
        states[id] = ["request_id": requestID, "state": "pending"]
        tasks[id] = Task {
            let root = PersistenceCore.defaultDataRoot()
            let result = await NativeOAuthFlow.startOAuthFlow(
                platform: NativeOAuthPlatform.self, providerId: id, dataRoot: root
            )
            let signedIn = result.ok && NativeOAuthFlow.isSignedIn(providerId: id, dataRoot: root)
            if signedIn {
                await QuietSelfAdmin.shared.appModel?.adoptProviderForBlankSurfaces(id)
            }
            states[id] = ["request_id": requestID, "state": signedIn ? "signed_in" : "failed"]
            tasks[id] = nil
            await NativeAgentEngine.live.deviceSync?.engine.writeSnapshots(forceHeavy: true)
        }
        return receipt(id, requestID: requestID)
    }

    private func receipt(_ id: String, requestID: String) -> [String: String] {
        ["status": "ok", "ok": "true", "provider_id": id,
         "request_id": requestID, "connection_state": "pending"]
    }
}
