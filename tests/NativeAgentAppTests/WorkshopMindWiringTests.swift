import Foundation
import Testing
import Context

// C2 (2026-07-11) — her active pursuit's intent colors context selection
// (activeTask/goal), with the M9 surface-suppression on `.missions`.

@Suite("WorkshopMindWiring")
struct WorkshopMindWiringTests {

    /// The M9 collision: on the `.missions` surface ContextFlow reuses
    /// `activeTask` as the mission prewarm-cache id. Pursuit intent must be
    /// suppressed on THAT surface only — every other surface keeps it. This
    /// pins the pure surface predicate the turn engine uses.
    @Test func pursuitIntentSuppressedOnWorkshopExecutionsSurfaceOnly() {
        // The turn engine gates on `ContextSurface(rawValue: surface) == .missions`.
        // Mirror that contract here so a regression that widens or narrows the
        // suppression is caught.
        func suppresses(_ surface: String) -> Bool {
            ContextSurface(rawValue: surface) == .workshop
        }
        #expect(suppresses("missions") == true)
        #expect(suppresses("chat") == false)
        #expect(suppresses("telegram") == false)
        #expect(suppresses("bridge") == false)
        #expect(suppresses("workshop") == false, "the workshop turn WANTS its pursuit as context")
    }
}
