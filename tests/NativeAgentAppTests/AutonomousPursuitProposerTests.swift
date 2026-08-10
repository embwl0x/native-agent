import Foundation
import Testing
import PersistenceCore
import CognitiveSubstrate
@testable import NativeAgentApp

// Wave C2b — the AUTONOMOUS PURSUIT PROPOSAL path (M7 anti-laundering).
//
// The load-bearing guarantee: an autonomous proposal's REQUIRED non-friction
// citation must be a `standingView(id)` that the resolver confirms is `.active`.
// A view is `.active` ONLY after User's resolveStandingView(approved:true) — there
// is no autonomous activation anywhere — so an active standing view is evidence
// Agent cannot fabricate inside the same reflection turn that cites it. Every rule
// fails CLOSED: unresolvable / non-active / capped / duplicate → NO proposal.
//
// These tests exercise the PURE core (`AutonomousPursuitProposer.propose`) with a
// stub resolver, and assert the built Pursuit passes the store's OWN
// `validationError()` gate (the same gate openPursuit re-runs under the flock).

@Suite("AutonomousPursuitProposer")
struct AutonomousPursuitProposerTests {

    // A resolver backed by a fixed id → status map. nil for an unknown id (the
    // "view doesn't exist" case), exactly as the real substrate lookup returns.
    private func resolver(_ map: [String: CognitiveStandingView.Status]) -> (String) -> CognitiveStandingView.Status? {
        { map[$0] }
    }

    private func candidate(_ id: String, title: String = "Care shows up in the small maintenance work", body: String = "I keep finding that the unglamorous upkeep is where trust is actually built.") -> StandingViewCandidate {
        StandingViewCandidate(id: id, title: title, body: body)
    }

    // MARK: - Cap (rule a)

    @Test("refuses when open agent pursuits are already at the cap")
    func refusesAtOpenPursuitCap() {
        let id = "view-active"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: SwiftNativeDeskStore.maxOpenAgentPursuits, // == 2
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal == nil)
    }

    @Test("refuses when over the cap (defensive > check)")
    func refusesOverOpenPursuitCap() {
        let id = "view-active"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: SwiftNativeDeskStore.maxOpenAgentPursuits + 5,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal == nil)
    }

    // MARK: - Anti-laundering (rule b) — the cited view must resolve .active

    @Test("refuses when the cited standing view resolves .proposed")
    func refusesWhenCitedViewResolvesProposed() {
        let id = "view-proposed"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .proposed])
        )
        #expect(proposal == nil)
    }

    @Test("refuses when the cited standing view resolves .retired")
    func refusesWhenCitedViewResolvesRetired() {
        let id = "view-retired"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .retired])
        )
        #expect(proposal == nil)
    }

    @Test("refuses when the cited standing view resolves nil (does not exist)")
    func refusesWhenCitedViewResolvesNil() {
        let id = "view-unknown"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([:]) // empty map → nil for any id
        )
        #expect(proposal == nil)
    }

    // MARK: - Duplicate (rule c)

    @Test("refuses a duplicate — the active view already has an open pursuit")
    func refusesDuplicatePursuitForSameView() {
        let id = "view-active"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 1,
            standingViewIdsWithOpenPursuit: [id], // already cited
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal == nil)
    }

    // MARK: - Accept (rules b/c/d together) + valid Pursuit

    @Test("accepts a resolved-active, non-duplicate view and builds a store-valid Pursuit")
    func acceptsResolvedActiveViewWithValidDossier() {
        let id = "view-active"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .active])
        )
        guard let built = proposal else { Issue.record("expected a proposal"); return }

        // The load-bearing citation is the active standing view.
        #expect(built.citedStandingViewId == id)
        #expect(built.project == AutonomousPursuitProposer.project)
        #expect(!built.title.isEmpty)

        // The dossier's required non-friction citation is exactly standingView(id).
        #expect(built.pursuit.evidence.citations == [.standingView(id: id)])
        #expect(built.pursuit.evidence.citations.contains { !$0.isFriction })

        // The built Pursuit passes the STORE's OWN gate (what openPursuit re-runs).
        #expect(built.pursuit.validationError() == nil)
        #expect(built.pursuit.evidence.validationError() == nil)
        #expect(!built.pursuit.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!built.pursuit.doneLooksLike.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!built.pursuit.abandonCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("built Pursuit is admissible through PromotionDossier — friction alone would be refused")
    func builtDossierIsNotFrictionOnly() {
        let id = "view-active"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(id)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([id: .active])
        )
        guard let built = proposal else { Issue.record("expected a proposal"); return }
        // A friction-only dossier is unrepresentable for a pursuit — prove the
        // built one carries a non-friction (standing-view) load-bearing citation.
        let frictionOnly = PromotionDossier(citations: [.traceFriction(count: 3, window: "7d")])
        #expect(frictionOnly.validationError() != nil)
        #expect(built.pursuit.evidence.validationError() == nil)
    }

    // MARK: - At most one proposal

    @Test("proposes at most ONE pursuit even when several active views are eligible")
    func proposesAtMostOne() {
        let a = "view-a", b = "view-b", c = "view-c"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(a), candidate(b), candidate(c)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([a: .active, b: .active, c: .active])
        )
        // Exactly one, and it's the FIRST eligible candidate.
        #expect(proposal?.citedStandingViewId == a)
    }

    @Test("skips a non-active / duplicate first candidate but still proposes ONE from the next eligible")
    func skipsIneligibleThenProposesOne() {
        let dup = "view-dup", proposed = "view-proposed", ok = "view-ok"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate(dup), candidate(proposed), candidate(ok)],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [dup],
            resolveStatus: resolver([dup: .active, proposed: .proposed, ok: .active])
        )
        #expect(proposal?.citedStandingViewId == ok)
    }

    // MARK: - Structural guards

    @Test("refuses a candidate with an empty id")
    func refusesEmptyId() {
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [candidate("   ")],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: { _ in .active } // even if the resolver would say active
        )
        #expect(proposal == nil)
    }

    @Test("refuses when there are no candidates at all")
    func refusesNoCandidates() {
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [],
            openAgentPursuitCount: 0,
            standingViewIdsWithOpenPursuit: [],
            resolveStatus: resolver([:])
        )
        #expect(proposal == nil)
    }
}

