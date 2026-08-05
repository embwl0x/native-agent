import Foundation
import Testing
import Context

// C2 (2026-07-11) — her active pursuit's intent colors context selection
// (activeTask/goal), with the M9 surface-suppression on `.missions`.

@Suite("WorkshopMindWiring")
struct WorkshopMindWiringTests {

    /// The M9 collision: on the Workshop surface ContextFlow reuses
    /// `activeTask` as the execution prewarm-cache id. Pursuit intent must be
    /// suppressed on THAT surface only — every other surface keeps it. This
    /// pins the pure surface predicate the turn engine uses.
    ///
    /// P2-3 (2026-08-05): `missions` and `workshop` used to be two DISTINCT
    /// ContextSurfaces, so this predicate answered differently for two spellings
    /// of one surface — a caller writing `workshop` walked straight into the
    /// prewarm collision the suppression exists to avoid. Both spellings fold to
    /// the same surface now, so both suppress.
    @Test func pursuitIntentSuppressedOnWorkshopExecutionsSurfaceOnly() {
        // The turn engine gates on `ContextSurface(rawValue: surface) == .workshop`.
        // Mirror that contract here so a regression that widens or narrows the
        // suppression is caught.
        func suppresses(_ surface: String) -> Bool {
            ContextSurface(rawValue: surface) == .workshop
        }
        // Mismatched pair: the 0.3.x spelling and the canonical one must both
        // resolve to the one Workshop surface.
        #expect(suppresses("missions") == true)
        #expect(suppresses("workshop") == true)
        #expect(suppresses("chat") == false)
        #expect(suppresses("telegram") == false)
        #expect(suppresses("bridge") == false)
    }
}
