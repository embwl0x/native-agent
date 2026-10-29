import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+Choices.swift` | Mac-owned model configuration and chat option controls on ChatView |

extension ChatView {
    // Every model control reads the shared Mac-owned tuple, including receipts.
    private var selectedModel: String { sync.surfaceModels["ios"]?.model ?? "" }

    private var selectedReasoningEffort: String { sync.surfaceModels["ios"]?.reasoningEffort ?? "high" }

    private var selectedFastMode: Bool { sync.surfaceModels["ios"]?.serviceTier == "priority" }

    private var selectedProviderId: String { sync.surfaceModels["ios"]?.providerID ?? "" }

    var runtimeControls: ChatRuntimeControls {
        ChatRuntimeControls(
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedFastMode ? "priority" : "default",
            fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess),
            providerId: selectedProviderId
        )
    }

    var configurationControls: some View {
            VStack(alignment: .leading, spacing: 0) {
                Menu {
                    ForEach(selectableProviders) { provider in
                        Section(provider.display_name) {
                            ForEach(selectableModelIDs(for: provider), id: \.self) { model in
                                Button {
                                    selectModel(model, providerID: provider.provider_id)
                                } label: {
                                    let title = provider.models.first(where: { $0.id == model }).map(ProviderWords.modelName) ?? modelLabel(model)
                                    if selectedProviderId == provider.provider_id && selectedModel == model {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        Task {
                            if let message = (await sync.refreshProviderControlsSnapshot()).feedbackMessage {
                                SystemToastCenter.shared.push(error: message)
                            }
                        }
                    } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                } label: {
                    controlPill("Model", title: isChatSample ? "Claude Fable 5.1 · extended context" : modelLabel(selectedModel))
                }

                AliveDivider()
                Menu {
                    ForEach(reasoningOptions, id: \.id) { option in
                        Button {
                            let requestedModel = selectedModel
                            let requestedProvider = selectedProviderId
                            let requestedServiceTier = selectedFastMode ? "priority" : "default"
                            Task {
                                do {
                                    try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requestedProvider,
                                        model: requestedModel,
                                        reasoningEffort: option.id,
                                        serviceTier: requestedServiceTier
                                    )
                                } catch {
                                    SystemToastCenter.shared.push(
                                        error: "Couldn't set reasoning to \(option.label): \(error.localizedDescription)"
                                    )
                                }
                            }
                        } label: {
                            Label(option.label, systemImage: selectedReasoningEffort == option.id ? "checkmark" : "brain")
                        }
                    }
                } label: {
                    controlPill("Thinking", title: reasoningLabel(selectedReasoningEffort))
                }

                AliveDivider()
                Menu {
                    Button { setFastMode(false) } label: {
                        Label("Normal", systemImage: selectedFastMode ? "circle" : "checkmark")
                    }
                    Button { setFastMode(true) } label: {
                        Label("Fast", systemImage: selectedFastMode ? "checkmark" : "bolt.fill")
                    }
                    .disabled(!selectedModelSupportsFast)
                } label: {
                    controlPill(
                        "Speed",
                        title: ChatRuntimeControlPresentation.processingModeTitle(fastMode: selectedFastMode)
                    )
                }
                .accessibilityLabel("Processing mode: \(selectedFastMode ? "Fast" : "Normal")")

                AliveDivider()
                Menu {
                    ForEach(fileAccessOptions, id: \.id) { option in
                        Button {
                            selectedFileAccess = option.id
                        } label: {
                            Label(option.label, systemImage: selectedFileAccess == option.id ? "checkmark" : option.icon)
                        }
                    }
                } label: {
                    controlPill("File access", title: fileAccessLabel(selectedFileAccess))
                }
            }
            .aliveCard()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        .tint(AlivePalette.text)
    }

    /// One row of the options card: what it is on the left, the current
    /// choice on the right. The whole row opens its menu.
    private func controlPill(_ label: String, title: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
            Spacer(minLength: 8)
            Text(title)
                .font(.body)
                .foregroundStyle(AlivePalette.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AlivePalette.secondary)
        }
        .aliveRow()
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var selectableProviders: [ProviderInfo] {
        sync.providers
            .filter { $0.auth_status.eligible }
            .sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
    }

    private func selectableModelIDs(for provider: ProviderInfo) -> [String] {
        var ids = Set(provider.models.map(\.id).filter { !$0.isEmpty })
        if provider.provider_id == selectedProviderId, !selectedModel.isEmpty {
            ids.insert(selectedModel)
        }
        return ids.sorted { lhs, rhs in
            if lhs == selectedModel { return true }
            if rhs == selectedModel { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func selectModel(_ model: String, providerID: String) {
        let effort = selectedReasoningEffort
        let tier = selectedFastMode ? "priority" : "default"
        Task {
            do {
                try await sync.configureSurfaceSelection(
                    surface: "ios", providerId: providerID, model: model,
                    reasoningEffort: effort, serviceTier: tier
                )
            } catch {
                SystemToastCenter.shared.push(
                    error: "Couldn't switch to \(modelLabel(model)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func setFastMode(_ enabled: Bool) {
        guard enabled != selectedFastMode else { return }
        guard !enabled || selectedModelSupportsFast else {
            SystemToastCenter.shared.push(error: "Fast mode is not available for \(modelLabel(selectedModel)).")
            return
        }
        let providerID = selectedProviderId
        let model = selectedModel
        let effort = selectedReasoningEffort
        Task {
            do {
                try await sync.configureSurfaceSelection(
                    surface: "ios", providerId: providerID, model: model,
                    reasoningEffort: effort, serviceTier: enabled ? "priority" : "default"
                )
            } catch {
                SystemToastCenter.shared.push(
                    error: "Couldn't change processing mode: \(error.localizedDescription)"
                )
            }
        }
    }

    private var reasoningOptions: [ReasoningEffortOption] {
        let supported = selectedModelInfo?.supported_reasoning_efforts
        let all = defaultReasoningEffortOptions
        return NativeAgentShared.reasoningOptions(available: supported?.isEmpty == false ? all : Array(all.prefix(4)),
            supported: supported, id: { $0.id })
    }

    private var selectedModelInfo: ProviderModelInfo? {
        sync.providers
            .first(where: { $0.provider_id == selectedProviderId })?
            .models
            .first(where: { $0.id == selectedModel })
    }

    private var selectedModelSupportsFast: Bool {
        selectedModelInfo?.supports_fast == true
    }

    private var fileAccessOptions: [(id: String, label: String, icon: String)] {
        [
            ("auto", "Auto", "wand.and.stars"),
            ("read_only", "Read only", "eye"),
            ("workspace", "Workspace", "folder"),
            ("full", "Full Mac", "bolt.trianglebadge.exclamationmark")
        ]
    }

    private func modelLabel(_ id: String) -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No pick of its own yet: the Mac's Chat choice is what this turn
            // will run on, and the phone says so rather than naming a model.
            return sync.providers.isEmpty ? "Waiting for the Mac's choice" : "Same as Mac"
        }
        return sync.providers
            .flatMap(\.models)
            .first(where: { $0.id == id })?
            .name ?? id
    }

    private func reasoningLabel(_ id: String) -> String {
        reasoningOptions.first(where: { $0.id == id })?.label ?? "Thinking"
    }

    private func fileAccessLabel(_ id: String) -> String {
        let normalized = ChatRuntimeControlPresentation.normalizedFileAccessID(id)
        return fileAccessOptions.first(where: { $0.id == normalized })?.label ?? "Auto"
    }
}
