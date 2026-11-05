import Foundation
import Cognition
import ContextFlow
import Onboarding
import PersonaEngine
import ChatTurnRuntime

// Blueprint: | `NativeAgentResidentRefresh.swift` | `NativeAgentEngine`; Defer mind/context reload until admitted turns settle |

public extension NativeAgentEngine {
    @MainActor
    func bindResidentPresentation(
        publishWorkStatus: @escaping @MainActor () async -> Void,
        policyChanged: @escaping @MainActor () -> Void,
        memoryProposalsChanged: @escaping @MainActor () -> Void
    ) {
        approvals.recordsDidChange = {
            Task { await publishWorkStatus() }
        }
        inbox.itemsDidChange = {
            Task { await publishWorkStatus() }
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

    @MainActor
    func resetOnboarding(confirm: Bool, resident: NativeAgentEngine) async throws -> OnboardingResetResult {
        let result = try await onboarding.resetOnboarding(confirm: confirm)
        if result.ok { await resident.refreshResidentMindAfterOnboardingTransition() }
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

    @MainActor
    func refreshResidentMindAfterOnboardingTransition() async {
        async let contextFlow: Void = self.contextFlow.reloadConfiguration()
        async let cognition = self.cognition?.refreshAfterOnboardingTransition()
        _ = await (contextFlow, cognition)
    }
}
