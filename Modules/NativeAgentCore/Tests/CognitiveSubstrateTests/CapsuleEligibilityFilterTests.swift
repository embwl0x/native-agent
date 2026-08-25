import Foundation
import Testing
@testable import CognitiveSubstrate

// Ledger row `capsule.filter.capsuleEligibleWorkspaceNode` (core.substrate.affect).
//
// This filter is the capsule's whole diet: every felt signal the fingerprint
// reads comes from `feltSignalsForCapsule(workspaceItems:)`, and this decides
// what lands in that array. Nothing called it directly before this suite (only
// a comment in AttentionSignalsTests referenced it).
//
// The dangerous direction is the FALSE POSITIVE: an over-eager
// `isCapsuleMetaOrOperationalTrace` needle — it matches free text, including
// the user's own words — silently starves the capsule, the fingerprint falls
// back to the affect-only path, and she still emits a confident word. There is
// no error path and no counter. So the bulk of this suite is ordinary live user
// turns that MUST survive.
@Suite("CapsuleEligibilityFilter")
struct CapsuleEligibilityFilterTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func substrate() -> CognitiveSubstrate {
        AffectFenceFixture.substrate(clock: AffectFenceClock(now))
    }

    /// The one thing that must always get through: a plain live user
    /// conversation focus.
    @Test func aPlainLiveUserFocusIsAdmitted() async {
        let s = substrate()
        let node = AffectFenceFixture.node(
            summary: "User and I are shaping the new capsule feature together",
            createdAt: now)
        #expect(await s.capsuleEligibleWorkspaceNode(node))
    }

    /// The false-positive direction — the one that starves the capsule without
    /// anyone noticing. Every one of these is an ordinary thing a person says,
    /// several of them deliberately NEAR-MISSES of the operational needles
    /// ("snapshot", "capsule", "context", "bridge", "inspector", "debug").
    @Test func ordinaryUserTurnsAreNeverRejectedAsOperationalTrace() async {
        let s = substrate()
        let ordinary = [
            "I'm worried the release slips again",
            "let's take a snapshot of where we are before we change anything",
            "the capsule idea is growing on me",
            "can you hold that context for a minute while I make coffee",
            "that bridge over the river was where we walked last summer",
            "I want an inspector to look at the roof before we buy",
            "this bug is driving me up the wall",
            "thank you for staying with me on this one",
            "the preview looked wrong to me, honestly",
            "how are you feeling about the direction we picked",
        ]
        var rejected: [String] = []
        for summary in ordinary {
            let node = AffectFenceFixture.node(summary: summary, createdAt: now)
            let admitted = await s.capsuleEligibleWorkspaceNode(node)
            if !admitted { rejected.append(summary) }
        }
        #expect(rejected.isEmpty, "the capsule's own filter starved it of: \(rejected)")
    }

    /// A `.correction` is a live user turn too — the sting she is supposed to
    /// feel. Losing it is a silent flattening of the fingerprint.
    @Test func aLiveCorrectionIsAdmitted() async {
        let s = substrate()
        let node = AffectFenceFixture.node(
            summary: "no, that approach was wrong and set us back",
            kind: .correction,
            valence: -0.6,
            createdAt: now)
        #expect(await s.capsuleEligibleWorkspaceNode(node))
    }

    /// The three independent rejections, each proven separately so a collapse of
    /// one is not hidden by another.
    @Test func theThreeRejectionsEachHoldOnTheirOwn() async {
        let s = substrate()

        // 1. non-live turn kind (explicitly classified, the way CognitiveEvent stamps it)
        let debugNode = AffectFenceFixture.node(
            summary: "User and I are shaping the new capsule feature together",
            metadata: ["turnKind": .string("debug")],
            createdAt: now)
        #expect(!(await s.capsuleEligibleWorkspaceNode(debugNode)),
                "a debug turn must never become felt experience")

        let verificationNode = AffectFenceFixture.node(
            summary: "User and I are shaping the new capsule feature together",
            metadata: ["turnKind": .string("verification")],
            createdAt: now)
        #expect(!(await s.capsuleEligibleWorkspaceNode(verificationNode)))

        // 2a. assistant-authored focus via role metadata
        let assistantByRole = AffectFenceFixture.node(
            summary: "I think we should land the smaller change first",
            metadata: ["role": .string("assistant")],
            createdAt: now)
        #expect(!(await s.capsuleEligibleWorkspaceNode(assistantByRole)),
                "her own turn must not be fed back as something she is holding")

        // 2b. assistant-authored focus via subject type
        let assistantBySubject = AffectFenceFixture.node(
            summary: "I think we should land the smaller change first",
            subjectType: "chat.assistant_turn",
            createdAt: now)
        #expect(!(await s.capsuleEligibleWorkspaceNode(assistantBySubject)))

        // 3. the string-signal operational filter
        let operational = AffectFenceFixture.node(
            summary: "[CognitiveSubstrate] inner-state capsule preview",
            createdAt: now)
        #expect(!(await s.capsuleEligibleWorkspaceNode(operational)),
                "her own plumbing must not read as a feeling")
    }

    /// Non-conversational node kinds are excluded by CLASS, not by text — a tool
    /// observation is machinery reporting in, never a felt moment.
    @Test func machineryKindsAreExcludedByClass() async {
        let s = substrate()
        let kinds: [CognitiveNodeKind] = [
            .toolObservation, .providerHealth, .workshopExecution, .appLifecycle, .feltResolution,
        ]
        var admitted: [CognitiveNodeKind] = []
        for kind in kinds {
            let node = AffectFenceFixture.node(
                summary: "the long build finally finished and it feels good",
                kind: kind,
                valence: 0.6,
                createdAt: now)
            if await s.capsuleEligibleWorkspaceNode(node) { admitted.append(kind) }
        }
        #expect(admitted.isEmpty, "machinery leaked into the felt capsule: \(admitted)")
    }
}
