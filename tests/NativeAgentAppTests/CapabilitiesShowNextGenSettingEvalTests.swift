import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / setting.capabilitiesShowNextGen

@MainActor
@Suite("Capabilities Next-Gen disclosure preference", .serialized)
struct CapabilitiesShowNextGenSettingEvalTests {
    @Test("the Next-Gen disclosure preference persists both expansion directions across fresh owners")
    func disclosurePreferenceRoundTripsItsPresentationState() throws {
        let suite = "NativeAgent.CapabilitiesShowNextGen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: CapabilitiesDisclosurePreference.nextGenKey) == nil,
                "A new install must not claim the optional runtime panel was opened.")

        #expect(!CapabilitiesDisclosurePreference.isNextGenExpanded(in: defaults))

        CapabilitiesDisclosurePreference.setNextGenExpanded(true, in: defaults)
        #expect(CapabilitiesDisclosurePreference.isNextGenExpanded(in: defaults))

        let freshExpandedReader = try #require(UserDefaults(suiteName: suite))
        #expect(CapabilitiesDisclosurePreference.isNextGenExpanded(in: freshExpandedReader))

        CapabilitiesDisclosurePreference.setNextGenExpanded(false, in: freshExpandedReader)
        #expect(!CapabilitiesDisclosurePreference.isNextGenExpanded(in: defaults))

        let freshCollapsedReader = try #require(UserDefaults(suiteName: suite))
        #expect(!CapabilitiesDisclosurePreference.isNextGenExpanded(in: freshCollapsedReader))
    }
}
