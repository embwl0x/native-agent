import BackgroundLoops
import BackgroundWork
import Connectors
import DeviceSync
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SlackBot
import TelegramBot
// Blueprint: | `EngineFaceActs+SettingsConnectors.swift` | Connector settings use credential and allowlist owners, then reconcile their live transport |

extension EngineFaceActs {
    func setConnectorEnabled(_ id: String, enabled: Bool) async throws -> FaceActReply {
        guard let saved = try await engine.connectors.update(id: id, enabled: enabled) else {
            throw Self.failure("connector_update_unconfirmed", "The connector did not confirm the saved switch.", effects: .unknown)
        }
        return try Self.committed(saved, identities: [id])
    }

    func disconnectConnector(_ id: String) async throws -> FaceActReply {
        switch id {
        case "telegram":
            try await engine.telegram.disconnectTelegram(restartPollLoop: {
                let result = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll")
                return result.didRestart
            })
            _ = try await engine.telegram.refresh()
        case "slack":
            _ = try await engine.connectors.disconnectMobileConnector(id: id)
        default: throw Self.failure("connector_disconnect_unavailable", "This connector is controlled by its setup page.")
        }
        return try Self.committed(true, identities: [id])
    }

    func saveConnectorCredentials(_ request: ConnectorCredentialWrite) async throws -> FaceActReply {
        var fields: [String: String] = [:]
        for (key, bytes) in request.fields {
            guard let text = try Self.secret(bytes) else { throw Self.failure("credential_missing", "A required credential field is missing.") }
            fields[key] = text
        }
        switch request.id {
        case "slack":
            let allowed: Set<String> = ["token", "app_token", "allowed_channels", "allowed_users", "require_mention"]
            guard Set(fields.keys).isSubset(of: allowed), let token = fields["token"],
                  let channels = fields["allowed_channels"], let users = fields["allowed_users"],
                  let mention = fields["require_mention"], ["true", "false"].contains(mention) else {
                throw Self.failure("slack_fields_invalid", "Submit the token, allowlists and mention choice together.")
            }
            let result = await NativeOAuthFlow.saveSlackToken(token, appToken: fields["app_token"],
                allowedChannelIds: Set(SlackAllowlist.parseIDs(channels)), allowedUserIds: Set(SlackAllowlist.parseIDs(users)),
                requireMention: mention == "true", dataRoot: engine.dataRoot)
            guard result.ok else { throw Self.failure("slack_save_failed", result.error ?? "Slack did not confirm the credential save.") }
            await ConnectorReadiness.restartSlackLane(root: engine.dataRoot)
            _ = try await engine.connectors.refresh().get()
        case "telegram":
            guard let token = fields["token"] else { throw Self.failure("telegram_token_required", "Enter the Telegram bot token.") }
            let current = try await engine.telegram.load()
            try await engine.telegram.configureTelegram(token: token, allowedChatIds: current.allowedChatIds,
                allowedUserIds: current.allowedUserIds, requireMention: current.requireMention, model: "", reasoningEffort: "", enabled: current.enabled,
                restartPollLoop: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll") })
            _ = try await engine.telegram.refresh()
        default: throw Self.failure("connector_credentials_unavailable", "This connector uses its own sign-in page.")
        }
        return try Self.committed(true, identities: [request.id, request.operation.uuidString])
    }

    func configureTelegram(_ request: TelegramConfigurationWrite) async throws -> FaceActReply {
        let current = try await engine.telegram.load()
        try await engine.telegram.configureTelegram(token: Self.secret(request.token) ?? "", allowedChatIds: request.allowedChatIDs,
            allowedUserIds: request.allowedUserIDs, requireMention: current.requireMention, model: "", reasoningEffort: "", enabled: true,
            restartPollLoop: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll") })
        _ = try await engine.telegram.refresh()
        return try Self.committed(true, identities: ["telegram"])
    }

    func saveSlackIngress(_ request: SlackIngressWrite) async throws -> FaceActReply {
        let root = engine.dataRoot
        let current = try await Task.detached { try SlackSocketModeConfig.loadIngressPolicy(dataRoot: root) }.value
        let result = await NativeOAuthFlow.saveSlackToken(try Self.secret(request.token) ?? "",
            allowedChannelIds: Set(request.allowedChannelIDs), allowedUserIds: Set(request.allowedUserIDs),
            requireMention: current.requireMention, dataRoot: engine.dataRoot)
        guard result.ok else { throw Self.failure("slack_save_failed", result.error ?? "Slack did not confirm the policy save.") }
        await ConnectorReadiness.restartSlackLane(root: engine.dataRoot)
        _ = try await engine.connectors.refresh().get()
        return try Self.committed(true, identities: ["slack"])
    }

    func testTelegram() async throws -> FaceActReply {
        let current = try await engine.telegram.load()
        let target = current.allowedChatIds.first ?? current.allowedUserIds.first
        guard let target else { throw Self.failure("telegram_target_required", "Save an allowed chat or user ID before sending the test reply.") }
        let saved = try await engine.telegram.sendTelegramTestReply(chatId: target, manager: .shared)
        return try Self.committed(saved, identities: ["telegram"])
    }

    func removePhonePairing(_ id: String) async throws -> FaceActReply {
        guard let owner = engine.sync.owner else { throw Self.failure("pairing_unavailable", "Pairing is unavailable on this Mac.") }
        guard await owner.pairedPhones.setStatus(.removed, id: id) else {
            throw Self.failure("pairing_remove_failed", await owner.pairedPhones.message ?? "The phone could not be removed.")
        }
        return try Self.committed(true, identities: [id])
    }
}
