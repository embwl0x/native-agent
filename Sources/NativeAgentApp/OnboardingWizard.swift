// PATCH-2026-05-07: onboarding-2 Generic onboarding wizard — name + persona type
import SwiftUI
import AppKit

// MARK: - Models

struct OnboardingStartResponse: Codable {
    var ready: Bool
    var hasExisting: Bool
    var currentPersonaName: String?
    var personaTypeOptions: [PersonaTypeOption]?
    var abilityOverview: [OnboardingAbility]?
    var pendingRecovery: Bool?
    var resetRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case ready
        case hasExisting = "has_existing"
        case currentPersonaName = "current_persona_name"
        case personaTypeOptions = "persona_type_options"
        case abilityOverview = "ability_overview"
        case pendingRecovery = "pending_recovery"
        case resetRequired = "reset_required"
    }
}

struct OnboardingAbility: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String?

    enum CodingKeys: String, CodingKey {
        case id, title, detail
        case systemImage = "system_image"
    }
}

struct PersonaTypeOption: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var description: String
    var sampleAnchor: String
    var pronouns: String

    enum CodingKeys: String, CodingKey {
        case id, label, description, pronouns
        case sampleAnchor = "sample_anchor"
    }
}

struct OnboardingCompleteResponse: Sendable, Equatable {
    let ok: Bool
    let agentName: String?
    let personaType: String?
    let userName: String?
    let docsWritten: [String]
    let error: String?
    let detail: String?
}

struct OnboardingResetResponse: Sendable, Equatable {
    let ok: Bool
    let backedUp: [String]
    let readyForOnboarding: Bool
    let error: String?
}

// MARK: - Wizard State

@Observable
@MainActor
final class OnboardingWizardState {
    enum Step: Int, CaseIterable {
        case identity = 0
        case provider = 1
        case confirm = 2
        case building = 3
        case done = 4
        case error = 5
    }

    /// Number of user-facing steps before the build spinner — drives the
    /// progress dots and the "show the nav bar / progress" gate. Kept as a
    /// single source so adding a step updates both.
    static let interactiveStepCount = 3

    var step: Step = .identity
    var agentName: String = ""
    /// The public build ships a SINGLE AI persona — onboarding no longer offers
    /// a female/male/ai choice (User, 2026-07-04: "just give it a name and tell
    /// it your name"). Fixed to "ai"; the backend still accepts it.
    var personaType: String = "ai"
    /// Provider connection captured during the `.provider` step. Skippable
    /// (User, 2026-07-04: "strongly suggest, allow skip"), so `connected`
    /// stays false when the user moves past without connecting — the chat
    /// surface then shows an honest "connect a provider" prompt.
    var providerConnected: Bool = false
    var connectedProviderLabel: String?
    /// Bumped by the nav bar's prominent "Connect a provider" action so the
    /// provider step scrolls back to the sign-in panel (sweep R4 C2). A counter
    /// rather than a Bool so repeated taps each re-scroll.
    var connectPromptTick: Int = 0
    // Blank by default — never pre-fill from the macOS account name
    // (NSFullUserName): a public user's Mac account isn't their answer to
    // "your name," and it leaked the host account into onboarding (User, 2026-07-05).
    var userName: String = ""
    var personaOptions: [PersonaTypeOption] = []
    var abilities: [OnboardingAbility] = OnboardingWizardState.defaultAbilities
    var errorMessage: String?
    var pendingRecoveryNeedsReset = false
    var isLoading: Bool = false
    /// True once this wizard has submitted a Build that did NOT succeed.
    ///
    /// fix-blank-install-onboarding (2026-08-02): the retry path re-read the
    /// durable start state and called `onComplete()` whenever it reported
    /// `hasExisting` — so a Build that failed with `persona_already_exists`
    /// (pre-existing persona bytes this wizard did not write) dismissed the
    /// wizard as though onboarding had SUCCEEDED, leaving an unnamed agent and
    /// no identity docs. A failed Build is never completion; while this flag is
    /// set, existing persona state is treated as the obstacle it is and the
    /// user is offered the backup-preserving reset instead.
    var buildFailed = false

