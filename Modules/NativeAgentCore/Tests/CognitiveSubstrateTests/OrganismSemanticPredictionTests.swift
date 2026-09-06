import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 46 acceptance (2026-09-01) — she predicts something other than plumbing.
//
// Measured defect: `OrganismPredictionKind` was five paths (provider, tool,
// phone, approval, workflow). Prediction error is real learning — satisfied and
// violated outcomes move confidence, vigilance, urgency and strategyCaution —
// but she never predicted an outcome or a person, so being wrong about the WORK
// taught nothing.
//
// These pin the semantic lane end to end at the ledger level: a HAND-MINTED
// expectation (exactly what the appraisal owner will stamp; see the mint seam in
// CognitiveSubstrate+AppraisalConcerns.swift) resolves at the next user turn and
// LEARNS, under the caps and the same violation machinery.

private let semanticOrgan = "chat.mac"

private func semanticSignal(
    _ kind: SomaticSignalKind,
    at date: Date,
    intensity: Double = 1,
    metadata: [String: JSONValue] = [:]
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(),
        kind: kind,
        sourceOrgan: semanticOrgan,
        occurredAt: date,
        intensity: intensity,
        metadata: metadata
    )
}

private let defaultScope = OrganismSemanticScope(sessionID: "s1", turnID: "chat_turn:t1")

private func mintSignal(
    label: String = "view:release-honesty",
    at date: Date,
    intensity: Double = 1,
    scope: OrganismSemanticScope = defaultScope
) -> SomaticSignal {
    semanticSignal(
        .assistantSpoke,
        at: date,
        intensity: intensity,
        metadata: [OrganismSemanticExpectation.mintMetadataKey: .object([
            OrganismSemanticExpectation.concernField: .string(label),
            OrganismSemanticExpectation.sessionField: .string(scope.sessionID),
            OrganismSemanticExpectation.turnField: .string(scope.turnID),
        ])]
    )
}

private func reactionSignal(
    _ reaction: String,
    at date: Date,
    scope: OrganismSemanticScope = defaultScope
) -> SomaticSignal {
    semanticSignal(
        .userSpoke,
        at: date,
        metadata: [OrganismSemanticExpectation.reactionMetadataKey: .object([
            OrganismSemanticExpectation.reactionField: .string(reaction),
            OrganismSemanticExpectation.sessionField: .string(scope.sessionID),
            OrganismSemanticExpectation.turnField: .string(scope.turnID),
        ])]
    )
}

private func apply(
    _ signal: SomaticSignal,
    _ ledger: OrganismPredictionLedger,
    _ chemistry: ChemicalState = .neutral
) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState, bodySchema: BodySchema) {
    OrganismPredictiveBody.applying(
        signal: signal,
        to: ledger,
        chemicalState: chemistry,
        bodySchema: .neutral
    )
}

private func semanticRows(_ ledger: OrganismPredictionLedger) -> [OrganismPrediction] {
    ledger.predictions.values
        .filter { $0.kind == .semanticExpectation }
        .sorted { $0.id < $1.id }
}

// MARK: - Mint

@Test func anAssistantTurnWithNoStampedExpectationMintsNothing() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let after = apply(semanticSignal(.assistantSpoke, at: t0), .empty)
    #expect(semanticRows(after.ledger).isEmpty)
    #expect(after.ledger == OrganismPredictionLedger.empty.withLastUpdated(t0))
}

@Test func aStampedExpectationOpensExactlyOnePendingSemanticRow() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let after = apply(mintSignal(at: t0), .empty)
    let rows = semanticRows(after.ledger)

    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.status == .pending)
    #expect(row.kind == .semanticExpectation)
    #expect(row.sourceOrgan == "chat-mac")
    #expect(row.semanticScope == defaultScope)
    // The backstop horizon is a day; the next user turn normally lands first.
    #expect(row.dueAt == t0.addingTimeInterval(OrganismSemanticExpectation.horizon))
    // No body path was touched — an expectation about how work lands is not
    // evidence about her hands.
    #expect(after.ledger.bodyConfidence == .neutral)
}

@Test func replayingTheSameCompletionCannotOpenTheRowTwice() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let once = apply(mintSignal(at: t0), .empty)
    let twice = apply(mintSignal(at: t0), once.ledger)
    #expect(semanticRows(twice.ledger).count == 1)
}

