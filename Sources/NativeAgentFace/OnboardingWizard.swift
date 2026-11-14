import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `OnboardingWizard.swift` | Shared onboarding pages with native identity commands, recovery and OAuth leaves |

// MARK: - Models


struct OnboardingWizard: View {
    let onComplete: () -> Void

    // Offscreen identity presentation needs state without starting a runtime.
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private(set) var state = OnboardingWizardState()
    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
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

                ZStack {
                    switch state.step {
                    case .identity:   IdentityAndAbilitiesStep(state: state) { await handleContinue() }
                    case .provider:   ProviderConnectStep(state: state) { await handleContinue() }
                    case .building:   BuildingStep(state: state)
                    case .done:       DoneStep(state: state, onComplete: onComplete)
                    case .profileRepair:
                        ProfileRepairStep(
                            state: state,
                            onSave: { await submitProfileRepair($0) },
                            onRecheck: { await loadOnboardingState() }
                        )
                    case .error:      ErrorStep(state: state, onRetry: {
                        // Re-read durable state so interrupted transactions resume without a payload.
                        await loadOnboardingState()
                    }, onReset: state.pendingRecoveryNeedsReset ? {
                        await resetPendingOnboarding()
                    } : nil)
                    }
                }
                // Remove the departing step immediately and animate only new content, keeping navigation fixed.
                .motionArrival()
                .id(state.step)
                .frame(maxWidth: 520)
                // Keep scroll content from painting over progress and navigation.
                .clipped()
                .padding(.horizontal, NativeAgentSpacing.xl)

                if state.step != .identity { Spacer() }


            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 640)
        .houseSheet()
        .macFaceStyle()
        .task {
            state.draftOwner = appModel
            let startup = Task { await loadOnboardingState() }
            state.startupTask = startup
            defer { state.startupTask = nil }
            await withTaskCancellationHandler { await startup.value } onCancel: { startup.cancel() }
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
        state.step = .building
        do {
            try await appModel.completeOnboarding(
                agentName: state.trimmedAgentName,
                personaType: state.personaType,
                userName: state.trimmedUserName
            )
            await finishSuccessfulOnboarding()
        } catch {
            state.errorMessage = FaceActionFeedback.message(error, action: "finish setup")
            state.step = .error
        }
    }

    /// The body commits identity; the mounted shell admits the welcome after this sheet closes.
    func finishSuccessfulOnboarding() async {
        state.releaseNames(agent: state.agentName, user: state.userName)
        if state.profileRepairOnly { state.step = .done } else { onComplete() }
    }

}

// MARK: - Step Views

private struct IdentityAndAbilitiesStep: View {
    @Bindable var state: OnboardingWizardState
    let onContinue: () async -> Void
    private var face: PartFace {
        PartFace(title: "Let's start with names.", line: "Saved on this Mac; change them anytime.", sections: [
            .init(id: "onboarding.names", rows: [], block: .init(kind: "form", key: "onboarding.names", fields: [
                .init(id: "user", label: "Your name", value: .string(state.userName), required: true),
                .init(id: "agent", label: "Agent name", value: .string(state.agentName), required: true)
            ], submit: [.init(id: "continue", label: "Continue", role: .primary, call: .init("onboarding.names.continue"))])),
            .init(id: "onboarding.abilities", title: "What the agent can help with", rows: state.abilities, folded: true)
        ])
    }
    var body: some View {
        ScrollView {
            FaceView(face: face, door: ClosureFaceDoor(open: { _ in }, waitingOn: "setup") { input in
                guard case .string(let agent)? = input.values?["agent"], case .string(let user)? = input.values?["user"] else {
                    return .interrupted(WireFailure(code: "names_required", message: "Enter both names.", cause: nil, effects: .none))
                }
                if let issue = NativeAgentIdentity.nameValidationMessage(agent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return .interrupted(WireFailure(code: "name_invalid", message: issue, cause: nil, effects: .none, fields: ["agent": issue]))
                }
                state.agentName = agent; state.userName = user
                await onContinue()
                return .init(effects: .none, accepted: true)
            }, session: state.forms)
        }
    }
}