    /// True when the persona documents committed but the post-completion
    /// scaffold repair did not succeed (gpt-5.5 review BLOCKING 2, 2026-08-02).
    ///
    /// Distinct from `buildFailed` on purpose. `buildFailed` means "pre-existing
    /// persona bytes blocked this Build" and its remedy is the backup-preserving
    /// reset. This means "identity landed, the app's own local files did not" —
    /// resetting would throw away good identity docs over an unrelated problem,
    /// so the retry re-runs the repair instead of re-reading start state (which
    /// would see the now-committed docs and dismiss the wizard as complete).
    var scaffoldRepairFailed = false

    // Name placeholder rotation
    private let nameSuggestions = ["Aria", "Max", "Ada", "Soren", "Clio", "Zev", "Noa"]
    var namePlaceholder: String { nameSuggestions[abs(Int(Date().timeIntervalSince1970) / 3) % nameSuggestions.count] }

    var trimmedAgentName: String { agentName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUserName: String { userName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canContinue: Bool {
        switch step {
        case .identity:
            return !trimmedUserName.isEmpty && !trimmedAgentName.isEmpty
        case .provider, .confirm:
            // `.provider` is intentionally always-continuable — connecting is
            // strongly suggested but skippable.
            return true
        case .building, .done, .error:
            return false
        }
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1),
              previous.rawValue >= Step.identity.rawValue else { return }
        step = previous
    }

    static let defaultAbilities: [OnboardingAbility] = [
        OnboardingAbility(id: "chat", title: "Chat with memory", detail: "Long-running conversations, recall, corrections, and personality growth.", systemImage: "message"),
        OnboardingAbility(id: "projects", title: "Build with you", detail: "Read approved projects, edit files, run tests, and keep receipts when access allows.", systemImage: "hammer"),
        OnboardingAbility(id: "mac", title: "Use Mac actions", detail: "Notifications, Spotlight, Shortcuts, files, shell, and app control behind Trust settings.", systemImage: "macbook"),
        OnboardingAbility(id: "connectors", title: "Connect services", detail: "Optional providers and connectors for chat models, Telegram, GitHub, email, calendar, and more.", systemImage: "point.3.connected.trianglepath.dotted"),
        OnboardingAbility(id: "mobile", title: "Work from iPhone", detail: "Pair the mobile app for chat, approvals, push notifications, inbox, activity, and remote actions.", systemImage: "iphone"),
        OnboardingAbility(id: "improve", title: "Improve safely", detail: "Harness checks, evals, incidents, receipts, and gated promotions keep behavior from regressing.", systemImage: "checkmark.shield"),
    ]
}

// MARK: - OnboardingWizard

struct OnboardingWizard: View {
    let onComplete: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var state = OnboardingWizardState()

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [NativeAgentBrand.accent.opacity(0.08), NativeAgentBrand.accentCool.opacity(0.06), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                if state.step.rawValue < OnboardingWizardState.Step.building.rawValue {
                    HStack(spacing: 8) {
                        ForEach(0..<OnboardingWizardState.interactiveStepCount, id: \.self) { i in
                            Circle()
                                .fill(i <= state.step.rawValue ? Color.blue : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .animation(NativeAgentMotion.snappy, value: state.step)
                        }
                    }
                    .padding(.top, NativeAgentSpacing.xl)
                }

                Spacer()

                // Step content
                Group {
                    switch state.step {
                    case .identity:   IdentityAndAbilitiesStep(state: state)
                    case .provider:   ProviderConnectStep(state: state)
                    case .confirm:    ConfirmStep(state: state)
                    case .building:   BuildingStep()
                    case .done:       DoneStep(state: state, onComplete: onComplete)
                    case .error:      ErrorStep(state: state, onRetry: {
                        // A scaffold-repair failure is NOT an onboarding-state
                        // problem: the transaction already committed, so
                        // re-reading start state would report `hasExisting` and
                        // dismiss the wizard over the very scaffold that failed.
                        // Retry the repair itself.
                        if state.scaffoldRepairFailed {
                            Task {
                                withAnimation { state.step = .building }
                                await finishSuccessfulOnboarding()
                            }
                            return
                        }
                        // Otherwise re-read the durable start state before
                        // choosing a retry path. A normal submit may have failed
                        // after publishing its transaction manifest, so blindly
                        // returning to Confirm can lose the payload-free
                        // recovery lane and retry with blank wizard fields.
                        Task { await loadOnboardingState() }
                    }, onReset: state.pendingRecoveryNeedsReset ? {
                        Task { await resetPendingOnboarding() }
                    } : nil)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, NativeAgentSpacing.xl)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(NativeAgentMotion.gentle, value: state.step)

                Spacer()

                // Navigation buttons
                if state.step.rawValue < OnboardingWizardState.Step.building.rawValue {
                    OnboardingNavBar(state: state) {
                        Task { await handleContinue() }
                    }
                    .padding(.bottom, NativeAgentSpacing.xl)
                }
            }
        }
        .frame(width: 680, height: 640)
        .task {
            await loadOnboardingState()
        }
    }

