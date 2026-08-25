import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.action.surfacePin
//
// The mounted Desk router resolves its real surface through the same provider
// registry used by model pins. A bad injected surface must refuse before it
// reads routing state or reaches a desk mutation implementation.

@Test("Desk surface pin is registered and an unknown router surface refuses before dispatch")
func deskSurfacePinIsRegistryBoundAtTheDispatchBoundary() async throws {
    let resolved = try DeskToolDispatchSurface.validated(DeskToolDispatchRouter.surface)
    #expect(resolved == "desk")
    #expect(MODEL_SURFACES.contains(resolved))

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("desk-surface-pin-\(UUID().uuidString)", isDirectory: true)
    let invalidRouter = DeskToolDispatchRouter(
        dataRoot: root,
        routingSurface: "desk_typo_not_a_surface"
    )
    do {
        _ = try await invalidRouter.run(
            tool: "desk_close",
            input: ["handle": .string("desk_missing")]
        )
        Issue.record("an unknown Desk routing surface reached dispatch")
    } catch {
        #expect(error is ProviderRoutingError)
    }
}
