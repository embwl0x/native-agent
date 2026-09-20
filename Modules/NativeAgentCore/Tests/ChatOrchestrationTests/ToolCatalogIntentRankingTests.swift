import Foundation
import Testing
import NativeAgentCore
@testable import ChatOrchestration

@Suite struct ToolCatalogIntentRankingTests {
    private func ranked(_ query: String) -> [String] {
        let factory = BuiltInToolSchemaFactory(requestedNames: nil)
        var available = factory.coreSchemas()
        available += factory.standingBotSchemas() + factory.agentCommunicationSchemas()
        factory.appendOptionalSchemas(
            to: &available, includeFullMacFileTools: true,
            includeFullMacSystemTools: false, includeFullMacAppTools: false,
            includeFullMacAccessibilityReadTools: false, includeFullMacAccessibilityInjectionTools: false,
            includeActivityQueryTool: false
        )
        let schemas = available.compactMap { $0 }
        let needles = SwiftToolDispatcher.catalogSearchNeedles(query)
        var matches: [(name: String, score: Int)] = []
        for schema in schemas {
            let score: Int = SwiftToolDispatcher.catalogSearchScore(
                name: schema.name, description: schema.description, groups: [], needles: needles, query: query
            )
            if score > 0 { matches.append((name: schema.name, score: score)) }
        }
        matches.sort { left, right in
            if left.score == right.score { return left.name < right.name }
            return left.score > right.score
        }
        let bestScore = matches.first?.score ?? 0
        return matches.filter {
            SwiftToolDispatcher.catalogSearchIsShortlisted(score: $0.score, bestScore: bestScore)
        }.map { $0.name }
    }

    @Test(arguments: [
        "who can I message",
        "list registered coding agents bots status availability",
        "discover registered coding helpers agents standing bots availability status",
        "find available agents and bots to help",
    ])
    func agentDirectoryIsDiscoverableWithoutKnowingItsToolName(query: String) {
        #expect(ranked(query).prefix(3).contains("agent_contacts"))
    }

    @Test(arguments: [
        "find a file by filename in a folder and read a bounded section",
        "search file names within directory",
    ])
    func localFileDiscoveryKeepsItsSubject(query: String) {
        let names = ranked(query)
        let directory = names.firstIndex(of: "list_dir") ?? Int.max
        #expect(directory < 5, "The requested directory filter must be discoverable on the first page")
        #expect(!names.contains("contacts_search"), "Contact names are not file names")
        for unrelated in ["notes_search", "notion_search", "slack_search_messages", "github_search", "write_file"] {
            #expect(directory < (names.firstIndex(of: unrelated) ?? Int.max), "Directory filtering should precede \(unrelated)")
        }
    }

    @Test(arguments: [
        ("search Slack messages", "slack_search_messages"),
        ("search Notion pages", "notion_search"),
        ("search Apple Notes", "notes_search"),
        ("search GitHub issues", "github_search"),
        ("correct a memory", "rewrite_memory"),
        ("read a file", "read_file"),
        ("write a file", "write_file"),
        ("search files on Mac", "mac_spotlight_search"),
        ("search text within exact local file", "grep"),
        ("find a phrase inside a log file", "grep"),
        ("locate matching lines in a local text file", "grep"),
    ])
    func neighboringOperationsRemainDiscoverable(query: String, expected: String) {
        let names = ranked(query)
        #expect(names.prefix(5).contains(expected), "Expected \(expected) near the top for \(query)")
        if expected == "rewrite_memory" {
            #expect((names.firstIndex(of: expected) ?? Int.max) < (names.firstIndex(of: "list_memories") ?? Int.max))
        }
    }

    @Test func fillerAndRepetitionDoNotChangeTheIntent() {
        #expect(ranked("please search for files in the directory") == ranked("search files directory"))
        #expect(ranked("search files files directory directory") == ranked("search files directory"))
        #expect(ranked("please and the within").isEmpty)
    }

