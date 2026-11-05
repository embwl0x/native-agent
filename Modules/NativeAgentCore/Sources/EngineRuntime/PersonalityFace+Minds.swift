import Cognition
import Foundation
import NativeAgentShared
import ProviderRouting
// Blueprint: | `PersonalityFace+Minds.swift` | Checked Memory and mind choices; the existing provider group transaction owns saves |

extension NativeAgentEngine {
    @MainActor func personalityMinds() async -> PartFace.Section {
        do {
            let snapshot = try await providers.routing.checkedProviderSnapshot()
            let connections = try ProvidersFacade.connections(from: snapshot)
            let surface = NativeCognitionRuntime.studioWanderSurface
            let preference = snapshot.routing.preferences[surface]
            let providerID = snapshot.routing.activeProviders[surface]
            let options = try connections.filter { $0.auth_status.eligible }.flatMap { provider in
                try provider.models.filter { $0.supported_reasoning_efforts != nil }.map { model in
                    PartFace.Control.Option(id: try personalityMindID(provider.provider_id, model.id),
                        label: provider.display_name + " · " + model.name)
                }
            }
            let selected: String?
            if let providerID, let preference {
                selected = try personalityMindID(providerID, preference.model)
            } else { selected = nil }
            let saved = [providerID, preference?.model].compactMap { $0 }.joined(separator: " · ")
            var rows = [PartFace.Row(id: "mind", title: ProviderSurfaceGroups.mind.title,
                detail: (options.isEmpty ? "No selectable models are available. Connect or refresh a provider."
                    : ProviderSurfaceGroups.mind.caption) + (saved.isEmpty ? "" : "\nSaved: " + saved),
                value: saved.isEmpty ? "No saved selection" : saved,
                control: options.isEmpty ? nil : .choice(options, selected: options.contains { $0.id == selected } ? selected : nil))]
            for provider in connections {
                if let note = provider.models_note, !note.isEmpty {
                    rows.append(.init(id: "mind-catalog:" + provider.provider_id, title: provider.display_name, detail: note, tone: .attention))
                }
            }
            rows.append(.init(id: "minds", title: "My minds", detail: "Open the existing provider and model picker.", open: "page:personality/minds"))
            return .init(id: "minds", title: "My minds", style: .values, rows: rows)
        } catch { return personalityIssue("minds", title: "My minds", error: error) }
    }

    @MainActor func personalityAct(row: String, action: String, value: String?) async throws -> String? {
        guard row == "mind", action == "set", let value, !value.isEmpty else {
            throw PartCallError(code: "unknown_action", message: "Choose an offered Memory and mind model, or open the row's destination.")
        }
        let snapshot = try await providers.routing.checkedProviderSnapshot()
        let connections = try ProvidersFacade.connections(from: snapshot)
        for provider in connections where provider.auth_status.eligible {
            for model in provider.models where model.supported_reasoning_efforts != nil {
                guard try personalityMindID(provider.provider_id, model.id) == value else { continue }
                let preference = snapshot.routing.preferences[NativeCognitionRuntime.studioWanderSurface]
                _ = try await saveProviderGroupSelection(group: ProviderSurfaceGroups.mind,
                    providerID: provider.provider_id, model: model.id,
                    reasoningEffort: ProvidersFacade.normalizedReasoningEffort(from: providers.catalog, providers: connections,
                        providerID: provider.provider_id, model: model.id, selected: preference?.reasoningEffort ?? ""),
                    serviceTier: preference?.serviceTier)
                return "Memory and mind → \(model.id) saved"
            }
        }
        throw PartCallError(code: "model_unavailable",
            message: "That model is no longer offered by a ready provider. Refresh Providers before choosing again.")
    }

    private func personalityMindID(_ provider: String, _ model: String) throws -> String {
        String(decoding: try JSONEncoder().encode([provider, model]), as: UTF8.self)
    }
}
