import Foundation
import NativeAgentShared

extension MacSyncActionRouter {
    func telegramAction(_ action: InboxAction) async -> [String: String] {
        let payload = action.payload
        let change: MobileTelegramChange
        switch (action.action, payload["setting"]) {
        case ("disconnect_telegram", nil) where payload == ["confirmed": "true"]:
            change = .disconnect
        case ("set_telegram_settings", "enabled"), ("set_telegram_settings", "requireMention"):
            guard let value = payload["value"], ["true", "false"].contains(value) else {
                return Self.invalidTelegramAction
            }
            let widensAccess = payload["setting"] == "enabled" ? value == "true" : value == "false"
            let expectedKeys: Set<String> = widensAccess ? ["setting", "value", "confirmed"] : ["setting", "value"]
            guard Set(payload.keys) == expectedKeys,
                  !widensAccess || payload["confirmed"] == "true" else {
                return Self.invalidTelegramAction
            }
            change = payload["setting"] == "enabled" ? .enabled(value == "true") : .requireMention(value == "true")
        default:
            return Self.invalidTelegramAction
        }
        do {
            let recovered = try await sync.host.changeTelegram(change)
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