/// OAuth and protection remain native leaves beside the stem's provider page.
private struct ProviderConnectStep: View {
    @Bindable var state: OnboardingWizardState
    let onContinue: () async -> Void
    @Environment(AppModel.self) private var appModel
    @State private var configureSheet: String?
    private var accounts: [PartFace.Row] {
        state.providers.filter { $0.auth_modes.contains("api_key") }.map { provider in
            .init(id: provider.provider_id, title: provider.display_name, detail: provider.auth_status.detail,
                actions: [.init(id: "configure", label: "Add key", call: .init("onboarding.provider.open", ["id": .string(provider.provider_id)]))])
        }
    }
    private var face: PartFace {
        var sections: [PartFace.Section] = [
            .init(id: "onboarding.accounts", title: "Or use an API key", rows: accounts, folded: true)
        ]
        if state.providerConnected {
            let options = state.providers.filter { $0.auth_status.eligible }.flatMap { provider in
                provider.offeredModels.filter { $0.supported_reasoning_efforts != nil }.map {
                    PartFace.Control.Option(id: provider.provider_id + "::" + $0.id, label: provider.display_name + " · " + $0.name)
                }
            }
            // A connected account that offers nothing yet says its own sentence; its choices appear here when its provider's list arrives.
            let waiting = state.providers.filter { $0.auth_status.eligible && $0.offeredModels.isEmpty }.compactMap(\.models_note)
            if options.isEmpty, !waiting.isEmpty {
                sections.append(.init(id: "onboarding.model.waiting", rows: [
                    .init(id: "onboarding.model.waiting", title: "No models to choose yet",
                          detail: waiting.joined(separator: " ") + " Read accounts again to ask.", tone: .attention)
                ]))
            }
            sections.append(.init(id: "onboarding.model", rows: [], block: .init(kind: "form", key: "onboarding.model", fields: [
                .init(id: "model", label: "Chat model", kind: "choice",
                    value: .string(appModel.displayedChatProvider + "::" + appModel.displayedChatModel), required: true, options: options)
            ], submit: [.init(id: "model", label: "Use this model", call: .init("onboarding.provider.model"))])))
        }
        sections.append(.init(id: "onboarding.navigation", rows: [
            .init(id: "onboarding.navigation", title: state.providerConnected ? "Ready to finish" : "You can connect later in Providers",
                detail: state.providerLoadError, actions: [
                    .init(id: "back", label: "Back", call: .init("onboarding.back")),
                    .init(id: "read", label: "Read accounts again", call: .init("onboarding.providers.read")),
                    .init(id: "continue", label: state.providerConnected ? "Continue" : "Skip for now", role: .primary,
                        call: .init("onboarding.finish"), unavailable: state.canContinue ? nil : "Wait for the accounts, then choose a connected model.")
                ])]))
        return PartFace(title: "Connect an AI account.", line: "Use your subscription or an API key. Chat needs a connected account.", sections: sections)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FaceView(face: PartFace(title: face.title, line: face.line, sections: []), door: ReadOnlyFaceDoor(), session: state.forms)
                OAuthSignInButton(provider: .chatgpt)
                OAuthSignInButton(provider: .anthropic)
                AnthropicSetupTokenInput()
                OAuthSignInButton(provider: .xai)
                FaceView(face: PartFace(sections: face.sections), door: door, session: state.forms)
            }
        }
        .sheet(isPresented: Binding(get: { configureSheet != nil }, set: { if !$0 { configureSheet = nil } })) {
            if let provider = configureSheet {
                ProviderConfigSheet(providerID: provider) { configureSheet = nil }.environment(appModel)
            }
        }
        .task { await state.reloadProviders(refresh: { await appModel.loadProvidersForChat() }) }
    }
    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "the provider owner") { input in
            do {
                switch input.action {
                case "configure":
                    guard case .string(let id)? = input.expectedCall.args["id"] else {
                        throw WireFailure(code: "account_missing", message: "Read the accounts again.", cause: nil, effects: .none)
                    }
                    configureSheet = id
                case "model":
                    guard case .string(let model)? = input.values?["model"] else {
                        throw WireFailure(code: "model_required", message: "Choose a model.", cause: nil, effects: .none)
                    }
                    let reply = try await appModel.protectedFormAct(.pageAct(.init(page: "providers", row: "providers.chat_model", action: "set",
                        value: .string(model), expectedRevision: nil,
                        expectedCall: PartFace.Call("provider.choose", ["group": .string("chat"), "setting": .string("model")]).setting(.string(model)),
                        answers: true, operation: input.id, checking: input.checking)))
                    let outcome = try FaceActOutcome.reply(reply)
                    if let failure = outcome.failure { throw failure }
                    guard outcome.accepted, !outcome.unresolved else { return outcome }
                    return .init(words: "Chat model saved.", effects: .known, accepted: true, committed: [.init(id: "model", value: .string(model))])
                case "back": state.goBack()
                // Reading the accounts again asks: the providers panel refresh act reaches the body's settings owner, which starts asking each
                // connected provider with no complete list and reads at once ("Asking…", then the list or the plain sentence).
                case "read": await state.reloadProviders(refresh: { await appModel.loadProvidersForChat() })
                case "continue":
                    guard state.canContinue else {
                        throw WireFailure(code: "setup_not_ready", message: "Wait for the accounts, then choose a connected model.", cause: nil, effects: .none)
                    }
                    await onContinue()
                default:
                    throw WireFailure(code: "setup_action_unknown", message: "Read this setup page again.", cause: nil, effects: .none)
                }
                return .init(effects: .none, accepted: true)
            } catch { return .interrupted(error) }
        }
    }
}

private struct BuildingStep: View {
    let state: OnboardingWizardState
    var body: some View {
        FaceView(face: PartFace(title: "Setting up the agent…", line: "Saving your setup on this Mac.", sections: [
            .init(id: "onboarding.building", style: .waiting, rows: [.init(id: "building", title: "Waiting on setup", tone: .live,
                actions: [.init(id: "cancel", label: "Cancel setup", call: .init("onboarding.cancel"))])])
        ]), door: ClosureFaceDoor(open: { _ in }) { _ in
            state.startupTask?.cancel()
            for operation in state.forms.operations.values where operation.item.row != "building" {
                state.forms.cancel(operation.item)
            }
            return .init(words: "Cancellation requested; waiting for setup to settle.", effects: .none, accepted: true)
        }, session: state.forms)
    }
}
