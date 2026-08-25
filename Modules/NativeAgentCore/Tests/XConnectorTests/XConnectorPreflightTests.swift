import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import XConnector

// Eval coverage (ledger fence core.connectors) for the X connector's
// input boundary. `x.post_tweet` is an IRREVERSIBLE public write and every
// read action hangs off one comma-joined `tweet.fields` string; neither had
// any test. Both suites below run WITHOUT touching the network: the input
// guards fire before `currentBearer()` is ever reached, and the query
// builders are pure.

@Suite("X connector input boundary")
struct XConnectorPreflightTests {
    private func failure(_ value: JSONValue) -> (status: String?, error: String?, detail: String?) {
        guard case .object(let object) = value else { return (nil, nil, nil) }
        func str(_ key: String) -> String? {
            if case .string(let s)? = object[key] { return s }
            return nil
        }
        return (str("status"), str("error"), str("detail"))
    }

    // XConnectorActions.swift:70. Empty or whitespace-only text must be
    // refused BEFORE a bearer is resolved — otherwise an empty post attempt
    // can rotate the refresh token, and a blank tweet is a public artifact
    // that cannot be taken back.
    @Test
    func postTweetRefusesEmptyTextBeforeResolvingACredential() async throws {
        for input: [String: JSONValue] in [
            [:],
            ["text": .string("")],
            ["text": .string("   \n\t ")],
        ] {
            let envelope = try await XConnectorActions.postTweet(input: input)
            let parsed = failure(envelope)
            #expect(parsed.status == "failed")
            #expect(parsed.error == "missing_input")
            #expect(parsed.detail?.isEmpty == false)
        }
    }

    // XConnectorActions.swift:48. An empty query must not become a
    // match-everything recent search.
    @Test
    func searchRecentRefusesAnEmptyQueryBeforeResolvingACredential() async throws {
        let envelope = try await XConnectorActions.searchRecent(input: ["query": .string("  ")])
        let parsed = failure(envelope)
        #expect(parsed.status == "failed")
        #expect(parsed.error == "missing_input")
    }

    @Test("X status reports a missing OAuth2 token as a failed envelope")
    func statusDoesNotClaimConnectionWithoutOAuth2Token() async throws {
        // The normal test-process root is deliberately empty. `status` reaches
        // `currentBearer` first, which fails before any HTTP request can be
        // formed; this is a real action-path negative control, not a hand-built
        // failure object.
        let value = try await XConnectorActions.status(input: [:])
        let parsed = failure(value)
        #expect(parsed.status == "failed")
        #expect(parsed.error == "missing_oauth2_token")
        #expect(parsed.detail?.contains("not connected") == true)
    }

    // XConnectorActions.swift:693. A leading @ is stripped exactly once; an
    // empty username resolves to nil rather than an empty path segment (which
    // would read someone else's — or nobody's — timeline).
    @Test
    func usernameNormalizationStripsOneAtSignAndRefusesEmptiness() throws {
        #expect(XConnectorActions.normalizedUsername("@nativeagent") == "nativeagent")
        #expect(XConnectorActions.normalizedUsername("  @nativeagent  ") == "nativeagent")
        #expect(XConnectorActions.normalizedUsername("@@nativeagent") == "@nativeagent")
        #expect(XConnectorActions.normalizedUsername("") == nil)
        #expect(XConnectorActions.normalizedUsername("   ") == nil)
        #expect(XConnectorActions.normalizedUsername("@") == nil)
        #expect(XConnectorActions.normalizedUsername(nil) == nil)
    }
}

@Suite("X read-query field contract")
struct XConnectorQueryContractTests {
    // XConnectorActions.swift:9 — `tweetFields` is a single comma-joined
    // string. X rejects the WHOLE request when one field name is invalid, and
    // quietly REMOVING one leaves calls succeeding while every downstream
    // consumer of that field sees null. Pin it as the wire contract it is.
    private static let expectedTweetFields = [
        "id", "text", "author_id", "created_at",
        "public_metrics", "conversation_id", "referenced_tweets", "lang",
    ]

    private func fields(_ query: [(String, String)], _ name: String) -> String? {
        query.first { $0.0 == name }?.1
    }

    @Test
    func timelineAndUserTweetQueriesRequestTheSameFullTweetFieldSet() throws {
        for query in [
            XConnectorActions.timelineQuery(input: [:]),
            XConnectorActions.userTweetsQuery(input: [:]),
        ] {
            let raw = try #require(fields(query, "tweet.fields"))
            let requested = raw.split(separator: ",").map(String.init)
            #expect(requested == Self.expectedTweetFields)
            // Defaults must be present and sane rather than absent.
            #expect(fields(query, "max_results") == "25")
        }
    }

    @Test
    func readQueriesClampPageSizeAndPassPaginationThrough() throws {
        let clampedHigh = XConnectorActions.timelineQuery(input: ["max": .int(5_000)])
        #expect(fields(clampedHigh, "max_results") == "100")
        let clampedLow = XConnectorActions.userTweetsQuery(input: ["max": .int(0)])
        #expect(fields(clampedLow, "max_results") == "1")

        let paged = XConnectorActions.userTweetsQuery(input: [
            "next_token": .string("cursor-1"),
            "exclude": .string("retweets"),
        ])
        #expect(fields(paged, "pagination_token") == "cursor-1")
        #expect(fields(paged, "exclude") == "retweets")

        // A blank cursor must be OMITTED, not sent as an empty parameter.
        let blank = XConnectorActions.userTweetsQuery(input: ["next_token": .string("   ")])
        #expect(fields(blank, "pagination_token") == nil)
    }
}
