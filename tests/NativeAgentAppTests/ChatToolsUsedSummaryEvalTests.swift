import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.transcript.toolsUsedSummary
@Suite("Chat tools-used summary")
struct ChatToolsUsedSummaryEvalTests {
    @Test("every catalog skill-reader is partitioned into the skills-used summary")
    func summarySkillPartitionFollowsCatalogTags() throws {
        let envelope: JSONValue = .object([
            "tools": .array([
                .object(["name": .string("read_skill"), "tags": .array([.string("skill_reader")])]),
                .object(["name": .string("list_skills"), "tags": .array([.string("skill_reader")])]),
                .object(["name": .string("save_skill"), "tags": .array([.string("skill_writer")])]),
                .object(["name": .string("read_file")]),
            ]),
            "currently_loaded": .array([]),
        ])
        let catalog = try #require(ChatToolCatalogSnapshot.from(jsonValue: envelope))
        let catalogSkillReaders = Set(catalog.tools.compactMap { tool in
            tool.tags?.contains("skill_reader") == true ? tool.name : nil
        })

        #expect(catalogSkillReaders == Set(["read_skill", "list_skills"]))
        #expect(ToolCallGroupPresentation.skillToolNames(catalog: catalog) == catalogSkillReaders)
        #expect(!ToolCallGroupPresentation.skillToolNames(catalog: catalog).contains("save_skill"))
    }

    @Test("the transcript group consumes catalog classification, with the dispatcher taxonomy only before loading")
    func mountedSummaryUsesTheCatalogBackedPresentationSeam() throws {
        let source = try AppSourceScraping.appSource("ChatMessageListView.swift")
        #expect(source.contains("ToolCallGroupPresentation.skillToolNames(catalog: appModel.chatToolCatalog)"))
        #expect(!source.contains("private static let skillToolNames"))

        let catalogSource = try AppSourceScraping.repositoryRoot()
            .appendingPathComponent("Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+ToolLoading.swift")
        let dispatcher = try String(contentsOf: catalogSource, encoding: .utf8)
        #expect(dispatcher.contains("Self.skillReaderToolNames.contains(schema.name)"))
        #expect(dispatcher.contains(".string(\"skill_reader\")"))
    }
}
