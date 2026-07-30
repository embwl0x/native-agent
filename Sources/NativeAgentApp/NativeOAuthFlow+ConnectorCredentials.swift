import Foundation
import PersistenceCore

struct ConnectorOAuthAppCredentials: Sendable, Equatable {
    let clientId: String
    let clientSecret: String?
}

extension NativeOAuthFlow {
    static func connectorOAuthAppCredentials(
        connectorId rawConnectorId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> ConnectorOAuthAppCredentials? {
        guard let config = connectorOAuthConfig(connectorId: rawConnectorId) else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
        let envClientId = environment[config.clientIdEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envSecret = environment[config.clientSecretEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envClientId, !envClientId.isEmpty {
            return ConnectorOAuthAppCredentials(
                clientId: envClientId,
                clientSecret: envSecret?.isEmpty == false ? envSecret : nil
            )
        }

        let path = connectorOAuthAppPath(
            connectorId: config.connectorId,
            dataRoot: dataRoot
        )
        guard let object = try? loadJSONObject(path),
              let clientId = (object["client_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientId.isEmpty else {
            return nil
        }
        let secret = (object["client_secret"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectorOAuthAppCredentials(
            clientId: clientId,
            clientSecret: secret?.isEmpty == false ? secret : nil
        )
    }

    static func saveConnectorOAuthApp(
        connectorId rawConnectorId: String,
        clientId rawClientId: String,
        clientSecret rawClientSecret: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> OAuthFlowResult {
        guard let config = connectorOAuthConfig(connectorId: rawConnectorId) else {
            return OAuthFlowResult(ok: false, error: "Unsupported OAuth connector.")
        }
        let clientId = rawClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = rawClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty, clientId.count <= 512,
              !clientId.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return OAuthFlowResult(ok: false, error: "Enter a valid OAuth client ID.")
        }
        guard clientSecret.count <= 1_024,
              !clientSecret.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return OAuthFlowResult(ok: false, error: "Enter a valid OAuth client secret.")
        }

        let path = connectorOAuthAppPath(
            connectorId: config.connectorId,
            dataRoot: dataRoot
        )
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                var object: [String: Any] = [
                    "client_id": clientId,
                    "connector_id": config.connectorId,
                    "redirect_uri": config.redirectURI,
                    "saved_at": isoBasic(Date()),
                ]
                if !clientSecret.isEmpty {
                    object["client_secret"] = clientSecret
                }
                try writeJSONObject(object, to: path)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path.path
                )
            }
            return OAuthFlowResult(ok: true, error: nil)
        } catch {
            return OAuthFlowResult(
                ok: false,
                error: "Could not save OAuth app configuration: \(error.localizedDescription)"
            )
        }
    }

    static func saveNotionToken(
        _ rawToken: String,
        validate: Bool = true,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        session: URLSession = .shared
    ) async -> OAuthFlowResult {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20, token.count <= 1_024,
              !token.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return OAuthFlowResult(ok: false, error: "Enter a valid Notion integration token.")
        }

        if validate {
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/users/me")!)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    return OAuthFlowResult(
                        ok: false,
                        error: "Notion rejected the token (HTTP \(status)): \(redact(body))"
                    )
                }
            } catch {
                return OAuthFlowResult(
                    ok: false,
                    error: "Could not validate the Notion token: \(redact(error.localizedDescription))"
                )
            }
        }

        let path = connectorTokenPath(connectorId: "notion", dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                try writeJSONObject([
                    "access_token": token,
                    "token_type": "Bearer",
                    "validated_at": isoBasic(Date()),
                ], to: path)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path.path
                )
            }
            return OAuthFlowResult(ok: true, error: nil)
        } catch {
            return OAuthFlowResult(
                ok: false,
                error: "Could not save the Notion token: \(error.localizedDescription)"
            )
        }
    }

    static func connectorOAuthConfig(connectorId rawConnectorId: String) -> ConnectorOAuthConfig? {
        switch rawConnectorId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "x", "twitter": .x
        case "gmail", "email": .gmail
        case "calendar", "gcal", "google_calendar": .calendar
        default: nil
        }
    }

    static func connectorOAuthAppPath(
        connectorId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectorId, isDirectory: true)
            .appendingPathComponent("oauth_app.json")
    }
}
