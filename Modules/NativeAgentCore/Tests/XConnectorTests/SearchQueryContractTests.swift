import Testing
import PersistenceCore
@testable import XConnector

@Test func toolContractXSearchWebOperatorNormalization() throws {
    for (web, api) in [("filter:retweets", "is:retweet"), ("filter:replies", "is:reply"),
                       ("filter:links", "has:links"), ("filter:media", "has:media"),
                       ("filter:images", "has:images"), ("filter:videos", "has:video_link")] {
        for prefix in ["", "-"] {
            #expect(try XConnectorActions.recentSearchQuery(.string("swift \(prefix)\(web)"))
                == "swift \(prefix)\(api)")
        }
        #expect(try XConnectorActions.recentSearchQuery(.string("swift \"\(web)\""))
            == "swift \"\(web)\"")
        #expect(try XConnectorActions.recentSearchQuery(.string("swift \(api)")) == "swift \(api)")
    }
    #expect(try XConnectorActions.recentSearchQuery(.string("from:XDevelopers -filter:retweets"))
        == "from:XDevelopers -is:retweet")
    #expect(try XConnectorActions.recentSearchQuery(.string("\"filter:retweets\" -filter:links"))
        == "\"filter:retweets\" -has:links")
    #expect(try XConnectorActions.recentSearchQuery(.string("(swift OR macOS) lang:en -is:retweet"))
        == "(swift OR macOS) lang:en -is:retweet")
}

@Test func toolContractXSearchAcceptsMinimumReplies() throws {
    for query in ["min_replies:10", "from:XDevelopers min_replies:10", "min_replies:0 -is:retweet"] {
        #expect(try XConnectorActions.recentSearchQuery(.string(query)) == query)
    }
}

@Test func toolContractXSearchPreservesUnrecognizedSyntax() throws {
    for query in ["has:media", "has:links OR is:retweet", "-from:XDevelopers", "swift since:2026-09-01",
                  "swift min_faves:10", "swift filter:unknown", "\"swift", "(swift", "swift OR", "from:",
                  "filter:links \"unclosed", "swift filter:videos_extra", "prefix:filter:links"] {
        #expect(try XConnectorActions.recentSearchQuery(.string(query)) == query)
    }
}

@Test func toolContractXSearchPreservesOriginalSpacingAndLiterals() throws {
    #expect(try XConnectorActions.recentSearchQuery(.string("  (cat\tOR dog)\n(-FILTER:VIDEOS  filter:links)  "))
        == "  (cat\tOR dog)\n(-has:video_link  has:links)  ")
    let query = #"猫 "a \" filter:links" (filter:images)"#
    #expect(try XConnectorActions.recentSearchQuery(.string(query))
        == #"猫 "a \" filter:links" (has:images)"#)
}

@Test func toolContractXSearchChecksFinalLength() throws {
    for length in [511, 512] {
        let query = String(repeating: "a", count: length - 14) + " (cat OR dog) "
        #expect(query.count == length)
        #expect(try XConnectorActions.recentSearchQuery(.string(query)) == query)
    }
    let shortened = String(repeating: "a", count: 501) + " filter:retweets"
    #expect(try XConnectorActions.recentSearchQuery(.string(shortened))
        == String(repeating: "a", count: 501) + " is:retweet")
    let atLimit = String(repeating: "a", count: 497) + " filter:videos"
    #expect(try XConnectorActions.recentSearchQuery(.string(atLimit))
        == String(repeating: "a", count: 497) + " has:video_link")
}

@Test func toolContractXSearchRejectsExcessLengthBeforeCredentials() async throws {
    for query in [String(repeating: "a", count: 513),
                  String(repeating: "a", count: 498) + " filter:videos"] {
        let result = try await XConnectorActions.searchRecent(input: ["query": .string(query), "max": .int(3)])
        guard case .object(let fields) = result, case .string(let detail)? = fields["detail"] else {
            Issue.record("Missing input error for \(query)"); continue
        }
        #expect(fields["error"] == .string("invalid_input"))
        #expect(detail.contains("query") && detail.contains("Example: from:XDevelopers -is:retweet"))
    }
}
