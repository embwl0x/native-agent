import Foundation
import DeviceSync
import TrustCenter
import PersistenceCore

@MainActor
struct AppMacSyncRemoteMacControlPort: MacSyncRemoteMacControlPort {

    func loadTrustPolicy() async throws -> TrustPolicy {
        try await NativeAgentEngine.live.trust.load()
    }

    func run(path: String, bodyData: Data, timeout: TimeInterval) async throws -> MacSyncRemoteMacControlResult {
        let result = try await TrustCenterMacControlPolicyProvider.run(
            path: path, bodyData: bodyData, dataRoot: PersistenceCore.defaultDataRoot(), localWorkbench: false
        )
        return MacSyncRemoteMacControlResult(statusCode: result.statusCode, json: result.json, rawData: result.rawData)
    }
}
