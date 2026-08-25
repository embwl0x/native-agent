import Testing
import ChatOrchestration
import NativeAgentCore
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.chatToolCatalogBucketing

@Suite("Tools catalog dispatcher bucketing")
struct ToolsChatToolCatalogBucketingEvalTests {
    @Test("every registered dispatcher name has a reviewed visible bucket")
    func registeredToolNamesNeverFallIntoAnUnreviewedBucket() {
        let coreNames = SwiftToolDispatcher.catalogRegisteredToolNames
        let appNames = AppChatToolDispatcher.catalogRegisteredToolNames

        #expect(!coreNames.isEmpty)
        #expect(!appNames.isEmpty)
        #expect(coreNames.filter {
            SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: $0) == nil
        }.isEmpty)
        #expect(appNames.filter {
            AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: $0) == nil
        }.isEmpty)

        let catalog = snapshot(
            tools: coreNames.sorted().compactMap { name in
                SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: name)
                    .map { tool(name, bucket: $0) }
            } + appNames.sorted().compactMap { name in
                AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: name)
                    .map { tool(name, bucket: $0) }
            }
        )
        let receipt = ChatToolCatalogPresentation.bucketResult(for: catalog)

        #expect(receipt.visibleToolCount == coreNames.count + appNames.count)
        #expect(receipt.unclassifiedToolCount == 0)
        #expect(!receipt.buckets.contains { $0.id == "other" })
    }

    @Test("an unregistered runtime name stays visibly adverse instead of borrowing a bucket")
    func unknownRuntimeToolIsNotSilentlyBucketed() {
        let unknown = "new_dispatcher_tool_requires_catalog_bucket"
        #expect(SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: unknown) == nil)
        #expect(AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: unknown) == nil)

        let receipt = ChatToolCatalogPresentation.bucketResult(for: snapshot(tools: [tool(unknown)]))

        #expect(receipt.buckets.map(\.id) == [ChatToolCatalogBucket.unclassified.rawValue])
        #expect(receipt.unclassifiedToolCount == 1)
        #expect(receipt.unclassifiedNotice?.contains("no reviewed dispatcher bucket") == true)
    }

    private func snapshot(tools: [ChatCatalogTool]) -> ChatToolCatalogSnapshot {
        ChatToolCatalogSnapshot(
            tools: tools,
            currentlyLoaded: [],
            builderAvailable: [],
            builderPolicyLocked: [],
            macAppAvailable: [],
            macAppPolicyLocked: [],
            fullMacActive: false,
            fileOpsAllowed: false,
            systemAllowed: false,
            appControlAllowed: false,
            builderModeDetail: "",
            permissionLevel: "confirm"
        )
    }

    private func tool(_ name: String, bucket: ChatToolCatalogBucket? = nil) -> ChatCatalogTool {
        ChatCatalogTool(
            name: name,
            description: "Dispatcher-owned catalog row",
            parametersPreview: nil,
            dispatchableVia: "dispatcher",
            loadState: "discovery_only",
            effectiveAutonomy: "confirm",
            availableNow: true,
            catalogBucket: bucket?.rawValue
        )
    }
}
