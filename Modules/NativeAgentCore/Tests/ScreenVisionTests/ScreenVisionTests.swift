// MARK: - ScreenVisionTests
//
// Permission-free unit tests. These deliberately do NOT call captureScreen()
// because that requires real Screen Recording authorization and would either
// hang on the TCC prompt or fail in CI / sandboxed environments. The capture
// path is exercised end-to-end at runtime by the chat composer button.

import Foundation
import Testing
@testable import ScreenVision

@Test
func permissionStatusReturnsValidString() async {
    let actor = SwiftNativeScreenVision()
    let status = actor.permissionStatus()
    #expect(["granted", "denied", "not_determined"].contains(status))
}

@Test
func errorDescriptionsAreNonEmpty() {
    let cases: [ScreenVisionError] = [
        .permissionDenied,
        .noDisplay,
        .captureFailed("synthetic-reason"),
    ]
    for err in cases {
        let desc = err.errorDescription
        #expect(desc != nil)
        #expect((desc?.isEmpty ?? true) == false)
    }
}

@Test
func captureFailedIncludesReason() {
    let err = ScreenVisionError.captureFailed("disk full")
    let desc = err.errorDescription ?? ""
    #expect(desc.contains("disk full"))
}

@Test
func permissionsHelperMatchesActor() async {
    // ScreenVisionPermissions.isAuthorized() and the actor's permissionStatus()
    // must agree on the boolean — both are reading the same CG preflight.
    let helperAuthorized = ScreenVisionPermissions.isAuthorized()
    let actor = SwiftNativeScreenVision()
    let actorAuthorized = (actor.permissionStatus() == "granted")
    #expect(helperAuthorized == actorAuthorized)
}