    // MARK: - Logic

    private func loadOnboardingState() async {
        // WAVE 15 (2026-06-01): switched from raw URLSession to NativeClient.startOnboarding()
        // so the SwiftNative gate in startOnboarding() is exercised rather than bypassed.
        // Runtime MUST be passed — daemon-side /v1/onboarding/start is retired (would throw
        // DaemonError.swiftOnlyRoute on fallthrough), and only the SwiftNative path is live.
        // R22: AppModel's canonical `client` already carries the shared runtime.
        let resp: OnboardingStartResponse
        // Any path through start state is a fresh verdict; a stale scaffold flag
        // must not hijack the next Retry.
        state.scaffoldRepairFailed = false
        do {
            resp = try await appModel.startOnboarding()
        } catch {
            state.pendingRecoveryNeedsReset = true
            state.errorMessage = "Onboarding recovery state is unavailable: \(error.localizedDescription)"
            withAnimation { state.step = .error }
            return
        }
        if resp.pendingRecovery == true {
            withAnimation { state.step = .building }
            do {
                let resumed = try await appModel.resumePendingOnboarding()
                if resumed.ok {
                    state.pendingRecoveryNeedsReset = false
                    state.agentName = resumed.agentName ?? resp.currentPersonaName ?? state.agentName
                    state.userName = resumed.userName ?? state.userName
                    state.personaType = resumed.personaType ?? state.personaType
                    await finishSuccessfulOnboarding()
                } else {
                    state.pendingRecoveryNeedsReset = true
                    state.errorMessage = resumed.detail ?? resumed.error ?? "Onboarding recovery failed."
                    withAnimation { state.step = .error }
                }
            } catch {
                state.pendingRecoveryNeedsReset = true
                state.errorMessage = error.localizedDescription
                withAnimation { state.step = .error }
            }
            return
        }
        if resp.resetRequired == true {
            state.pendingRecoveryNeedsReset = true
            state.errorMessage = "Incomplete persona documents were found. Reset will back them up before onboarding starts again."
            withAnimation { state.step = .error }
            return
        }
        if resp.hasExisting {
            switch Self.existingPersonaDisposition(buildFailed: state.buildFailed) {
            case .alreadyOnboarded:
                onComplete()
            case .blockedNeedsReset:
                state.pendingRecoveryNeedsReset = true
                state.errorMessage = state.errorMessage
                    ?? Self.buildFailureMessage(error: "persona_already_exists", detail: nil)
                withAnimation { state.step = .error }
            }
            return
        }
        state.pendingRecoveryNeedsReset = false
        // Persona-type picker removed 2026-07-04 (single AI persona) — only the
        // ability overview is still consumed from the start response.
        state.abilities = resp.abilityOverview?.isEmpty == false ? (resp.abilityOverview ?? OnboardingWizardState.defaultAbilities) : OnboardingWizardState.defaultAbilities
        if state.step == .error {
            withAnimation { state.step = .confirm }
        }
    }

