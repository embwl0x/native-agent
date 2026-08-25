import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.memory.advancedDiagnostics.identifiers

@Suite("Memory advanced diagnostics identifiers")
struct MemoryAdvancedDiagnosticsIdentifiersEvalTests {
    @Test("a data root under home is represented as a private location in diagnostics")
    func homeRootIsNeverRenderedVerbatim() {
        let home = "/Users/diagnostic-user"
        let root = "\(home)/Library/Application Support/NativeAgent"
        let identifier = MemoryAdvancedDiagnosticsIdentifiers.dataRoot(
            path: root,
            homeDirectory: home
        )

        #expect(identifier == .privateLocation)
        #expect(identifier.dataRootLabel == "data root: private location hidden")
        #expect(!identifier.dataRootLabel.localizedCaseInsensitiveContains(home))
    }

    @Test("unavailable and non-home roots retain distinct diagnostic states")
    func absentAndPublicRootsAreNotConflated() {
        #expect(MemoryAdvancedDiagnosticsIdentifiers.dataRoot(path: "", homeDirectory: "/Users/diagnostic-user") == .unavailable)
        #expect(MemoryAdvancedDiagnosticsIdentifiers.dataRoot(
            path: "/private/var/tmp/nativeagent-eval",
            homeDirectory: "/Users/diagnostic-user"
        ).dataRootLabel == "data root: /private/var/tmp/nativeagent-eval")
    }
}
