import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CodexOAuthAccessContext.swift` | Checked Codex OAuth access identity and stable re-sign-in-required exhaustion marker |
/// Credential exhaustion requires sign-in repair, never a switch to an API-key route.
public let OpenAIOAuthDirectExhaustedMarker = "openai_oauth_direct_exhausted: re-sign-in required"

public struct CodexOAuthAccessContext: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String
    public let authPath: URL

    public init(accessToken: String, accountID: String, authPath: URL) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.authPath = authPath
    }
}
