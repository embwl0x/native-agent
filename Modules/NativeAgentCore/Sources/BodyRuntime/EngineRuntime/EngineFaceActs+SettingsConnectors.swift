import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import DeskCore
// Blueprint: | `EngineFaceActs+SettingsConnectors.swift` | Connector settings use credential and allowlist owners, then reconcile their live transport |

extension EngineFaceActs {
    func saveConnectorCredentials(_ request: ConnectorCredentialWrite) async throws -> FaceActReply {
        var fields: [String: String] = [:]
        for (key, bytes) in request.fields {
            guard let text = try Self.secret(bytes) else { throw Self.failure("credential_missing", "A required credential field is missing.") }
            fields[key] = text
        }
        var issue: WireFailure?
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
            do { _ = try await engine.connectors.refresh().get() }
            catch {
                issue = Self.publicationIssue("connector_publication_failed",
                    "Slack setup was saved, but Connectors could not be read.", error)
            }
        case "telegram":
            guard let token = fields["token"] else { throw Self.failure("telegram_token_required", "Enter the Telegram bot token.") }
            let current = try await engine.telegram.load()
            try await engine.telegram.configureTelegram(token: token, allowedChatIds: current.allowedChatIds,
                allowedUserIds: current.allowedUserIds, requireMention: current.requireMention, model: "", reasoningEffort: "", enabled: current.enabled,
                restartPollLoop: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll") })
            do { _ = try await engine.telegram.refresh() }
            catch {
                issue = Self.publicationIssue("connector_publication_failed",
                    "The Telegram token was saved, but Telegram settings could not be read.", error)
            }
        default: throw Self.failure("connector_credentials_unavailable", "This connector uses its own sign-in page.")
        }
        return try Self.committed(true, identities: [request.id, request.operation.uuidString], publicationFailure: issue)
    }
}
