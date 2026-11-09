import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `QuietComposerCommands+Presentation.swift` | Feed-only composer labels and body-owned routing transactions; window card call endpoints |

enum QuietComposerCommands {
    static let cardNames = ChatComposerCard.allCases.map(\.rawValue)

    @MainActor
    struct Routing {
        let appModel: AppModel
        let sessionID: String
        init(appModel: AppModel, sessionID: String? = nil) {
            self.appModel = appModel
            self.sessionID = sessionID ?? appModel.activeChatSessionId
        }

        var presentation: ProviderComposerPresentation? {
            let session = sessionID
            return appModel.face.slot(.settings).select("providers.composer.\(session)", as: SettingsFace.self) {
                $0?.providers.sessions[session]?.controls
            }
        }
        var residentPresentation: ProviderComposerPresentation? { presentation.flatMap { $0.contract == nil ? $0 : nil } }
        var routeChoice: ProviderTurnChoice? { presentation?.choice }
        var botContract: ProviderHelperPresentation? { presentation?.contract }
        var isBotConversation: Bool { botContract != nil }
        var providerGroups: [ChatComposerModelGroup] { residentPresentation?.providerGroups ?? [] }
        var efforts: [ReasoningEffortOption] { presentation?.efforts ?? [] }
        var effortIndex: Int? { efforts.firstIndex { $0.id == routeChoice?.reasoningEffort } }
        var selectedModelSupportsFast: Bool { residentPresentation?.supportsFast == true }
        var fastIsOn: Bool { presentation?.fastIsOn == true }
        var modelWord: String {
            guard let presentation else { return "Reading model…" }
            if let contract = presentation.contract { return contract.model ?? "Helper model unavailable" }
            guard let choice = presentation.choice, !choice.model.isEmpty else { return "Choose model" }
            return presentation.selectedModel?.displayName ?? choice.model
        }
        var effortWord: String {
            guard let presentation else { return "Reading thinking…" }
            if presentation.contract != nil, routeChoice?.reasoningEffort == nil { return "Helper thinking unavailable" }
            if presentation.selectedModel?.supportedReasoningEfforts == [] { return "Thinking not configurable" }
            guard let effort = routeChoice?.reasoningEffort, let choice = efforts.first(where: { $0.id == effort }) else {
                return "Thinking unavailable"
            }
            return choice.label
        }
        var trustWord: String {
            appModel.face.slot(.settings).select("trust.word", as: SettingsFace.self) { $0?.trust.word } ?? "Reading Trust…"
        }
        var activeTrustPreset: MobileTrustAction.Preset? {
            appModel.face.slot(.settings).select("trust.activePreset", as: SettingsFace.self) {
                $0?.trust.activePreset.flatMap(MobileTrustAction.Preset.init(rawValue:))
            }
        }

        func select(model: String, provider: String) async throws {
            try await save { choice in
                ProviderTurnChoice(provider: provider, model: model, reasoningEffort: choice.reasoningEffort, fast: choice.fast)
            }
        }

        func setEffort(_ effort: String) async throws {
            try await save(edit: .reasoning) { ProviderTurnChoice(provider: $0.provider, model: $0.model, reasoningEffort: effort, fast: $0.fast) }
        }

        func setFast(_ enabled: Bool) async throws {
            try await save(edit: .fast) { ProviderTurnChoice(provider: $0.provider, model: $0.model, reasoningEffort: $0.reasoningEffort, fast: enabled) }
        }

        /// The act readback supplies the baseline; drawing values never decide the transaction.
        private func save(edit: ChatChoiceEdit = .selection,
                          _ change: @MainActor (ProviderTurnChoice) -> ProviderTurnChoice) async throws {
            let request = PageActRequest(page: "providers", row: sessionID, action: "read_chat_choice",
                                         value: nil, expectedRevision: nil, expectedCall: nil)
            guard case .provider(let settings) = try await appModel.chatAct(.pageAct(request)),
                  let baseline = settings.chatChoice, let snapshot = settings.snapshot else {
                throw appModel.chatProtocolFailure("the current Chat choice and its revision.")
            }
            try Task.checkCancellation()
            let choice = change(baseline)
            guard choice != baseline else { return }
            let write = ChatChoiceWrite(choice: choice, expectedBaseline: baseline, expectedRevision: snapshot.routing.revision, edit: edit)
            guard case .provider(let saved) = try await appModel.chatAct(.saveChatChoice(write)), saved.chatChoice != nil else {
                throw appModel.chatProtocolFailure("the saved provider settings.")
            }
        }
    }

    @MainActor
    static func openFaceCard(_ name: String) -> FaceReply {
        guard let card = ChatComposerCard(rawValue: name) else {
            return .refused(WireFailure(code: "unknown_card", message: "The composer panes are: " + cardNames.joined(separator: ", "),
                                        cause: nil, effects: .none))
        }
        guard let shell = QuietSelfAdmin.shared.composerCards, shell.open(card) else {
            return .refused(WireFailure(code: "composer_unavailable", message: "That composer control is not mounted.", cause: nil, effects: .none))
        }
        return .acknowledged
    }

    @MainActor
    static func closeFaceCard() -> FaceReply {
        guard let shell = QuietSelfAdmin.shared.composerCards else {
            return .refused(WireFailure(code: "composer_unavailable", message: "No composer is mounted.", cause: nil, effects: .none))
        }
        shell.dismiss()
        return .acknowledged
    }
}
