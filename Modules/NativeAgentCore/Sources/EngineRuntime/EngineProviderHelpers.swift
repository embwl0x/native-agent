import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Foundation
import ProviderRouting
extension ProvidersFacade {
    public nonisolated static func readJSONObject(at path: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    public nonisolated static func readModelRoutingConfig(dataRoot: URL) async throws -> ModelRoutingConfig {
        let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
        return try modelRoutingConfig(from: snapshot)
    }

    public nonisolated static func modelRoutingConfig(from snapshot: ProviderRoutingSnapshot) throws -> ModelRoutingConfig {
        func pref(_ surface: String) throws -> ModelSurfacePreference {
            guard let value = snapshot.preferences[surface] else {
                throw ProviderRoutingError.underlying("canonical routing snapshot is incomplete")
            }
            return ModelSurfacePreference(
                surface: surface, model: value.model, reasoningEffort: value.reasoningEffort,
                serviceTier: value.serviceTier, source: snapshot.activeProviders[surface],
                modelKnown: value.modelKnown
            )
        }
        return try ModelRoutingConfig(
            status: "ok", defaultModel: pref("chat").model, fallbackModels: [],
            reasoningEfforts: defaultReasoningEffortOptions,
            current: ModelRoutingCurrent(
                chat: pref("chat"), telegram: pref("telegram"), ios: pref("ios"),
                executions: pref(WorkshopSurfaceVocabulary.canonical), autonomy: pref("autonomy"),
                swarms: pref("swarms"), dream: pref("dream"), training: pref("training")
            )
        )
    }

    public nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

}
