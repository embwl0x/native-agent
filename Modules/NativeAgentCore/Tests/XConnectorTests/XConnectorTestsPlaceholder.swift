import Foundation
import NativeAgentCore
import Testing
@testable import XConnector

@Suite("X connector request and credential boundaries")
struct XConnectorTests {
    @Test
    func oauth1SignerMatchesThePublishedProtocolVector() throws {
        let header = XConnectorActions.oauth1AuthHeader(
            method: "POST",
            url: try #require(URL(string: "http://example.com/request")),
            query: [
                ("b5", "=%3D"),
                ("a3", "a"),
                ("c@", ""),
                ("a2", "r b"),
            ],
            formBody: [("c2", ""), ("a3", "2 q")],
            credentials: XConnectorActions.OAuth1Credentials(
                apiKey: "9djdj82h48djs9d2",
                apiSecret: "j49sk3j29djd",
                accessToken: "kkk9d7dh3k39sjv7",
                accessTokenSecret: "dh893hdasih9"
            ),
            nonce: "7d8f3e4a",
            timestamp: 137_131_201
        )

        #expect(header.contains("oauth_signature=\"OB33pYjWAnf%2BxtOHN4Gmbdil168%3D\""))
        #expect(header.contains("oauth_nonce=\"7d8f3e4a\""))
        #expect(header.contains("oauth_timestamp=\"137131201\""))
    }

    @Test
    func refreshGateCoalescesConcurrentRotatingTokenRefreshes() async throws {
        let gate = XConnectorActions.RefreshGate()
        let counter = RefreshCounter()

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.resolveBearer {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(25))
                        return "fresh-access-token"
                    }
                }
            }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }

        #expect(values.count == 20)
        #expect(values.allSatisfy { $0 == "fresh-access-token" })
        #expect(await counter.value == 1)
    }

    @Test
    func tokenPersistenceIsAtomicJSONWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-xconnector-tests-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("oauth_tokens/x.json")

        try XConnectorActions.saveOAuth2Token([
            "access_token": "access",
            "refresh_token": "refresh",
            "expires_at": "12345",
        ], to: path)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: String]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        #expect(object["access_token"] == "access")
        #expect(object["refresh_token"] == "refresh")
        #expect(permissions & 0o777 == 0o600)
    }

    @Test
    func queryEncodingAndBoundsPreserveExactWireValues() throws {
        #expect(XConnectorActions.percentEncode("Ladies + Gentlemen") == "Ladies%20%2B%20Gentlemen")
        #expect(XConnectorActions.formEncode([("a b", "x+y")]) == "a%20b=x%2By")
        #expect(XConnectorActions.normalizedUsername("  @nativeagent  ") == "nativeagent")

        let query = XConnectorActions.timelineQuery(input: [
            "max": .int(5_000),
            "exclude": .string("retweets,replies"),
            "next_token": .string("page + one"),
        ])
        let values = Dictionary(uniqueKeysWithValues: query)
        #expect(values["max_results"] == "100")
        #expect(values["exclude"] == "retweets,replies")
        #expect(values["pagination_token"] == "page + one")

        let url = XConnectorActions.appendQuery(
            query,
            to: try #require(URL(string: "https://api.twitter.com/2/users/me?existing=yes"))
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let decoded = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        #expect(decoded["existing"] == "yes")
        #expect(decoded["pagination_token"] == "page + one")
    }

    @Test
    func httpFailureEnvelopeCarriesTypedStatusAndBoundsRemoteBody() throws {
        let payload = Data(String(repeating: "x", count: 500).utf8)
        let result = XConnectorActions.httpFailureEnvelope(
            actionId: "x.search_recent",
            statusCode: 429,
            data: payload
        )
        guard case .object(let object) = result else {
            Issue.record("expected object envelope")
            return
        }

        #expect(object["status"] == .string("failed"))
        #expect(object["error"] == .string("http_429"))
        #expect(object["statusCode"] == .int(429))
        guard case .string(let detail) = object["detail"] else {
            Issue.record("expected detail string")
            return
        }
        #expect(detail == "X API HTTP 429: " + String(repeating: "x", count: 400))
    }
}

private actor RefreshCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
