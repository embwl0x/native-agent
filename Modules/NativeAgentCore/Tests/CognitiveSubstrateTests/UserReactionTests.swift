import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// U1 acceptance (2026-07-09): the user's REACTION becomes how her work FELT.
//
// A completion is stamped the instant it lands — before the only evidence that
// matters exists. These pin the retrospective correction: the completion's node
// is remembered in one slot, and the next user-authored turn re-stamps it
// THROUGH the asymmetric reconsolidation blend (praise lifts fast, criticism
// cools slowly) rather than overwriting it. Every add has a remove, and all of
// them are pinned here: consumed on use, dropped on session change, expired
// after 10 minutes, cleared with transient state.
@Suite("UserReaction")
struct UserReactionTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
    }

    /// Per-turn subjects, exactly as ChatOrchestration mints them (audit C2) — so a
    /// user turn and the completion it reacts to are DIFFERENT field nodes.
    private func completion(_ id: String, session: String = "u1", at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "chat:\(session):\(id)", kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "\(session):\(id)"),
            sourceClass: .selfReported, occurredAt: now,
            summary: "Rewrote the decoder and the suite is green.", importance: 0.55,
            metadata: ["sessionId": .string(session)])
    }

    private func userTurn(_ id: String, _ text: String, session: String = "u1", at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "chat:\(session):\(id)", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "\(session):\(id)"),
            sourceClass: .userStated, occurredAt: now,
            summary: text, importance: 0.65,
            metadata: ["sessionId": .string(session)])
    }

    /// The stored feeling on the completion's node.
    private func completionValence(
        _ s: CognitiveSubstrate, _ id: String, session: String = "u1"
    ) async throws -> Double {
        let node = try #require(
            await s.snapshot().nodes.first { $0.subjectReference.id == "\(session):\(id)" },
            "completion node \(id) should still be in the field")
        return node.emotionalValence
    }

    private let praise = "great work, that's exactly right"
    private let criticism = "You keep overengineering this, it's sloppy and not your best"
    private let neutral = "so what do you think about the weather today"

    // MARK: - the correction itself

    @Test func praiseAfterACompletionLiftsThatCompletionsStoredValence() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let before = try await completionValence(s, "m1")

        clock.advance(30)
        await s.ingest(userTurn("m2", praise, at: clock.now()))
        let after = try await completionValence(s, "m1")

        #expect(after > before, "praise should lift the completion: \(before) → \(after)")
    }

    @Test func criticismAfterACompletionDropsThatCompletionsStoredValence() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let before = try await completionValence(s, "m1")

        clock.advance(30)
        await s.ingest(userTurn("m2", criticism, at: clock.now()))
        let after = try await completionValence(s, "m1")

        #expect(after < before, "criticism should cool the completion: \(before) → \(after)")
    }

    /// The re-stamp goes THROUGH the asymmetric blend, it is not a raw overwrite:
    /// the node moves `blendRate × reaction` from where it was, warm-fast (0.5) on
    /// praise and cool-slow (0.15) on criticism. Pins the mechanism, not just the sign.
    @Test func reStampBlendsAsymmetricallyRatherThanOverwriting() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))

        let up = makeSubstrate(clock)
        await up.ingest(completion("m1", at: clock.now()))
        let upBefore = try await completionValence(up, "m1")
        clock.advance(30)
        await up.ingest(userTurn("m2", praise, at: clock.now()))
        let upAfter = try await completionValence(up, "m1")

        let clock2 = Clock(Date(timeIntervalSince1970: 1_000_000))
        let down = makeSubstrate(clock2)
        await down.ingest(completion("m1", at: clock2.now()))
        let downBefore = try await completionValence(down, "m1")
        clock2.advance(30)
        await down.ingest(userTurn("m2", criticism, at: clock2.now()))
        let downAfter = try await completionValence(down, "m1")

        let praiseValence = await up.conversationalAppraisal(in: praise).valence
        let criticismValence = await down.conversationalAppraisal(in: criticism).valence
        #expect(praiseValence > 0 && criticismValence < 0, "lexicon precondition")

        let expectedUp = ContinuityField.emotionBlendFastRate * praiseValence
        let expectedDown = ContinuityField.emotionBlendSlowRate * criticismValence
        #expect(abs((upAfter - upBefore) - expectedUp) < 1e-9,
                "praise must move \(expectedUp), moved \(upAfter - upBefore)")
        #expect(abs((downAfter - downBefore) - expectedDown) < 1e-9,
                "criticism must move \(expectedDown), moved \(downAfter - downBefore)")

        // Not an overwrite: the node never simply becomes the reaction value.
        #expect(abs(upAfter - praiseValence) > 1e-6 || abs(upBefore) < 1e-12)
    }

    /// Arousal and warmth are handed back unchanged, so their blends are exact no-ops:
    /// a reaction re-feels the turn's VALENCE only.
    @Test func reStampLeavesArousalAndWarmthUntouched() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(completion("m1", at: clock.now()))
        let before = try #require(await s.snapshot().nodes.first { $0.subjectReference.id == "u1:m1" })

        clock.advance(30)
        await s.ingest(userTurn("m2", praise, at: clock.now()))
        let after = try #require(await s.snapshot().nodes.first { $0.subjectReference.id == "u1:m1" })

        #expect(after.emotionalArousal == before.emotionalArousal)
        #expect(after.emotionalWarmth == before.emotionalWarmth)
    }

    // MARK: - neutral changes nothing

    @Test func neutralNextMessageLeavesTheCompletionUntouched() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let before = try await completionValence(s, "m1")

        clock.advance(30)
        await s.ingest(userTurn("m2", neutral, at: clock.now()))
        let after = try await completionValence(s, "m1")

        #expect(await s.conversationalAppraisal(in: neutral).valence == 0, "lexicon precondition")
        #expect(after == before, "a neutral reaction must not re-feel the turn: \(before) → \(after)")
    }

    // MARK: - every add has a remove

    /// Consumed on use: the slot answers ONE reaction. A second praise message finds
    /// nothing pending and cannot ratchet the same completion upward again.
    @Test func slotIsConsumedOnUseSoASecondMessageCannotReStamp() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        clock.advance(30)
        await s.ingest(userTurn("m2", praise, at: clock.now()))
        let afterFirst = try await completionValence(s, "m1")
        #expect(await s.pendingCompletion == nil, "the slot must be consumed on use")

        clock.advance(30)
        await s.ingest(userTurn("m3", praise, at: clock.now()))
        let afterSecond = try await completionValence(s, "m1")

        #expect(afterSecond == afterFirst, "a consumed slot must never re-stamp again")
    }

    /// A neutral reaction still CONSUMES the slot — it is a reaction, just a flat one.
    @Test func neutralReactionStillConsumesTheSlot() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(completion("m1", at: clock.now()))
        clock.advance(30)
        await s.ingest(userTurn("m2", neutral, at: clock.now()))
        #expect(await s.pendingCompletion == nil)
    }

    @Test func slotExpiresAfterTenMinutes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let before = try await completionValence(s, "m1")

        clock.advance(11 * 60)
        await s.ingest(userTurn("m2", praise, at: clock.now()))
        let after = try await completionValence(s, "m1")

        #expect(after == before, "an expired completion must not be re-felt: \(before) → \(after)")
        #expect(await s.pendingCompletion == nil, "the expired slot must be dropped")
    }

    /// Just inside the window still lands — proves the expiry test isn't passing for
    /// some unrelated reason.
    @Test func slotSurvivesJustInsideTheWindow() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let before = try await completionValence(s, "m1")

        clock.advance(9 * 60)
        await s.ingest(userTurn("m2", praise, at: clock.now()))
        #expect(try await completionValence(s, "m1") > before)
    }

    @Test func sessionSwitchClearsTheSlot() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", session: "sessionA", at: clock.now()))
        let before = try await completionValence(s, "m1", session: "sessionA")

        clock.advance(30)
        await s.ingest(userTurn("m2", praise, session: "sessionB", at: clock.now()))
        let after = try await completionValence(s, "m1", session: "sessionA")

        #expect(after == before, "a reaction in another session must not re-feel this turn")
        #expect(await s.pendingCompletion == nil, "the stale-session slot must be dropped")
    }

    @Test func clearTransientStateDropsTheSlot() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(completion("m1", at: clock.now()))
        #expect(await s.pendingCompletion != nil)
        await s.clearTransientState()
        #expect(await s.pendingCompletion == nil)
    }

    /// Only the LATEST completion is in the room: a second completion replaces the
    /// slot, so the reaction lands on the turn it actually answers.
    @Test func latestCompletionOwnsTheSlot() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        let firstBefore = try await completionValence(s, "m1")
        clock.advance(10)
        await s.ingest(completion("m2", at: clock.now()))
        let secondBefore = try await completionValence(s, "m2")

        clock.advance(10)
        await s.ingest(userTurn("m3", praise, at: clock.now()))

        #expect(try await completionValence(s, "m1") == firstBefore, "the superseded turn is untouched")
        #expect(try await completionValence(s, "m2") > secondBefore, "the latest turn is re-felt")
    }

    /// The slot only ever holds a completion — a user turn with no completion pending
    /// is a no-op, and a user turn never becomes the thing a later reaction re-stamps.
    @Test func userTurnWithNoPendingCompletionIsANoOp() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(userTurn("m1", praise, at: clock.now()))
        #expect(await s.pendingCompletion == nil)
    }

    /// A re-observed user turn (same messageId — the field dedups it) must be wholly
    /// inert. Without the accepted-as-new guard, the replayed praise below lands on
    /// completion m3, which that message never saw.
    @Test func replayedUserTurnCannotReFeelALaterCompletion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.ingest(completion("m1", at: clock.now()))
        clock.advance(30)
        let reaction = userTurn("m2", praise, at: clock.now())
        await s.ingest(reaction)                      // consumes m1's slot

        clock.advance(30)
        await s.ingest(completion("m3", at: clock.now()))
        let laterBefore = try await completionValence(s, "m3")

        clock.advance(30)
        await s.ingest(reaction)                      // duplicate: same event id

        #expect(try await completionValence(s, "m3") == laterBefore,
                "a replayed reaction must not re-feel a completion it never saw")
        #expect(await s.pendingCompletion != nil, "the duplicate must not consume m3's slot")
    }

    /// Defense in depth against a caller that mints PER-SESSION subjects (the shape
    /// audit C2 removed): both event kinds map to the `.conversationFocus` node kind,
    /// so the user turn would reactivate the very node the slot points at. The turn
    /// must not be treated as the reaction to itself and blended twice — the slot is
    /// consumed, and only the ordinary reactivation stamp lands.
    @Test func aTurnIsNeverTheReactionToItself() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let shared = CognitiveSubjectReference(type: "chat.session", id: "u1")

        await s.ingest(CognitiveEvent(
            id: "chat:u1:m1", kind: .assistantTurnCompleted, subject: shared,
            sourceClass: .selfReported, occurredAt: clock.now(),
            summary: "Rewrote the decoder.", importance: 0.55,
            metadata: ["sessionId": .string("u1")]))
        #expect(await s.pendingCompletion?.nodeKey != nil)

        clock.advance(30)
        await s.ingest(CognitiveEvent(
            id: "chat:u1:m2", kind: .userMessageReceived, subject: shared,
            sourceClass: .userStated, occurredAt: clock.now(),
            summary: praise, importance: 0.65,
            metadata: ["sessionId": .string("u1")]))

        // Consumed either way; the point is it did not double-blend the shared node.
        #expect(await s.pendingCompletion == nil)
        let node = try #require(await s.snapshot().nodes.first { $0.subjectReference.id == "u1" })
        #expect(node.emotionalValence <= 1 && node.emotionalValence >= -1, "tag stays welfare-bounded")
    }

    // MARK: - determinism

    @Test func reStampIsDeterministic() async throws {
        func run() async throws -> Double {
            let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
            let s = makeSubstrate(clock)
            await s.ingest(completion("m1", at: clock.now()))
            clock.advance(30)
            await s.ingest(userTurn("m2", criticism, at: clock.now()))
            clock.advance(30)
            await s.ingest(completion("m3", at: clock.now()))
            clock.advance(30)
            await s.ingest(userTurn("m4", praise, at: clock.now()))
            return try await completionValence(s, "m1") + completionValence(s, "m3")
        }
        let a = try await run()
        let b = try await run()
        #expect(a == b, "the same event stream must produce the same feelings: \(a) vs \(b)")
    }
}
