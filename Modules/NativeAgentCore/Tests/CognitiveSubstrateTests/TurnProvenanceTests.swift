import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// COGNITION STEP 1 (APPRAISAL) · H3 — stop deleting ordinary prose from her felt
// state. 2026-08-02.
//
// Two defects, both measured:
//   1. `systemMarkers` was a list of bare nouns ("doctor", "reflection",
//      "observatory", "scheduler", "background loop") substring-matched against a
//      haystack that INCLUDES the user's own message. "remind me about the
//      doctor" classified User's turn `.system` — and a `.system` node is
//      excluded from mood (+Mood), the capsule (+Capsule) and attention
//      (+AttentionSignals), and is workspace-eligible only at half weight under
//      a system-item cap (+Workspace). Affect is the exception:
//      `.system.contributesToLivedState` is true, so felt chemistry still
//      moves. (Corrected 2026-08-02, gpt-5.5 review B2 — the old wording
//      claimed a blanket affect/workspace exclusion the code never had.) Her
//      felt life was being demoted by topic word.
//   2. The escape hatch was ONE-WAY: `CognitiveNode.turnKind` honoured an
//      explicit `.debug` but discarded an explicit `.live` whenever inference
//      disagreed — and since `CognitiveEvent.init` stamps the resolved kind into
//      metadata, that demotion re-fired on every node read.
//
// The fix classifies `.system` by PROVENANCE (the originator says so, or the
// event kind — machine-originated vs person-originated), never by the words in
// the turn, and honours an explicit classification in BOTH directions.
@Suite("TurnProvenance")
struct TurnProvenanceTests {

    private func userTurn(_ text: String, turnKind: CognitiveTurnKind? = nil) -> CognitiveEvent {
        CognitiveEvent(
            id: "turn:chat:user:s1:\(UUID().uuidString)",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:\(UUID().uuidString)"),
            sourceClass: .userStated,
            occurredAt: Date(timeIntervalSince1970: 1_000_000),
            summary: text,
            importance: 0.62,
            turnKind: turnKind,
            metadata: ["sessionId": .string("s1")]
        )
    }

    /// The exact sentences that were being deleted. Every one of these is User
    /// talking about his life or his app; none of them is a background loop.
    @Test func ordinaryProseAboutSystemTopicsStaysLive() {
        let deleted = [
            "remind me about the doctor",
            "can you book the doctor appointment for thursday",
            "what does the observatory show right now",
            "some reflection on how this month went would be nice",
            "add it to the scheduler for tomorrow morning",
            "the background loop thing you built is working well",
        ]
        for text in deleted {
            let event = userTurn(text)
            #expect(event.turnKind == .live, "\"\(text)\" is User typing, not machinery")
            #expect(event.turnKind.contributesToLivedState)
        }
    }

    /// The same words, read back off the NODE — the surface the felt layer,
    /// mood, capsule and attention all actually consult.
    @Test func ordinaryProseStaysLiveOnTheNodeToo() async throws {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64),
            dependencies: CognitiveSubstrateDependencies(now: { clock }, makeUUID: { UUID() })
        )
        await substrate.ingest(userTurn("remind me about the doctor on friday"))
        let nodes = await substrate.snapshot().nodes
        let node = try #require(nodes.first { $0.summary.contains("doctor") })
        #expect(node.turnKind == .live, "a topic word must not bar the turn from her felt layer")
    }

    /// Inference no longer produces `.system` from ANY content. Provenance is not
    /// recoverable from words, so the function stops pretending it is.
    @Test func inferenceNeverDerivesSystemFromContent() {
        let probes = [
            "observatory", "reflection", "background loop", "background_loop",
            "scheduler", "doctor", "the doctor said the scheduler needs a reflection",
        ]
        for probe in probes {
            #expect(CognitiveTurnKind.inferred(fromSignals: [probe]) == .live,
                    "\"\(probe)\" carries no provenance")
        }
    }

    /// Bridge provenance PREFIXES still classify — those are stamped onto the
    /// wire by the originating harness, not typed by a person.
    @Test func bridgeProvenanceMarkersStillClassify() {
        #expect(CognitiveTurnKind.inferred(fromSignals: ["[from: codex via bridge]"]) == .debug)
        #expect(CognitiveTurnKind.inferred(fromSignals: ["ctx-snapshot-verify"]) == .verification)
    }

    /// Provenance channel 1 — the originator states it. A background loop or the
    /// motor lane minting a turn says `.system` and is believed, even though the
    /// text is indistinguishable from ordinary prose.
    @Test func originatorStatedProvenanceIsHonoured() {
        let loopTurn = userTurn("remind me about the doctor", turnKind: .system)
        #expect(loopTurn.turnKind == .system)
    }

    /// Provenance channel 2 — the event KIND. Machine-originated kinds still
    /// default `.system`; person-originated kinds still default `.live`.
    @Test func eventKindRemainsAProvenanceChannel() {
        let tool = CognitiveEvent(
            id: "tool:1", kind: .toolSucceeded,
            subject: CognitiveSubjectReference(type: "tool", id: "grep"),
            sourceClass: .observed, occurredAt: Date(timeIntervalSince1970: 1_000_000),
            summary: "grep returned 4 matches")
        #expect(tool.turnKind == .system)

        let chat = userTurn("hey, how did the release go")
        #expect(chat.turnKind == .live)
    }

    /// The escape hatch is two-way. An explicit `.live` survives a node read even
    /// when the node's own words would have inferred something else — the same
    /// respect an explicit `.debug` already got.
    @Test func explicitClassificationIsHonouredInBothDirections() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func node(_ summary: String, explicit: CognitiveTurnKind) -> CognitiveNode {
            CognitiveNode(
                id: UUID(), kind: .conversationFocus,
                subjectReference: CognitiveSubjectReference(type: "chat_turn", id: "s1:m1"),
                activation: 0.8, salience: 0.8, confidence: 0.8, sourceClass: .userStated,
                createdAt: now, lastActivatedAt: now,
                decayHalfLife: 3_600, summary: summary,
                metadata: [CognitiveTurnKind.metadataKey: .string(explicit.rawValue)])
        }
        // Words that WOULD have inferred `.debug` — explicit `.live` must win.
        #expect(node("[from: codex via bridge] the fix landed", explicit: .live).turnKind == .live)
        // And the direction that already worked must keep working.
        #expect(node("an ordinary sentence", explicit: .debug).turnKind == .debug)
        #expect(node("an ordinary sentence", explicit: .system).turnKind == .system)
    }

    /// Non-live classes are untouched by all of the above: `.debug` and
    /// `.verification` still do not contribute to her lived state.
    @Test func nonLiveClassesStillDoNotContributeToLivedState() {
        #expect(CognitiveTurnKind.live.contributesToLivedState)
        #expect(CognitiveTurnKind.system.contributesToLivedState)
        #expect(CognitiveTurnKind.debug.contributesToLivedState == false)
        #expect(CognitiveTurnKind.verification.contributesToLivedState == false)
    }
}
