import Foundation
import Onboarding
import PersonaEngine


extension NativeClient {
    /// The onboarding writer must use the same explicit store root as the
    /// caller's personality reader. This is especially important for an
    /// injected app body: falling back to the process default here could make
    /// the starter panel create a persona somewhere other than the panel then
    /// reloads.
    private func onboardingClient() -> any OnboardingClient {
        guard let dataRootOverride else {
            return makeOnboardingClient()
        }
        return SwiftNativeOnboardingClient(
            personaRoot: PersonaRootResolver.resolveIsolated(dataRoot: dataRootOverride),
            dataRoot: dataRootOverride
        )
    }

    func startOnboarding() async throws -> OnboardingStartResponse {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = onboardingClient()
        let r = try await impl.startOnboarding()
        let options = r.personaTypeOptions.map {
            PersonaTypeOption(
                id: $0.id,
                label: $0.label,
                description: $0.description,
                sampleAnchor: $0.sampleAnchor,
                pronouns: $0.pronouns
            )
        }
        let overview = r.abilityOverview.map {
            OnboardingAbility(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
        return OnboardingStartResponse(
            ready: r.ready,
            hasExisting: r.hasExisting,
            currentPersonaName: r.currentPersonaName,
            personaTypeOptions: options,
            abilityOverview: overview,
            pendingRecovery: r.pendingRecovery,
            resetRequired: r.resetRequired,
            profileRepairRequired: r.profileRepairRequired
        )
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResponse {
        let r = try await onboardingClient().resumePendingOnboarding()
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingCompleteResponse(
            ok: r.ok,
            agentName: r.agentName,
            personaType: r.personaType,
            userName: r.userName,
            docsWritten: r.docsWritten,
            error: r.error,
            detail: r.detail
        )
    }

    /// Wave 20 (2026-06-01): SwiftNative-only.
    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResponse {
        let impl = onboardingClient()
        let r = try await impl.completeOnboarding(payload: OnboardingCompletePayload(
            agentName: agentName, personaType: personaType, userName: userName
        ))
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingCompleteResponse(
            ok: r.ok,
            agentName: r.agentName,
            personaType: r.personaType,
            userName: r.userName,
            docsWritten: r.docsWritten,
            error: r.error,
            detail: r.detail
        )
    }

    /// User, 2026-09-06: the repair lane for `profile_repair_required` — writes
    /// only memory/profile.json and leaves every persona document untouched.
    ///
    /// Unlike complete/reset, this one does NOT refresh the resident mind
    /// here. A repair happens on an install that has been running for months
    /// and may well have a turn in flight; the refresh stops and restarts
    /// Context Flow, so `AppModel.repairOnboardingProfile` owns its timing and
    /// holds it until the turn closes.
    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResponse {
        let impl = onboardingClient()
        let r = try await impl.repairProfile(payload: OnboardingCompletePayload(
            agentName: agentName, personaType: personaType, userName: userName
        ))
        return OnboardingCompleteResponse(
            ok: r.ok,
            agentName: r.agentName,
            personaType: r.personaType,
            userName: r.userName,
            docsWritten: r.docsWritten,
            error: r.error,
            detail: r.detail
        )
    }

    /// Wave 20 (2026-06-01): SwiftNative-only.
    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResponse {
        let impl = onboardingClient()
        let r = try await impl.resetOnboarding(confirm: confirm)
        if r.ok {
            await refreshResidentMindAfterOnboardingTransition()
        }
        return OnboardingResetResponse(
            ok: r.ok,
            backedUp: r.backedUp,
            readyForOnboarding: r.readyForOnboarding,
            error: r.error
        )
    }

    // SUBSYSTEM #17: retired Swift wrapper checkOnboardingNeeded — startOnboarding() remains live.

    func refreshResidentMindAfterOnboardingTransition() async {
        async let contextFlow: Void = NativeContextFlowRuntime.shared.reloadConfiguration()
        async let cognition = NativeCognitionRuntime.shared.refreshAfterOnboardingTransition()
        _ = await (contextFlow, cognition)
    }
}
