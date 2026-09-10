import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.surfaceLabel
@Suite("Provider Settings surface labels", .serialized)
struct ProviderSettingsSurfaceLabelEvalTests {
    @Test("clearing an activity restores inherited routing and its displayed origin")
    @MainActor
    func clearOverrideRestoresInheritedLabel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        for surface in ["chat", "slack"] {
            try await routing.saveSurfaceConfiguration(
                surface: surface, model: "gpt-5.6-sol", reasoningEffort: "medium",
                serviceTier: nil, providerId: "codex"
            )
        }
        let inherited = try await routing.checkedRoutingSnapshot().preferences["telegram"]
        try await routing.saveSurfaceConfiguration(
            surface: "telegram", model: "gpt-5.6-sol", reasoningEffort: "high",
            serviceTier: "priority", providerId: "codex"
        )
        let before = try await routing.checkedRoutingSnapshot()
        #expect(ProviderSettingsView.selectionOrigin(isExplicit: before.pinnedModels["telegram"] != nil || before.activeProviders["telegram"] != nil)
            == "Explicit override")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        try await app.clearSurfaceOverride(surface: "telegram")
        let after = try await routing.checkedRoutingSnapshot()
        #expect(after.pinnedModels["telegram"] == nil)
        #expect(after.activeProviders["telegram"] == nil)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("providers/surfaces.json"))) as! [String: Any]
        #expect(saved["telegram"] == nil)
        for other in ["chat", "slack"] {
            #expect(after.pinnedModels[other] == before.pinnedModels[other])
            #expect(after.activeProviders[other] == before.activeProviders[other])
            #expect(after.preferences[other]?.reasoningEffort == before.preferences[other]?.reasoningEffort)
            #expect(after.preferences[other]?.serviceTier == before.preferences[other]?.serviceTier)
        }
        await #expect(throws: ProviderRoutingError.self) {
            try await routing.clearSurfaceOverride(surface: "chat")
        }
        #expect(ProviderSettingsView.selectionOrigin(isExplicit: after.pinnedModels["telegram"] != nil || after.activeProviders["telegram"] != nil)
            == "Inherited default")
        guard case let .loaded(refreshed) = await ProviderSettingsRefreshAction.perform(
            appModel: app, refreshCatalog: false
        ) else {
            Issue.record("clearing an override must leave the Providers refresh readable")
            return
        }
        let preference = refreshed.preferences["telegram"]
        #expect(preference?.model == inherited?.model)
        #expect(preference?.reasoningEffort == inherited?.reasoningEffort)
        #expect(preference?.serviceTier == inherited?.serviceTier)
    }

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
