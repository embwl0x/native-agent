import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.onboardingTourOverlay

@MainActor
@Suite("macOS onboarding tour overlay", .serialized)
struct OnboardingTourOverlayEvalTests {
    @Test("tour state routes visible controls, presents the same step, and completes once")
    func tourStateDrivesTheRealOverlayCallbacks() {
        var tour = OnboardingTourState()

        #expect(tour.route == .chat)
        let first = OnboardingTourPresentation(state: tour)
        #expect(first.progressText == "Step 1 of \(onboardingTourSteps.count)")
        #expect(first.title == "Chat")
        #expect(first.sidebarItem == .chat)
        #expect(first.advanceLabel == "Continue")
        #expect(!first.backEnabled)
        #expect(tour.apply(.retreat) == .none,
                "Back must refuse an underflow from the first tour stop.")

        #expect(tour.apply(.advance) == .route(.activity))
        #expect(OnboardingTourPresentation(state: tour).progressText
            == "Step 2 of \(onboardingTourSteps.count)")
        #expect(OnboardingTourPresentation(state: tour).backEnabled)

        #expect(tour.apply(.select(stepID: 6)) == .route(.settings))
        #expect(OnboardingTourPresentation(state: tour).title == "Settings")
        #expect(tour.apply(.retreat) == .route(.providers))
        #expect(OnboardingTourPresentation(state: tour).title == "Providers")

        #expect(tour.apply(.skip) == .complete)
        #expect(tour.apply(.skip) == .none,
                "The completion effect is idempotent; ContentView owns hiding the persisted replay preference.")
    }
}
