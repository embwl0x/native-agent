import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Cloud connector chat tools")
struct CloudConnectorChatToolTests {
    @Test func unusedPrimaryIDDoesNotMaskTheReadAlias() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)
        for unused in [JSONValue.null, .string("")] {
            let gmail = await dispatcher.impl_gmail_read(input: ["id": unused, "message_id": .string("message")])
            let notion = await dispatcher.impl_notion_read_page(input: ["id": unused, "page_id": .string("page")])
            for result in [gmail, notion] {
                guard case .object(let fields) = result else { Issue.record("Missing error envelope"); continue }
                #expect(fields["status"] == .string("needs_input"))
            }
        }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-connector-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func connectorReadsAreLazyCatalogToolsWithSchemas() throws {
        let names = [
            "gmail_status", "gmail_search", "gmail_read",
            "google_calendar_status", "google_calendar_list",
            "notion_status", "notion_search", "notion_read_page",
        ]
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let schemas = SwiftToolDispatcher(dataRoot: dataRoot)
            .builtInToolSchemas(includeFullMacFileTools: false)

        for name in names {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(name))
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(name))
            #expect(schemas.contains { $0.name == name }, "missing schema for \(name)")
        }
    }

    @Test func disconnectedToolsRequestConnectionWithoutNetworkWork() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)

        for (name, connector) in [("gmail_status", "gmail"), ("google_calendar_status", "gcal"), ("notion_status", "notion")] {
            let result = try await dispatcher.dispatch(tool: name, input: [:], surface: "chat")
            guard case .object(let object) = result else {
                Issue.record("\(name) returned a non-object failure")
                continue
            }
            #expect(object["status"] == .string("needs_input"))
            #expect(ChatToolOutcome.isWaitingInteraction(result))
            #expect(!ChatToolOutcome.outputLooksSuccessful(result))
            #expect(ChatToolOutcome.exactResultClass(result) == .unknown)
            #expect(object["connected"] == .bool(false))
            let need = try #require(InlineInteractionNeed.interaction(in: result))
            #expect(need.kind == .connector)
            #expect(need.target == connector)
        }
    }

    @Test func compactGroupsRouteToConnectorSpecificReads() {
        let inventory = Set(SwiftToolDispatcher.builtInToolNames)
        let groups = ToolPreloadHeuristics.groupIndex(availableToolNames: inventory)

        #expect(groups["gmail"]?.contains("gmail_search") == true)
        #expect(groups["google_calendar"]?.contains("google_calendar_list") == true)
        #expect(groups["notion"]?.contains("notion_search") == true)
    }
}