    @Test func recoveryAdviceDoesNotMakeAWriterAReader() {
        let query = SwiftToolDispatcher.catalogSearchNeedles("read a file")
        let read = SwiftToolDispatcher.catalogSearchScore(
            name: "file_reader", description: "Read a file.", groups: [], needles: query
        )
        let write = SwiftToolDispatcher.catalogSearchScore(
            name: "file_writer", description: "Write a file. Read a file first to inspect it before writing.", groups: [], needles: query
        )
        #expect(read > write)
    }

    @Test func exactNamesAndVerbOnlySearchStillWork() {
        #expect(ranked("mac_spotlight_search").prefix(5).contains("mac_spotlight_search"))
        #expect(!ranked("search").isEmpty)
    }

    @Test(arguments: [
        ("grep count matching lines in local files", "grep"),
        ("Please inspect `read_chat_message` for exact historical evidence", "read_chat_message"),
        ("Explain MAC_SPOTLIGHT_SEARCH filename lookup", "mac_spotlight_search"),
        ("Explain browser.status connection state", "browser.status"),
        ("Inspect grep.", "grep"),
    ])
    func explicitIdentifierSurvivesDescriptiveNoise(query: String, name: String) {
        let score = SwiftToolDispatcher.catalogSearchScore(
            name: name, description: "A tool.", groups: [],
            needles: SwiftToolDispatcher.catalogSearchNeedles(query), query: query
        )
        let descriptive = SwiftToolDispatcher.catalogSearchScore(
            name: "file_excerpt", description: "Read a bounded, line-numbered section of a local text file.", groups: ["files"],
            needles: SwiftToolDispatcher.catalogSearchNeedles(query), query: query
        )
        #expect(score > descriptive)
        #expect(!SwiftToolDispatcher.catalogSearchIsShortlisted(score: descriptive, bestScore: score))
    }

    @Test(arguments: ["not_grep", "grep_extra", "my-grep", "read chat message", "file_excerpt_backup", "browser.status.extra"])
    func identifierPriorityDoesNotUseSubstringsOrReconstructedNames(query: String) {
        for name in ["grep", "read_chat_message", "file_excerpt", "browser.status"] {
            let needles = SwiftToolDispatcher.catalogSearchNeedles(query)
            let withQuery = SwiftToolDispatcher.catalogSearchScore(name: name, description: "Read a file.", groups: [], needles: needles, query: query)
            let lexical = SwiftToolDispatcher.catalogSearchScore(name: name, description: "Read a file.", groups: [], needles: needles)
            #expect(withQuery == lexical)
        }
    }
    @Test(arguments: [("search Slack messages", "slack_search_messages"),
                      ("search file names within directory", "list_dir")])
    func loadedBestMatchDoesNotRecommendUnrelatedLoads(query: String, expected: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = UUID().uuidString
        _ = try await dispatcher.activeToolsStore.addLoaded(
            sessionId: session, names: [expected]
        )
        guard case .object(let result) = try await dispatcher.impl_tool_catalog(input: [
            "session_id": .string(session), "query": .string(query),
        ]), case .array(let matches)? = result["matches"] else {
            Issue.record("Missing search receipt"); return
        }
        #expect(result["load_next"] == nil, "The best tool is already ready; no unrelated load repair is needed")
        let names: [String] = matches.compactMap { match in
            guard case .object(let row) = match, case .string(let name)? = row["name"] else { return nil }
            return name
        }
        #expect(names.first == expected)
        #expect(!names.contains("image_generate"))
        #expect(!names.contains("search_chat_history"))
        #expect(!names.contains("gmail_search"))
        if case .int(let all)? = result["match_count"], case .int(let omitted)? = result["shortlist_omitted"] {
            #expect(all == Int64(matches.count) + omitted)
        } else { Issue.record("Missing explicit shortlist coverage") }
    }

}
