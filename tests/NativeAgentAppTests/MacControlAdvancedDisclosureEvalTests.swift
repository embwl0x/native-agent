import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.macControl.advancedDisclosure

@MainActor
@Suite("Mac Control Advanced disclosure", .serialized)
struct MacControlAdvancedDisclosureEvalTests {
    @Test("Advanced Mac Control persists both disclosure directions and gates the Save path")
    func advancedDisclosurePreferenceControlsSavePathVisibility() throws {
        let suite = "NativeAgent.MacControlAdvancedDisclosure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.object(forKey: MacControlAdvancedDisclosurePresentation.preferenceKey) == nil)
        #expect(!MacControlAdvancedDisclosurePresentation.isExpanded(in: defaults))
        #expect(!MacControlAdvancedDisclosurePresentation.savePathIsVisible(isExpanded: false))

        MacControlAdvancedDisclosurePresentation.setExpanded(true, in: defaults)
        let freshExpandedReader = try #require(UserDefaults(suiteName: suite))
        #expect(MacControlAdvancedDisclosurePresentation.isExpanded(in: freshExpandedReader))
        #expect(MacControlAdvancedDisclosurePresentation.savePathIsVisible(isExpanded: true))

        MacControlAdvancedDisclosurePresentation.setExpanded(false, in: freshExpandedReader)
        let freshCollapsedReader = try #require(UserDefaults(suiteName: suite))
        #expect(!MacControlAdvancedDisclosurePresentation.isExpanded(in: freshCollapsedReader))
        #expect(!MacControlAdvancedDisclosurePresentation.savePathIsVisible(isExpanded: false))
    }
}
