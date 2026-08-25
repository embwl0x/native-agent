import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `substrate.workspace.reasons` (fence core.substrate.field).
//
// Each provenance chip the Cognition Observatory renders is a bare string
// literal chosen inside one private helper. A branch that stops being taken
// does not error — the chip simply stops appearing and the Observatory shows
// thinner provenance forever. Three of the eight were unpinned anywhere:
// `high-confidence`, `correction-priority`, and the `turn-<kind>` family.
// (`task-pressure` is pinned in AnalyticProjectionTests, `spreading-activation`
// in CognitiveSubstrateTests, `mood-congruent` in MoodTests.)
//
// This is REACHABILITY plus CLOSURE, never ranking:
//   - each unpinned reason must be produced by some constructed scenario;
//   - each must be ABSENT from a scenario that should not earn it (otherwise a
//     reason that fires unconditionally would pass a reachability test);
//   - no snapshot may ever emit a reason outside the declared vocabulary.
@Suite("WorkspaceReasonVocabulary")
struct WorkspaceReasonVocabularyTests {

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                affectEnabled: true,
                maximumWorkspaceItems: 8
            )
        )
    }

    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        id: String,
        kind: CognitiveEventKind = .userMessageReceived,
        sourceClass: CognitiveSourceClass = .userStated,
        subjectID: String,
        summary: String,
        turnKind: CognitiveTurnKind? = nil,
        importance: Double = 0.6
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "topic", id: subjectID, label: subjectID),
            sourceClass: sourceClass,
            occurredAt: at,
            summary: summary,
            importance: importance,
            turnKind: turnKind
        )
    }

    /// Every reason string the helper can emit (CognitiveSubstrate+Workspace.swift:872).
    private static var declaredVocabulary: Set<String> {
        var out: Set<String> = [
            "activation", "salience", "high-confidence", "correction-priority",
            "task-pressure", "spreading-activation", "mood-congruent",
        ]
        for turnKind in CognitiveTurnKind.allCases { out.insert("turn-\(turnKind.rawValue)") }
        return out
    }

    @Test("`high-confidence` is reachable, and is not emitted for a low-confidence source")
    func highConfidenceIsReachableAndDiscriminating() async {
        let mind = substrate()
        // userStated seeds confidence 0.85 (>= the 0.8 gate).
        await mind.ingest(event(
            id: "confident", subjectID: "auction-house",
            summary: "The auction house scan finished."))
        // dreamed seeds 0.35 — the same shape, under the gate.
        await mind.ingest(event(
            id: "hazy", kind: .userMessageReceived, sourceClass: .dreamed, subjectID: "half-memory",
            summary: "Something about a half-remembered errand."))

        let items = await mind.workspaceSnapshot().items
        let confident = items.first { $0.node.subjectReference.id == "auction-house" }
        let hazy = items.first { $0.node.subjectReference.id == "half-memory" }
        #expect(confident?.reasons.contains("high-confidence") == true)
        #expect(hazy?.reasons.contains("high-confidence") == false)
        // The two always-on reasons are the floor of every item.
        #expect(confident?.reasons.prefix(2) == ["activation", "salience"])
    }

    @Test("`correction-priority` is reachable, and only for a correction")
    func correctionPriorityIsReachableAndDiscriminating() async {
        let mind = substrate()
        await mind.ingest(event(
            id: "correction", kind: .userCorrection, subjectID: "retail-tab",
            summary: "No — I meant the retail tab."))
        await mind.ingest(event(
            id: "plain", subjectID: "auction-tab",
            summary: "Scan the auction tab when you get a chance."))

        let items = await mind.workspaceSnapshot().items
        let correction = items.first { $0.node.kind == .correction }
        let plain = items.first { $0.node.subjectReference.id == "auction-tab" }
        #expect(correction?.reasons.contains("correction-priority") == true)
        #expect(plain?.reasons.contains("correction-priority") == false)
    }

    @Test("`turn-system` is reachable; a live turn is never labelled with its own kind")
    func turnKindReasonIsReachableForSystemOnly() async {
        let mind = substrate()
        await mind.ingest(event(
            id: "tool", kind: .toolSucceeded, sourceClass: .observed, subjectID: "screen-read",
            summary: "Read the frontmost window."))
        await mind.ingest(event(
            id: "live", subjectID: "auction-house",
            summary: "Check the auction house for me."))

        let items = await mind.workspaceSnapshot().items
        let system = items.first { $0.node.kind == .toolObservation }
        let live = items.first { $0.node.subjectReference.id == "auction-house" }
        #expect(system?.reasons.contains("turn-system") == true)
        // `turn-live` is deliberately never emitted — the label exists to mark
        // a NON-live item. If it ever appears, every live chip gained noise.
        #expect(live?.reasons.contains("turn-live") == false)
        #expect(items.allSatisfy { !$0.reasons.contains("turn-live") })
    }

    // MEASURED DEAD BRANCH, pinned so it cannot rot silently in either
    // direction. `workspaceEligible` (CognitiveSubstrate+Workspace.swift:760)
    // admits only `.live` and `.system`, so `turn-debug` and `turn-verification`
    // are structurally unreachable from any workspace snapshot even though the
    // reason helper can spell them. This asserts the eligibility contract:
    // debug/verification traffic must never reach the workspace at all.
    @Test("debug and verification traffic never reaches the workspace")
    func debugAndVerificationTurnsAreNeverInTheWorkspace() async {
        let mind = substrate()
        await mind.ingest(event(
            id: "debug", subjectID: "bridge", summary: "codex bridge probe",
            turnKind: .debug))
        await mind.ingest(event(
            id: "verification", subjectID: "snapshot", summary: "snapshot verify ping",
            turnKind: .verification))
        await mind.ingest(event(
            id: "live", subjectID: "auction-house", summary: "Check the auction house."))

        let items = await mind.workspaceSnapshot().items
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.reasons.contains("turn-debug") })
        #expect(items.allSatisfy { !$0.reasons.contains("turn-verification") })
        #expect(items.allSatisfy { $0.node.turnKind == .live || $0.node.turnKind == .system })
    }

    @Test("no snapshot emits a reason outside the declared vocabulary")
    func everyEmittedReasonIsDeclared() async {
        let mind = substrate()
        // A deliberately mixed field: correction, live turns, a tool observation,
        // a provider failure (task pressure), and a low-confidence source.
        await mind.ingest(event(
            id: "correction", kind: .userCorrection, subjectID: "retail-tab",
            summary: "No — I meant the retail tab.", importance: 0.9))
        for index in 0..<4 {
            await mind.ingest(event(
                id: "pressure-\(index)", subjectID: "deadline-\(index)",
                summary: "We need this right now, immediately — keep moving.", importance: 1))
        }
        await mind.ingest(event(
            id: "tool", kind: .toolSucceeded, sourceClass: .observed, subjectID: "screen-read",
            summary: "Read the frontmost window."))
        await mind.ingest(event(
            id: "hazy", sourceClass: .dreamed, subjectID: "half-memory",
            summary: "Something about a half-remembered errand."))

        let items = await mind.workspaceSnapshot().items
        #expect(!items.isEmpty)
        let emitted = Set(items.flatMap(\.reasons))
        #expect(emitted.subtracting(Self.declaredVocabulary).isEmpty,
                "undeclared workspace reason(s): \(emitted.subtracting(Self.declaredVocabulary).sorted())")
        // The scenario is rich enough that the discriminating reasons really fire —
        // otherwise the closure check above would pass on an empty vocabulary.
        #expect(emitted.contains("high-confidence"))
        #expect(emitted.contains("correction-priority"))
        #expect(emitted.contains("task-pressure"))
    }
}
