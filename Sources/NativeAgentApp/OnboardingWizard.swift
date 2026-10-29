import AppToolRuntime
import Onboarding
import EngineRuntime
import SwiftUI
import NativeAgentShared
// Blueprint: | `OnboardingWizard.swift` | Fresh identity setup and shared wizard presentation; recovery, profile repair and reset are separate identity operations |

// MARK: - Models

extension AbilityOverviewEntry: @retroactive Identifiable {}

struct OnboardingWizard: View {
    let onComplete: () -> Void

    // Loading/actions require the real model; an offscreen identity fixture only
    // needs wizard state. Optional lookup avoids eagerly starting a runtime.
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private(set) var state = OnboardingWizardState()
    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Progress dots
                if state.step.rawValue < OnboardingWizardState.Step.building.rawValue {
                    HStack(spacing: 8) {
                        ForEach(0..<OnboardingWizardState.interactiveStepCount, id: \.self) { i in
                            Circle()
                                .fill(i <= state.step.rawValue ? NativeAgentShell.text : NativeAgentShell.tertiary)
                                .frame(width: 8, height: 8)
                                .animation(NativeAgentMotion.quick, value: state.step)
                        }
                    }
                    .padding(.top, NativeAgentSpacing.xl)
                }

                if state.step != .identity { Spacer() }

                // Step content
                ZStack {
                    switch state.step {
                    case .identity:   IdentityAndAbilitiesStep(state: state)
                    case .provider:   ProviderConnectStep(state: state)
                    case .building:   BuildingStep(state: state)
                    case .done:       DoneStep(state: state, onComplete: onComplete)
                    case .profileRepair:
                        ProfileRepairStep(
                            state: state,
                            onSave: { Task { await submitProfileRepair() } },
                            onRecheck: { Task { await loadOnboardingState() } }
                        )
                    case .error:      ErrorStep(state: state, onRetry: {
                        // Identity is committed; retry the scaffold repair itself.
                        if state.scaffoldRepairFailed {
                            Task {
                                state.step = .building
                                await finishSuccessfulOnboarding()
                            }
                            return
                        }
                        // Re-read durable state so interrupted transactions resume without a payload.
                        Task { await loadOnboardingState() }
                    }, onReset: state.pendingRecoveryNeedsReset ? {
                        Task { await resetPendingOnboarding() }
                    } : nil)
                    }
                }
                // Each step arrives once: the old one leaves at once (no
                // overlap, no lingering labels) and the new one fades up. The
                // step changes themselves carry no animation, so the dots,
                // spacers and nav bar never ride along.
                .motionArrival()
                .id(state.step)
                .frame(maxWidth: 520)
                // The step owns its viewport. Native scroll content must not
                // paint above it over the progress dots or below the nav bar.
                .clipped()
                .padding(.horizontal, NativeAgentSpacing.xl)

                if state.step != .identity { Spacer() }

