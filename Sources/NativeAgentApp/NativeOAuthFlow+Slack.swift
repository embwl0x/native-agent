import Foundation
import PersistenceCore

extension NativeOAuthFlow {
    /// Store a Slack OAuth token that the user already generated in Slack's app
    /// console. Slack's app UI exposes a Bot User OAuth Token after install, so
    /// this path validates that token with auth.test and persists it directly
    /// instead of forcing the generic browser OAuth wizard.
    static func saveSlackToken(
        _ rawToken: String,
        appToken rawAppToken: String? = nil,
        validateWithSlack: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
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

        let authFields: [String: String]
        if validateWithSlack {
            do {
                authFields = slackAuthFields(try await slackAuthTest(token: token))
            } catch {
                return OAuthFlowResult(ok: false,
                    error: "Slack token validation failed: \(redact(error.localizedDescription))")
            }
        } else {
            authFields = [:]
        }

        let root = dataRoot
        let now = isoBasic(Date())
        let legacyPath = root
            .appendingPathComponent("oauth_tokens", isDirectory: true)
            .appendingPathComponent("slack.json")
        let connectorPath = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("auth.json")
        let persistence = SwiftNativePersistenceCore()

        do {
            try await persistence.withFileLock(legacyPath) {
                var obj: [String: Any] = (try? loadJSONObject(legacyPath)) ?? [:]
                obj["provider"] = "slack"
                obj["access_token"] = token
                obj["token_type"] = "Bearer"
                obj["auth_mode"] = "manual_oauth_token"
                obj["saved_at"] = now
                mergeSlackSocketModeFields(appToken: appToken, into: &obj)
                mergeSlackAuthFields(authFields, into: &obj)
                try writeJSONObject(obj, to: legacyPath)
            }

            try await persistence.withFileLock(connectorPath) {
                var obj: [String: Any] = (try? loadJSONObject(connectorPath)) ?? [:]
                obj["provider"] = "slack"
                obj["access_token"] = token
                obj["token_type"] = "Bearer"
                obj["auth_mode"] = "manual_oauth_token"
                obj["saved_at"] = now
                obj["validated_at"] = validateWithSlack ? now : nil
                mergeSlackSocketModeFields(appToken: appToken, into: &obj)
                mergeSlackAuthFields(authFields, into: &obj)
                try writeJSONObject(obj, to: connectorPath)
            }

            _ = try await NativeClient.mutateConnectorRegistryEntry(
                root: root,
                provider: "slack",
                createIfMissing: true
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
                error: "Could not save Slack token: \(redact(error.localizedDescription))")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    private static func isPlausibleSlackToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard lower.hasPrefix("xox") else { return false }
        return token.count > 20 && token.range(of: #"\s"#, options: .regularExpression) == nil
    }

    private static func existingSlackBotToken(dataRoot: URL) -> String? {
        let paths = [
            dataRoot
                .appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("auth.json"),
            dataRoot
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("slack.json"),
        ]
        for path in paths {
            guard let object = try? loadJSONObject(path),
                  let token = object["access_token"] as? String else {
                continue
            }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

    private static func mergeSlackAuthFields(_ authFields: [String: String], into obj: inout [String: Any]) {
        for (key, value) in authFields {
            obj[key] = value
        }
    }

    private static func mergeSlackSocketModeFields(appToken: String, into obj: inout [String: Any]) {
        guard !appToken.isEmpty else { return }
        obj["app_token"] = appToken
        obj["socket_mode_app_token"] = appToken
        obj["socket_mode_enabled"] = true
    }

}
