import Foundation
import Testing
@testable import Context

private final class PrewarmTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var last: UInt64

    init(_ values: [UInt64]) {
        self.values = values
        self.last = values.last ?? 0
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if !values.isEmpty {
            last = values.removeFirst()
        }
        return last
    }
}

private func prewarmCandidate(
    _ id: String,
    bytes: Int = 4,
    likelihood: Double = 0.5,
    generation: Int64 = 1
) -> ContextPrewarmCandidate {
    ContextPrewarmCandidate(
        atomID: ContextAtomID(rawValue: id),
        generationID: generation,
        sourceFingerprint: "source-\(id)",
        estimatedByteCount: bytes,
        likelihood: likelihood
    )
}

private func sessionEvent(
    id: String,
    eventID: String,
    revision: Int64,
    priority: Int = 0,
    candidates: [ContextPrewarmCandidate]
) -> ContextPrewarmEvent {
    .session(ContextSessionPrewarmHint(
        sessionID: id,
        eventID: eventID,
        revision: revision,
        priority: priority,
        candidates: candidates
    ))
}

@Test func everyFC6EventContractProducesPointerOnlyAdvisoryPlans() async throws {
    let candidate = prewarmCandidate("atom")
    let events: [ContextPrewarmEvent] = [
        .session(ContextSessionPrewarmHint(
            sessionID: "session", eventID: "s", revision: 1, candidates: [candidate]
        )),
        .desk(ContextDeskPrewarmHint(
            deskID: "desk", eventID: "d", revision: 1, candidates: [candidate]
        )),
        .workshopExecution(ContextWorkshopPrewarmHint(
            executionID: "mission", eventID: "m", revision: 1, candidates: [candidate]
        )),
        .file(ContextFilePrewarmHint(
            sourceID: ContextSourceID(rawValue: "file"),
            contentFingerprint: "content",
            eventID: "f",
            revision: 1,
            candidates: [candidate]
        )),
        .toolResult(ContextToolResultPrewarmHint(
            toolCallID: "tool",
            resultFingerprint: "result",
            eventID: "t",
            revision: 1,
            candidates: [candidate]
        )),
        .cognitive(ContextCognitivePrewarmHint(
            workspaceID: "workspace",
            activationID: "activation",
            eventID: "c",
            revision: 1,
            candidates: [candidate]
        )),
        .organism(ContextOrganismPrewarmHint(
            predictionID: "prediction", eventID: "o", revision: 1, candidates: [candidate]
        )),
    ]
    let expectedKinds = Set(ContextPrewarmHintKind.allCases)
    var observedKinds = Set<ContextPrewarmHintKind>()

    for event in events {
        let planner = ContextPrewarmPlanner()
        #expect(await planner.submit(event).outcome == .accepted)
        let receipt = await planner.processNext()
        let plan = try #require(receipt.plan)
        observedKinds.insert(try #require(plan.items.first).cause.kind)
        #expect(plan.items.map(\.candidate) == [candidate])
        #expect(!plan.canAlterSelection)
        #expect(!plan.canGrantAuthority)
    }
    #expect(observedKinds == expectedKinds)
}

@Test func equalRevisionHintsDedupeDeterministicallyAcrossArrivalOrder() async throws {
    let limits = try ContextPrewarmLimits(maximumAtomsPerHint: 4)
    let first = sessionEvent(
        id: "session",
        eventID: "z-event",
        revision: 7,
        priority: 1,
        candidates: [prewarmCandidate("b", likelihood: 0.8)]
    )
    let second = sessionEvent(
        id: "session",
        eventID: "a-event",
        revision: 7,
        priority: 3,
        candidates: [
            prewarmCandidate("a", likelihood: 0.9),
            prewarmCandidate("b", bytes: 2, likelihood: 0.8),
        ]
    )
    let forward = ContextPrewarmPlanner(limits: limits)
    let reverse = ContextPrewarmPlanner(limits: limits)

    _ = await forward.submit(first)
    let forwardDedupe = await forward.submit(second)
    _ = await reverse.submit(second)
    let reverseDedupe = await reverse.submit(first)

    #expect(forwardDedupe.outcome == .deduplicated(intoEventID: "a-event"))
    #expect(reverseDedupe.outcome == .deduplicated(intoEventID: "a-event"))
    let forwardPlan = try #require(await forward.processNext().plan)
    let reversePlan = try #require(await reverse.processNext().plan)
    #expect(forwardPlan == reversePlan)
    #expect(forwardPlan.items.map(\.candidate.atomID.rawValue) == ["a", "b"])
    #expect(forwardPlan.items.last?.candidate.estimatedByteCount == 2)
}

@Test func newerRevisionSupersedesAndCancellationInvalidatesPlans() async throws {
    let planner = ContextPrewarmPlanner()
    let old = sessionEvent(
        id: "session",
        eventID: "old",
        revision: 1,
        candidates: [prewarmCandidate("old")]
    )
    _ = await planner.submit(old)
    let oldPlan = try #require(await planner.processNext().plan)

    let newer = sessionEvent(
        id: "session",
        eventID: "new",
        revision: 2,
        candidates: [prewarmCandidate("new")]
    )
    #expect(await planner.submit(newer).outcome == .accepted)
    let invalidatedByRevision = await planner.validate(oldPlan)
    #expect(invalidatedByRevision.validItems.isEmpty)
    #expect(invalidatedByRevision.invalidatedItems == oldPlan.items)

    let scope = ContextPrewarmScope(kind: .session, id: "session")
    let cancellation = ContextPrewarmCancellation(
        scope: scope,
        eventID: "cancel",
        revision: 2
    )
    let cancellationReceipt = await planner.submit(.cancel(cancellation))
    #expect(cancellationReceipt.outcome == .cancelled)
    #expect(cancellationReceipt.supersededEventIDs == ["new"])
    #expect(await planner.pendingHintCount() == 0)

    let stale = await planner.submit(old)
    #expect(stale.outcome == .stale(latestRevision: 2))
}

@Test func queueAtomAndByteBoundsAreHardAndDeterministic() async throws {
    let limits = try ContextPrewarmLimits(
        maximumQueuedHints: 2,
        maximumTrackedScopes: 4,
        maximumAtomsPerHint: 3,
        maximumAtomsPerPlan: 2,
        maximumBytesPerHint: 12,
        maximumBytesPerPlan: 8
    )
    let planner = ContextPrewarmPlanner(limits: limits)
    let candidates = [
        prewarmCandidate("a", likelihood: 1),
        prewarmCandidate("b", likelihood: 0.9),
        prewarmCandidate("c", likelihood: 0.8),
        prewarmCandidate("d", likelihood: 0.7),
    ]
    let low = await planner.submit(sessionEvent(
        id: "low", eventID: "low", revision: 1, priority: 1, candidates: candidates
    ))
    #expect(low.acceptedAtomCount == 3)
    #expect(low.acceptedByteCount == 12)
    #expect(low.droppedAtomCount == 1)

    _ = await planner.submit(sessionEvent(
        id: "high", eventID: "high", revision: 1, priority: 3,
        candidates: [prewarmCandidate("high")]
    ))
    let middle = await planner.submit(sessionEvent(
        id: "middle", eventID: "middle", revision: 1, priority: 2,
        candidates: [prewarmCandidate("middle")]
    ))
    #expect(middle.evictedEventIDs == ["low"])
    #expect(await planner.pendingHintCount() == 2)

    let firstPlan = try #require(await planner.processNext().plan)
    let secondPlan = try #require(await planner.processNext().plan)
    #expect(firstPlan.items.map(\.cause.id) == ["high"])
    #expect(secondPlan.items.map(\.cause.id) == ["middle"])
    #expect(firstPlan.items.count <= limits.maximumAtomsPerPlan)
    #expect(firstPlan.estimatedByteCount <= limits.maximumBytesPerPlan)
}

@Test func processingStopsAtInjectedMonotonicTimeBoundWithoutTimers() async throws {
    let testClock = PrewarmTestClock([0, 0, 10, 10])
    let limits = try ContextPrewarmLimits(maximumPlanningNanoseconds: 5)
    let planner = ContextPrewarmPlanner(
        limits: limits,
        clock: ContextPrewarmClock(readNanoseconds: testClock.read)
    )
    _ = await planner.submit(sessionEvent(
        id: "session",
        eventID: "event",
        revision: 1,
        candidates: [prewarmCandidate("a"), prewarmCandidate("b")]
    ))

    let receipt = await planner.processNext()
    #expect(receipt.outcome == .timeBounded)
    #expect(receipt.plan?.items.map(\.candidate.atomID.rawValue) == ["a"])
    #expect(receipt.consideredAtomCount == 1)
    #expect(receipt.elapsedNanoseconds == 10)
}

@Test func resourcePressureCancelsAndSuppressesUntilANewEvent() async throws {
    let planner = ContextPrewarmPlanner()
    let event = sessionEvent(
        id: "session",
        eventID: "event",
        revision: 1,
        candidates: [prewarmCandidate("a")]
    )
    _ = await planner.submit(event)
    let plan = try #require(await planner.processNext().plan)

    let pressure = await planner.setResourcePressure(.warning)
    #expect(pressure.cancelledEventIDs == ["event"])
    #expect(pressure.queueCount == 0)
    #expect(await planner.submit(event).outcome == .suppressed(.warning))
    #expect(await planner.processNext().outcome == .suppressed(.warning))

    _ = await planner.setResourcePressure(.normal)
    #expect(await planner.processNext().outcome == .empty)
    #expect(await planner.validate(plan).validItems.isEmpty)
    let futureEvent = sessionEvent(
        id: "session",
        eventID: "future",
        revision: 2,
        candidates: [prewarmCandidate("b")]
    )
    #expect(await planner.submit(futureEvent).outcome == .accepted)
    #expect(await planner.processNext().outcome == .planned)
}

@Test func usefulnessReceiptsObserveIndependentSelectionAndStayBounded() async throws {
    let limits = try ContextPrewarmLimits(maximumUsefulnessReceipts: 2)
    let planner = ContextPrewarmPlanner(limits: limits)
    _ = await planner.submit(sessionEvent(
        id: "session",
        eventID: "event",
        revision: 1,
        candidates: [prewarmCandidate("a"), prewarmCandidate("b")]
    ))
    let plan = try #require(await planner.processNext().plan)

    let receipt = await planner.recordUsefulness(
        for: plan,
        warmedAtomIDs: [ContextAtomID(rawValue: "a"), ContextAtomID(rawValue: "b")],
        independentlySelectedAtomIDs: [ContextAtomID(rawValue: "b"), ContextAtomID(rawValue: "other")]
    )
    #expect(receipt.usefulAtomIDs.map(\.rawValue) == ["b"])
    #expect(receipt.unusedWarmedAtomIDs.map(\.rawValue) == ["a"])
    #expect(receipt.usefulness == 0.5)
    #expect(receipt.selectionWasObservedOnly)
    #expect(!receipt.authorityGranted)
    #expect(!plan.canAlterSelection)
    #expect(!plan.canGrantAuthority)

    _ = await planner.recordUsefulness(
        for: plan,
        warmedAtomIDs: [],
        independentlySelectedAtomIDs: []
    )
    _ = await planner.recordUsefulness(
        for: plan,
        warmedAtomIDs: [],
        independentlySelectedAtomIDs: []
    )
    let retained = await planner.recentUsefulnessReceipts()
    #expect(retained.count == 2)
    #expect(retained.map(\.ordinal) == [2, 3])
}