// MARK: - Paraphrase rut guard (rule e, 2026-08-08)

@Suite("AutonomousPursuitProposer paraphrase guard")
struct PursuitParaphraseGuardTests {
    private func resolver(_ map: [String: CognitiveStandingView.Status]) -> (String) -> CognitiveStandingView.Status? {
        { map[$0] }
    }

    /// THE LIVE RUT: two User-approved standing views carrying the same thought
    /// reworded produced two open pursuits two days apart. The id dedup can't
    /// see it; the title-similarity gate must.
    @Test("refuses a proposal whose title paraphrases an open pursuit")
    func refusesParaphraseOfOpenPursuit() {
        let id = "view-quiet-system"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [StandingViewCandidate(
                id: id,
                title: "A quiet system is at rest until a second, verified read says otherwise",
                body: "A quiet system is at rest until a second, verified read says otherwise — absence of evidence needs its own check."
            )],
            openAgentPursuitCount: 1,
            standingViewIdsWithOpenPursuit: ["view-absence"],
            openPursuitTitles: ["Pursue: Absence is a system at rest until a second, verified read says otherwise"],
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal == nil,
                "the live paraphrase pair must be refused by the similarity gate")
    }

    /// Threshold calibration (gpt-5.5 review): surface-variant pursuits that
    /// share domain words but differ in the distinguishing token are DISTINCT
    /// and must pass — under-blocking is the chosen failure mode.
    @Test("surface-variant pursuits sharing domain words are not blocked")
    func surfaceVariantPasses() {
        let id = "view-slack-recall"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [StandingViewCandidate(
                id: id,
                title: "Improve memory recall for Slack conversations",
                body: "Slack threads deserve the same recall quality as Mac chat."
            )],
            openAgentPursuitCount: 1,
            standingViewIdsWithOpenPursuit: [],
            openPursuitTitles: ["Pursue: Improve memory recall for Telegram conversations"],
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal != nil,
                "Telegram-vs-Slack variants score ~0.67 and must clear the 0.7 threshold")
    }

    @Test("a genuinely different pursuit still passes the gate")
    func distinctTitlePasses() {
        let id = "view-small-maintenance"
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [StandingViewCandidate(
                id: id,
                title: "Care shows up in the small maintenance work",
                body: "The unglamorous upkeep is where trust is actually built."
            )],
            openAgentPursuitCount: 1,
            standingViewIdsWithOpenPursuit: ["view-absence"],
            openPursuitTitles: ["Pursue: Absence is a system at rest until a second, verified read says otherwise"],
            resolveStatus: resolver([id: .active])
        )
        #expect(proposal != nil, "distinct thoughts must not be blocked by the gate")
    }

    @Test("a later distinct candidate wins when the first is a paraphrase")
    func gateSkipsToNextCandidate() {
        let dup = StandingViewCandidate(
            id: "view-dup",
            title: "A quiet system is at rest until a second, verified read says otherwise",
            body: "same thought reworded"
        )
        let fresh = StandingViewCandidate(
            id: "view-fresh",
            title: "Care shows up in the small maintenance work",
            body: "The unglamorous upkeep is where trust is actually built."
        )
        let proposal = AutonomousPursuitProposer.propose(
            candidates: [dup, fresh],
            openAgentPursuitCount: 1,
            standingViewIdsWithOpenPursuit: [],
            openPursuitTitles: ["Pursue: Absence is a system at rest until a second, verified read says otherwise"],
            resolveStatus: resolver(["view-dup": .active, "view-fresh": .active])
        )
        #expect(proposal?.citedStandingViewId == "view-fresh",
                "the gate refuses the paraphrase but lets the next candidate through")
    }
}
