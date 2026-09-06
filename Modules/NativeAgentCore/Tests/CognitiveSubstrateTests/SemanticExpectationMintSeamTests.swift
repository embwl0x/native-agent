import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 46, the appraisal owner's half (2026-09-01).
//
// The organism holds the semantic prediction lane but cannot see a standing view
// or run an appraisal. These pin the substrate side: what she expects is derived
// from her LIVED concerns (D-1 — concerns from User-approved ACTIVE standing
// views), and how it landed is the same `conversationalAppraisal` read U1 already
// uses to re-feel a completion. No LLM, no new store, no new sense.
//
// SEAM: the metadata still has to reach the somatic bus, which happens in
// `NativeCognitionRuntime.observe(_:)` — one line, outside this change's fence.
// Until it exists the lane is inert, which is how an unwired seam should fail.

@Suite("SemanticExpectationMintSeam")
struct SemanticExpectationMintSeamTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: false,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                maximumActiveNodes: 128
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { "User" }
            )
        )
    }

    private func seedActiveView(
        _ substrate: CognitiveSubstrate,
        title: String,
        body: String,
        at now: Date
    ) async {
        _ = await substrate.restoreStandingViews(from: [
            CognitiveStandingView(
                id: UUID(),
                title: title,
                body: body,
                status: .active,
                moodValenceAtFormation: 0.3,
                evidenceNodeIds: [UUID(), UUID()],
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-3_600),
                lineageId: "lineage-release-honesty"
            ).toJSON()
        ])
    }

    private func assistantTurn(summary: String, session: String, at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString,
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat_turn", id: UUID().uuidString),
            sourceClass: .selfReported,
            occurredAt: now,
            summary: summary,
            importance: 0.7,
            metadata: ["sessionId": .string(session), "surface": .string("mac")]
        )
    }

    private func userTurn(summary: String, session: String, at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: UUID().uuidString),
            sourceClass: .userStated,
            occurredAt: now,
            summary: summary,
            importance: 0.7,
            metadata: ["sessionId": .string(session), "surface": .string("mac")]
        )
    }

    // MARK: - Mint

    /// ORDERING CONTRACT (review fix 1): the runtime asks AFTER ingest, so every
    /// case here ingests first. Before ingest there is no completion slot and
    /// nothing to scope a mint to.
    @Test func aCompletionTouchingOneOfHerOwnViewsMintsAScopedExpectation() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)
        await seedActiveView(
            substrate,
            title: "Releases",
            body: "Shipping something unverified is worse than shipping nothing.",
            at: clock.now()
        )

        let turn = assistantTurn(
            summary: "I shipped it unverified because the check was slow.",
            session: "s1",
            at: clock.now()
        )
        await substrate.ingest(turn)
        let metadata = await substrate.semanticExpectationMetadata(for: turn)
        let name = try #require(OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.concernField,
            in: metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ))
        #expect(name.hasPrefix("view:"))
        // Review fix 2: scope rides with the mint, or the organism could only
        // resolve it by settling the whole ledger.
        let scope = try #require(OrganismSemanticExpectation.scope(
            in: metadata, key: OrganismSemanticExpectation.mintMetadataKey
        ))
        #expect(scope.sessionID == "s1")
        #expect(!scope.turnID.isEmpty)
    }

    @Test func aCompletionTouchingNoLivedConcernMintsNothing() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)
        await seedActiveView(
            substrate,
            title: "Releases",
            body: "Shipping something unverified is worse than shipping nothing.",
            at: clock.now()
        )

        let turn = assistantTurn(summary: "Sure, here you go.", session: "s1", at: clock.now())
        await substrate.ingest(turn)
        let metadata = await substrate.semanticExpectationMetadata(for: turn)
        #expect(metadata[OrganismSemanticExpectation.mintMetadataKey] == nil)
    }

    @Test func aFreshInstallWithNoViewsMintsNothingAtAll() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)

        let turn = assistantTurn(
            summary: "Shipping something unverified is worse than shipping nothing.",
            session: "s1",
            at: clock.now()
        )
        await substrate.ingest(turn)
        let metadata = await substrate.semanticExpectationMetadata(for: turn)
        // Zero active standing views degrades to nothing — byte-identical to the
        // behaviour before this lane existed.
        #expect(metadata.isEmpty)
    }

    // MARK: - Reaction

    /// Review fix 1, the HIGH one: production ingest CONSUMES `pendingCompletion`,
    /// and the runtime asks for metadata afterwards. Before the stash, this read
    /// came back empty every single time, so no reaction was ever stamped and
    /// every expectation expired instead of resolving. Ingest the reaction turn
    /// FIRST, exactly as production does, then ask.
    @Test func pushbackIsStillReadableAfterIngestHasConsumedTheCompletion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)
        // 2026-09-06: the seed was missing. A mint needs a LIVED concern, and
        // lived concerns come only from leaning standing views — which is what
        // `aFreshInstallWithNoViewsMintsNothingAtAll` two tests up pins. With
        // no view seeded the `#require` below could never hold, so this test
        // has been red since it was written (7df7a4cd, 2026-09-01) and no
        // commit moved it. The reaction contract it exists to pin — a verdict
        // still readable after ingest has consumed `pendingCompletion` — is
        // untouched; only its precondition was absent. The completion names
        // "unverified" for the same reason the mint test above does: concern
        // keywords match on substring, so "release" does not reach the view's
        // "releases" term and the completion has to touch a term the view
        // actually carries.
        await seedActiveView(
            substrate,
            title: "Releases",
            body: "Shipping something unverified is worse than shipping nothing.",
            at: clock.now()
        )

        let completion = assistantTurn(
            summary: "Shipped the release check unverified, as it stood.",
            session: "s1",
            at: clock.now()
        )
        await substrate.ingest(completion)
        let mintScope = try #require(OrganismSemanticExpectation.scope(
            in: await substrate.semanticExpectationMetadata(for: completion),
            key: OrganismSemanticExpectation.mintMetadataKey
        ))

        clock.advance(30)
        let reaction = userTurn(summary: "That's wrong, roll it back.", session: "s1", at: clock.now())
        await substrate.ingest(reaction)
        let metadata = await substrate.semanticExpectationMetadata(for: reaction)

        #expect(OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.reactionField,
            in: metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) == OrganismSemanticExpectation.pushbackReaction)
        // The verdict names the very turn it answers, so the organism settles
        // that row and no other.
        #expect(OrganismSemanticExpectation.scope(
            in: metadata, key: OrganismSemanticExpectation.reactionMetadataKey
        ) == mintScope)
    }

    /// One verdict per completion. A second ask must not re-resolve.
    @Test func theReactionStashIsSingleUse() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)

        await substrate.ingest(assistantTurn(
            summary: "Shipped the release check as it stood.", session: "s1", at: clock.now()
        ))
        clock.advance(30)
        let reaction = userTurn(summary: "That's wrong.", session: "s1", at: clock.now())
        await substrate.ingest(reaction)

        let first = await substrate.semanticExpectationMetadata(for: reaction)
        let second = await substrate.semanticExpectationMetadata(for: reaction)
        #expect(first[OrganismSemanticExpectation.reactionMetadataKey] != nil)
        #expect(second[OrganismSemanticExpectation.reactionMetadataKey] == nil)
    }

    @Test func aUserTurnWithNoOpenCompletionIsNotAVerdictOnAnything() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)

        let cold = userTurn(summary: "That's wrong, roll it back.", session: "s1", at: clock.now())
        await substrate.ingest(cold)
        let metadata = await substrate.semanticExpectationMetadata(for: cold)
        #expect(metadata[OrganismSemanticExpectation.reactionMetadataKey] == nil)
    }

    @Test func aUserTurnFromAnotherSessionCannotAnswerThisCompletion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)

        await substrate.ingest(assistantTurn(
            summary: "Shipped the release check as it stood.",
            session: "s1",
            at: clock.now()
        ))
        clock.advance(30)
        let elsewhere = userTurn(summary: "That's wrong.", session: "s2", at: clock.now())
        await substrate.ingest(elsewhere)
        let metadata = await substrate.semanticExpectationMetadata(for: elsewhere)
        #expect(metadata[OrganismSemanticExpectation.reactionMetadataKey] == nil)
    }

    @Test func pastTheCompletionWindowTheNextMessageIsANewBeginning() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_200_000))
        let substrate = makeSubstrate(clock)

        await substrate.ingest(assistantTurn(
            summary: "Shipped the release check as it stood.",
            session: "s1",
            at: clock.now()
        ))
        clock.advance(CognitiveSubstrate.pendingCompletionMaxAge + 60)
        let late = userTurn(summary: "That's wrong.", session: "s1", at: clock.now())
        await substrate.ingest(late)
        let metadata = await substrate.semanticExpectationMetadata(for: late)
        #expect(metadata[OrganismSemanticExpectation.reactionMetadataKey] == nil)
    }
}