    private func resetPendingOnboarding() async {
        do {
            let reset = try await appModel.resetOnboarding(confirm: true)
            guard reset.ok else {
                state.errorMessage = reset.error ?? "Onboarding reset failed."
                return
            }
            state.pendingRecoveryNeedsReset = false
            state.buildFailed = false
            state.errorMessage = nil
            state.agentName = ""
            state.userName = ""
            withAnimation { state.step = .identity }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func handleContinue() async {
        withAnimation {
            switch state.step {
            case .identity:
                state.agentName = state.trimmedAgentName
                state.userName = state.trimmedUserName
                state.step = .provider
            case .provider:
                state.step = .confirm
            case .confirm:
                Task { await submitOnboarding() }
            case .building, .done, .error:
                break
            }
        }
    }

    private func submitOnboarding() async {
        state.scaffoldRepairFailed = false
        withAnimation { state.step = .building }
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
                // `persona_already_exists` means unrelated persona bytes are in
                // the way. That is precisely what reset (which BACKS UP before
                // clearing) exists for, so surface the affordance instead of
                // showing a raw error code with no way forward.
                if resp.error == "persona_already_exists" {
                    state.pendingRecoveryNeedsReset = true
                }
                withAnimation { state.step = .error }
            }
        } catch {
            state.buildFailed = true
            state.errorMessage = error.localizedDescription
            withAnimation { state.step = .error }
        }
    }

    /// What pre-existing persona state means to a wizard that is currently open.
    enum ExistingPersonaDisposition: Equatable {
        /// Someone else already onboarded this Mac — close the wizard.
        case alreadyOnboarded
        /// This wizard's own Build failed against that state; it is an
        /// obstacle, not a success. Offer the backup-preserving reset.
        case blockedNeedsReset
    }

    /// fix-blank-install-onboarding (2026-08-02): `hasExisting` alone used to
    /// mean "done" on every path, so a Build that died on
    /// `persona_already_exists` dismissed the wizard as if it had succeeded.
    static func existingPersonaDisposition(buildFailed: Bool) -> ExistingPersonaDisposition {
        buildFailed ? .blockedNeedsReset : .alreadyOnboarded
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

    /// Runs the fresh-install scaffold repair and only then declares onboarding
    /// done. Reached from BOTH completion paths: submit-success and the
    /// payload-free pending-recovery resume.
    ///
    /// Fresh-install scaffold (2026-07-04, User: "it starts with a bunch of red
    /// warnings"): create the app-owned runtime JSON stores + bridge dirs now,
    /// so first launch lands clean.
    ///
    /// gpt-5.5 review BLOCKING 2 (2026-08-02): the repair result was DISCARDED,
    /// so a repair that threw — or that reported failing scaffold checks over a
    /// store it could not fix — still wrote the first-run welcome marker and
    /// showed "<Agent> is ready" over a broken install. A failed repair now
    /// blocks completion and names what failed. The persona documents really did
    /// commit at this point, so this is NOT `buildFailed` and must not offer
    /// reset (which would back out good identity docs over a scaffold problem);
    /// the actionable retry is the repair itself.
    private func finishSuccessfulOnboarding() async {
        let outcome = await appModel.runDoctor(repair: true)
        guard outcome.didRun, outcome.failingScaffoldChecks.isEmpty else {
            state.scaffoldRepairFailed = true
            // Reset would back out the identity docs that DID commit. Never
            // offer it for a scaffold problem.
            state.pendingRecoveryNeedsReset = false
            state.errorMessage = Self.scaffoldRepairFailureMessage(outcome)
            withAnimation { state.step = .error }
            return
        }
        state.scaffoldRepairFailed = false
        appModel.markFirstRunWelcomePending()
        withAnimation { state.step = .done }
    }

    /// Honest, actionable copy for a scaffold repair that did not succeed.
    /// Says what DID land (identity docs) so the user is not told their work was
    /// lost, names the failing check, and points at the one action that helps.
    static func scaffoldRepairFailureMessage(_ outcome: AppModel.DoctorRunOutcome) -> String {
        let detail = outcome.failureDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Your identity documents were written, but setting up the app's local files did not finish, so this install is not ready yet.",
            detail.isEmpty ? nil : detail,
            "Retry the repair, or open Diagnostics to fix it and continue."
        ].compactMap { $0 }.joined(separator: " ")
    }

}

// MARK: - Step Views

private struct IdentityAndAbilitiesStep: View {
    @Bindable var state: OnboardingWizardState

