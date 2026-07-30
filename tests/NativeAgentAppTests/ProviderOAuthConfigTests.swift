import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

struct ProviderOAuthConfigTests {
    @Test func chatGPTOAuthAuthorizationUsesSharedBackendOriginator() throws {
        let url = ProviderOAuthConfig.openai.buildAuthURL(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state",
            challenge: "challenge"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(query["originator"] == OpenAIOAuthDirectAdapter.codexBackendOriginator)
        #expect(query["codex_cli_simplified_flow"] == "true")
        #expect(query["redirect_uri"] == "http://localhost:1455/auth/callback")
    }
}
