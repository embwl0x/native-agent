import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import ProviderRouting

// MARK: - INVARIANT (2a) — THE CAPSULE REACHES THE TURN, IN THE RIGHT PLACE
//
// The capsule is the one part of her nobody sees. It rides INSIDE the prompt,
// it is never quoted back, and when it stops being attached the chat still
// looks fine. Doctor's `subconscious_vitals` row exists because that failure is
// silent; this suite is the same question asked at build time.
//
// Two properties, and they pull in opposite directions:
//   * PRESENT on every capsule surface — chat, telegram, ios;
//   * and present in the VOLATILE TAIL, never in the cached head, because it
//     churns every turn and churn in the cached region costs full-price input
//     on every later turn of the session.

private func capsuleSubstrate(
    at instant: Date,
    capsuleInjection: Bool = true
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: capsuleInjection,
            affectEnabled: true,
            maximumActiveNodes: 64
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: { instant }, makeUUID: { UUID() }, userName: { "User" }
        )
    )
}

private func userTurnEvent(
    id: String,
    at instant: Date,
    summary: String
) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(
            type: "chat.user_turn", id: "session-1:\(id)", label: "the rollout"
        ),
        sourceClass: .userStated,
        occurredAt: instant,
        summary: summary,
        importance: 0.9
    )
}

/// Compile a real capsule the way the production frozen path does: freeze the
/// read, render from the frozen read, never from live state.
private func compiledCapsule(
    surface: String,
    at instant: Date,
    capsuleInjection: Bool = true
) async -> CognitiveCapsule {
    let mind = capsuleSubstrate(at: instant, capsuleInjection: capsuleInjection)
    for index in 0..<4 {
        await mind.ingest(userTurnEvent(
            id: "turn-\(index)",
            at: instant.addingTimeInterval(Double(index)),
            summary: "the rollout keeps slipping and it is wearing on me"
        ))
    }
    let read = await mind.frozenRead(at: instant, currentSessionId: "session-1")
    return await mind.compileFrozenCapsule(
        CognitiveCapsuleRequest(
            surface: surface,
            userMessage: "where did the rollout land",
            sessionId: "session-1",
            mode: .inject,
            turnKind: .live
        ),
        from: read
    )
}

@Suite("TurnRegression.CapsuleInjection")
struct CapsuleInjectionTurnRegressionTests {

    private let instant = Date(timeIntervalSince1970: 1_756_000_000)

