import EngineRuntime
import Onboarding
import NativeAgentShared
import SwiftUI
// Blueprint: | `OnboardingWizardState.swift` | OnboardingWizardState: local progress and name drafts; provider connections and Chat readiness derive from ProvidersFacade |

@Observable
@MainActor
final class OnboardingWizardState {
    enum Step: Int, CaseIterable {
        case identity = 0
        case provider = 1
        case building = 2
        /// Reached only by a profile repair; a fresh setup goes straight to
        /// the greeting, which does the "ready" job.
        case done = 3
        case error = 4
        /// Missing-profile repair has its own action, without progress dots or shared navigation.
        case profileRepair = 5
    }

    /// Drives both progress dots and the shared navigation gate.
    static let interactiveStepCount = 2

    var step: Step = .identity
    weak var draftOwner: AppModel?
    private var savedAgentName: String
    private var savedUserName = ""
    var agentName: String {
        get { draftOwner?.editDraft("persona/new/agentName", seed: savedAgentName) ?? savedAgentName }
        set {
            if let draftOwner { draftOwner.setEditDraft(newValue, for: "persona/new/agentName") }
            else { savedAgentName = newValue }
        }
    }
    /// Onboarding creates one AI persona.
    var personaType: String = "ai"
    var providers: [ProviderInfo] { draftOwner?.engine.providers.connections ?? [] }
    var providersLoading = false
    var savingModel = false
    var providerLoadError: String? {
        draftOwner?.engine.providers.settingsError == nil ? nil : "Couldn't check your connected accounts"
    }
    var providerConnected: Bool {
        !providersLoading && providerLoadError == nil && providers.contains { $0.auth_status.eligible }
    }
    var connectedProviderLabel: String? {
        let ready = providers.filter { $0.auth_status.eligible }
        let providerID = draftOwner?.engine.providers.settings?.activeProviders["chat"]
        return (ready.first { $0.provider_id == providerID } ?? ready.first)?.display_name
    }
    var chatModelReady: Bool {
        guard let settings = draftOwner?.engine.providers.settings else { return false }
        return ProvidersFacade.chatModelIsReady(
            providers: settings.providers, providerID: settings.activeProviders["chat"] ?? "",
            model: settings.preferences["chat"]?.model ?? ""
        )
    }
    func reloadProviders(refresh: () async -> Bool) async {
        guard !providersLoading else { return }
        providersLoading = true
        defer { providersLoading = false }
        _ = await refresh()
    }
    // Names come from the person, never the macOS account.
    var userName: String {
        get { draftOwner?.editDraft("persona/new/userName", seed: savedUserName) ?? savedUserName }
        set {
            if let draftOwner { draftOwner.setEditDraft(newValue, for: "persona/new/userName") }
            else { savedUserName = newValue }
        }
    }

    func prepareProfileRepair() {
        savedAgentName = ""
        savedUserName = ""
    }

    func releaseNames(agent: String, user: String) {
        savedAgentName = agent
        savedUserName = user
        draftOwner?.clearEditDraft("persona/new/agentName")
        draftOwner?.clearEditDraft("persona/new/userName")
    }
    var abilities: [AbilityOverviewEntry] = SwiftNativeOnboardingClient.abilityOverview
    var showsAbilityOverview = false
    var errorMessage: String?
    var pendingRecoveryNeedsReset = false
    var isLoading: Bool = false
    /// A failed build cannot count existing persona bytes as successful completion.
    var buildFailed = false

    /// Identity committed; retry scaffold repair without resetting those documents.
    var scaffoldRepairFailed = false

    /// Profile-only repair preserves persona documents and never re-arms the first-run welcome.
    var profileRepairOnly = false

    /// A refused repair can re-read durable state without dismissing the sheet.
    var profileRepairRecheckOffered = false

    private static let nameSuggestions = ["Aria", "Max", "Ada", "Soren", "Clio", "Zev", "Noa"]
    // Pick once per sheet; editing the value must never recreate the field.
    let suggestedName: String

    init() {
        let suggestion = Self.nameSuggestions.randomElement() ?? ""
        suggestedName = suggestion
        savedAgentName = suggestion
    }

    var trimmedAgentName: String { agentName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUserName: String { userName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var missingNamesMessage: String? {
        if trimmedUserName.isEmpty && trimmedAgentName.isEmpty {
            return "Enter your name and an agent name."
        }
        if trimmedUserName.isEmpty { return "Enter your name." }
        if trimmedAgentName.isEmpty { return "Enter an agent name." }
        return nil
    }

    var canContinue: Bool {
        switch step {
        case .identity:
            return missingNamesMessage == nil
        case .provider:
            return !providersLoading && !savingModel && (!providerConnected || chatModelReady)
        case .building, .done, .error, .profileRepair:
            return false
        }
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1),
              previous.rawValue >= Step.identity.rawValue else { return }
        step = previous
    }

}
