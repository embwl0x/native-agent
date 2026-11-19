import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+ProviderCommands.swift` | Provider presentation and commands over FaceClient; save replies carry the committed choice |

@MainActor
extension AppModel {
    func performSlashBrain(_ route: ChatSlashCommandRoute, argument: String, session: String) async throws -> String {
        let reply = try await checkedFaceAct(.pageAct(.init(page: "providers", row: session, action: "read_chat_choice",
            value: nil, expectedRevision: nil, expectedCall: nil)))
        guard case .provider(let baseline) = reply, let choice = baseline.chatChoice, let revision = baseline.snapshot?.routing.revision else {
            throw chatProtocolFailure("the checked model choice and routing revision.")
        }
        let selected: ProviderTurnChoice
        switch route {
        case .model:
            guard !argument.isEmpty else { return "Chat model: " + choice.model }
            selected = .init(provider: choice.provider, model: argument, reasoningEffort: choice.reasoningEffort, fast: choice.fast)
        case .think:
            guard !argument.isEmpty else { throw PartCallError(code: "reasoning_level_required", message: "Usage: /think <level>") }
            selected = .init(provider: choice.provider, model: choice.model, reasoningEffort: argument.lowercased(), fast: choice.fast)
        case .fast:
            guard choice.model.lowercased().hasPrefix("gpt-"), ["on", "off"].contains(argument.lowercased()) else {
                throw PartCallError(code: "fast_choice_invalid", message: "Choose a GPT model and use /fast <on|off>.")
            }
            selected = .init(provider: choice.provider, model: choice.model, reasoningEffort: choice.reasoningEffort, fast: argument.lowercased() == "on")
        default: throw chatProtocolFailure("a model selection command.")
        }
        let edit: ChatChoiceEdit = route == .think ? .reasoning : route == .fast ? .fast : .selection
        let saved = try await checkedFaceAct(.saveChatChoice(.init(choice: selected, expectedBaseline: choice, expectedRevision: revision, edit: edit)))
        guard case .provider(let readback) = saved, let committed = readback.chatChoice else {
            throw chatProtocolFailure("the saved model choice.")
        }
        return "Chat brain saved: " + committed.model + " / " + committed.reasoningEffort
    }

    var providerSettingsIssue: String? {
        face.slot(.settings).select("providers.issue", as: SettingsFace.self) { $0?.providers.error }
    }

    var providerAccounts: [ProviderInfo] {
        face.slot(.settings).select("providers.accounts", as: SettingsFace.self) { $0?.providers.snapshot?.providers } ?? []
    }

    var providerReadiness: ProviderSettingsFace.Readiness {
        face.slot(.settings).select("providers.readiness", as: SettingsFace.self) { $0?.providers.readiness } ?? .loading
    }

    var displayedChatModel: String {
        face.slot(.settings).select("providers.chatModel", as: SettingsFace.self) { $0?.providers.chatChoice?.model } ?? ""
    }

    var displayedChatProvider: String {
        face.slot(.settings).select("providers.chatProvider", as: SettingsFace.self) { $0?.providers.chatChoice?.provider } ?? ""
    }

    var providerSavingChatBrain: Bool {
        face.slot(.settings).select("providers.savingChatBrain", as: SettingsFace.self) { $0?.providers.isSavingChatBrain } == true
    }


    /// The providers panel refresh: the body starts asking any connected provider with no complete list (`startAskingMissingModelLists`) and
    /// reads at once, so setup's "Read accounts again" retries a failed or cancelled first fetch.
    @discardableResult
    func loadProvidersForChat() async -> Bool {
        do {
            _ = try await checkedFaceAct(.refresh(.panel(SidebarItem.providers.rawValue)))
            return true
        } catch { setFailureStatus(error, action: "read Providers"); return false }
    }

    func testProviderConnection(_ request: ProviderTestRequest) async throws -> ProviderTestReply {
        guard case .providerTest(let probe) = try await checkedFaceAct(.testProvider(request)) else {
            throw FaceActionFeedback.unexpected("a provider-test result")
        }
        return probe
    }
}