    private let columns = [
        GridItem(.flexible(), spacing: NativeAgentSpacing.sm),
        GridItem(.flexible(), spacing: NativeAgentSpacing.sm),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("What's your name, and what should the agent be called?")
                        .font(NativeAgentFont.display)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These names become the local starting identity documents. Private state starts blank on this Mac and can be changed later.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                }

                NativePanel {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your name")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.secondary)
                            TextField("Your name", text: $state.userName)
                                .font(NativeAgentFont.body)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Agent name")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.secondary)
                            TextField(state.namePlaceholder, text: $state.agentName)
                                .font(NativeAgentFont.body)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("What NativeAgent can help with")
                        .font(NativeAgentFont.section)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        ForEach(state.abilities) { ability in
                            AbilityOverviewTile(ability: ability)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct AbilityOverviewTile: View {
    let ability: OnboardingAbility

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: ability.systemImage ?? "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24, alignment: .leading)
            Text(ability.title)
                .font(NativeAgentFont.label)
                .fontWeight(.semibold)
                .lineLimit(2)
            Text(ability.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(NativeAgentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Provider connect step (G4-2, 2026-07-04)

/// Fresh-install blocker fix: onboarding used to jump from persona straight to
/// "ready to chat" with NO provider connected, so a stranger's first message
/// died. This step MIRRORS the working Providers tab surface (User,
/// 2026-07-04: "we dont have to have a preferred one, just show all the options
/// we have — you have the working app to go off of") — the SAME OAuth buttons,
/// setup-token input, and per-provider config sheet, so every provider (ChatGPT
/// OAuth, Anthropic OAuth/token, Grok OAuth, OpenAI/OpenRouter/Anthropic API
/// keys) is connectable here, none preferred. On first connect the chat surface
/// is pointed at whatever the user connected (the default active provider is
/// ChatGPT/Codex, which a fresh Mac can't use). Skippable.
private struct ProviderConnectStep: View {
    @Bindable var state: OnboardingWizardState
    @Environment(AppModel.self) private var appModel

    @State private var providers: [ProviderInfo] = []
    @State private var isLoading = false
    @State private var configureSheet: ProviderInfo? = nil

    /// Scroll target for the nav bar's "Connect a provider" action (sweep R4 C2).
    private static let signInAnchor = "onboarding-provider-signin"

    var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                .onChange(of: state.connectPromptTick) {
                    withAnimation { proxy.scrollTo(Self.signInAnchor, anchor: .top) }
                }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Connect a provider.")
                        .font(NativeAgentFont.display)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(agentDisplayName) needs a model to think with. Connect whichever service(s) you already use — sign in with OAuth, or paste an API key. No provider is required to be a particular one.")
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
                        // A2.2 close-out (2026-07-24): the codex-CLI caveat that
                        // lived here was stale — ChatGPT sign-in has been the
                        // codex-free native loopback flow since 2026-07-05
                        // (NativeOAuthFlow+Loopback). No dependency, no caveat.
                        OAuthSignInButton(provider: .chatgpt) { Task { await reload(connectedId: "openai_oauth_direct") } }
                        Divider()
                        OAuthSignInButton(provider: .anthropic) { Task { await reload(connectedId: "anthropic_oauth_direct") } }
                        AnthropicSetupTokenInput { Task { await reload(connectedId: "anthropic_oauth_direct") } }
                        Divider()
                        OAuthSignInButton(provider: .xai) { Task { await reload(connectedId: "xai_oauth_direct") } }
                    }
                }
                .id(Self.signInAnchor)

                // Full provider list — API keys (OpenAI, OpenRouter, Anthropic,
                // …) and per-provider config, reusing the SAME row + sheet as the
                // Providers tab panel.
                NativePanel {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        HStack {
                            Text("All providers")
                                .font(NativeAgentFont.section)
                            Spacer()
                            if isLoading { ProgressView().controlSize(.small) }
                        }
                        Text("Paste an API key for any provider — OpenAI, OpenRouter, Anthropic, xAI — or reconfigure one above.")
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(providers) { provider in
                            ProviderRowView(provider: provider) { configureSheet = provider }
                        }
                    }
                }

                if state.providerConnected {
                    Label("Connected: \(state.connectedProviderLabel ?? "provider"). You're ready to chat.", systemImage: "checkmark.seal.fill")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.green)
                } else {
                    Text("You can skip this and connect later in the Providers tab in the sidebar — but chat won't work until a provider is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(item: $configureSheet) { provider in
            ProviderConfigSheet(provider: provider) {
                let configuredId = provider.provider_id
                configureSheet = nil
                Task { await reload(connectedId: configuredId) }
            }
            .environment(appModel)
        }
        .task {
            await reload()
        }
    }

    private var agentDisplayName: String {
        let n = state.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Your agent" : n
    }

    /// Reload the provider list and reflect whether ANY provider is ready.
    /// `connectedId` is set ONLY when the user just connected a specific
    /// provider (an OAuth button, the setup-token, or a config-sheet save) —
    /// and ONLY then do we point the chat surface at it, so the first message
    /// uses what they connected (the default active provider is ChatGPT/Codex,
    /// unusable on a fresh Mac). The passive initial `.task` load passes nil so
    /// it NEVER repins an existing choice — critical on a persona RESET, where
    /// provider files + the active pin persist (gpt-5.5 review 2026-07-04).
    private func reload(connectedId: String? = nil) async {
        isLoading = true
        let list = (try? await appModel.listProviders()) ?? providers
        providers = list
        let ready = list.filter { $0.auth_status.state == "ready" }
        if let connectedId,
           let connected = ready.first(where: { $0.provider_id == connectedId }) {
            // Populate ALL surfaces with the just-connected provider (blank
            // slate at onboarding), not just chat — so the user doesn't have to
            // hand-switch ~15 surfaces off the stale codex/blank default.
            await appModel.adoptProviderForBlankSurfaces(connected.provider_id)
            state.connectedProviderLabel = connected.display_name
        } else if state.connectedProviderLabel == nil {
            state.connectedProviderLabel = ready.first?.display_name
        }
        state.providerConnected = !ready.isEmpty
        isLoading = false
    }
}

private struct ConfirmStep: View {
    let state: OnboardingWizardState

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            Text("Ready to build.")
                .font(NativeAgentFont.display)

            NativePanel {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    ConfirmRow(label: "Agent name", value: state.agentName)
                    ConfirmRow(label: "Your name", value: state.userName)
                    ConfirmRow(
                        label: "Provider",
                        value: state.providerConnected
                            ? (state.connectedProviderLabel ?? "Connected")
                            : "Not connected — connect later in Settings"
                    )
                }
            }

            Text("Tap Build to generate their SOUL, VOICE, and USER documents from the template.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

}

private struct ConfirmRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(NativeAgentFont.body)
                .fontWeight(.medium)
        }
    }
}

