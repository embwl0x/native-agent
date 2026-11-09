import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `ChatView+Choices.swift` | Shared Chat option forms over the Mac-owned model tuple and local file-access choice |

extension ChatView {
    private var selectedModel: String { sync.surfaceModels["ios"]?.model ?? "" }
    private var selectedProviderId: String { sync.surfaceModels["ios"]?.providerID ?? "" }
    private var selectedReasoningEffort: String { sync.surfaceModels["ios"]?.reasoningEffort ?? "high" }
    private var selectedFastMode: Bool { sync.surfaceModels["ios"]?.serviceTier == "priority" }
    private var choicesSession: FacePageSession { sync.pageSessions.page("phone-chat-options") }

    var runtimeControls: ChatRuntimeControls {
        .init(model: selectedModel, reasoningEffort: selectedReasoningEffort, serviceTier: selectedFastMode ? "priority" : "default",
            fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess), providerId: selectedProviderId)
    }

    var configurationControls: some View {
        FaceView(face: choicesFace, door: choicesDoor, session: choicesSession)
    }

    private struct ModelChoice {
        let provider: String
        let model: String
        let label: String
        var id: String { "\(provider.utf8.count):" + provider + model }
    }

    private var modelChoices: [ModelChoice] {
        sync.providers.filter { $0.auth_status.eligible }.flatMap { provider in
            var models = provider.models.map(\.id).filter { !$0.isEmpty }
            if provider.provider_id == selectedProviderId, !selectedModel.isEmpty, !models.contains(selectedModel) { models.append(selectedModel) }
            return Set(models).sorted().map { model in
                ModelChoice(provider: provider.provider_id, model: model,
                    label: provider.display_name + " · " + (provider.models.first(where: { $0.id == model }).map(ProviderWords.modelName) ?? model))
            }
        }
    }

    private var modelInfo: ProviderModelInfo? {
        sync.providers.first(where: { $0.provider_id == selectedProviderId })?.models.first(where: { $0.id == selectedModel })
    }

    private func choiceSection(_ id: String, label: String, value: String, options: [PartFace.Control.Option]) -> PartFace.Section {
        .init(id: id, rows: [], block: .init(kind: "form", key: id,
            fields: [.init(id: "value", label: label, kind: "choice", value: .string(value), required: true, options: options)],
            submit: [.init(id: "save", label: "Set " + label.lowercased(), call: .init("phone.chat." + id, [
                "provider": .string(selectedProviderId), "model": .string(selectedModel),
                "effort": .string(selectedReasoningEffort), "tier": .string(selectedFastMode ? "priority" : "default")
            ]), unavailable: options.isEmpty ? "Read the current model catalog before choosing." : nil)]))
    }

    private var choicesFace: PartFace {
        let selected = ModelChoice(provider: selectedProviderId, model: selectedModel, label: "").id
        let efforts = (modelInfo?.supported_reasoning_efforts ?? []).map { effort in
            PartFace.Control.Option(id: effort, label: defaultReasoningEffortOptions.first(where: { $0.id == effort })?.label ?? effort.capitalized)
        }
        var tiers = [PartFace.Control.Option(id: "default", label: "Normal")]
        if modelInfo?.supports_fast == true { tiers.append(.init(id: "priority", label: "Fast")) }
        return .init(sections: [
            choiceSection("model", label: "Model", value: selected, options: modelChoices.map { .init(id: $0.id, label: $0.label) }),
            choiceSection("effort", label: "Thinking", value: selectedReasoningEffort, options: efforts),
            choiceSection("tier", label: "Speed", value: selectedFastMode ? "priority" : "default", options: tiers),
            choiceSection("files", label: "File access", value: ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess),
                options: ICloudChatFileAccessPolicy.Mode.allCases.compactMap { mode in
                    switch mode {
                    case .auto: .init(id: mode.rawValue, label: "Auto")
                    case .readOnly: .init(id: mode.rawValue, label: "Read only")
                    case .workspace: .init(id: mode.rawValue, label: "Workspace")
                    case .full: .init(id: mode.rawValue, label: "Full Mac")
                    case .none: nil
                    }
                }),
            .init(id: "catalog", rows: [.init(id: "refresh", title: "Models", actions: [
                .init(id: "refresh", label: "Refresh Models", call: .init("phone.chat.refresh"))
            ])])
        ])
    }

    private var choicesDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, cancellationLabel: "Cancel waiting", waitingOn: "the Mac's model selection") { submission in
            do {
                if submission.checking || submission.expectedCall.action == "phone.chat.refresh" {
                    let result = await sync.refreshProviderControlsSnapshot()
                    guard result.outcome == .refreshed else {
                        throw choiceFailure(result.feedbackMessage ?? "The Mac's model controls could not be read.")
                    }
                    if submission.expectedCall.action == "phone.chat.refresh" {
                        return .init(words: "Model catalog refreshed.", effects: .none, accepted: true)
                    }
                    let current: String?
                    switch submission.expectedCall.action {
                    case "phone.chat.model": current = ModelChoice(provider: selectedProviderId, model: selectedModel, label: "").id
                    case "phone.chat.effort": current = selectedReasoningEffort
                    case "phone.chat.tier": current = selectedFastMode ? "priority" : "default"
                    case "phone.chat.files": current = ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess)
                    default: current = nil
                    }
                    guard let current, submission.values?["value"] == .string(current) else {
                        return .init(words: "The current choice does not confirm the submitted change. Read the choices above.", effects: .unknown)
                    }
                    return .init(words: "The current choice confirms this change.", effects: .known, accepted: true,
                        committed: [.init(id: "value", value: .string(current))])
                }
                guard let value = submission.values?["value"]?.stringValue else { throw choiceFailure("Choose an offered chat option.") }
                if submission.expectedCall.action == "phone.chat.files" {
                    guard ICloudChatFileAccessPolicy.Mode.allCases.contains(where: { $0 != .none && $0.rawValue == value }) else {
                        throw choiceFailure("Choose an offered file access mode.")
                    }
                    if selectedFileAccess != value { selectedFileAccess = value }
                    return .init(effects: .known, accepted: true, committed: [.init(id: "value", value: .string(value))])
                }
                let args = submission.expectedCall.args
                guard let provider = args["provider"]?.stringValue, let model = args["model"]?.stringValue,
                      let effort = args["effort"]?.stringValue, let tier = args["tier"]?.stringValue,
                      provider == selectedProviderId, model == selectedModel, effort == selectedReasoningEffort,
                      tier == (selectedFastMode ? "priority" : "default") else {
                    throw choiceFailure("The Mac's model selection changed. Read its current choices before submitting.")
                }
                var pickedProvider = provider, pickedModel = model, pickedEffort = effort, pickedTier = tier
                switch submission.expectedCall.action {
                case "phone.chat.model":
                    guard let choice = modelChoices.first(where: { $0.id == value }) else { throw choiceFailure("That model is unavailable.") }
                    pickedProvider = choice.provider; pickedModel = choice.model
                case "phone.chat.effort":
                    guard modelInfo?.supported_reasoning_efforts?.contains(value) == true else {
                        throw choiceFailure("That thinking level is unavailable.")
                    }
                    pickedEffort = value
                case "phone.chat.tier":
                    guard value == "default" || value == "priority" && modelInfo?.supports_fast == true else {
                        throw choiceFailure("Fast mode is unavailable for this model.")
                    }
                    pickedTier = value
                default: throw choiceFailure("This chat option is unavailable.")
                }
                if pickedProvider != provider || pickedModel != model || pickedEffort != effort || pickedTier != tier {
                    try await sync.configureSurfaceSelection(surface: "ios", providerId: pickedProvider, model: pickedModel,
                        reasoningEffort: pickedEffort, serviceTier: pickedTier)
                }
                return .init(words: "Chat option saved.", effects: .known, accepted: true, committed: [.init(id: "value", value: .string(value))])
            } catch { return .phoneFailure(error) }
        }
    }

    private func choiceFailure(_ words: String) -> WireFailure {
        .init(code: "chat_choice_unavailable", message: words, cause: nil, effects: .none)
    }
}

enum ProviderWords {
    static func modelName(_ model: ProviderModelInfo) -> String {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.id : name
    }
}
