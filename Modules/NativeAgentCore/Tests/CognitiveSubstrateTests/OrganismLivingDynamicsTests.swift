import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

@Suite("Organism living dynamics")
struct OrganismLivingDynamicsTests {
    @Test func analyticDecayNeedsNoTickAndFindsExactThreshold() {
        let start = Date(timeIntervalSince1970: 10_000)
        let law = OrganismAnalyticDecay(valueAtAnchor: 1, halfLife: 60, anchoredAt: start)

        #expect(abs(law.value(at: start.addingTimeInterval(60)) - 0.5) < 0.000_000_1)
        #expect(abs(law.value(at: start.addingTimeInterval(120)) - 0.25) < 0.000_000_1)
        let crossing = law.crossingDate(for: 0.125, after: start)
        #expect(crossing == start.addingTimeInterval(180))
        #expect(law.crossingDate(for: 1.1, after: start) == nil)
    }

    @Test func residualRepairWaitsForQuietAndDoesNotReplaySameEvidence() async throws {
        let clock = LivingDynamicsClock(Date(timeIntervalSince1970: 20_000))
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(
                now: { clock.now() },
                makeUUID: { UUID(uuidString: "71000000-0000-0000-0000-000000000001")! }
            )
        )
        await kernel.ingest(livingSignal(.providerFailed, at: clock.now()))

        let immediate = await kernel.residualRepairOpportunity()
        #expect(immediate.localRepairPressure >= OrganismResidualRepair.minimumPressure)
        #expect(immediate.ready == false)
        #expect(immediate.nextRepairAt == clock.now().addingTimeInterval(OrganismResidualRepair.quietInterval))
        #expect(await kernel.runResidualRepairIfDue() == false)

        clock.advance(by: OrganismResidualRepair.quietInterval + 1)
        let due = await kernel.residualRepairOpportunity()
        #expect(due.ready)
        #expect(await kernel.runResidualRepairIfDue())
        let repaired = await kernel.snapshot()
        #expect(repaired.dreamRepairSummary.lastReason == "residual_pressure")
        #expect(repaired.dreamRepairSummary.lastOperationCount > 0)

