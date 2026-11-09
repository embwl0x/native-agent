import AuthoredCapabilities
import Cognition
import Foundation
import NativeAgentShared
import Onboarding
import ProviderRouting
// Blueprint: | `PersonalityFace+Minds.swift` | Personality's levers: Memory and mind (`personality.mind`, a group transaction) and Reset identity (`personality.reset`, the onboarding reset), and the owner code behind both |

extension NativeAgentEngine {
    func personalityMinds() async -> PartFace.Section {
        do {
            let snapshot = try await providers.routing.checkedProviderSnapshot()
            let connections = try ProvidersFacade.connections(from: snapshot)
            let surface = NativeCognitionRuntime.studioWanderSurface
            let preference = snapshot.routing.preferences[surface]
            let providerID = snapshot.routing.activeProviders[surface]
            var options = try connections.filter { $0.auth_status.eligible }.flatMap { provider in
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
            // A saved choice no ready provider offers stays visible as the selection, marked unavailable; choosing it again is refused.
            let unoffered = selected.map { id in !options.contains { $0.id == id } } ?? false
            if unoffered, let selected, !options.isEmpty { options.insert(.init(id: selected, label: saved + " (saved; unavailable)"), at: 0) }
            var rows = [PartFace.Row(id: "mind", title: ProviderSurfaceGroups.mind.title,
                detail: (options.isEmpty ? "No selectable models are available. Connect or refresh a provider."
                    : ProviderSurfaceGroups.mind.caption) + (saved.isEmpty ? "" : "\nSaved: " + saved + (unoffered ? " (unavailable)" : "")),
                value: saved.isEmpty ? "No saved selection" : saved, tone: unoffered ? .attention : nil,
                control: options.isEmpty ? nil : .choice(options, selected: selected, call: PartFace.Call("personality.mind")))]
            for provider in connections {
                if let note = provider.models_note, !note.isEmpty {
                    rows.append(.init(id: "mind-catalog:" + provider.provider_id, title: provider.display_name, detail: note, tone: .attention))
                }
            }
            rows.append(.init(id: "mind-providers", title: "Thinking, Fast and each activity",
                detail: "Providers holds Memory and mind's thinking level, Fast, Same as Chat, each activity's account and every account's readiness.",
                open: "page:providers"))
            return .init(id: "minds", title: "My minds", style: .values, rows: rows)
        } catch { return personalityIssue("minds", title: "My minds", error: error) }
    }

    /// Reset identity, offered once the saved identity documents have been read and hold an identity.
    func personalityResetLever() -> PartFace.Section {
        .init(id: "reset", title: "Reset identity", style: .list, rows: [
            .init(id: "reset", title: "Identity documents",
                detail: "SOUL, VOICE, USER, GROWTH and AGENTS are backed up, then cleared. The onboarding wizard appears next launch.",
                actions: [.init(id: "reset", label: "Reset identity", role: .destructive, doors: ["mac"], call: PartFace.Call("personality.reset"))])
        ])
    }

    /// Until the saved identity documents are read and hold an identity, the lever says why it offers nothing.
    func personalityResetUnavailable(_ unread: Error?) -> PartFace.Section {
        let row: PartFace.Row
        if let unread {
            row = .init(id: "reset-unavailable", title: "Reset is unavailable until the saved identity documents have been read.",
                detail: unread.localizedDescription, tone: .failed)
        } else {
            row = .init(id: "reset-unavailable", title: "There is no saved identity to reset.", tone: .quiet)
        }
        return .init(id: "reset", title: "Reset identity", style: .list, rows: [row])
    }

    /// Reset identity (`personality.reset`, a lever the door runs only as the person's own act): the onboarding owner backs up, then clears,
    /// the identity documents.
    @MainActor func personalityReset() async throws -> String {
        let result = try await resetOnboarding(confirm: true, resident: self)
        guard result.ok else {
            throw PartCallError(code: "reset_failed",
                message: "The identity documents were not reset: " + (result.error ?? "the reset owner gave no reason."))
        }
        return "Reset complete. \(result.backedUp.count) document(s) backed up. The onboarding wizard appears next launch."
    }

    /// The Memory and mind model (`personality.mind`, a lever): `value` is an option id the mind row offers.
    @MainActor func personalityChooseMind(_ value: String?) async throws -> String {
        guard let value, !value.isEmpty else {
            throw PartCallError(code: "unknown_action", message: "Choose an offered Memory and mind model.")
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
