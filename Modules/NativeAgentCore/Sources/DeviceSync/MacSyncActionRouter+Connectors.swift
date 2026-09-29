import Foundation

extension MacSyncActionRouter {
    func connectorAction(_ action: InboxAction) async throws -> [String: String] {
        if let message = sync.pairedPhones.authorize(action, requiresPairing: true) {
            return ["status": "error", "ok": "false", "code": "device_not_verified", "message": message]
        }
        let payload = action.payload
        let allowedKeys: Set<String> = action.action == "set_connector_enabled"
            ? ["id", "enabled"] : ["id"]
        guard Set(payload.keys) == allowedKeys,
              let id = payload["id"], !id.isEmpty else {
            return ["status": "error", "message": "A connector id and only the supported connector settings are required."]
        }
        let recovered: DeviceSyncSnapshotRows
        switch action.action {
        case "set_connector_enabled":
            guard let value = payload["enabled"], value == "true" || value == "false" else {
                return ["status": "error", "message": "Connector enabled must be true or false."]
            }
            recovered = try await sync.host.setConnectorEnabled(id: id, enabled: value == "true")
        case "disconnect_connector":
            recovered = try await sync.host.disconnectConnector(id: id)
        default:
            return ["status": "error", "message": "Unsupported connector action."]
        }
        let data = try JSONEncoder().encode(recovered)
        return ["status": "ok", "ok": "true", "connector": String(decoding: data, as: UTF8.self)]
    }
}
