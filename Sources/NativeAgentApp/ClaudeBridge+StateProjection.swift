import Foundation
import Network
import Agents
import Cognition
import ContextFlow
import PersistenceCore

/// HTTP lifecycle and app bindings for the Core state projection.
extension ClaudeBridge {
    func handleState(conn: NWConnection) {
        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool: exactly
        // one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        // 2026-09-23: .userInitiated; at .utility the first /codex/state reply
        // nearly missed the installer's 2s liveness check.
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let payload = await ClaudeBridgeStateProjection.statePayload(
                dataRoot: NativeAgentPaths.dataRoot,
                port: StatePort(bridge: self)
            )
            guard workLatch.claim() else { return }
            self.writeJSON(conn, status: 200, obj: payload)
        }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/claude/state",
                "seconds": Self.readWorkDeadlineSeconds,
            ])
        }
    }

    func readActivePersona(dataRoot: URL) -> String? {
        ClaudeBridgeStateProjection.readActivePersona(
            dataRoot: dataRoot, preferred: UserDefaults.standard.string(forKey: "chatPersona")
        )
    }

    func readBridgeActiveSession(dataRoot: URL) -> (id: String?, updatedAt: String?) {
        ClaudeBridgeStateProjection.readBridgeActiveSession(
            dataRoot: dataRoot, preferred: { UserDefaults.standard.string(forKey: "activeChatSessionId") }
        )
    }

    private struct StatePort: ClaudeBridgeStatePort {
        let bridge: ClaudeBridge
        var startedAt: Date { bridge.startedAt }
        var preferredPersona: String? { UserDefaults.standard.string(forKey: "chatPersona") }
        var preferredSessionID: String? { UserDefaults.standard.string(forKey: "activeChatSessionId") }
        var cognition: NativeCognitionRuntime { NativeAgentEngine.liveCognition }
        var contextFlow: NativeContextFlowRuntime { NativeAgentEngine.live.contextFlow }
        func recentEventPayloads() -> [[String: Any]] { bridge.recentEventPayloads() }
    }
}
