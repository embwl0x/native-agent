import Foundation
import MindCore
import DeskCore

// Blueprint: | `NativeAgentResidentRefresh.swift` | `NativeAgentEngine`; Defer mind/context reload until admitted turns settle |

public extension NativeAgentEngine {
    @MainActor
    func bindResidentPresentation(
        publishWorkStatus: @escaping @MainActor () async -> Void,
        policyChanged: @escaping @MainActor () -> Void,
        memoryProposalsChanged: @escaping @MainActor () -> Void
    ) {
        Task { [desk] in
            await EngineFaceProjection.watch(read: { desk.page.id }) { _ in
                await publishWorkStatus()
            }
        }
        turns.activityDidChange = {
            guard #available(macOS 27, *) else { return }
            Task { await publishWorkStatus() }
        }
        macIntegration.observePermissionChanges()
        trust.policyDidChange = { [macIntegration] in
            policyChanged()
            Task { await macIntegration.refresh() }
        }
        memory.proposalsDidChange = memoryProposalsChanged
    }

    var onboarding: SwiftNativeOnboardingClient {
        hasBody ? SwiftNativeOnboardingClient() : SwiftNativeOnboardingClient(
            personaRoot: PersonaRootResolver.resolveIsolated(dataRoot: dataRoot), dataRoot: dataRoot
        )
    }

    @MainActor
    func completeOnboarding(
        payload: OnboardingCompletePayload, resident: NativeAgentEngine
    ) async throws -> OnboardingCompleteResult {
        let result = try await onboarding.completeOnboarding(payload: payload)
        if result.ok { await resident.refreshResidentMindAfterOnboardingTransition() }
        return result
    }

    @MainActor
    func resumePendingOnboarding(resident: NativeAgentEngine) async throws -> OnboardingCompleteResult {
        let result = try await onboarding.resumePendingOnboarding()
        if result.ok { await resident.refreshResidentMindAfterOnboardingTransition() }
        return result
    }

    @MainActor
    func repairOnboardingProfile(
        payload: OnboardingCompletePayload,
        publishProfile: @escaping @MainActor @Sendable () async -> Void, resident: NativeAgentEngine
    ) async throws -> OnboardingCompleteResult {
        let response = try await onboarding.repairProfile(payload: payload)
        if response.ok {
            await refreshResidentMindAfterProfileRepair(
                publishProfile: publishProfile,
                refreshMind: { await resident.refreshResidentMindAfterOnboardingTransition() }
            )
        }
        return response
    }

    /// The reset runs through the mind's one serial owner: the running mind closes (everything its start attached is stopped and joined) before the
    /// identity it was made from is removed, and the owner's decision after it rechecks setup. A completed reset leaves no mind; one that did not
    /// complete leaves setup finished, and a new mind starts. Nothing else decides between the close and the removal.
    @MainActor
    func resetOnboarding(confirm: Bool, resident: NativeAgentEngine) async throws -> OnboardingResetResult {
        let onboarding = self.onboarding
        guard confirm else { return try await onboarding.resetOnboarding(confirm: false) }
        guard let mind = resident.mind else { return try await onboarding.resetOnboarding(confirm: true) }
        let result = try await mind.reset { try await onboarding.resetOnboarding(confirm: true) }
        await resident.contextFlow.reloadConfiguration()
        return result
    }

    /// Profile repair must not reload cognition during admitted turns; retain busy requests and recheck the live owner before publication.
    @MainActor
    func refreshResidentMindAfterProfileRepair(
        publishProfile: @escaping @MainActor @Sendable () async -> Void,
        refreshMind: @escaping @MainActor @Sendable () async -> Void
    ) async {
        await TurnAdmission.shared.refreshResidentWhenIdle(dataRoot: dataRoot) {
            await publishProfile()
            await refreshMind()
        }
    }

    /// The one hook every setup transition reaches: ContextFlow reloads, and the mind's owner decides whether a mind runs (`MindLifetime.reconcile`).
    @MainActor
    func refreshResidentMindAfterOnboardingTransition() async {
        async let contextFlow: Void = self.contextFlow.reloadConfiguration()
        async let mind: Void? = self.mind?.reconcile()
        _ = await (contextFlow, mind)
    }
}
