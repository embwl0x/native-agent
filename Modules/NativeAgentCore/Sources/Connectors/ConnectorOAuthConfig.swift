import Foundation

// MARK: - Connector OAuth config

public struct ConnectorOAuthConfig: Sendable {
    public let connectorId: String
    public let clientIdEnv: String
    public let clientSecretEnv: String
    public let authURL: String
    public let tokenURL: String
    public let scopes: String
    public let redirectURI: String
    public let extraAuthParams: [(String, String)]
    public let extraTokenParams: [String: String]

    public static let x = ConnectorOAuthConfig(
        connectorId:    "x",
        clientIdEnv:    "NATIVE_AGENT_X_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_X_CLIENT_SECRET",
        authURL:        "https://twitter.com/i/oauth2/authorize",
        tokenURL:       "https://api.twitter.com/2/oauth2/token",
        // 2026-06-06 x-connector port: match the scope set Agent's
        // persisted token already carries (follows.read + tweet.write +
        // tweet.read + users.read + offline.access). Narrowing here would
        // make a re-auth round-trip downgrade her capabilities.
        scopes:         "follows.read offline.access tweet.write users.read tweet.read",
        redirectURI:    "http://127.0.0.1:53682/oauth/callback",
        extraAuthParams: [],
        extraTokenParams: [:]
    )

    public static let gmail = ConnectorOAuthConfig(
        connectorId:    "gmail",
        clientIdEnv:    "NATIVE_AGENT_GMAIL_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_GMAIL_CLIENT_SECRET",
        authURL:        "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURL:       "https://oauth2.googleapis.com/token",
        scopes:         "openid https://www.googleapis.com/auth/gmail.readonly",
        redirectURI:    "http://127.0.0.1:53683/oauth/callback",
        // Google requires access_type=offline + prompt=consent to reliably
        // return a refresh_token for an already-consented user.
        extraAuthParams: [("access_type", "offline"), ("prompt", "consent")],
        extraTokenParams: [:]
    )

    public static let calendar = ConnectorOAuthConfig(
        connectorId:    "calendar",
        clientIdEnv:    "NATIVE_AGENT_CALENDAR_CLIENT_ID",
        clientSecretEnv:"NATIVE_AGENT_CALENDAR_CLIENT_SECRET",
        authURL:        "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURL:       "https://oauth2.googleapis.com/token",
        scopes:         "openid https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events",
        redirectURI:    "http://127.0.0.1:53684/oauth/callback",
        extraAuthParams: [("access_type", "offline"), ("prompt", "consent")],
        extraTokenParams: [:]
    )
}
