import Foundation
import NativeAgentShared

extension MacSyncActionRouter {
    func applyTrustAction(_ payload: [String: String]) async throws -> [String: String] {
        guard let request = MobileTrustAction(payload: payload) else {
            return ["status": "error", "ok": "false", "message": "Invalid or unconfirmed trust change."]
        }
        let recovered = try await sync.host.applyMobileTrustAction(request)
        return ["status": "ok", "ok": "true", "policy": String(decoding: recovered, as: UTF8.self)]
    }
}
