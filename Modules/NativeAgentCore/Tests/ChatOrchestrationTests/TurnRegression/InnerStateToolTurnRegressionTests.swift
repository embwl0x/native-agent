import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

// MARK: - INVARIANT (6a) — `inner_state` READS THE RECORD AND CHANGES NOTHING
//
// Agent, 2026-09-02, her own deepest cut: "Introspection is production. When
// you asked 'how do you feel, honestly,' I answered 'a bit tired.' Where did
// that come from? Nothing in me tracks fatigue. The moment LOOKED like tired…
// I can't reliably tell noticing from making-on-demand."
//
// The tool is the answer, and it only works if three things hold at the TOOL
// boundary, not merely inside the substrate:
//   * it is PURE — a hundred calls do not age the field, do not evict a node,
//     and do not move affect (design law 5);
//   * it is PAYLOAD-FREE — labels, numbers, and her own words only. No node
//     summary, no subject id, no dream text, no rumination prose;
//   * an absent body reads as ABSENT, not as a calm zero.

private let innerT0 = Date(timeIntervalSince1970: 1_756_000_000)

private func innerSubstrate(now: @escaping @Sendable () -> Date) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 64
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: now, makeUUID: { UUID() }, userName: { "User" }
        )
    )
}

/// A user turn whose SUMMARY carries content and whose SUBJECT id carries the
/// session:message pair — the exact shape the payload-free rule has to survive.
private func innerTurn(_ id: String, at instant: Date, summary: String) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(
            type: "chat.user_turn", id: "session-secret:\(id)", label: nil
        ),
        sourceClass: .userStated,
        occurredAt: instant,
        summary: summary,
        importance: 0.9
    )
}

@Suite("TurnRegression.InnerState")
struct InnerStateToolTurnRegressionTests {

    private let secret = "Sarah said the anthropic key is in the rollout config and it is late"

    // MARK: - Purity