        let settled = await kernel.residualRepairOpportunity()
        #expect(settled.nextRepairAt == nil)
        #expect(await kernel.runResidualRepairIfDue() == false)
    }

    @Test func capabilityBeliefsAreSmoothedFreshAndPayloadFree() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let success = OrganismPrediction(
            id: "provider-success",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now.addingTimeInterval(-60),
            dueAt: now,
            status: .satisfied,
            confidence: 0.8,
            uncertainty: 0.2,
            lastUpdatedAt: now.addingTimeInterval(-60)
        )
        let failure = OrganismPrediction(
            id: "provider-failure",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now.addingTimeInterval(-30),
            dueAt: now,
            status: .violated,
            confidence: 0.3,
            uncertainty: 0.8,
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
        let beliefs = OrganismCapabilitySelfModel.beliefs(
            ledger: OrganismPredictionLedger(predictions: [success.id: success, failure.id: failure]),
            at: now
        )
        let provider = try #require(beliefs.first { $0.kind == .providerCompletion })

        #expect(provider.evidenceCount == 2)
        #expect(provider.resolvedEvidenceCount == 2)
        #expect(provider.expiredEvidenceCount == 0)
        #expect(provider.successLikelihood == 0.5)
        #expect(provider.uncertainty > 0 && provider.uncertainty < 1)
        #expect(provider.freshness > 0.99)
        #expect(provider.lastEvidenceAt == failure.lastUpdatedAt)
    }

    @Test func expiredPredictionRaisesUncertaintyWithoutBecomingFailure() throws {
        let now = Date(timeIntervalSince1970: 45_000)
        let expired = OrganismPrediction(
            id: "provider-expired",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now.addingTimeInterval(-60),
            dueAt: now.addingTimeInterval(-30),
            status: .expired,
            confidence: 0.5,
            uncertainty: 0.8,
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
        let belief = try #require(OrganismCapabilitySelfModel.beliefs(
            ledger: OrganismPredictionLedger(predictions: [expired.id: expired]),
            at: now
        ).first { $0.kind == .providerCompletion })

        #expect(belief.successLikelihood == 0.5)
        #expect(belief.resolvedEvidenceCount == 0)
        #expect(belief.expiredEvidenceCount == 1)
        #expect(belief.uncertainty == 1)
    }

    @Test func predictionResidualWithoutRepairableFieldDoesNotArmADeadline() {
        let now = Date(timeIntervalSince1970: 30_000)
        let failed = OrganismPrediction(
            id: "provider-failure",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now.addingTimeInterval(-10),
            dueAt: now,
            status: .violated,
            confidence: 0.2,
            uncertainty: 0.9,
            lastUpdatedAt: now
        )
        let opportunity = OrganismResidualRepair.opportunity(
            ledger: OrganismPredictionLedger(predictions: [failed.id: failed]),
            field: .empty,
            repairState: .empty,
            lastSignalAt: now,
            at: now.addingTimeInterval(OrganismResidualRepair.quietInterval + 1)
        )

        #expect(opportunity.predictionResidual > 0)
        #expect(opportunity.nextRepairAt == nil)
        #expect(opportunity.ready == false)
    }

    @Test func delayedSignalCannotMoveQuietPhysiologyBackward() async {
        let start = Date(timeIntervalSince1970: 35_000)
        let clock = LivingDynamicsClock(start)
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
        await kernel.ingest(livingSignal(.providerFailed, at: start))
        clock.advance(by: 60)
        await kernel.ingest(livingSignal(.providerFailed, at: start.addingTimeInterval(-3_600)))

        let opportunity = await kernel.residualRepairOpportunity()
        #expect(opportunity.ready == false)
        #expect(opportunity.quietUntil == clock.now().addingTimeInterval(OrganismResidualRepair.quietInterval))
    }

    @Test func futureSourceTimestampCannotDeferQuietPhysiology() async {
        let start = Date(timeIntervalSince1970: 36_000)
        let clock = LivingDynamicsClock(start)
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
        await kernel.ingest(livingSignal(.providerFailed, at: start.addingTimeInterval(86_400)))

        let opportunity = await kernel.residualRepairOpportunity()
        #expect(opportunity.ready == false)
        #expect(opportunity.quietUntil == start.addingTimeInterval(OrganismResidualRepair.quietInterval))
    }

    @Test func delayedEventAfterRepairCreatesANewMutationWithoutReplayingOldTissue() async {
        let start = Date(timeIntervalSince1970: 37_000)
        let clock = LivingDynamicsClock(start)
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
        await kernel.ingest(livingSignal(.providerFailed, at: start))
        clock.advance(by: OrganismResidualRepair.quietInterval + 1)
        #expect(await kernel.runResidualRepairIfDue())
        #expect(await kernel.residualRepairOpportunity().nextRepairAt == nil)

        clock.advance(by: 10)
        await kernel.ingest(livingSignal(.providerFailed, at: start.addingTimeInterval(-3_600)))
        let next = await kernel.residualRepairOpportunity()
        #expect(!next.chargedNodeIDs.isEmpty || !next.noisyEdgeIDs.isEmpty)
        #expect(next.ready == false)
        #expect(next.nextRepairAt == clock.now().addingTimeInterval(OrganismResidualRepair.quietInterval))
    }

    @Test func boundedResidualPassesExhaustEveryTargetBeforeAcknowledgingGeneration() throws {
        var nodes: [String: OrganismNode] = [:]
        let start = Date(timeIntervalSince1970: 38_000)
        for index in 0..<6 {
            let id = "charged-\(index)"
            nodes[id] = OrganismNode(
                id: id,
                kind: .signal,
                label: id,
                activation: 1,
                charge: 1,
                lastActivatedAt: start
            )
        }
        var field = OrganismField(
            nodes: nodes,
            lastUpdatedAt: start,
            mutationGeneration: 7
        )
        var state = OrganismDreamRepairState.empty
        var operatedTargets = Set<String>()
        var now = start.addingTimeInterval(OrganismResidualRepair.quietInterval + 1)

        for _ in 0..<24 {
            let opportunity = OrganismResidualRepair.opportunity(
                ledger: .empty,
                field: field,
                repairState: state,
                lastSignalAt: start,
                at: now
            )
            guard opportunity.nextRepairAt != nil else { break }
            #expect(opportunity.ready)
            let result = OrganismDreamRepair.applyingResidualPressure(
                opportunity,
                at: now,
                to: field,
                state: state,
                limits: OrganismDreamRepairLimits(maximumOperations: 2)
            )
            field = result.field
            state = result.state
            operatedTargets.formUnion(state.lastReceipt?.operations.map(\.targetID) ?? [])
            now = now.addingTimeInterval(OrganismResidualRepair.quietInterval + 1)
        }

        #expect(operatedTargets == Set(nodes.keys))
        #expect(field.nodes.values.allSatisfy { $0.charge < 0.12 })
        #expect(state.lastReceipt?.sourceFieldGeneration == field.mutationGeneration)
        let settled = OrganismResidualRepair.opportunity(
            ledger: .empty,
            field: field,
            repairState: state,
            lastSignalAt: start,
            at: now
        )
        #expect(settled.nextRepairAt == nil)
    }

    @Test func legacyFieldDecodeStartsAtGenerationZero() throws {
        let legacy = Data(#"{"nodes":{},"edges":{},"lastUpdatedAt":null}"#.utf8)
        let field = try JSONDecoder().decode(OrganismField.self, from: legacy)
        #expect(field.mutationGeneration == 0)
        let roundTrip = try JSONDecoder().decode(OrganismField.self, from: JSONEncoder().encode(field))
        #expect(roundTrip == field)
    }

    @Test func reviewedReflexEvidenceDoesNotClaimProcedureCompilation() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        var state = OrganismReflexState.empty
        for offset in 0..<8 {
            state = OrganismReflexCompiler.applying(
                signal: livingSignal(
                    .toolSucceeded,
                    source: "tool.search",
                    at: now.addingTimeInterval(Double(offset))
                ),
                to: state
            )
        }
        state = state.reviewedCandidate(
            id: "tool:tool-search",
            decision: .approve,
            reviewedAt: now.addingTimeInterval(20),
            reviewedBy: "operator"
        )
        let reviewed = try #require(state.reviewCandidates().first)
        #expect(reviewed.approvedAt != nil)
        #expect(reviewed.autoActivationAllowed)
        // Reflex review remains useful behavior evidence. It does not mint a
        // compiled routine; exact multi-step Workshop trajectories are owned
        // solely by PersistenceCore's ProcedureCompilation pipeline.
        #expect(reviewed.pattern.contains("tool-search"))
    }

    @Test func highRiskReflexRemainsReviewBound() throws {
        let now = Date(timeIntervalSince1970: 60_000)
        var state = OrganismReflexState.empty
        for offset in 0..<12 {
            state = OrganismReflexCompiler.applying(
                signal: livingSignal(
                    .toolSucceeded,
                    source: "tool.shell",
                    at: now.addingTimeInterval(Double(offset))
                ),
                to: state
            )
        }
        let candidate = try #require(state.reviewCandidates().first)
        #expect(candidate.trustClass == .highRisk)
        #expect(!candidate.autoActivationAllowed)
    }
}

private final class LivingDynamicsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private func livingSignal(
    _ kind: SomaticSignalKind,
    source: String = "provider",
    at date: Date
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(),
        kind: kind,
        sourceOrgan: source,
        occurredAt: date,
        intensity: 1
    )
}
