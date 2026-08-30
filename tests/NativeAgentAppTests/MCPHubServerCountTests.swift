import Testing
@testable import NativeAgentApp

@Suite("MCP Hub server inventory counts")
struct MCPHubServerCountTests {
    @Test func currentSelectedInventoryWinsOverStaleMetadataIncludingValidZero() {
        let current = MCPHubServerCountPresentation.resolve(
            isSelected: true, isCurrent: true, visibleCount: 5, reportedCount: 3
        )
        #expect(current == .loaded(5))
        #expect(current.label(noun: "tool") == "5 tools")
        let empty = MCPHubServerCountPresentation.resolve(
            isSelected: true, isCurrent: true, visibleCount: 0, reportedCount: 3
        )
        #expect(empty == .loaded(0))
        #expect(empty.label(noun: "resource") == "0 resources")
    }

    @Test func anotherServersInventoryAndUnverifiedReadsNeverBecomeCurrentCounts() {
        let otherServer = MCPHubServerCountPresentation.resolve(
            isSelected: false, isCurrent: true, visibleCount: 5, reportedCount: 2
        )
        #expect(otherServer == .reported(2))
        #expect(otherServer.label(noun: "tool") == "2 tools reported")
        for reported in [nil, -1] as [Int?] {
            let unknown = MCPHubServerCountPresentation.resolve(
                isSelected: true, isCurrent: false, visibleCount: 0, reportedCount: reported
            )
            #expect(unknown == .unknown)
            #expect(unknown.label(noun: "resource") == "Resource count unknown")
        }
        let unverified = MCPHubServerCountPresentation.resolve(
            isSelected: true, isCurrent: false, visibleCount: 5, reportedCount: 1
        )
        #expect(unverified.label(noun: "tool") == "1 tool reported")
    }

    @Test func toolsAndResourcesUseTheirOwnSuccessfulReadState() throws {
        let source = try AppSourceScraping.appSource("MCPHubView.swift")
        #expect(source.contains("isCurrent: appModel.mcpToolReadState == .current"))
        #expect(source.contains("isCurrent: appModel.mcpResourceReadState == .current"))
        #expect(source.contains("visibleCount: appModel.mcpTools.count"))
        #expect(source.contains("visibleCount: appModel.mcpResources.count"))
        #expect(!source.contains("server.toolCount ?? 0"))
        #expect(!source.contains("server.resourceCount ?? 0"))
    }
}