                // Navigation buttons
                if state.step.rawValue < OnboardingWizardState.Step.building.rawValue {
                    OnboardingNavBar(state: state) {
                        Task { await handleContinue() }
                    }
                    .frame(maxWidth: 568)
                    .padding(.top, NativeAgentSpacing.lg)
                    .padding(.bottom, NativeAgentSpacing.xl)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 640)
        .houseSheet()
        .task {
            state.draftOwner = appModel
            await loadOnboardingState()
        }
    }

    // MARK: - Logic

    func setupModel() -> AppModel? {
        guard let appModel else {
            state.errorMessage = "Setup is unavailable because the app model is missing."
            state.step = .error
            return nil
        }
        return appModel
    }

    private func handleContinue() async {
        guard state.canContinue else { return }
        switch state.step {
        case .identity:
            state.agentName = state.trimmedAgentName
            state.userName = state.trimmedUserName
            state.step = .provider
        case .provider:
            await submitOnboarding()
        case .building, .done, .error, .profileRepair:
            break
        }
    }

    private func submitOnboarding() async {
        guard let appModel = setupModel() else { return }
        state.scaffoldRepairFailed = false
        state.step = .building
        do {
            let resp = try await appModel.completeOnboarding(
                agentName: state.trimmedAgentName,
                personaType: state.personaType,
                userName: state.trimmedUserName
            )
            if resp.ok {
                state.buildFailed = false
                await finishSuccessfulOnboarding()
            } else {
                state.buildFailed = true
                state.errorMessage = Self.buildFailureMessage(error: resp.error, detail: resp.detail)
                if resp.requiresPersonaReset {
                    state.pendingRecoveryNeedsReset = true
                }
                state.step = .error
            }
        } catch {
            state.buildFailed = true
            state.errorMessage = UserFacingError.message(error, action: "finish setup")
            state.step = .error
        }
    }

    /// Raw backend error codes are not user-facing copy.
    static func buildFailureMessage(error: String?, detail: String?) -> String {
        switch error {
        case "persona_already_exists":
            return "Persona documents already exist on this Mac, so onboarding could not write its own. Reset will back them up before starting over."
        case .some(let code) where detail == nil || detail?.isEmpty == true:
            return "Onboarding failed (\(code))."
        default:
            return detail ?? error ?? "Onboarding failed."
        }
    }

    /// Fresh completion and pending-transaction resume both require scaffold repair.
    /// Registered owners repair scaffolding; canonical owners initialize runtime stores.
    /// Failure keeps committed identity documents and offers repair again, never reset.
    func finishSuccessfulOnboarding() async {
        guard let appModel = setupModel() else { return }
        state.releaseNames(agent: state.agentName, user: state.userName)
        let outcome = await appModel.runDoctor(repair: true, repairScope: .onboarding)
        guard outcome.didRun, outcome.failingScaffoldChecks.isEmpty else {
            state.scaffoldRepairFailed = true
            state.pendingRecoveryNeedsReset = false
            state.errorMessage = Self.scaffoldRepairFailureMessage(outcome)
            state.step = .error
            return
        }
        state.scaffoldRepairFailed = false
        guard !state.profileRepairOnly else {
            state.step = .done
            return
        }
        appModel.markFirstRunWelcomePending()
        // Fresh setup opens Simple view and the greeting.
        UserDefaults.standard.set(SimpleViewMode.simple, forKey: SimpleViewMode.key)
        onComplete()
    }

    /// Name the failed scaffold check, the saved identity and the repair action.
    static func scaffoldRepairFailureMessage(_ outcome: DoctorFacade.RunOutcome) -> String {
        let detail = outcome.failureDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Your identity documents were written, but setting up the app's local files did not finish, so this install is not ready yet.",
            detail.isEmpty ? nil : detail,
            "Choose Try again to finish setting up the app's local files."
        ].compactMap { $0 }.joined(separator: " ")
    }

}

// MARK: - Step Views

private struct IdentityAndAbilitiesStep: View {
    @Bindable var state: OnboardingWizardState
    @Environment(\.colorScheme) private var scheme
    private let titleSize: CGFloat = 25
    private let bodySize: CGFloat = 16
    private let labelSize: CGFloat = 13

    private var secondaryInk: Color { OnboardingInk.secondary(scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Let's start with names.")
                        .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use these names in conversations. Saved on this Mac; change them anytime.")
                        .font(.system(size: bodySize))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Group {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your name")
                                .font(.system(size: labelSize))
                                .foregroundStyle(secondaryInk)
                            TextField("Your name", text: $state.userName)
                                .font(.system(size: bodySize))
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Agent name")
                                .font(.system(size: labelSize))
                                .foregroundStyle(secondaryInk)
                            TextField("Agent name", text: $state.agentName)
                                .accessibilityLabel("Agent name")
                                .font(.system(size: bodySize))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(20)
                .aliveCard()

                if let message = state.missingNamesMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(secondaryInk)
                }

                DisclosureGroup(isExpanded: $state.showsAbilityOverview) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                        ForEach(state.abilities) { ability in
                            AbilityOverviewTile(ability: ability)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("What \(state.trimmedAgentName.isEmpty ? "the agent" : state.trimmedAgentName) can help with")
                        .font(.system(size: labelSize, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 4)
        }
    }
}

private enum OnboardingInk {
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.80, green: 0.82, blue: 0.86) : Color(red: 0.28, green: 0.30, blue: 0.34)
    }
}

private struct AbilityOverviewTile: View {
    let ability: AbilityOverviewEntry
    @Environment(\.colorScheme) private var scheme
    private let bodySize: CGFloat = 16
    private let detailSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ability.systemImage.isEmpty ? "sparkles" : ability.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NativeAgentShell.secondary)
                .frame(width: 24, height: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(ability.title)
                    .font(.system(size: bodySize))
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ability.detail)
                    .font(.system(size: detailSize))
                    .foregroundStyle(OnboardingInk.secondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(NativeAgentSpacing.md)
        .aliveCard()
    }
}

// MARK: - Provider connect step

/// Uses the Providers sign-in and configuration controls; connecting adopts the account for Chat.
/// Setup can finish without a connection.
private struct ProviderConnectStep: View {
    @Bindable var state: OnboardingWizardState
    @Environment(AppModel.self) private var appModel

    @State private var configureSheet: String? = nil
    @State private var showsAPIKeys = false
    @State private var modelSaveError: String?

