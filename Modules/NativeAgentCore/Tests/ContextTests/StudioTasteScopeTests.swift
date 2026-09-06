import Foundation
import Testing
@testable import Context

/// Desk 903 phase 5 — the eligibility half of "taste by recall pointer".
///
/// A studio pointer is reached BY THE WORK (title / creator / medium) or by the
/// turn being a taste judgment, and by nothing else. The agent's own kill line
/// for this feature: "if it shows up on ops turns I'll learn to ignore it, and
/// ignored is worse than absent." These pin that the gate is hard to trip.
@Suite("Studio pointer scope")
struct StudioTasteScopeTests {

    // MARK: - The scope gate

    @Test("a studio pointer is reached by its work, creator or medium")
    func studioPointerIsReachedByItsEndpoints() {
        let atom = pointer(title: "The Green Ray", creator: "Éric Rohmer", medium: "film")
        #expect(ContextCorrectionScope.applies(atom, message: "what did I make of The Green Ray?", recentTurns: []))
        #expect(ContextCorrectionScope.applies(atom, message: "anything by Éric Rohmer?", recentTurns: []))
        #expect(ContextCorrectionScope.applies(atom, message: "film, specifically", recentTurns: []))
    }

    @Test("an ops turn is outside scope — not merely low-ranked")
    func opsTurnsAreOutsideScope() {
        let atom = pointer(title: "The Green Ray", creator: "Éric Rohmer", medium: "film")
        for message in [
            "rerun the build and push the branch",
            "why did the migration fail",
            "review this diff before I merge",
            "does this look right?",
            "check the logs for the crash",
        ] {
            #expect(
                !ContextCorrectionScope.applies(atom, message: message, recentTurns: []),
                "\"\(message)\" must not pull a studio pointer"
            )
        }
    }

    @Test("a taste-judgment turn admits the pointer with the work unnamed")
    func tasteJudgmentTurnsAdmitUnnamedWorks() {
        let atom = pointer(title: "The Green Ray", creator: "Éric Rohmer", medium: "film")
        #expect(ContextCorrectionScope.applies(
            atom, message: "design review on the settings screen", recentTurns: []
        ))
        #expect(ContextCorrectionScope.applies(
            atom, message: "which of these two covers is better?", recentTurns: []
        ))
    }

    /// The fail-open rule the whole scope rests on: an atom that supplies no
    /// scoping entity stays global, so nothing that existed before this scope
    /// was introduced changes behaviour.
    @Test("an atom with no studio entities is unaffected")
    func atomsWithoutStudioEntitiesStayGlobal() {
        let plain = draft(kind: .evidence, body: "A dream fragment.", entities: [])
        #expect(ContextCorrectionScope.applies(plain, message: "rerun the build", recentTurns: []))
        let otherKind = draft(
            kind: .evidence,
            body: "A standing view.",
            entities: [ContextEntity(kind: "context_topic", id: "t", label: "Hermes")]
        )
        #expect(ContextCorrectionScope.applies(otherKind, message: "rerun the build", recentTurns: []))
    }

    // MARK: - The taste-judgment predicate

    @Test("a taste judgment needs both an ask and an aesthetic object")
    func tasteJudgmentNeedsBothSignals() {
        for message in [
            "design review",
            "can you do an art direction pass on this?",
            "which typeface is better here",
            "what do you think of this palette",
            "critique the layout",
            "is the composition better with the crop?",
        ] {
            #expect(
                ContextCorrectionScope.isTasteJudgmentTask(message),
                "\"\(message)\" is a taste judgment"
            )
        }
    }

    @Test("one signal alone is never a taste judgment")
    func oneSignalIsNeverEnough() {
        for message in [
            // Ask with no aesthetic object.
            "review this pull request",
            "which branch should I merge",
            "what do you think about the timeout",
            "critique my commit message",
            // Aesthetic object with no ask.
            "the design doc is in docs/",
            "set the color to red",
            "the film finished exporting",
            // Neither.
            "rerun the build",
            "",
        ] {
            #expect(
                !ContextCorrectionScope.isTasteJudgmentTask(message),
                "\"\(message)\" must not read as a taste judgment"
            )
        }
    }

    /// Word-boundary matched, so a bare substring never trips the gate.
    @Test("substrings do not count as tokens")
    func substringsDoNotCount() {
        #expect(!ContextCorrectionScope.isTasteJudgmentTask("restart the colorectal import job"))
        #expect(!ContextCorrectionScope.isTasteJudgmentTask("which module should I start with"))
    }

    // MARK: - Fixtures

    private func pointer(title: String, creator: String, medium: String) -> ContextAtomDraft {
        draft(
            kind: .evidence,
            body: "\(title) — \(creator) (\(medium)) · journal entry_x · stance formed",
            entities: [title, creator, medium].map {
                ContextEntity(
                    kind: ContextCorrectionScope.studioEntityKind,
                    id: $0.lowercased(),
                    label: $0
                )
            }
        )
    }

    private func draft(
        kind: ContextAtomKind,
        body: String,
        entities: [ContextEntity]
    ) -> ContextAtomDraft {
        let sourceID = ContextStableID.source(owner: "test.studio", locator: "studio/fixture")
        return ContextAtomDraft(
            id: ContextStableID.atom(
                sourceID: sourceID,
                kind: kind,
                headingPath: [],
                blockAnchor: body
            ),
            sourceID: sourceID,
            kind: kind,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "studio-fixture",
            body: body,
            authority: .inferred,
            confidence: 0.5,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 8_000)),
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities,
            triggers: [],
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
    }
}
