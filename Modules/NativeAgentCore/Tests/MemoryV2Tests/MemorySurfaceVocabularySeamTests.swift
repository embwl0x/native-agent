import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MemoryV2

/// P2-3 at the memory-disclosure seam.
///
/// Rows already written to the live store list `missions` in their
/// `permittedSurfaces` metadata and are NEVER rewritten. Every case here pairs
/// a row minted in one vocabulary with a request minted in the other — the only
/// arrangement that can catch the two drifting apart. A same-spelling test
/// would keep passing while every Workshop recall silently returned nothing.
@Suite("Memory disclosure surface vocabulary")
struct MemorySurfaceVocabularySeamTests {

    private func record(permittedSurfaces: [String]) -> MemoryRecord {
        MemoryRecord(
            id: "seam",
            text: "A Workshop execution finished.",
            personaId: "ResidentAgent",
            lifecycle: MemoryLifecycle.confirmed,
            createdAt: "2026-07-14T00:00:00Z",
            updatedAt: "2026-07-14T00:00:00Z",
            status: "active",
            extras: .object([
                "permittedSurfaces": .array(permittedSurfaces.map { JSONValue.string($0) }),
            ])
        )
    }

    /// The live 0.3.x row: written with `missions`, read by code that now asks
    /// for `workshop`.
    @Test func legacyRowGrantsTheCanonicalSurface() {
        let decision = MemoryRecordDisclosurePolicy.classify(record(permittedSurfaces: ["missions"]))
        let d = decision
        #expect(d?.permits(surface: "workshop", personaID: "ResidentAgent") == true)
        #expect(d?.permits(surface: "missions", personaID: "ResidentAgent") == true)
        // Its stored set is canonicalized, so nothing downstream has to know
        // two spellings exist.
        #expect(d?.permittedSurfaces.contains("workshop") == true)
        // Unrelated surfaces still fail closed — the fold is not a widening.
        #expect(d?.permits(surface: "slack", personaID: "ResidentAgent") == false)
        #expect(d?.permits(surface: "chat", personaID: "ResidentAgent") == false)
    }

    /// The mirror case: a row written by the CURRENT runtime, asked for by a
    /// caller still on the old spelling.
    @Test func canonicalRowGrantsTheLegacySurface() {
        let decision = MemoryRecordDisclosurePolicy.classify(record(permittedSurfaces: ["workshop"]))
        let d = decision
        #expect(d?.permits(surface: "missions", personaID: "ResidentAgent") == true)
        #expect(d?.permits(surface: "workshop", personaID: "ResidentAgent") == true)
        #expect(d?.permits(surface: "telegram", personaID: "ResidentAgent") == false)
    }

    /// A row carrying both — which is exactly what the default
    /// `localPrivateSurfaces` writer emits — collapses to one entry, not two.
    @Test func rowListingBothSpellingsCollapsesToOneSurface() {
        let decision = MemoryRecordDisclosurePolicy
            .classify(record(permittedSurfaces: ["missions", "workshop"]))
        let d = decision
        #expect(d?.permittedSurfaces == ["workshop"])
        #expect(d?.permits(surface: "missions", personaID: "ResidentAgent") == true)
    }

    /// The allowlists are what execution-memory rows persist verbatim. Keeping
    /// BOTH spellings in them is what lets a 0.3.x build — whose fold runs the
    /// other direction (`workshop` -> `missions`) — still read rows this build
    /// writes. Dropping `missions` here is a one-way door.
    @Test func allowlistsCarryBothSpellingsForCrossVersionReaders() {
        #expect(MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains("missions"))
        #expect(MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains("workshop"))
        #expect(MemoryRecordDisclosurePolicy.allSurfaces.contains("missions"))
        #expect(MemoryRecordDisclosurePolicy.allSurfaces.contains("workshop"))
    }

    /// The bridge spellings share this seam; folding Workshop must not have
    /// disturbed them.
    @Test func bridgeSurfaceAliasesStillFold() {
        #expect(MemoryRecordDisclosurePolicy.canonicalSurface("claude-bridge") == "bridge")
        #expect(MemoryRecordDisclosurePolicy.canonicalSurface("codex_bridge") == "bridge")
        #expect(MemoryRecordDisclosurePolicy.canonicalSurface("missions") == "workshop")
        #expect(MemoryRecordDisclosurePolicy.canonicalSurface("workshop") == "workshop")
    }
}