    private static let signInProviderIDs: Set<String> = [
        "openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Connect an AI account.")
                        .font(NativeAgentFont.display)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Connect an account you already use, or add an API key.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Sign in with a subscription account (same OAuth buttons as
                // the Providers tab).
                NativePanel {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        Text("Sign in with your account")
                            .font(NativeAgentFont.section)
                        Text("Use your existing ChatGPT, Claude, or Grok subscription.")
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                        OAuthSignInButton(provider: .chatgpt)
                        Divider()
                        OAuthSignInButton(provider: .anthropic)
                        AnthropicSetupTokenInput()
                        Divider()
                        OAuthSignInButton(provider: .xai)
                    }
                }

                if let error = state.providerLoadError {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await reload() } }
                        .disabled(state.providersLoading)
                }

                // Keep API-key configuration behind disclosure so account sign-in stays prominent.
                DisclosureGroup(isExpanded: $showsAPIKeys) {
                    NativePanel {
                        // Sign-in controls are above; this list contains API-key rows only.
                        ForEach(state.providers.filter { !Self.signInProviderIDs.contains($0.provider_id) }) { provider in
                            ProviderRowView(provider: provider) { configureSheet = provider.provider_id }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    HStack {
                        Text("Use an API key instead")
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                        if state.providersLoading { ProgressView().controlSize(.small) }
                    }
                }

                if state.providerConnected {
                    Label("Connected: \(state.connectedProviderLabel ?? "provider").", systemImage: "checkmark.seal.fill")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.green)
                    ProviderThenModelPicker(
                        providers: state.providers.map { provider in
                            ProviderThenModelPicker.Provider(
                                id: provider.provider_id,
                                name: ProviderThenModelPicker.plainProviderName(provider.display_name),
                                ready: provider.auth_status.eligible,
                                models: provider.models.map { .init(id: $0.id, name: $0.name) }
                            )
                        },
                        currentProviderID: appModel.chatProvider,
                        currentModelID: appModel.chatModel,
                        disabled: state.savingModel || state.providersLoading,
                        onSelect: { provider, model in
                            state.savingModel = true
                            modelSaveError = nil
                            Task {
                                defer { state.savingModel = false }
                                do {
                                    _ = try await appModel.engine.saveProviderGroupSelection(
                                        group: ProviderSurfaceGroups.chat,
                                        providerID: provider.id, model: model.id
                                    )
                                } catch {
                                    modelSaveError = UserFacingError.message(error, action: "save your model choice")
                                }
                            }
                        }
                    )
                    if let modelSaveError {
                        Text(modelSaveError).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("You can connect later in Providers. Chat needs a connected account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: Binding(get: { configureSheet != nil }, set: { if !$0 { configureSheet = nil } })) {
            if let provider = appModel.engine.providers.connections.first(where: { $0.provider_id == configureSheet }) {
            ProviderConfigSheet(provider: provider) {
                configureSheet = nil
            }
            .environment(appModel)
            }
        }
        .task {
            await reload()
        }
    }

    /// Passive reads preserve saved provider choices; connection operations own adoption.
    private func reload() async {
        await state.reloadProviders(refresh: { await appModel.loadProvidersForChat() })
    }
}

private struct BuildingStep: View {
    let state: OnboardingWizardState

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Setting up \(state.trimmedAgentName.isEmpty ? "the agent" : state.trimmedAgentName)…")
                .font(NativeAgentFont.title)
            Text("Saving your setup on this Mac.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - Nav Bar

private struct OnboardingNavBar: View {
    @Bindable var state: OnboardingWizardState
    let onContinue: () -> Void

    /// Without a connection, skipping stays a plain link so sign-in is the primary action.
    private var isUnconnectedProviderStep: Bool {
        state.step == .provider && !state.providerConnected
    }

    var body: some View {
        HStack {
            if state.step.rawValue > OnboardingWizardState.Step.identity.rawValue {
                Button("Back") { state.goBack() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(NativeAgentFont.label)
            }

            Spacer()

            if isUnconnectedProviderStep {
                Button("Skip for now") {
                    onContinue()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(NativeAgentFont.label)
                .help("Finish setup without a provider — chat won't work until one is connected.")
                .disabled(!state.canContinue)
            } else {
                if state.step == .provider && state.providerConnected && !state.providersLoading
                    && !state.savingModel && !state.chatModelReady {
                    Text("Choose a model to continue")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!state.canContinue)
                .opacity(state.canContinue ? 1 : 0.4)
            }
        }
        .padding(.horizontal, NativeAgentSpacing.xl)
    }
}
