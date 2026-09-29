import Foundation
import DeviceSync
import TrustCenter

@MainActor
struct AppMacSyncRemoteMacControlPort: MacSyncRemoteMacControlPort {
    let api: NativeClient

    func loadTrustPolicy() async throws -> TrustPolicy {
        try await NativeAgentEngine.live.trust.load()
    }

    func run(path: String, bodyData: Data, timeout: TimeInterval) async throws -> MacSyncRemoteMacControlResult {
        let result = try await api.macControlRun(path: path, bodyData: bodyData, timeout: timeout)
        return MacSyncRemoteMacControlResult(statusCode: result.statusCode, json: result.json, rawData: result.rawData)
    }
}