private struct BuildingStep: View {
    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Building your AI companion…")
                .font(NativeAgentFont.title)
            Text("Writing SOUL, VOICE, USER, and GROWTH documents.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct DoneStep: View {
    let state: OnboardingWizardState
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [NativeAgentBrand.accent.opacity(0.25), .clear],
                                       center: .center, startRadius: 5, endRadius: 70)
                    )
                    .frame(width: 130, height: 130)
                Image(systemName: "sparkles")
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            GradientText(
                text: "\(state.agentName) is ready.",
                colors: [NativeAgentBrand.accentDeep, NativeAgentBrand.accent, NativeAgentBrand.accentCool],
                font: .system(.largeTitle, design: .rounded, weight: .bold)
            )
            if state.providerConnected {
                Text("Say hello in Chat.")
                    .font(NativeAgentFont.title)
                    .foregroundStyle(.secondary)
            } else {
                Text("One more step: connect an AI provider in the Providers tab in the sidebar, then say hello in Chat.")
                    .font(NativeAgentFont.title)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Start") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }
}

private struct ErrorStep: View {
    let state: OnboardingWizardState
    let onRetry: () -> Void
    let onReset: (() -> Void)?

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong.")
                .font(NativeAgentFont.title)
            Text(state.errorMessage ?? "Unknown error.")
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { onRetry() }
                .buttonStyle(.borderedProminent)
            if let onReset {
                Button("Reset onboarding and start over", role: .destructive) { onReset() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Nav Bar

private struct OnboardingNavBar: View {
    @Bindable var state: OnboardingWizardState
    let onContinue: () -> Void

    var continueLabel: String {
        switch state.step {
        case .confirm: return "Build"
        case .identity: return "Continue"
        default: return "Continue"
        }
    }

    /// Sweep R4 C2: on the provider step with nothing connected, the big blue
    /// button used to read "Skip for now" — the app advertised skipping the one
    /// load-bearing step. Skipping is still allowed and unblocked (deliberate,
    /// User 2026-07-04) but it is now a plain tertiary link UNDER the prominent
    /// "Connect a provider" action, which scrolls the step back to the sign-in
    /// panel. Once connected, the prominent button is "Continue" as before.
    private var isUnconnectedProviderStep: Bool {
        state.step == .provider && !state.providerConnected
    }

    var body: some View {
        HStack {
            if state.step.rawValue > OnboardingWizardState.Step.identity.rawValue {
                Button("Back") {
                    withAnimation { state.goBack() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(NativeAgentFont.label)
            }

            Spacer()

            if isUnconnectedProviderStep {
                VStack(alignment: .trailing, spacing: NativeAgentSpacing.xs) {
                    Button("Connect a provider") {
                        state.connectPromptTick += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Skip for now") {
                        onContinue()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(NativeAgentFont.label)
                    .help("Finish setup without a provider — chat won't work until one is connected.")
                }
            } else {
                Button(continueLabel) {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!state.canContinue)
            }
        }
        .padding(.horizontal, NativeAgentSpacing.xl)
    }
}

// MARK: - Settings: Reset Persona

struct ResetPersonaView: View {
    @Environment(AppModel.self) private var appModel
    var onReset: (@MainActor () async -> Void)?
    @State private var showConfirmAlert = false
    @State private var isResetting = false
    @State private var resetResult: String?

    var body: some View {
        NativePanel(title: "Reset Persona", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                Text("Reset your AI's identity documents.")
                    .font(NativeAgentFont.body)
                Text("Existing documents are backed up before reset. This lets you run the onboarding wizard again.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                if let result = resetResult {
                    Text(result)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
                Button(isResetting ? "Resetting…" : "Reset Persona") {
                    showConfirmAlert = true
                }
                .buttonStyle(.bordered)
                .disabled(isResetting)
            }
        }
        .alert("Reset AI Persona?", isPresented: $showConfirmAlert) {
            Button("Reset", role: .destructive) {
                Task { await performReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your AI's identity documents will be backed up and cleared. The onboarding wizard will appear next launch.")
        }
    }

    private func performReset() async {
        isResetting = true
        resetResult = nil
        do {
            let resp = try await appModel.resetOnboarding(confirm: true)
            if resp.ok {
                resetResult = "Reset complete. \(resp.backedUp.count) doc(s) backed up."
                await onReset?()
            } else {
                resetResult = "Reset failed: \(resp.error ?? "unknown")."
            }
        } catch {
            resetResult = error.localizedDescription
        }
        isResetting = false
    }
}
