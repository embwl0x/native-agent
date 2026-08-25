import ChatOrchestration
import NativeAgentShared
import Testing

@Suite("iOS tool-activity catalog parity")
struct IosToolActivityCatalogParityEvalTests {
    // Coverage ledger: ios.screens / ios.chat.bubble.toolActivity
    @Test("every catalog-owned skill reader remains a mobile skills-used event")
    func mobileSkillActivityClassificationMatchesTheDispatcherCatalog() {
        let catalogNames = SwiftToolDispatcher.skillReaderToolNames
        let mobileNames = ToolActivityPresentation.skillReaderToolNames

        #expect(mobileNames == catalogNames)
        #expect(catalogNames.allSatisfy {
            ToolActivityPresentation.isSkillReaderTool(named: $0)
        })
        #expect(!ToolActivityPresentation.isSkillReaderTool(named: "save_skill"))
        #expect(!ToolActivityPresentation.isSkillReaderTool(named: "read_file"))
    }
}
