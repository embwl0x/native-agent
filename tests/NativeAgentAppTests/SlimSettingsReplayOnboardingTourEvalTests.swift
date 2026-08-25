import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.replayOnboardingTour
@Suite("Settings onboarding tour replay", .serialized)
struct SlimSettingsReplayOnboardingTourEvalTests {
    @MainActor
    @Test("a Settings replay request reaches the main tour's first step exactly once")
    func replayRequestDeliversTheMountedTourStart() {
        let coordinator = OnboardingTourReplayCoordinator()

        let requestID = coordinator.requestReplay()
        #expect(coordinator.claim(requestID))
        #expect(!coordinator.claim(requestID))
        #expect(onboardingTourSteps.first?.title == "Chat")
        #expect(onboardingTourSteps.first?.id == 0)
    }

    @MainActor
    @Test("missing and stale requests do not reopen a completed tour")
    func replayDeliveryRejectsInvalidAndStaleEdges() {
        let coordinator = OnboardingTourReplayCoordinator()
        #expect(!coordinator.claim(0))
        #expect(!coordinator.claim(-1))

        let firstRequest = coordinator.requestReplay()
        let latestRequest = coordinator.requestReplay()
        #expect(!coordinator.claim(firstRequest))
        #expect(coordinator.claim(latestRequest))
        #expect(!coordinator.claim(latestRequest))

        #expect(coordinator.requestID == latestRequest)
    }
}
