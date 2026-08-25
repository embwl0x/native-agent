import Foundation
import ProviderRouting
import Testing

// EVAL FENCE: app.settings / ui.ProviderSettings.surfaceRowSet
@Suite("Provider Settings surface row set", .serialized)
struct ProviderSurfaceRowSetBehaviorTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-surface-rows-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writePickerStores(
        root: URL,
        extraSurface: String? = nil
    ) throws {
        var surfaces = Dictionary(uniqueKeysWithValues: MODEL_SURFACES.map {
            ($0, ["model": "gpt-5.6-sol", "reasoningEffort": "high", "serviceTier": "default"])
        })
        var active = Dictionary(uniqueKeysWithValues: MODEL_SURFACES.map { ($0, "openai_oauth_direct") })
        // This is the real compatibility fossil presently carried by both
        // stores. It is intentionally allowed but never becomes a picker row.
        surfaces["cognition_cue"] = ["model": "claude-fable-5", "reasoningEffort": "medium"]
        active["cognition_cue"] = "anthropic_oauth_direct"
        if let extraSurface {
            surfaces[extraSurface] = ["model": "gpt-5.6-sol", "reasoningEffort": "high"]
            active[extraSurface] = "openai_oauth_direct"
        }
        let directory = root.appendingPathComponent("providers", isDirectory: true)
        try JSONSerialization.data(withJSONObject: surfaces, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("surfaces.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: active, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("active.json"), options: .atomic)
    }

    @Test("all persisted fixture keys are visible or explicitly retired")
    func persistedSurfaceKeysResolveToRowsOrTheDatedRetirementAllowlist() async throws {
        let dataRoot = try root("retired")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        try writePickerStores(root: dataRoot)

        let rowSet = try await SwiftNativeProviderRouting(dataRoot: dataRoot).providerSurfaceRowSet()
        #expect(rowSet.visibleSurfaces == MODEL_SURFACES)
        #expect(rowSet.retiredStoredKeys == ["cognition_cue"])
        #expect(rowSet.unsupportedStoredKeys.isEmpty)
    }

    @Test("an unregistered persisted key is adverse instead of silently disappearing from Providers")
    func unknownPersistedSurfaceIsExplicitlyReportedForRepair() async throws {
        let dataRoot = try root("unknown")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        try writePickerStores(root: dataRoot, extraSurface: "future_unregistered_surface")

        let rowSet = try await SwiftNativeProviderRouting(dataRoot: dataRoot).providerSurfaceRowSet()
        #expect(rowSet.visibleSurfaces == MODEL_SURFACES)
        #expect(rowSet.retiredStoredKeys == ["cognition_cue"])
        #expect(rowSet.unsupportedStoredKeys == ["future_unregistered_surface"])
    }
}
