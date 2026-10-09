import Foundation
import PersistenceCore

/// The Google credential owner shared by cloud tools and Doctor. One exchange
/// per credential; the file lock spans read, exchange and durable publication.
public enum GoogleOAuthCredentials {
    public struct RefreshError: Error {
        public let statusCode: Int
        public let requiresReauthentication: Bool
    }

    public struct AccountChangedError: LocalizedError {
        public var errorDescription: String? { "Google account changed; retry the request." }
    }

    private struct RefreshResult: Sendable {
        let accountSubject: String
        let originalAccessToken: String?
        let accessToken: String
        let refreshToken: String?

        func token(for rejectedAccessToken: String?, expectedAccountSubject: String?) throws -> String {
            guard accountSubject == expectedAccountSubject else { throw AccountChangedError() }
            if let rejectedAccessToken, rejectedAccessToken != originalAccessToken {
                throw AccountChangedError()
            }
            return accessToken
        }
    }

    private actor RefreshGate {
        static let shared = RefreshGate()
        private var inFlight: [String: Task<RefreshResult, Error>] = [:]
        private var lastRefresh: [String: RefreshResult] = [:]

        func refresh(path: URL, rejectedAccessToken: String?) async throws -> String {
            let key = path.standardizedFileURL.path
            let accountSubject = GoogleOAuthCredentials.string(try GoogleOAuthCredentials.read(path)["account_sub"])
            if let task = inFlight[key] {
                return try await task.value.token(for: rejectedAccessToken, expectedAccountSubject: accountSubject)
            }
            let previousRefresh = lastRefresh[key]
            let task = Task {
                try await SwiftNativePersistenceCore().withFileLock(path) {
                    try await GoogleOAuthCredentials.refreshLocked(
                        path: path, rejectedAccessToken: rejectedAccessToken,
                        previousRefresh: previousRefresh, expectedAccountSubject: accountSubject
                    )
                }
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            let result = try await task.value
            lastRefresh[key] = result
            return try result.token(for: rejectedAccessToken, expectedAccountSubject: accountSubject)
        }
    }

    public static func credentialStatus(path: URL) throws -> OAuthCredentialHealth {
        let object = try read(path)
        if object["expires_at"] != nil && parseExpiresAt(object["expires_at"]) == nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        let hasRefresh = string(object["refresh_token"]) != nil
        let accountSubject = string(object["account_sub"])
        let boundRefresh = hasRefresh && accountSubject != nil
            && accountSubject == string(object["refresh_token_account_sub"])
        return OAuthCredentialHealth(
            configured: string(object["access_token"]) != nil,
            expiresAt: parseExpiresAt(object["expires_at"]),
            canRefresh: boundRefresh,
            requiresRefresh: hasRefresh && !boundRefresh
        )
    }

    /// Bind a new sign-in to the subject from Google's authenticated endpoint.
    public static func accountSubject(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = string(object["sub"]) else {
            throw RefreshError(statusCode: status, requiresReauthentication: true)
        }
        return subject
    }

    public static func refresh(path: URL, rejectedAccessToken: String? = nil) async throws -> String {
        try await RefreshGate.shared.refresh(path: path, rejectedAccessToken: rejectedAccessToken)
    }

    private static func read(_ path: URL) throws -> [String: Any] {
        let data = try ConnectorCredentialFile.read(at: path)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func refreshLocked(
        path: URL, rejectedAccessToken: String?, previousRefresh: RefreshResult?, expectedAccountSubject: String?
    ) async throws -> RefreshResult {
        var object = try read(path)
        guard string(object["account_sub"]) == expectedAccountSubject else { throw AccountChangedError() }
        let originalAccessToken = string(object["access_token"])
        if let rejectedAccessToken, originalAccessToken != rejectedAccessToken {
            // Only an exchange witnessed by this owner proves continuity. A
            // sign-in (or an unobserved refresh) must start a new read instead.
            guard let previousRefresh,
                  previousRefresh.accountSubject == string(object["account_sub"]),
                  previousRefresh.accountSubject == string(object["refresh_token_account_sub"]),
                  previousRefresh.originalAccessToken == rejectedAccessToken,
                  previousRefresh.accessToken == originalAccessToken,
                  previousRefresh.refreshToken == string(object["refresh_token"]) else {
                throw AccountChangedError()
            }
            return previousRefresh
        }
        guard let accountSubject = string(object["account_sub"]),
              accountSubject == string(object["refresh_token_account_sub"]),
              let refreshToken = string(object["refresh_token"]) else {
            throw RefreshError(statusCode: 401, requiresReauthentication: true)
        }
        if let access = originalAccessToken, rejectedAccessToken == nil,
           let expiry = parseExpiresAt(object["expires_at"]), expiry > Date() {
            return RefreshResult(
                accountSubject: accountSubject,
                originalAccessToken: access, accessToken: access,
                refreshToken: string(object["refresh_token"])
            )
        }
        let appPath = path.deletingLastPathComponent().appendingPathComponent("oauth_app.json")
        if FileManager.default.fileExists(atPath: appPath.path) {
            let app = try read(appPath)
            for key in ["client_id", "client_secret"] where object[key] == nil {
                object[key] = app[key]
            }
        }
        guard let clientID = string(object["client_id"]) else {
            throw RefreshError(statusCode: 401, requiresReauthentication: true)
        }
        var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if let secret = string(object["client_secret"]) { fields["client_secret"] = secret }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let tokens = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), let tokens,
              let access = string(tokens["access_token"]) else {
            let rejected = (400..<500).contains(status)
                && ["invalid_grant", "invalid_client", "unauthorized_client"].contains(string(tokens?["error"]) ?? "")
            throw RefreshError(statusCode: status, requiresReauthentication: rejected)
        }
        for (key, value) in tokens { object[key] = value }
        object["refresh_token"] = string(tokens["refresh_token"]) ?? refreshToken
        object["account_sub"] = accountSubject
        object["refresh_token_account_sub"] = accountSubject
        let expiresIn = (tokens["expires_in"] as? NSNumber)?.doubleValue
            ?? (tokens["expires_in"] as? String).flatMap(Double.init) ?? 3_600
        object["expires_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        // Once exchanged, persist the rotating token even if the caller left.
        try ConnectorCredentialFile.write(output, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return RefreshResult(
            accountSubject: accountSubject,
            originalAccessToken: originalAccessToken, accessToken: access,
            refreshToken: string(object["refresh_token"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
