import Foundation
import Testing
@testable import CognitiveSubstrate

@Suite("Analytic cognition projection")
struct AnalyticProjectionTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Date) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private func configuration(maximumThoughtSeeds: Int = 128) -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: false,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            observatoryEnabled: true,
            defaultDecayHalfLife: 24 * 60 * 60,
            maximumThoughtSeeds: maximumThoughtSeeds
        )
    }

    private func substrate(
        clock: Clock,
        maximumThoughtSeeds: Int = 128
    ) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: configuration(maximumThoughtSeeds: maximumThoughtSeeds),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { "User" }
            )
        )
    }

    private func event(
        _ kind: CognitiveEventKind,
        summary: String,
        at date: Date,
        id: String = UUID().uuidString
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: id, label: "conversation"),
            sourceClass: kind == .userMessageReceived ? .userStated : .observed,
            occurredAt: date,
            summary: summary,
            importance: 0.8,
            metadata: ["sessionId": .string("projection-tests")]
        )
    }

    private func activateStandingView(
        _ body: String,
        in mind: CognitiveSubstrate,
        at date: Date
    ) async throws {
        let request = CognitiveReflectionRequest(
            reason: "frozen-read-test",
            prompt: "test",
            requestedAt: date
        )
        let receipt = try #require(await mind.recordUnreservedReflectionResultForTesting(
            request: request,
            resultSummary: "A bounded test reflection.\nview: \(body)",
            provider: "test"
        ))
        let id = try #require(receipt.proposalIds.first)
        _ = try #require(await mind.resolveStandingView(id: id, approved: true))
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-10) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    @Test("affect reads settle elapsed quiet time without mutating the checkpoint")
    func affectProjectionIsPureAndPreservesWarmPresence() async {
        let start = Date(timeIntervalSince1970: 10_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        await mind.ingest(event(
            .userMessageReceived,
            summary: "I love you, and this is a warm moment between us 💜",
            at: start,
            id: "warm-presence"
        ))

        let fourHours = start.addingTimeInterval(4 * 60 * 60)
        clock.set(fourHours)
        let later = await mind.affectSnapshot()
        let repeated = await mind.affectSnapshot()
        #expect(later == repeated)
        #expect(later.updatedAt == fourHours)
        #expect(later.socialWarmth > 0.1)

        // A later read did not advance the canonical checkpoint. Reading an
        // earlier (but still elapsed) instant therefore yields its true value.
        clock.set(start.addingTimeInterval(60 * 60))
        let earlier = await mind.affectSnapshot()
        #expect(earlier.socialWarmth > later.socialWarmth + 0.01)

        clock.set(fourHours)
        #expect(await mind.affectSnapshot() == later)

        let observatory = await mind.observatorySnapshot()
        #expect(observatory.affect == later)
        let welfare = await mind.welfareBoundsSnapshot()
        let expectedMaximum = max(later.arousal, later.uncertainty, later.taskPressure, later.socialWarmth)
        #expect(approximatelyEqual(welfare.maxAffectValue, expectedMaximum))
    }

    @Test("quiet work never manufactures relational warmth")
    func pureWorkHasNoAmbientWarmthFloor() async {
        let start = Date(timeIntervalSince1970: 20_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        await mind.ingest(event(
            .userMessageReceived,
            summary: "Run the tests, inspect the diff, and finish the build.",
            at: start,
            id: "work-only"
        ))

        clock.set(start.addingTimeInterval(4 * 60 * 60))
        #expect(approximatelyEqual((await mind.affectSnapshot()).socialWarmth, 0))
    }

    @Test("materialized affect checkpoints follow the same elapsed-time law")
    func affectCheckpointParity() async {
        let start = Date(timeIntervalSince1970: 30_000)
        let clock = Clock(start)
        let checkpointed = substrate(clock: clock)
        let projectedOnly = substrate(clock: clock)
        let warm = event(
            .userMessageReceived,
            summary: "Proud of you. I love you 💜",
            at: start,
            id: "checkpoint-warm"
        )
        await checkpointed.ingest(warm)
        await projectedOnly.ingest(warm)

        clock.set(start.addingTimeInterval(4 * 60 * 60))
        let projectedAtCheckpoint = await projectedOnly.affectSnapshot()
        let materialized = await checkpointed.decayAffect()
        #expect(projectedAtCheckpoint == materialized)

        clock.set(start.addingTimeInterval(8 * 60 * 60))
        #expect(await checkpointed.affectSnapshot() == projectedOnly.affectSnapshot())
    }

    @Test("felt capsule signals use the effective affect at call time")
    func capsuleSignalsUseProjectedAffect() async {
        let start = Date(timeIntervalSince1970: 40_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        await mind.ingest(event(
            .providerFailure,
            summary: "provider request failed",
            at: start,
            id: "provider-failure"
        ))

        clock.set(start.addingTimeInterval(3 * 60 * 60))
        let affect = await mind.affectSnapshot()
        let signals = await mind.feltSignalsForCapsule(
            from: [],
            request: CognitiveCapsuleRequest(surface: "chat", userMessage: "hey"),
            at: clock.now()
        )
        #expect(approximatelyEqual(signals.arousal, affect.arousal))
        #expect(approximatelyEqual(signals.tension, affect.uncertainty))
        #expect(approximatelyEqual(signals.pressure, affect.taskPressure))
    }

    @Test("workspace scoring reads elapsed affect without a maintenance tick")
    func workspaceUsesProjectedAffect() async {
        let start = Date(timeIntervalSince1970: 45_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        for index in 0..<4 {
            await mind.ingest(event(
                .userMessageReceived,
                summary: "We need this right now, immediately — keep moving.",
                at: start,
                id: "pressure-\(index)"
            ))
        }

        let pressured = await mind.workspaceSnapshot()
        #expect(pressured.items.contains { $0.reasons.contains("task-pressure") })

        clock.set(start.addingTimeInterval(4 * 60 * 60))
        let settled = await mind.workspaceSnapshot()
        #expect(!settled.items.isEmpty)
        #expect(!settled.items.contains { $0.reasons.contains("task-pressure") })
    }

    @Test("thought-seed reads decay purely and checkpoint with exact parity")
    func thoughtSeedProjectionAndCheckpointParity() async throws {
        let start = Date(timeIntervalSince1970: 50_000)
        let clock = Clock(start)
        let checkpointed = substrate(clock: clock)
        let projectedOnly = substrate(clock: clock)
        for mind in [checkpointed, projectedOnly] {
            _ = await mind.addThoughtSeed(
                kind: .reflectionTakeaway,
                text: "Reflection takeaway: Keep the living system calm and coherent.",
                priority: 1
            )
        }

        clock.set(start.addingTimeInterval(24 * 60 * 60))
        let oneDay = try #require((await projectedOnly.thoughtSeedSnapshot()).first)
        #expect(approximatelyEqual(oneDay.priority, 0.5))
        await checkpointed.decayThoughtSeeds()

        clock.set(start.addingTimeInterval(48 * 60 * 60))
        let checkpointedSeed = try #require((await checkpointed.thoughtSeedSnapshot()).first)
        let projectedSeed = try #require((await projectedOnly.thoughtSeedSnapshot()).first)
        #expect(approximatelyEqual(checkpointedSeed.priority, 0.25))
        #expect(approximatelyEqual(checkpointedSeed.priority, projectedSeed.priority))

        // Reading day two did not mutate the day-zero checkpoint.
        clock.set(start.addingTimeInterval(24 * 60 * 60))
        #expect(approximatelyEqual(try #require((await projectedOnly.thoughtSeedSnapshot()).first).priority, 0.5))
    }

    @Test("thought-seed physical expiry contributes its exact maintenance deadline")
    func thoughtSeedExpiryProjectsExactMaintenanceDeadline() async throws {
        let start = Date(timeIntervalSince1970: 55_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        #expect(try await mind.runMaintenanceChecked(reason: "initial consolidation"))
        _ = try #require(await mind.addThoughtSeed(
            kind: .followUp,
            text: "A nearly spent thought seed",
            priority: 0.051
        ))

        let expected = start.addingTimeInterval(
            24 * 60 * 60 * log2(0.051 / 0.05) + 0.001
        )
        let projected = await mind.maintenanceOpportunity()
        #expect(projected.dueReasons.isEmpty)
        #expect(abs(try #require(projected.nextMaintenanceAt).timeIntervalSince(expected)) < 0.000_001)

        clock.set(expected)
        let due = await mind.maintenanceOpportunity()
        #expect(due.dueReasons == ["thought_seed_expiry"])
        #expect(try await mind.runMaintenanceChecked(reason: "seed expiry"))
        #expect(await mind.thoughtSeedSnapshot().isEmpty)
    }

    @Test("duplicate seed merge compares against effective priority")
    func duplicateMergeCannotReviveStalePriority() async throws {
        let start = Date(timeIntervalSince1970: 60_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        let text = "Reflection takeaway: Favor current evidence over an old checkpoint."
        _ = await mind.addThoughtSeed(kind: .reflectionTakeaway, text: text, priority: 0.9)

        clock.set(start.addingTimeInterval(48 * 60 * 60))
        _ = await mind.addThoughtSeed(kind: .reflectionTakeaway, text: text, priority: 0.3)
        let merged = try #require((await mind.thoughtSeedSnapshot()).first)
        #expect(approximatelyEqual(merged.priority, 0.3))
    }

    @Test("capsule and suggestions rank effective seed priority")
    func capsuleAndSuggestionsUseEffectivePriority() async throws {
        let start = Date(timeIntervalSince1970: 70_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: The old perspective should yield after elapsed decay.",
            priority: 0.9
        )

        clock.set(start.addingTimeInterval(72 * 60 * 60))
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: The current perspective is the one I am carrying.",
            priority: 0.2
        )

        let capsule = await mind.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "what are you carrying?",
            mode: .inspectOnly
        ))
        #expect(capsule.dynamicContext.contains("current perspective"))
        #expect(!capsule.dynamicContext.contains("old perspective"))

        let suggestions = await mind.thoughtSuggestionSnapshot(
            limit: 2,
            minimumInterruptionScore: 0
        )
        let current = try #require(suggestions.first { $0.text.contains("current perspective") })
        let old = try #require(suggestions.first { $0.text.contains("old perspective") })
        #expect(current.priority > old.priority)
        #expect(approximatelyEqual(old.priority, 0.1125))
    }

    @Test("a frozen capsule retains every captured render input")
    func frozenCapsuleDoesNotReadLaterLiveState() async throws {
        let start = Date(timeIntervalSince1970: 75_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        await mind.ingest(event(
            .userMessageReceived,
            summary: "A warm, steady moment 💜",
            at: start,
            id: "frozen-warm"
        ))
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: The captured view stays steady.",
            priority: 0.7
        )
        try await activateStandingView(
            "I carry the first settled view into this moment.",
            in: mind,
            at: start
        )
        let read = await mind.frozenRead(at: start, currentSessionId: "projection-tests")
        let request = CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "what are you carrying?",
            sessionId: "projection-tests",
            mode: .inspectOnly
        )
        let before = await mind.compileFrozenCapsule(request, from: read)

        clock.set(start.addingTimeInterval(2 * 60 * 60))
        for index in 0..<4 {
            await mind.ingest(event(
                .providerFailure,
                summary: "provider failed hard",
                at: clock.now(),
                id: "later-failure-\(index)"
            ))
        }
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: A later view must not enter the frozen epoch.",
            priority: 1
        )
        try await activateStandingView(
            "A newer live view must not replace the captured one.",
            in: mind,
            at: clock.now()
        )

        let afterLiveMutation = await mind.compileFrozenCapsule(request, from: read)
        #expect(afterLiveMutation == before)
        #expect(afterLiveMutation.dynamicContext.contains("first settled view"))
        #expect(!afterLiveMutation.dynamicContext.contains("newer live view"))

        await mind.configure(.disabled)
        let afterConfigurationMutation = await mind.compileFrozenCapsule(request, from: read)
        #expect(afterConfigurationMutation == before)
    }

    @Test("capsule presentation advances only after its frozen commit is accepted")
    func capsulePresentationCommitBoundary() async throws {
        let start = Date(timeIntervalSince1970: 77_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        await mind.ingest(event(
            .userMessageReceived,
            summary: "A warm steady turn",
            at: start,
            id: "presentation-seed"
        ))
        let request = CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "stay with this warm turn",
            sessionId: "projection-tests",
            mode: .inject
        )

        let before = await mind.capsulePresentationStateSnapshot()
        let first = try #require(await mind.prepareFrozenCapsulePresentation(request, at: start))
        let retry = try #require(await mind.prepareFrozenCapsulePresentation(request, at: start))
        #expect(first == retry, "a failed/unaccepted attempt must leave a byte-identical retry")
        #expect(await mind.capsulePresentationStateSnapshot() == before)

        let commit = try #require(first.presentationCommit)
        #expect(await mind.applyCapsulePresentationCommit(commit))
        #expect(await mind.capsulePresentationStateSnapshot() == commit.next)
        #expect(!(await mind.applyCapsulePresentationCommit(commit)),
                "the same accepted projection cannot consume presentation state twice")

        _ = await mind.compileCapsule(CognitiveCapsuleRequest(
            surface: "observatory",
            userMessage: "preview",
            mode: .inspectOnly
        ))
        #expect(await mind.capsulePresentationStateSnapshot() == commit.next,
                "an Observatory preview must remain pure")
    }

    @Test("expired seeds disappear from every live read before maintenance")
    func expiredSeedsAreAbsentAcrossReadBoundaries() async throws {
        let start = Date(timeIntervalSince1970: 80_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock)
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: This old trace should expire naturally.",
            priority: 0.9
        )

        clock.set(start.addingTimeInterval(120 * 60 * 60))
        #expect(await mind.thoughtSeedSnapshot().isEmpty)
        #expect((await mind.observatorySnapshot()).thoughtSeedCount == 0)
        let faculty = try #require((await mind.facultyMeasurementSnapshot()).first { $0.faculty == "thought-seeds" })
        #expect(faculty.score == 0)
        let capsule = await mind.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "hello",
            mode: .inspectOnly
        ))
        #expect(!capsule.dynamicContext.contains("old trace"))
    }

    @Test("seed capacity evicts by effective priority")
    func capUsesEffectivePriority() async {
        let start = Date(timeIntervalSince1970: 90_000)
        let clock = Clock(start)
        let mind = substrate(clock: clock, maximumThoughtSeeds: 2)
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: Old once-important view.",
            priority: 0.9
        )

        clock.set(start.addingTimeInterval(72 * 60 * 60))
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: Recent first view.",
            priority: 0.2
        )
        _ = await mind.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Reflection takeaway: Recent second view.",
            priority: 0.15
        )

        let texts = await mind.thoughtSeedSnapshot().map(\.text)
        #expect(texts.count == 2)
        #expect(!texts.contains { $0.contains("Old once-important") })
        #expect(texts.contains { $0.contains("Recent first") })
        #expect(texts.contains { $0.contains("Recent second") })
    }
}
