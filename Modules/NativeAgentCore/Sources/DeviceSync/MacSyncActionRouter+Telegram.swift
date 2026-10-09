import Foundation
import NativeAgentShared

extension MacSyncActionRouter {
    func telegramAction(_ action: InboxAction) async -> [String: String] {
        let payload = action.payload
        do {
            let recovered: MobileTelegramSnapshot
            if action.action == "disconnect_telegram", payload == ["confirmed": "true"] {
                recovered = try await sync.host.changeTelegram(.disconnect)
            } else if action.action == "set_telegram_settings",
                      let setting = payload["setting"], ["enabled", "requireMention"].contains(setting),
                      let value = payload["value"], ["true", "false"].contains(value),
                      Set(payload.keys).isSubset(of: ["setting", "value", "confirmed"]),
                      (setting == "enabled" && value == "false")
                        || (setting == "requireMention" && value == "true") || payload["confirmed"] == "true" {
                _ = try await sync.host.setAppSetting(
                    id: setting == "enabled" ? "telegram.enabled" : "telegram.require_mention",
                    value: value, actionID: action.msgId, clientID: action.clientId)
                recovered = try await sync.host.telegramSnapshot()
            } else {
                return Self.invalidTelegramAction
            }
            let data = try JSONEncoder().encode(recovered)
            return ["status": "ok", "ok": "true", "telegram": String(decoding: data, as: UTF8.self)]
        } catch {
            // Telegram errors may contain transport URLs carrying a bot token.
            return ["status": "error", "ok": "false", "message": "Telegram could not confirm the change. Refresh its settings before trying again."]
        }
    }

    private static var invalidTelegramAction: [String: String] {
        ["status": "error", "ok": "false", "message": "Invalid Telegram settings request."]
    }
}
