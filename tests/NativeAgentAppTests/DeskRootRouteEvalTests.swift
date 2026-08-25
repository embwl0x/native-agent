import Testing
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, ledger row `desk.route.root`.
// This follows the real command-route parser into the same root-reset token
// ContentView supplies to DeskHubView, then verifies a route cannot leave the
// mounted hub on Schedule or Research.

@Test("a Desk route always resets the mounted hub to its Desk root")
func deskRootRouteDoesNotRetainAPreviousSubpage() {
    let route = NativeAgentNavigationDestination.route("sidebar:desk")
    #expect(route == .sidebar(.desk))

    guard let route, case .sidebar(let destination) = route else {
        Issue.record("the Desk command route must produce a sidebar destination")
        return
    }
    let resetVersion = DeskRootRoutePresentation.nextRootRouteVersion(
        current: 41,
        destination: destination)
    #expect(resetVersion == 42)
    #expect(DeskRootRoutePresentation.mode(afterRootRequestFrom: .schedule) == .desk)
    #expect(DeskRootRoutePresentation.mode(afterRootRequestFrom: .research) == .desk)
    #expect(DeskRootRoutePresentation.nextRootRouteVersion(
        current: resetVersion,
        destination: .providers) == resetVersion)
}
