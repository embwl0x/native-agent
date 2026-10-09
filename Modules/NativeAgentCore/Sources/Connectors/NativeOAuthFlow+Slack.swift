import ProviderRouting
import Foundation
import PersistenceCore
import SlackConnector

extension NativeOAuthFlow {
    /// Store a Slack OAuth token that the user already generated in Slack's app
    /// console. Slack's app UI exposes a Bot User OAuth Token after install, so
    /// this path validates that token with auth.test and persists it directly
    /// instead of forcing the generic browser OAuth wizard.
    public static func saveSlackToken(
        _ rawToken: String,
        appToken rawAppToken: String? = nil,
        allowedChannelIds: Set<String>? = nil,
        allowedUserIds: Set<String>? = nil,
        requireMention: Bool? = nil,
        validateWithSlack: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
        do { try SlackCredentials.recoverPendingSave(dataRoot: dataRoot) }
        catch {
            return OAuthFlowResult(ok: false,
                error: "Could not save Slack token: \(NativeOAuthSupport.redact(error.localizedDescription))")
        }
        let providedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = providedToken.isEmpty
            ? (existingSlackBotToken(dataRoot: dataRoot) ?? "")
            : providedToken
        guard isPlausibleSlackToken(token) else {
            return OAuthFlowResult(ok: false,
                error: "Paste a Slack OAuth token such as xoxb-... from OAuth & Permissions, or save the bot token before adding Socket Mode.")
        }
        let appToken = rawAppToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !appToken.isEmpty, !isPlausibleSlackAppToken(appToken) {
            return OAuthFlowResult(ok: false,
                error: "Paste a Slack Socket Mode app token such as xapp-... with connections:write, or leave that field blank.")
        }
        let channels = allowedChannelIds ?? []
        let users = allowedUserIds ?? []
        guard !channels.isEmpty || !users.isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "Add at least one allowed Slack channel or user before saving. NativeAgent will not create an inbound connector with an empty allowlist.")
        }

        let authFields: [String: String]
        if validateWithSlack {
            do {
                authFields = slackAuthFields(try await slackAuthTest(token: token))
            } catch {
                return OAuthFlowResult(ok: false,
                    error: "Slack token validation failed: \(NativeOAuthSupport.redact(error.localizedDescription))")
            }
        } else {
            authFields = [:]
        }

        let root = dataRoot
        let now = NativeOAuthSupport.isoBasic(Date())
        let legacyPath = root
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("slack.json")
        let connectorPath = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("auth.json")
        let persistence = SwiftNativePersistenceCore()

        // Stage an immutable, verified grant before a durable save intent.
        // Startup finishes that exact intent before admitting the connection.
        do {
            try SlackCredentials.recoverPendingSave(dataRoot: root)
            _ = try await ConnectorOAuthRegistry.mutateConnectorRegistryEntry(
                root: root,
                provider: "slack",
                createIfMissing: true,
                publish: { registry, _ in
                    try await persistence.withFileLock(legacyPath) {
                        try await persistence.withFileLock(connectorPath) {
                            // Check both authorities before publishing either destination.
                            var legacy = try ConnectorOAuthRegistry.checkedCredentialObject(at: legacyPath)
                            var connector = try ConnectorOAuthRegistry.checkedCredentialObject(at: connectorPath)
                            let savedAppToken = appToken.isEmpty
                                ? try SlackCredentials.read(.app, dataRoot: root, allowMissingGrant: !providedToken.isEmpty)
                                : appToken
                            let reference = try SlackCredentials.stageGrant(bot: token, app: savedAppToken, dataRoot: root)
                            for path in [legacyPath, connectorPath] {
                                var obj = path == legacyPath ? legacy : connector
                                obj["provider"] = .string("slack")
                                for key in SlackCredentials.fileKeys.values.joined() { obj[key] = nil }
                                obj["credential_store"] = .string("keychain")
                                obj[SlackCredentials.referenceField] = .string(reference)
                                obj["token_type"] = .string("Bearer")
                                obj["auth_mode"] = .string("manual_oauth_token")
                                obj["saved_at"] = .string(now)
                                if !appToken.isEmpty { obj["socket_mode_enabled"] = .bool(true) }
                                mergeSlackIngressFields(
                                    allowedChannelIds: channels,
                                    allowedUserIds: users,
                                    requireMention: requireMention,
                                    into: &obj
                                )
                                mergeSlackAuthFields(authFields, into: &obj)
                                if path == legacyPath { legacy = obj } else { connector = obj }
                            }
                            connector["validated_at"] = validateWithSlack ? .string(now) : nil
                            try SlackCredentials.commitSave(legacy: .object(legacy), connector: .object(connector),
                                                            registry: registry, dataRoot: root)
                        }
                    }
                }
            ) { entry in
                entry["id"] = .string("slack")
                entry["name"] = .string("Slack")
                entry["kind"] = .string("connector")
                entry["description"] = .string("Slack workspace messaging connector.")
                entry["enabled"] = .bool(true)
                entry["registered"] = .bool(true)
                entry["client_id_present"] = .bool(true)
                entry["authState"] = .string("connected")
                entry["healthStatus"] = .string("ok")
                entry["connected"] = .bool(true)
                entry["connected_at"] = .string(now)
                entry["connectedAt"] = .string(now)
            }
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not save Slack token: \(NativeOAuthSupport.redact(error.localizedDescription))")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    private static func isPlausibleSlackToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard lower.hasPrefix("xox") else { return false }
        return token.count > 20 && token.range(of: #"\s"#, options: .regularExpression) == nil
    }

    private static func existingSlackBotToken(dataRoot: URL) -> String? {
        try? SlackCredentials.read(.bot, dataRoot: dataRoot)
    }

    private static func isPlausibleSlackAppToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard lower.hasPrefix("xapp-") else { return false }
        return token.count > 20 && token.range(of: #"\s"#, options: .regularExpression) == nil
    }

    private static func slackAuthTest(token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NativeAgentSlack", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Slack auth.test returned non-JSON."
            ])
        }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "NativeAgentSlack", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Slack auth.test HTTP \(http.statusCode)."
            ])
        }
        if (obj["ok"] as? Bool) != true {
            let err = (obj["error"] as? String) ?? "unknown_error"
            throw NSError(domain: "NativeAgentSlack", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Slack auth.test rejected the token: \(err)"
            ])
        }
        return obj
    }

    private static func slackAuthFields(_ authInfo: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for key in ["url", "team", "team_id", "user", "user_id", "bot_id", "enterprise_id"] {
            if let value = authInfo[key] as? String, !value.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }

    private static func mergeSlackAuthFields(_ authFields: [String: String], into obj: inout [String: JSONValue]) {
        for (key, value) in authFields {
            obj[key] = .string(value)
        }
    }

    private static func mergeSlackIngressFields(
        allowedChannelIds: Set<String>?,
        allowedUserIds: Set<String>?,
        requireMention: Bool?,
        into obj: inout [String: JSONValue]
    ) {
        if let allowedChannelIds {
            obj["allowed_channel_ids"] = .array(allowedChannelIds.sorted().map(JSONValue.string))
        }
        if let allowedUserIds {
            obj["allowed_user_ids"] = .array(allowedUserIds.sorted().map(JSONValue.string))
        }
        if let requireMention {
            obj["require_mention"] = .bool(requireMention)
        }
    }

}