@Test func theCapIsPerSessionAndEvictsTheOldestNotTheNewest() throws {
    var ledger = OrganismPredictionLedger.empty
    let t0 = Date(timeIntervalSince1970: 800_000)
    for index in 0..<6 {
        ledger = apply(
            mintSignal(label: "view:concern-\(index)", at: t0.addingTimeInterval(Double(index))),
            ledger
        ).ledger
    }
    let pending = semanticRows(ledger).filter { $0.status == .pending }
    #expect(pending.count == OrganismSemanticExpectation.maximumPendingPerSession)
    // The newest expectation is the one the next turn is about; dropping IT
    // discarded the only row that could still resolve.
    #expect(pending.contains { $0.id.contains("view-concern-5") })
    #expect(!pending.contains { $0.id.contains("view-concern-0") })
}

@Test func aBusySessionCannotStarveAQuietOne() throws {
    var ledger = OrganismPredictionLedger.empty
    let t0 = Date(timeIntervalSince1970: 800_000)
    let quiet = OrganismSemanticScope(sessionID: "quiet", turnID: "chat_turn:q1")
    ledger = apply(mintSignal(label: "view:quiet", at: t0, scope: quiet), ledger).ledger
    for index in 0..<5 {
        ledger = apply(
            mintSignal(label: "view:busy-\(index)", at: t0.addingTimeInterval(Double(index) + 1)),
            ledger
        ).ledger
    }
    let pending = semanticRows(ledger).filter { $0.status == .pending }
    #expect(pending.filter { $0.semanticScope?.sessionID == "quiet" }.count == 1)
    #expect(pending.filter { $0.semanticScope?.sessionID == "s1" }.count == 3)
}

@Test func anUnscopedMintOpensNothing() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let unscoped = semanticSignal(
        .assistantSpoke,
        at: t0,
        metadata: [OrganismSemanticExpectation.mintMetadataKey: .object([
            OrganismSemanticExpectation.concernField: .string("view:release-honesty"),
        ])]
    )
    #expect(semanticRows(apply(unscoped, .empty).ledger).isEmpty)
}

// MARK: - Resolution at the next user turn

@Test func pushbackAtTheNextUserTurnViolatesAndTeaches() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    let resolved = apply(
        reactionSignal(OrganismSemanticExpectation.pushbackReaction, at: t0.addingTimeInterval(30)),
        minted.ledger,
        minted.chemicalState
    )

    let row = try #require(semanticRows(resolved.ledger).first)
    #expect(row.status == .violated)
    #expect(resolved.ledger.violatedCount == 1)
    #expect(resolved.ledger.lastViolationAt == t0.addingTimeInterval(30))

    // The SAME violation machinery the plumbing kinds feed.
    #expect(resolved.ledger.strategyCaution > minted.ledger.strategyCaution)
    #expect(resolved.chemicalState.vigilance > minted.chemicalState.vigilance)
    #expect(resolved.chemicalState.confidence < minted.chemicalState.confidence)
    // A person disagreeing is not a deadline.
    #expect(resolved.chemicalState.urgency == minted.chemicalState.urgency)

    // Cumulative per-kind evidence exists, so the learning survives eviction.
    let counts = try #require(resolved.ledger.outcomeCountsByKind?[
        OrganismPredictionKind.semanticExpectation.rawValue
    ])
    #expect(counts.violated == 1)
    #expect(counts.satisfied == 0)
}

@Test func confirmationAtTheNextUserTurnSatisfiesAndSettles() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    var start = OrganismPredictionLedger.empty
    start.strategyCaution = 0.4
    let minted = apply(mintSignal(at: t0), start, ChemicalState(vigilance: 0.4))
    let resolved = apply(
        reactionSignal(OrganismSemanticExpectation.confirmedReaction, at: t0.addingTimeInterval(45)),
        minted.ledger,
        minted.chemicalState
    )

    let row = try #require(semanticRows(resolved.ledger).first)
    #expect(row.status == .satisfied)
    #expect(resolved.ledger.satisfiedCount == 1)
    #expect(resolved.ledger.violatedCount == 0)
    #expect(resolved.ledger.strategyCaution < minted.ledger.strategyCaution)
    #expect(resolved.chemicalState.vigilance < minted.chemicalState.vigilance)

    let counts = try #require(resolved.ledger.outcomeCountsByKind?[
        OrganismPredictionKind.semanticExpectation.rawValue
    ])
    #expect(counts.satisfied == 1)
}

