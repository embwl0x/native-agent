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

        let functionalLabels = [
            "workshop": "Task execution",
            "missions": "Task execution",
            "autonomy": "Independent tasks",
            "swarms": "Coordinated tasks",
            "dream": "Memory review",
            "rem": "Personal growth",
            "training": "Skill practice",
            "heartbeat": "Background check-ins",
            "cognition_reflection": "Reflection",
            "compaction": "Conversation summaries",
            "self_improvement": "Learning",
            "studio_wander": "Creative exploration",
        ]
        for (surface, label) in functionalLabels {
            #expect(ProviderSettingsSurfaceLabel.presentation(for: surface) == .named(label))
            #expect(ProviderSettingsSurfaceLabel.presentation(for: surface).text == label)
        }
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
