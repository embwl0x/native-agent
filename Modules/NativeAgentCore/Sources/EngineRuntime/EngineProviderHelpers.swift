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

    public nonisolated static func readModelRoutingConfig(dataRoot: URL) -> ModelRoutingConfig {
        // The default IS Chat's saved choice, resolved below; there is no model
        // named in code here any more (2026-09-13).
        var defaultModel = ""
        let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let surfaces = readJSONObject(at: providersDir.appendingPathComponent("surfaces.json"))
        let activeRaw = readJSONObject(at: providersDir.appendingPathComponent("active.json"))
        var active: [String: String] = [:]
        for (surface, value) in activeRaw {
            if let provider = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provider.isEmpty {
                active[surface] = provider
            }
        }

        // 2026-09-13 review: resolve CHAT first. This legacy projection used to
        // build the Telegram/iOS rows while `defaultModel` was still empty, so a
        // surface with no saved key of its own reported nothing instead of the
        // Chat choice it actually runs on.
        func savedModel(_ surface: String) -> String? {
            let raw = surfaces[surface]
            let value = (raw as? [String: Any]).map { stringValue($0["model"]) } ?? stringValue(raw)
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        defaultModel = savedModel("chat") ?? ""

        var surfacePrefs: [String: ModelSurfacePreference] = [:]
        for surface in Set(surfaces.keys).union(active.keys).sorted() {
            let raw = surfaces[surface]
            var model: String?
            var effort: String?
            var serviceTier: String?
            if let entry = raw as? [String: Any] {
                model = stringValue(entry["model"])
                effort = stringValue(entry["reasoningEffort"]) ?? stringValue(entry["reasoning_effort"])
                serviceTier = stringValue(entry["serviceTier"]) ?? stringValue(entry["service_tier"])
            } else {
                model = stringValue(raw)
            }
            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (trimmedModel?.isEmpty == false) ? trimmedModel! : defaultModel
            let resolvedEffort = (trimmedEffort?.isEmpty == false) ? trimmedEffort! : "medium"
            surfacePrefs[surface] = ModelSurfacePreference(
                surface: surface,
                model: resolvedModel,
                reasoningEffort: resolvedEffort,
                serviceTier: serviceTier == "priority" ? "priority" : "default",
                source: active[surface],
                modelKnown: nil
            )
        }

        func pref(_ surface: String) -> ModelSurfacePreference {
            surfacePrefs[surface] ?? ModelSurfacePreference(
                surface: surface,
                model: defaultModel,
                reasoningEffort: "medium",
                serviceTier: "default",
                source: active[surface],
                modelKnown: nil
            )
        }
        let efforts = defaultReasoningEffortOptions
        let current = ModelRoutingCurrent(
            chat: pref("chat"),
            telegram: pref("telegram"),
            // An absent row means "follows Chat", so say Chat's answer rather
            // than nothing: these are the rows the phone and Telegram read.
            ios: surfacePrefs["ios"] ?? pref("ios"),
            executions: ProviderRoutingSurfaceLookup.value(surfacePrefs, WorkshopSurfaceVocabulary.canonical),
            autonomy: surfacePrefs["autonomy"],
            swarms: surfacePrefs["swarms"],
            dream: surfacePrefs["dream"],
            training: surfacePrefs["training"]
        )
        return ModelRoutingConfig(
            status: "ok",
            defaultModel: defaultModel,
            fallbackModels: [],
            reasoningEfforts: efforts,
            current: current
        )
    }

    public nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

}
