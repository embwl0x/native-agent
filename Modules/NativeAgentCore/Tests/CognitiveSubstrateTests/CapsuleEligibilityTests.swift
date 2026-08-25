import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `workspace.capsuleEligibility` (fence core.substrate.field).
//
// `capsuleEligibleWorkspaceNode` is the LAST gate between the workspace and
// everything Agent actually says — five consumers read it (+Capsule.swift:40
// and :119, +FeltFingerprint.swift:337, +DeliveryEnvelope.swift:186). Before
// this suite, `grep -rn capsuleEligible Tests` returned a single COMMENT.
//
// Both failure directions are silent:
//   - too permissive → operational trace ("[CognitiveSubstrate] …", a context
//     snapshot, a rejected memory proposal) leaks into her own voice;
//   - too strict → the capsule quietly empties and she sounds contextless, with
//     no error anywhere.
//
// These assert the VERDICT per branch and the REACHABILITY of every marker
// string, not any ranking. The marker list is a hardcoded 14-entry vocabulary;
// a marker that stops matching (or a haystack field that stops being scanned)
// is otherwise completely invisible.
@Suite("CapsuleEligibility")
struct CapsuleEligibilityTests {

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(enabled: true, workspaceEnabled: true)
        )
    }

    /// `turnKind` is stamped EXPLICITLY on every node here so a test only ever
    /// fails for the reason it is about: an explicit classification wins over
    /// inference in both directions (CognitiveModels.swift H3), so marker text
    /// in a summary can never quietly re-route the node into `.debug` and pass
    /// the assertion for the wrong reason.
    private func node(
        kind: CognitiveNodeKind = .conversationFocus,
        turnKind: CognitiveTurnKind = .live,
        subjectType: String = "chat.user_turn",
        subjectID: String = "turn-1",
        subjectLabel: String? = nil,
        summary: String = "User asked about the auction house scraper.",
        metadata: [String: JSONValue] = [:]
    ) -> CognitiveNode {
        var merged = metadata
        merged[CognitiveTurnKind.metadataKey] = .string(turnKind.rawValue)
        return CognitiveNode(
            id: UUID(),
            kind: kind,
            subjectReference: CognitiveSubjectReference(type: subjectType, id: subjectID, label: subjectLabel),
            activation: 0.8,
            salience: 0.7,
            confidence: 0.85,
            sourceClass: .userStated,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            decayHalfLife: 3_600,
            summary: summary,
            metadata: merged
        )
    }

    /// The exact 14-marker vocabulary at CognitiveSubstrate+Workspace.swift:792.
    /// Kept here as the REACHABILITY contract: each one must still reject.
    static let capsuleMetaMarkers: [String] = [
        "[cognitivesubstrate]",
        "cognitive capsule:",
        "cognition_microcycle",
        "cognitive_microcycle",
        "context.snapshot",
        "ctx-snapshot",
        "turncontext",
        "capsule injection",
        "cognitive preview",
        "rejectmemoryproposal",
        "memoryproposal rejected",
        "ios rejectmemoryproposal",
        "subconscious context is provisional runtime state",
        "provisional runtime state to read",
    ]

    @Test("a live conversation turn and a live correction are the only admitted shapes")
    func liveConversationAndCorrectionAreEligible() async {
        let mind = substrate()
        #expect(await mind.capsuleEligibleWorkspaceNode(node(kind: .conversationFocus)) == true)
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(kind: .correction, summary: "No — I meant the retail tab, not the auction tab.")) == true)
    }

    @Test("every non-live turn kind is dropped")
    func nonLiveTurnKindsAreDropped() async {
        let mind = substrate()
        for turnKind in CognitiveTurnKind.allCases where turnKind != .live {
            #expect(
                await mind.capsuleEligibleWorkspaceNode(node(turnKind: turnKind)) == false,
                "turnKind \(turnKind.rawValue) must never reach the capsule"
            )
        }
    }

    @Test("assistant-authored focus is dropped by BOTH of its detectors")
    func assistantAuthoredFocusIsDropped() async {
        let mind = substrate()
        // Detector 1: an explicit role in metadata (case-insensitive).
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["role": .string("assistant")])) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["role": .string("ASSISTANT")])) == false)
        // Detector 2: the subject type alone (LIVE: all 17 chat.assistant_turn
        // nodes in the store carry no role key at all).
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(subjectType: "chat.assistant_turn")) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(subjectType: "  Chat.Assistant_Turn  ")) == false)
        // …and the control: a user role is NOT treated as assistant-authored.
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["role": .string("user")])) == true)
    }

    @Test("every non-conversation node kind is dropped, even when live")
    func nonConversationKindsAreDropped() async {
        let mind = substrate()
        let dropped: [CognitiveNodeKind] = [
            .toolObservation, .providerHealth, .workshopExecution, .appLifecycle, .feltResolution,
        ]
        for kind in dropped {
            #expect(
                await mind.capsuleEligibleWorkspaceNode(node(kind: kind)) == false,
                "\(kind.rawValue) must never reach the capsule"
            )
        }
        // Guard against the list silently going stale: exactly two kinds pass.
        let eligibleKinds = CognitiveNodeKind.allCases.filter { !dropped.contains($0) }
        #expect(Set(eligibleKinds) == Set([.conversationFocus, .correction]))
    }

    @Test("every capsule-meta marker still rejects, in the summary")
    func everyMarkerIsReachableFromTheSummary() async {
        let mind = substrate()
        for marker in Self.capsuleMetaMarkers {
            let victim = node(summary: "Preamble text \(marker) trailing text.")
            #expect(
                await mind.capsuleEligibleWorkspaceNode(victim) == false,
                "marker '\(marker)' no longer rejects — operational trace can reach her voice"
            )
            // Casing is normalized, not literal: the live producers are mixed-case.
            let upper = node(summary: "Preamble \(marker.uppercased()) trailing.")
            #expect(
                await mind.capsuleEligibleWorkspaceNode(upper) == false,
                "marker '\(marker)' is case-sensitive — real traces are mixed case"
            )
        }
    }

    @Test("the marker haystack really scans subject type, id, label and metadata values")
    func markerHaystackCoversEveryDeclaredField() async {
        let mind = substrate()
        let marker = "ctx-snapshot"
        #expect(await mind.capsuleEligibleWorkspaceNode(node(subjectType: marker)) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(node(subjectID: marker)) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(node(subjectLabel: marker)) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["origin": .string(marker)])) == false)
        // Nested values count too — a trace tucked inside a payload object is
        // exactly how this leaks in practice.
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["payload": .object(["note": .string("A \(marker) preview")])])) == false)
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["payload": .array([.string(marker)])])) == false)
        // Negative control: an unrelated string in the same slots is admitted,
        // so the assertions above are not passing for a structural reason.
        #expect(await mind.capsuleEligibleWorkspaceNode(
            node(metadata: ["origin": .string("auction-house")])) == true)
    }
}
