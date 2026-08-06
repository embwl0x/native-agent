// Wave 5b (de-mission phase 2) — the surface allowlists that used to open-code
// `case "workshop", "mission", "missions"` now route through
// `WorkshopSurfaceVocabulary.gateSpellings`.
//
// The contract is BEHAVIOR-IDENTICAL: every gate below still accepts all three
// spellings, so a turn that arrives on a 0.3.x `missions` (or the singular
// `mission`) surface keeps the same iteration budget, the same unattended
// deadline, and the same full-mac yolo eligibility it had before the refactor.
// Each test therefore pins the LEGACY spellings, not just the canonical one —
// a refactor that silently dropped `mission`/`missions` would compile fine and
// quietly demote those turns.

import Testing
import Foundation

@testable import ChatOrchestration
import NativeAgentCore

@Test("5b vocabulary: all three gate spellings resolve, unrelated surfaces do not")
func wave5GateSpellingsAreExhaustive() {
    for spelling in ["workshop", "missions", "mission"] {
        #expect(WorkshopSurfaceVocabulary.isWorkshopGateSurface(spelling))
        // Gates receive already-normalized surfaces, but the predicate must be
        // robust to the raw form too — it is called from a switch subject in
        // one file and from a Set membership in another.
        #expect(WorkshopSurfaceVocabulary.isWorkshopGateSurface("  \(spelling.uppercased()) "))
    }
    #expect(WorkshopSurfaceVocabulary.gateSpellings.first == "workshop")
    #expect(Set(WorkshopSurfaceVocabulary.gateSpellings) == ["workshop", "missions", "mission"])

    // Negative controls: neighbouring surfaces must NOT be folded in.
    for other in ["chat", "telegram", "background", "autonomy", "workshops", "", "missionary"] {
        #expect(!WorkshopSurfaceVocabulary.isWorkshopGateSurface(other))
    }
}

@Test("5b tool-loop budget: legacy missions/mission keep the 80-iteration budget")
func wave5ToolLoopBudgetAcceptsLegacySurfaces() {
    for spelling in ["workshop", "missions", "mission"] {
        #expect(ToolLoopBudget.defaultIterations(for: spelling) == 80)
        #expect(ToolLoopBudget.defaultIterations(for: spelling.uppercased()) == 80)
    }
    // The non-Workshop entries in the same switch are untouched.
    #expect(ToolLoopBudget.defaultIterations(for: "autonomy") == 80)
    #expect(ToolLoopBudget.defaultIterations(for: "background") == 80)
    #expect(ToolLoopBudget.defaultIterations(for: "telegram") == 180)
    #expect(ToolLoopBudget.defaultIterations(for: "ios") == 90)
    // Negative control: an unknown surface still falls to the 60 default. If a
    // widened predicate ever swallowed this, every surface would silently get
    // the unattended budget.
    #expect(ToolLoopBudget.defaultIterations(for: "somethingelse") == 60)
}

@Test("5b dispatch deadline: legacy missions/mission still count as unattended")
func wave5UnattendedSurfacesAcceptLegacySpellings() {
    for spelling in ["workshop", "missions", "mission"] {
        #expect(ToolDispatchDeadline.isUnattended(surface: spelling))
        #expect(ToolDispatchDeadline.isUnattended(surface: " \(spelling.capitalized) "))
    }
    for other in ["autonomy", "background", "swarm", "swarms", "worker", "workers", "training"] {
        #expect(ToolDispatchDeadline.isUnattended(surface: other))
    }
    // Negative controls: an attended surface must keep the interactive
    // deadline, otherwise a hung chat tool would wait 65 minutes.
    for attended in ["chat", "telegram", "ios", "", "unknown"] {
        #expect(!ToolDispatchDeadline.isUnattended(surface: attended))
    }
}