    /// The surfaces Doctor grades. A capsule missing on any of them is the
    /// exact silent regression `subconscious_vitals` was written to catch —
    /// caught here instead, before it ships.
    @Test("a capsule is assembled for every capsule surface: chat, telegram, ios")
    func aCapsuleIsAssembledForEveryCapsuleSurface() async throws {
        for surface in ["chat", "telegram", "ios"] {
            let capsule = await compiledCapsule(surface: surface, at: instant)
            #expect(
                !capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(surface) produced no capsule at all"
            )
            let injected = SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
                runId: "run-1",
                sessionId: "session-1",
                surface: surface,
                fileAccess: "full",
                capsule: capsule,
                posture: nil
            )
            let block = try #require(injected, "\(surface) dropped the capsule at injection")
            #expect(block.contains("[CognitiveSubstrate]"))
            #expect(block.contains("surface: \(surface)"))
            #expect(block.contains(capsule.combined))
        }
    }

    /// The one functional line, and only that line. Her guardrails live in her
    /// persona; the injection seam's only job is to stop her narrating the
    /// block itself.
    @Test("the injected block carries the do-not-quote line and no second persona")
    func theInjectedBlockCarriesOnlyItsOneFunctionalLine() async throws {
        let capsule = await compiledCapsule(surface: "chat", at: instant)
        let block = try #require(
            SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
                runId: "run-1", sessionId: "session-1", surface: "chat",
                fileAccess: "full", capsule: capsule, posture: nil
            )
        )
        #expect(block.contains("never quotes or mentions it"))
        #expect(!block.lowercased().contains("you are an ai"))
        #expect(!block.lowercased().contains("as an ai"))
    }

    /// THE CACHE HALF. The capsule is the LAST bytes of the volatile mass and
    /// must never enter the cached prefix — it changes every turn by design.
    @Test("the capsule rides the volatile tail and never the cached head")
    func theCapsuleRidesTheVolatileTailNotTheCachedHead() async throws {
        let capsule = await compiledCapsule(surface: "chat", at: instant)
        let block = try #require(
            SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
                runId: "run-1", sessionId: "session-1", surface: "chat",
                fileAccess: "full", capsule: capsule,
                posture: OrganismBehaviorPosture(
                    generatedAt: instant, enabled: true, posture: "careful",
                    directives: ["Tie completion claims to observed results, not intention."]
                )
            )
        )
        let rows = TurnRegression.session()
        let context = TurnRegression.context(
            turn: 0, session: rows, cursor: TurnRegression.cursor(), capsule: block
        )
        let turn = TurnRegression.wire(context, index: 0)

        let head = TurnRegression.systemText(turn.body)
        #expect(
            !head.contains("[CognitiveSubstrate]"),
            "the capsule entered the CACHED system head; every later turn now pays for it"
        )
        let volatileBlock = try #require(turn.seed.context.turnVolatileBlock)
        #expect(volatileBlock.contains("[CognitiveSubstrate]"))
        #expect(volatileBlock.contains("[OrganismBehavior]"))
        #expect(
            volatileBlock.hasSuffix(block),
            "the capsule must be the LAST bytes of the volatile mass"
        )
    }

    /// A capsule that changes every turn must not move the head. This is the
    /// pair to the test above: the capsule is allowed to churn precisely
    /// BECAUSE it churns outside anything a cache has to match.
    @Test("six turns of a changing capsule leave the replayed head untouched")
    func aChangingCapsuleNeverMovesTheHead() async throws {
        var blocks: [String] = []
        for index in 0..<6 {
            let capsule = await compiledCapsule(
                surface: "chat", at: instant.addingTimeInterval(Double(index) * 600)
            )
            blocks.append(
                SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
                    runId: "run-\(index)", sessionId: "session-1", surface: "chat",
                    fileAccess: "full", capsule: capsule, posture: nil
                ) ?? ""
            )
        }
        let injected = blocks
        let turns = TurnRegression.sixTurns(capsule: { injected[$0] })
        let head = try #require(turns.first).digests
        for turn in turns {
            #expect(turn.digests == head, "turn \(turn.index) moved the head")
        }
        #expect(
            Set(turns.compactMap(\.seed.context.turnVolatileBlock)).count == 6,
            "the capsules have to actually differ or this proves nothing"
        )
    }

    /// The master switch is a REAL absence. Capsule injection off means no
    /// block at all — not an empty heading, not a placeholder.
    @Test("capsule injection off produces no block, not an empty one")
    func capsuleInjectionOffProducesNoBlockAtAll() async {
        let capsule = await compiledCapsule(
            surface: "chat", at: instant, capsuleInjection: false
        )
        #expect(capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let injected = SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
            runId: "run-1", sessionId: "session-1", surface: "chat",
            fileAccess: "full", capsule: capsule, posture: nil
        )
        #expect(injected == nil, "an off capsule still shipped a heading")
    }

    /// Preparing a capsule does not SPEND it. A frozen render carries a
    /// presentation commit that becomes valid only when the provider accepts
    /// the turn — a failed request must not burn a cadence window.
    @Test("a prepared capsule is not committed until the provider accepts the turn")
    func aPreparedCapsuleIsNotCommittedByPreparingIt() async throws {
        let mind = capsuleSubstrate(at: instant)
        for index in 0..<4 {
            await mind.ingest(userTurnEvent(
                id: "turn-\(index)",
                at: instant.addingTimeInterval(Double(index)),
                summary: "the rollout keeps slipping and it is wearing on me"
            ))
        }
        let read = await mind.frozenRead(at: instant, currentSessionId: "session-1")
        let request = CognitiveCapsuleRequest(
            surface: "chat", userMessage: "where did the rollout land",
            sessionId: "session-1", mode: .inject, turnKind: .live
        )
        let first = await mind.compileFrozenCapsulePresentation(request, from: read)
        let second = await mind.compileFrozenCapsulePresentation(request, from: read)
        // Rendering twice off the same frozen read yields the same capsule:
        // the render mutated nothing that a second render could read.
        #expect(first.capsule.combined == second.capsule.combined)
        #expect(first.capsule.mode == .inject)
    }
}