@Test func silenceIsNotPushbackButIsWeakerEvidenceThanAgreement() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    var start = OrganismPredictionLedger.empty
    start.strategyCaution = 0.5

    let neutral = apply(
        reactionSignal(OrganismSemanticExpectation.neutralReaction, at: t0.addingTimeInterval(30)),
        apply(mintSignal(at: t0), start).ledger
    )
    let confirmed = apply(
        reactionSignal(OrganismSemanticExpectation.confirmedReaction, at: t0.addingTimeInterval(30)),
        apply(mintSignal(at: t0), start).ledger
    )

    #expect(try #require(semanticRows(neutral.ledger).first).status == .satisfied)
    #expect(neutral.ledger.violatedCount == 0)
    // Moving on without objecting still counts, but counts for less.
    #expect(neutral.ledger.strategyCaution > confirmed.ledger.strategyCaution)
}

@Test func anUnrecognisedReactionCannotManufactureAViolation() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    let resolved = apply(reactionSignal("PUSH_BACK_typo", at: t0.addingTimeInterval(30)), minted.ledger)

    #expect(try #require(semanticRows(resolved.ledger).first).status == .satisfied)
    #expect(resolved.ledger.violatedCount == 0)
}

@Test func aTurnIsNeverTheReactionToItself() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    // Same instant: the user turn cannot be answering an expectation that was
    // opened at that same instant.
    let sameInstant = apply(
        reactionSignal(OrganismSemanticExpectation.pushbackReaction, at: t0),
        minted.ledger
    )
    #expect(try #require(semanticRows(sameInstant.ledger).first).status == .pending)
}

@Test func everyExpectationInThisTurnsScopeIsAnsweredTogether() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    var ledger = OrganismPredictionLedger.empty
    for index in 0..<3 {
        ledger = apply(
            mintSignal(label: "view:concern-\(index)", at: t0.addingTimeInterval(Double(index))),
            ledger
        ).ledger
    }
    let resolved = apply(
        reactionSignal(OrganismSemanticExpectation.pushbackReaction, at: t0.addingTimeInterval(60)),
        ledger
    )
    #expect(semanticRows(resolved.ledger).allSatisfy { $0.status == .violated })
    #expect(resolved.ledger.violatedCount == 3)
}

@Test func aReplyInAnotherConversationCannotResolveOrPunishThisOne() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    let elsewhere = apply(
        reactionSignal(
            OrganismSemanticExpectation.pushbackReaction,
            at: t0.addingTimeInterval(30),
            scope: OrganismSemanticScope(sessionID: "other", turnID: "chat_turn:z9")
        ),
        minted.ledger,
        minted.chemicalState
    )
    #expect(try #require(semanticRows(elsewhere.ledger).first).status == .pending)
    #expect(elsewhere.ledger.violatedCount == 0)
    #expect(elsewhere.chemicalState.vigilance == minted.chemicalState.vigilance)
}

@Test func aReplyAboutADifferentTurnOfTheSameSessionDoesNotResolveThisOne() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    let otherTurn = apply(
        reactionSignal(
            OrganismSemanticExpectation.pushbackReaction,
            at: t0.addingTimeInterval(30),
            scope: OrganismSemanticScope(sessionID: "s1", turnID: "chat_turn:t2")
        ),
        minted.ledger
    )
    #expect(try #require(semanticRows(otherTurn.ledger).first).status == .pending)
}

@Test func anUnscopedReactionResolvesNothing() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    let bare = semanticSignal(
        .userSpoke,
        at: t0.addingTimeInterval(30),
        metadata: [OrganismSemanticExpectation.reactionMetadataKey: .object([
            OrganismSemanticExpectation.reactionField: .string(
                OrganismSemanticExpectation.pushbackReaction
            ),
        ])]
    )
    #expect(try #require(semanticRows(apply(bare, minted.ledger).ledger).first).status == .pending)
}

// MARK: - Expiry backstop

@Test func anUnansweredExpectationExpiresAfterADay() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    let minted = apply(mintSignal(at: t0), .empty)
    // Any later signal runs the overdue sweep; a day and a minute later the
    // expectation is no longer about the turn that produced it.
    let swept = apply(
        semanticSignal(.appWake, at: t0.addingTimeInterval(OrganismSemanticExpectation.horizon + 60)),
        minted.ledger
    )
    #expect(try #require(semanticRows(swept.ledger).first).status == .expired)
    #expect(swept.ledger.expiredCount == 1)
}

// MARK: - The felt lane and the D-2 gate

