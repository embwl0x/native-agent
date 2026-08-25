import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.showDataLimits
@Suite("Slim Settings data-limits reference")
struct SlimSettingsDataLimitsEvalTests {
    @Test("release-layout document opens through the settings action")
    func opensPreferredBundledDocument() {
        let releaseDocument = URL(fileURLWithPath: "/bundle/Resources/docs/data-bounds.md")
        var opened: URL?

        let outcome = SlimSettingsDataLimitsReference.open(
            resourceLookup: { name, ext, subdirectory in
                #expect(name == SlimSettingsDataLimitsReference.resourceName)
                #expect(ext == SlimSettingsDataLimitsReference.resourceExtension)
                return subdirectory == SlimSettingsDataLimitsReference.preferredSubdirectory
                    ? releaseDocument
                    : nil
            },
            opener: { url in
                opened = url
                return true
            }
        )

        #expect(outcome == .opened)
        #expect(opened == releaseDocument)
    }

    @Test("development-root fallback and unavailable or failed outcomes remain explicit")
    func fallbackAndAdverseOutcomesAreNotSilent() {
        let developmentDocument = URL(fileURLWithPath: "/test-bundle/data-bounds.md")
        let fallback = SlimSettingsDataLimitsReference.open(
            resourceLookup: { _, _, subdirectory in
                subdirectory == nil ? developmentDocument : nil
            },
            opener: { $0 == developmentDocument }
        )
        #expect(fallback == .opened)

        let missing = SlimSettingsDataLimitsReference.open(
            resourceLookup: { _, _, _ in nil },
            opener: { _ in
                Issue.record("missing resource must not invoke the opener")
                return true
            }
        )
        #expect(missing == .resourceUnavailable)
        #expect(missing.failureMessage?.contains("missing") == true)

        let blocked = SlimSettingsDataLimitsReference.open(
            resourceLookup: { _, _, _ in developmentDocument },
            opener: { _ in false }
        )
        #expect(blocked == .openFailed)
        #expect(blocked.failureMessage?.contains("could not open") == true)
    }
}
