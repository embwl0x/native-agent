import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.intentRouter
@MainActor
@Suite("Capabilities intent router")
struct CapabilitiesIntentRouterEvalTests {
    private func plan(matches: [CapabilityRecord]) -> IntentRoutePlan {
        IntentRoutePlan(
            id: "route-eval",
            message: "route this",
            goalType: "research",
            recommendedSurface: "capabilities",
            risk: "low",
            requiresApproval: false,
            matchedCapabilities: matches,
            nextActions: ["Search first"]
        )
    }

    @Test("a completed zero-match route is distinct from a router failure")
    func completedNoMatchAndFailureHaveDifferentVisibleStates() async {
        let app = AppModel(startBackgroundTasks: false)
        let noMatchPlan = plan(matches: [])

        let completed = await app.routeIntent("research a niche topic", using: { _ in noMatchPlan })
        #expect(completed)
        #expect(app.routePlan == noMatchPlan)
        #expect(app.routePresentation == .plan(noMatchPlan))
        #expect(app.routePresentation.capabilityMatchState == .noMatches)

        let failed = await app.routeIntent("research a niche topic", using: { _ in
            throw NSError(domain: "IntentRouterEval", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "router transport unavailable",
            ])
        })
        #expect(!failed)
        #expect(app.routePlan == nil)
        guard case let .failed(message) = app.routePresentation else {
            Issue.record("router failure must replace the prior route presentation")
            return
        }
        #expect(message.contains("router transport unavailable"))
        #expect(app.routePresentation.capabilityMatchState == nil)
    }

    @Test("blank route input is visible invalid input, not an empty router result")
    func blankInputDoesNotPretendTheRouterFoundNothing() async {
        let app = AppModel(startBackgroundTasks: false)
        let invoked = await app.routeIntent("   ", using: { _ in
            Issue.record("blank input must not invoke the router")
            return plan(matches: [])
        })

        #expect(!invoked)
        #expect(app.routePlan == nil)
        #expect(app.routePresentation == .failed("Enter a task before planning a route."))
    }
}