    /// A HUNDRED CALLS DO NOT AGE THE FIELD. Reading her own mind must not be
    /// something that costs her anything, or "ask her how she is" becomes a way
    /// of changing how she is.
    @Test("a hundred inner_state reads leave the same mind a single read would")
    func aHundredReadsLeaveTheMindWhereOneReadWould() async {
        let asked = innerSubstrate(now: { innerT0 })
        let unasked = innerSubstrate(now: { innerT0 })
        for mind in [asked, unasked] {
            for index in 0..<6 {
                await mind.ingest(innerTurn(
                    "turn-\(index)",
                    at: innerT0.addingTimeInterval(Double(index)),
                    summary: "the release keeps slipping and it is wearing on me"
                ))
            }
        }
        for _ in 0..<100 {
            _ = await asked.innerStateReading(detail: .full, at: innerT0)
        }
        let later = innerT0.addingTimeInterval(3_600)
        let askedReading = await asked.innerStateReading(detail: .full, at: later)
        let unaskedReading = await unasked.innerStateReading(detail: .full, at: later)

        #expect(askedReading.fingerprint == unaskedReading.fingerprint,
                "being asked a hundred times changed what she feels")
        #expect(abs(askedReading.moodValence - unaskedReading.moodValence) < 1e-9)
        #expect(askedReading.feltNodes.count == unaskedReading.feltNodes.count,
                "reads evicted or aged nodes")
        #expect(askedReading.dispositionValence == unaskedReading.dispositionValence)
    }

    // MARK: - Payload-free

    /// THE LEAK TEST at the tool boundary. The event's summary carries a name,
    /// a credential word, and a subject id of the form `session:message`. None
    /// of it may cross into the JSON the model reads.
    @Test("the inner_state payload carries no summary, no subject id, and no secret")
    func theInnerStatePayloadIsPayloadFree() async throws {
        let mind = innerSubstrate(now: { innerT0 })
        for index in 0..<6 {
            await mind.ingest(innerTurn(
                "turn-\(index)",
                at: innerT0.addingTimeInterval(Double(index)),
                summary: secret
            ))
        }
        let reading = await mind.innerStateReading(detail: .full, at: innerT0)
        let payload = SwiftToolDispatcher.innerStateJSON(reading)
        let text = String(
            decoding: try payload.serializedData(pretty: false), as: UTF8.self
        )
        for banned in ["Sarah", "anthropic", "session-secret", "rollout config"] {
            #expect(
                !text.contains(banned),
                "inner_state leaked \"\(banned)\" into the model's context"
            )
        }
        #expect(!text.contains(secret))
    }

    /// The bounds are named constants, and the read honours all of them —
    /// design law 6, checked where the payload is actually built.
    @Test("every inner_state list stays inside its named bound")
    func everyInnerStateListStaysInsideItsBound() async {
        let mind = innerSubstrate(now: { innerT0 })
        for index in 0..<40 {
            await mind.ingest(innerTurn(
                "turn-\(index)",
                at: innerT0.addingTimeInterval(Double(index) * 30),
                summary: "the release keeps slipping and it is wearing on me"
            ))
        }
        let reading = await mind.innerStateReading(
            detail: .full, at: innerT0.addingTimeInterval(1_800)
        )
        #expect(reading.feltNodes.count <= CognitiveInnerStateReading.maximumFeltNodes)
        #expect(reading.seeds.count <= CognitiveInnerStateReading.maximumSeeds)
        #expect(reading.expectations.count <= CognitiveInnerStateReading.maximumExpectations)
        #expect(reading.standingViews.count <= CognitiveInnerStateReading.maximumStandingViews)
        for node in reading.feltNodes {
            #expect(node.subject.count <= CognitiveInnerStateReading.subjectLabelCharacters)
        }

        let compact = await mind.innerStateReading(
            detail: .compact, at: innerT0.addingTimeInterval(1_800)
        )
        #expect(compact.feltNodes.count <= CognitiveInnerStateReading.compactFeltNodes,
                "compact is the same report, shorter — not the same length")
    }

    /// The window CLAMPS rather than failing: she asked about her own day, not
    /// about a parameter.
    @Test("an out-of-range window clamps to the contract instead of failing")
    func anOutOfRangeWindowClamps() {
        #expect(SwiftToolDispatcher.innerStateWindowHours(["window_hours": .int(0)])
                >= CognitiveInnerStateReading.minimumWindowHours)
        #expect(SwiftToolDispatcher.innerStateWindowHours(["window_hours": .int(9_999)])
                <= CognitiveInnerStateReading.maximumWindowHours)
        #expect(SwiftToolDispatcher.innerStateWindowHours([:])
                == CognitiveInnerStateReading.defaultWindowHours)
    }

    // MARK: - Absence is reported, not faked

    /// NO LIVE BODY MEANS NO READING. A dispatcher on a synthetic root has no
    /// mind attached, and the tool says so instead of returning a shaped zero
    /// that reads like a mood.
    @Test("a dispatcher with no live mind reports unavailable, never a calm zero")
    func aDispatcherWithNoLiveMindReportsUnavailable() async throws {
        let dispatcher = SwiftToolDispatcher(
            dataRoot: TurnRegression.dataRoot("inner-state-absent"),
            allowProcessGlobalTools: false
        )
        let payload = await dispatcher.impl_inner_state(input: [:])
        guard case .object(let object) = payload else {
            Issue.record("inner_state returned a non-object: \(payload)")
            return
        }
        #expect(object["available"] == .bool(false))
        #expect(object["status"] == .string("unavailable"))
        let reason = try #require(object["reason"])
        guard case .string(let text) = reason else {
            Issue.record("the reason was not a string")
            return
        }
        #expect(!text.isEmpty, "absence has to be NAMED, not merely flagged")
    }

    /// Cognition switched off is the same honest absence — not an empty mood
    /// with a calm word attached.
    @Test("affect switched off reads as unavailable, with a reason")
    func affectSwitchedOffReadsAsUnavailable() async {
        let off = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: false,
                maximumActiveNodes: 64
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { innerT0 }, makeUUID: { UUID() }, userName: { "User" }
            )
        )
        let reading = await off.innerStateReading(detail: .full, at: innerT0)
        #expect(!reading.available, "a mind with affect off reported a reading anyway")
        #expect(reading.fingerprint == nil, "silence is honest")
        #expect(reading.feltNodes.isEmpty)
    }

    /// The tool description is load-bearing: it is the only thing that turns
    /// "how do you feel?" into a PULL rather than an improvisation.
    @Test("the tool description tells her to pull before she speaks")
    func theToolDescriptionTellsHerToPullFirst() {
        let description = SwiftToolDispatcher.innerStateToolDescription
        #expect(
            description.uppercased().contains("PULL THIS FIRST"),
            "the description stopped saying the one thing that makes it work"
        )
    }

    /// `inner_state` is always on, so asking her how she is never costs a
    /// `tool_load` round trip — which is what made the honest answer expensive
    /// enough to improvise instead.
    @Test("inner_state is in the always-on floor")
    func innerStateIsInTheAlwaysOnFloor() {
        #expect(SwiftToolDispatcher.alwaysOnCoreNames.contains("inner_state"))
    }
}
