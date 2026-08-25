import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.surfaceLabel
@Suite("Provider Settings surface labels", .serialized)
struct ProviderSettingsSurfaceLabelEvalTests {
    @Test("every mounted routing row has an explicit customer-facing label")
    func canonicalRoutingSurfacesHaveNamedLabels() {
        for surface in MODEL_SURFACES {
            guard case .named(let label) = ProviderSettingsSurfaceLabel.presentation(for: surface) else {
                Issue.record("Provider Settings has no named label for canonical surface: \(surface)")
                continue
            }
            #expect(!label.isEmpty)
            #expect(!label.contains("_"))
        }

        #expect(ProviderSettingsSurfaceLabel.presentation(for: "rem") == .named("REM"))
        #expect(ProviderSettingsSurfaceLabel.presentation(for: "workshop") == .named("Workshop"))
        #expect(ProviderSettingsSurfaceLabel.presentation(for: "desk") == .named("Desk"))
    }

    @Test("unknown and malformed identifiers never become cosmetic wire labels")
    func adverseSurfaceIdentifiersAreExplicit() {
        let unknown = ProviderSettingsSurfaceLabel.presentation(for: "future_unregistered_surface")
        #expect(unknown == .unrecognized("future_unregistered_surface"))
        #expect(unknown.text == "Unrecognized surface (future_unregistered_surface)")

        for malformed in ["", " cognition_reflection", "Cognition_reflection"] {
            #expect(ProviderSettingsSurfaceLabel.presentation(for: malformed) == .malformed)
            #expect(ProviderSettingsSurfaceLabel.presentation(for: malformed).text == "Surface label unavailable")
        }
    }
}
