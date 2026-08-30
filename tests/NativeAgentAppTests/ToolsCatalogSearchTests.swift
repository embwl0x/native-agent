import Testing
@testable import NativeAgentApp

@Suite("Local tool catalog search")
struct ToolsCatalogSearchTests {
    private func tool(_ name: String, _ description: String, available: Bool = true) -> ChatCatalogTool {
        ChatCatalogTool(name: name, description: description, availableNow: available)
    }

    @Test("name and description matches preserve catalog order, categories, and unavailable status")
    func filterPreservesAuthoritativeRows() {
        let read = tool("read_file", "Read a workspace file")
        let calendar = tool("mac_calendar_list", "List upcoming Calendar events", available: false)
        let buckets: [ChatToolCatalogPresentation.Bucket] = [
            .init(id: "files", title: "Files", icon: "doc", tools: [read]),
            .init(id: "mac", title: "Mac", icon: "macwindow", tools: [calendar, tool("mac_notify", "Show a notification")]),
        ]
        var search = ChatToolCatalogSearchState()
        #expect(search.filteredBuckets(buckets) == buckets)
        search.setQuery("  CALENDAR upcoming  ")
        let matches = search.filteredBuckets(buckets)
        #expect(matches.map(\.id) == ["mac"])
        #expect(matches.first?.title == "Mac")
        #expect(matches.first?.tools == [calendar])
        #expect(matches.first?.tools.first?.availableNow == false)
        search.setQuery("read_file workspace")
        #expect(search.filteredBuckets(buckets).first?.tools == [read])
        search.setQuery("not-a-real-tool")
        #expect(search.filteredBuckets(buckets).isEmpty)
        search.setQuery(" \n ")
        #expect(!search.isSearching)
        #expect(search.filteredBuckets(buckets) == buckets)
    }

    @Test("search opens result groups without overwriting ordinary disclosure choices")
    func clearRestoresNormalExpansionState() {
        var search = ChatToolCatalogSearchState()
        search.setExpanded(true, bucketID: "files")
        #expect(search.isExpanded("files"))
        #expect(!search.isExpanded("mac"))
        search.setQuery("calendar")
        #expect(search.isExpanded("mac"))
        search.setExpanded(false, bucketID: "mac")
        #expect(!search.isExpanded("mac"))
        search.setQuery("notify")
        #expect(search.isExpanded("mac"))
        search.setExpanded(false, bucketID: "files")
        search.setQuery("")
        #expect(search.isExpanded("files"))
        #expect(!search.isExpanded("mac"))
    }
}
