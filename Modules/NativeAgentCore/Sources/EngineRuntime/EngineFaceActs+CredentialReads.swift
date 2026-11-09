import AgentConversations
import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SlackBot
// Blueprint: | `EngineFaceActs+CredentialReads.swift` | Credential reconciliation reads owners without repeating saves or provider requests |

extension EngineFaceActs {
    func readCredential(_ request: FaceCredentialRead) async throws -> FaceActOutcome {
        let root = engine.dataRoot
        let fields = try await Self.credentialFields(request, root: root, pages: engine.pages)
        guard let fields else {
            return .init(words: "The saved state does not confirm this submission. The effect remains unconfirmed; nothing was repeated.", effects: .unknown)
        }
        return .init(words: "The saved state confirms this submission.", effects: .known, accepted: true, committed: fields)
    }

    @concurrent private static func credentialFields(_ request: FaceCredentialRead, root: URL, pages: PartFaces) async throws -> [FaceCommittedField]? {
        switch request {
        case .providerRemoval(let id):
            guard try SwiftNativeProviderRouting(dataRoot: root).confirmsDisconnection(id) else { return nil }
            return [.init(id: "key")]
        case .provider(let write):
            guard try SwiftNativeProviderRouting(dataRoot: root).confirmsConnection(write) else { return nil }
            return [.init(id: "authMode", value: .string(write.authMode))]
                + (write.defaultModel.isEmpty ? [] : [.init(id: "model", value: .string(write.defaultModel))])
                + (write.secret?.isEmpty == false ? [.init(id: "key")] : [])
        case .anthropic(let secret):
            guard try SwiftNativeProviderRouting(dataRoot: root).confirmsAnthropicToken(secret) else { return nil }
            return [.init(id: "token")]
        case .slack(let write):
            return try SlackCredentials.withSnapshot(dataRoot: root) {
                guard let bot = try SlackCredentials.read(.bot, dataRoot: root), !bot.isEmpty else { return nil }
                let policy = try SlackSocketModeConfig.loadIngressPolicy(dataRoot: root)
                func text(_ id: String) throws -> String {
                    guard let value = try Self.secret(write.fields[id]) else { throw Self.failure("slack_field_missing", "Read the Slack setup fields.") }
                    return value
                }
                let channels = try text("allowed_channels"), users = try text("allowed_users"), mention = try text("require_mention")
                guard policy.allowedChannelIds == Set(SlackAllowlist.parseIDs(channels)),
                      policy.allowedUserIds == Set(SlackAllowlist.parseIDs(users)), String(policy.requireMention) == mention else { return nil }
                for (id, kind) in [("token", SlackCredentials.Token.bot), ("app_token", SlackCredentials.Token.app)] {
                    let submitted = try text(id).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !submitted.isEmpty, try SlackCredentials.read(kind, dataRoot: root) != submitted { return nil }
                }
                return [.init(id: "token"), .init(id: "app_token"),
                    .init(id: "allowed_channels", value: .string(policy.allowedChannelIds.sorted().joined(separator: ", "))),
                    .init(id: "allowed_users", value: .string(policy.allowedUserIds.sorted().joined(separator: ", "))),
                    .init(id: "require_mention", value: .bool(policy.requireMention))]
            }
        case .grok(let write):
            let submitted = try JSONDecoder().decode([String: String].self, from: write.secret)
            let saved = try GrokLinkCredential.read(peer: write.contact)
            guard Set(submitted.keys) == ["url", "key"], let url = submitted["url"], let key = submitted["key"],
                  saved.webhookURL == url, saved.webhookKey == key,
                  let contact = try AgentPeerStore(dataRoot: root).list().first(where: { $0.id == write.contact }),
                  contact.transport == .grokBot, contact.grokSetup == "set up", contact.grokBootstrapConfirmed == true else { return nil }
            return [.init(id: "credentials")]
        case .keyring(let request, let bytes):
            guard let secret = try Self.secret(bytes) else { return nil }
            return try await pages.readKeyringForm(request, secret: secret)
        }
    }
}
