import Foundation
import Testing
import Context

// Resident Desk pursuit stays out of unrelated conversational context while
// all active intent stays suppressed on the Workshop execution surface.

@Suite("WorkshopMindWiring")
struct WorkshopMindWiringTests {

    /// The M9 collision: on the Workshop surface ContextFlow reuses
    /// `activeTask` as the execution prewarm-cache id. Pursuit intent must be
    /// suppressed on that surface. Resident Desk pursuit is additionally
    /// suppressed on ordinary surfaces, while non-Desk cognitive intent can
    /// still participate in conversation relevance.
    ///
    /// P2-3 (2026-08-05): `missions` and `workshop` used to be two DISTINCT
    /// ContextSurfaces, so this predicate answered differently for two spellings
    /// of one surface — a caller writing `workshop` walked straight into the
    /// prewarm collision the suppression exists to avoid. Both spellings fold to
    /// the same surface now, so both suppress.
    @Test func pursuitIntentSuppressedOnWorkshopExecutionsSurfaceOnly() {
        func suppresses(_ surface: String, residentWorkIntent: Bool = false) -> Bool {
            ContextSurface(rawValue: surface) == .workshop || residentWorkIntent
        }
        // Mismatched pair: the 0.3.x spelling and the canonical one must both
        // resolve to the one Workshop surface.
        #expect(suppresses("missions") == true)
        #expect(suppresses("workshop") == true)
        #expect(suppresses("chat") == false)
        #expect(suppresses("telegram") == false)
        #expect(suppresses("bridge") == false)
        #expect(suppresses("chat", residentWorkIntent: true) == true)
        #expect(suppresses("telegram", residentWorkIntent: true) == true)
        #expect(suppresses("bridge", residentWorkIntent: true) == true)
    }
}
