import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.buckets

@Suite("Tools catalog buckets")
struct ToolsBucketsEvalTests {
    @Test("each uniquely identified catalog tool is placed in one stable bucket")
    func bucketsPartitionTheAuthoritativeCatalog() {
        let catalog = snapshot(
            tools: [
                tool("mcp__calendar__list"),
                tool("shell"),
                tool("system_info"),
                tool("mac_view"),
                tool("mac_notify"),
                tool("read_file"),
                tool("time_now"),
                tool("browser.open_url"),
                tool("ordinary_tool"),
            ],
            currentlyLoaded: ["time_now"]
        )

        let receipt = ChatToolCatalogPresentation.bucketResult(for: catalog)

        #expect(receipt.buckets.map(\.id) == [
            "mcp", "shell", "system", "mac-control", "mac-integration", "file-ops", "always-on", "browser", "unclassified",
        ])
        #expect(receipt.buckets.flatMap(\.tools).map(\.name).sorted() == catalog.tools.map(\.name).sorted())
        #expect(receipt.visibleToolCount == 9)
        #expect(receipt.withheldToolCount == 0)
        #expect(receipt.unclassifiedToolCount == 1)
    }

    @Test("blank and duplicate identities are withheld instead of colliding in SwiftUI")
    func malformedRowsStayObservableButDoNotMasqueradeAsToolRows() {
        let catalog = snapshot(tools: [
            tool("shell", description: "first copy"),
            tool("shell", description: "second copy"),
            tool("   ", description: "no identity"),
            tool("ordinary_tool"),
        ])

        let receipt = ChatToolCatalogPresentation.bucketResult(for: catalog)

        #expect(receipt.visibleToolCount == 1)
        #expect(receipt.withheldToolCount == 3)
        #expect(receipt.buckets.map(\.id) == ["unclassified"])
        #expect(receipt.buckets[0].tools.map(\.name) == ["ordinary_tool"])
        #expect(receipt.withheldNotice?.contains("3 malformed or duplicate catalog rows") == true)
        #expect(receipt.unclassifiedNotice?.contains("1 runtime tool has no reviewed dispatcher bucket") == true)
    }

    @Test("loading, empty, unavailable, fresh, and stale catalog evidence remain distinct")
    func catalogReceiptDoesNotPresentMissingOrStaleDataAsFresh() {
        #expect(ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: false,
            loadError: nil
        ) == .loading)

        let unavailable = ChatToolCatalogPresentation.catalogState(
            catalog: nil,
            loadFailed: true,
            loadError: "runtime reader refused"
        )
        #expect(unavailable == .unavailable(detail: "runtime reader refused"))

        let empty = ChatToolCatalogPresentation.catalogState(
            catalog: snapshot(tools: []),
            loadFailed: false,
            loadError: nil
        )
        #expect(empty == .empty)

        let prior = snapshot(tools: [tool("ordinary_tool")])
        let fresh = ChatToolCatalogPresentation.catalogState(
            catalog: prior,
            loadFailed: false,
            loadError: nil
        )
        let stale = ChatToolCatalogPresentation.catalogState(
            catalog: prior,
            loadFailed: true,
            loadError: String(repeating: "x", count: 300)
        )

        if case .available(let catalog, let receipt) = fresh {
            #expect(catalog == prior)
            #expect(receipt.visibleToolCount == 1)
        } else {
            Issue.record("Expected a fresh catalog receipt")
        }
        if case .stale(let catalog, _, let detail) = stale {
            #expect(catalog == prior)
            #expect(detail?.count == 241)
            #expect(detail?.hasSuffix("…") == true)
        } else {
            Issue.record("Expected stale rather than fresh catalog evidence")
        }
    }

    @Test("tool availability and policy receipts retain their stronger adverse outcome")
    func toolStatusDoesNotUpgradeAnAdverseCatalogReceipt() {
        let catalog = snapshot(
            tools: [
                tool("locked", effectiveAutonomy: "blocked", availableNow: false),
                tool("unavailable", availableNow: false),
                tool("approval", effectiveAutonomy: "confirm"),
                tool("active", loadState: "loaded"),
            ],
            builderPolicyLocked: ["locked"]
        )

        #expect(ChatToolCatalogPresentation.status(for: catalog.tools[0], in: catalog) == "policy-locked")
        #expect(ChatToolCatalogPresentation.status(for: catalog.tools[1], in: catalog) == "unavailable")
        #expect(ChatToolCatalogPresentation.status(for: catalog.tools[2], in: catalog) == "approval")
        #expect(ChatToolCatalogPresentation.status(for: catalog.tools[3], in: catalog) == "active")
    }

    private func snapshot(
        tools: [ChatCatalogTool],
        currentlyLoaded: Set<String> = [],
        builderPolicyLocked: [String] = [],
        macAppAvailable: [String] = []
    ) -> ChatToolCatalogSnapshot {
        ChatToolCatalogSnapshot(
            tools: tools,
            currentlyLoaded: currentlyLoaded,
            builderAvailable: [],
            builderPolicyLocked: builderPolicyLocked,
            macAppAvailable: macAppAvailable,
            macAppPolicyLocked: [],
            fullMacActive: false,
            fileOpsAllowed: true,
            systemAllowed: true,
            appControlAllowed: true,
            builderModeDetail: "",
            permissionLevel: "confirm"
        )
    }

    private func tool(
        _ name: String,
        description: String = "Tool description",
        loadState: String? = nil,
        effectiveAutonomy: String? = nil,
        availableNow: Bool? = true
    ) -> ChatCatalogTool {
        ChatCatalogTool(
            name: name,
            description: description,
            parametersPreview: nil,
            dispatchableVia: "chat",
            loadState: loadState,
            effectiveAutonomy: effectiveAutonomy,
            availableNow: availableNow
        )
    }
}
