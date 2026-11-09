import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `OnboardingWizardState.swift` | Local name/progress drafts; the Providers face supplies Chat readiness |

@Observable
@MainActor
final class OnboardingWizardState {
    enum Step: Int, CaseIterable {
        case identity = 0
        case provider = 1
        case building = 2
        /// Only profile repair needs a Done step; fresh setup finishes with the greeting.
        case done = 3
        case error = 4
        /// Missing-profile repair has its own action, without progress dots or shared navigation.
        case profileRepair = 5
    }

    /// One gate keeps progress dots and navigation in agreement.
    static let interactiveStepCount = 2

    let forms = FacePageSession()
    @ObservationIgnored var startupTask: Task<Void, Never>?
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
    var personaType: String = "ai"
    var providers: [ProviderInfo] { draftOwner?.providerAccounts ?? [] }
    var providersLoading = false
    var savingModel: Bool {
        guard let operation = forms.operations["onboarding.model"] else { return false }
        return operation.outcome == nil || operation.checking || operation.outcome?.unresolved == true
    }
    var providerLoadError: String? {
        draftOwner?.providerSettingsIssue
    }
    var providerConnected: Bool {
        !providersLoading && draftOwner?.providerReadiness == .ready
    }
    var chatModelReady: Bool {
        draftOwner?.face.slot(.settings).select("providers.chatModelReady", as: SettingsFace.self) {
            $0?.providers.chatModelReady
        } == true
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
    var abilities: [PartFace.Row] {
        draftOwner?.face.slot(.onboarding).select("abilityOverview", as: OnboardingFace.self) { $0?.abilityOverview ?? [] } ?? []
    }
    var errorMessage: String?
    var pendingRecoveryNeedsReset = false
    var isLoading: Bool = false
    /// Profile-only repair preserves persona documents and never re-arms the first-run welcome.
    var profileRepairOnly = false

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
