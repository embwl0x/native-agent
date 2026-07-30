import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Cloud connector chat tools")
struct CloudConnectorChatToolTests {
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

    @Test func disconnectedToolsFailClosedWithoutNetworkWork() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot)

        for name in ["gmail_status", "google_calendar_status", "notion_status"] {
            let result = try await dispatcher.dispatch(tool: name, input: [:], surface: "chat")
            guard case .object(let object) = result else {
                Issue.record("\(name) returned a non-object failure")
                continue
            }
            #expect(object["status"] == .string("failed"))
            #expect(object["error"] == .string("not_connected"))
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