@Test func aViolatedSemanticExpectationCanBecomeAFeltDisappointment() throws {
    let t0 = Date(timeIntervalSince1970: 800_000)
    var start = OrganismPredictionLedger.empty
    // Sit the path expectation well above even odds so the disappointment floor
    // is cleared: she counted on this landing.
    start.bodyConfidence = .neutral
    let minted = apply(mintSignal(at: t0, intensity: 1), start)
    let before = minted.ledger
    let after = apply(
        reactionSignal(OrganismSemanticExpectation.pushbackReaction, at: t0.addingTimeInterval(30)),
        before
    )
    let felt = OrganismResolutionFelt.events(
        before: before,
        after: after.ledger,
        at: t0.addingTimeInterval(30)
    )
    // The felt lane must be able to SEE this kind; whether this particular row
    // clears the magnitude floor is the floor's business, not the lane's.
    #expect(felt.stamped.lastResolutionFeltAt?.keys.allSatisfy {
        OrganismPredictionKind(rawValue: $0) != nil
    } != false)
    for event in felt.events where event.pathKind == .semanticExpectation {
        #expect(event.kind == .disappointment)
        // Provenance rides the felt event so D-2 can admit it (review fix 6).
        #expect(event.semanticScope == defaultScope)
    }
}

@Test func semanticResolutionsAreOnlyStakeBearingWithProvenance() throws {
    // Review fix 6: `subject.label` is just a string on an event. The semantic
    // kind must NOT sit in the unconditional allowlist, or anything wearing that
    // label walks past the aboutness gate — the denylist-shaped hole gate 1
    // exists to close, reopened under a new name.
    #expect(!CognitiveSubstrate.stakeBearingResolutionPathKinds.contains(
        OrganismPredictionKind.semanticExpectation.rawValue
    ))
    #expect(CognitiveSubstrate.conditionallyStakeBearingResolutionPathKinds.contains(
        OrganismPredictionKind.semanticExpectation.rawValue
    ))

    func feltEvent(metadata: [String: JSONValue]) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString,
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_path",
                id: "chat-mac#abcd1234",
                label: OrganismPredictionKind.semanticExpectation.rawValue
            ),
            sourceClass: .observed,
            occurredAt: Date(timeIntervalSince1970: 800_000),
            summary: "Disappointment — the thing I counted on fell through.",
            importance: 0.65,
            metadata: metadata
        )
    }
    #expect(CognitiveSubstrate.carriesSemanticResolutionProvenance(feltEvent(metadata: [
        OrganismSemanticExpectation.mintMetadataKey: .object([
            OrganismSemanticExpectation.sessionField: .string("s1"),
            OrganismSemanticExpectation.turnField: .string("chat_turn:t1"),
        ]),
    ])))
    // A forged label with no provenance, and a half-scoped one, both fail closed
    // and fall through to gate 2's aboutness test.
    #expect(!CognitiveSubstrate.carriesSemanticResolutionProvenance(feltEvent(metadata: [:])))
    #expect(!CognitiveSubstrate.carriesSemanticResolutionProvenance(feltEvent(metadata: [
        OrganismSemanticExpectation.mintMetadataKey: .object([
            OrganismSemanticExpectation.sessionField: .string("s1"),
        ]),
    ])))
}

// MARK: - Metadata contract

@Test func theSemanticMetadataKeysSurviveTheSomaticAdapter() throws {
    let event = CognitiveEvent(
        id: "turn-1",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat", id: "session-1", label: "turn"),
        sourceClass: .selfReported,
        occurredAt: Date(timeIntervalSince1970: 800_000),
        summary: "Shipped the release honesty fix.",
        metadata: [
            "surface": .string("mac"),
            OrganismSemanticExpectation.mintMetadataKey: .object([
                OrganismSemanticExpectation.concernField: .string("view:release-honesty"),
                OrganismSemanticExpectation.sessionField: .string("s1"),
                OrganismSemanticExpectation.turnField: .string("chat_turn:t1"),
            ]),
        ]
    )
    let signal = try #require(CognitiveSomaticSignalAdapter.signal(from: event, id: UUID()))
    #expect(signal.kind == .assistantSpoke)
    // Nested, so the scope survives the top-level metadata key cap intact.
    #expect(OrganismSemanticExpectation.scope(
        in: signal.metadata, key: OrganismSemanticExpectation.mintMetadataKey
    ) == defaultScope)
}

private extension OrganismPredictionLedger {
    func withLastUpdated(_ date: Date) -> OrganismPredictionLedger {
        var copy = self
        copy.lastUpdatedAt = date
        return copy
    }
}
