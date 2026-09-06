import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Review 2026-09-01.
///
/// HIGH — `liveTurnInFlight` was `pendingMicrocycleGeneration != nil`. The
/// coalescer clears that generation the moment the settlement it owns STARTS,
/// while the user's turn (provider stream, tool loop, reply persistence) runs on
/// for minutes. A residual deadline landing in that window read "no turn in
/// flight" and could start a pressure dream — or a studio encounter — on top of
/// a live turn. The latch now tracks the real chat-turn lifecycle the runtime is
/// already handed through `observe`: admission (`userMessageReceived` + runId)
/// through terminal settlement (`assistantTurnCompleted` / `providerFailure` for
/// the same runId), counted, with a wall-clock safety valve.
///
/// MEDIUM — the fire path's `dream.pressure_deferred` receipt was written on
/// every re-anchor while policy kept refusing. It is now change-only, keyed on
/// kind + reason + decision, like the quiet-decision suppression beside it.
@Suite("Live chat-turn latch and pressure-dream deferral receipts", .serialized)
struct CognitionLiveTurnLatchTests {
    private final class LatchClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    // MARK: - HIGH: the latch is the turn, not the coalescer

    @Test("a chat turn holds the latch after its coalesced settlement has run")
    func latchOutlivesCoalescedSettlement() async throws {
        let root = try temporaryRoot("outlives")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 0)

        await runtime.observe(turnEvent(id: "user-1", kind: .userMessageReceived, runId: "run-1"))
        // The settlement this event coalesced now runs to completion — the exact
        // moment the old property went false while the turn was still streaming.
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 1)
        #expect(await runtime.liveTurnInFlight)

        await runtime.observe(turnEvent(id: "assistant-1", kind: .assistantTurnCompleted, runId: "run-1"))
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 0)
    }

    @Test("a provider failure is a terminal settlement for its run")
    func providerFailureReleasesTheLatch() async throws {
        let root = try temporaryRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()

        await runtime.observe(turnEvent(id: "user-2", kind: .userMessageReceived, runId: "run-2"))
        #expect(await runtime.liveTurnLatchCount() == 1)
        await runtime.observe(turnEvent(id: "failure-2", kind: .providerFailure, runId: "run-2"))
        #expect(await runtime.liveTurnLatchCount() == 0)
    }

    @Test("concurrent turns are counted; the latch releases on the last one")
    func concurrentTurnsAreCounted() async throws {
        let root = try temporaryRoot("counted")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()

        await runtime.observe(turnEvent(id: "user-a", kind: .userMessageReceived, runId: "run-a"))
        await runtime.observe(turnEvent(id: "user-b", kind: .userMessageReceived, runId: "run-b"))
        #expect(await runtime.liveTurnLatchCount() == 2)

        await runtime.observe(turnEvent(id: "assistant-a", kind: .assistantTurnCompleted, runId: "run-a"))
        #expect(await runtime.liveTurnLatchCount() == 1)
        #expect(await runtime.liveTurnInFlight)

        await runtime.observe(turnEvent(id: "assistant-b", kind: .assistantTurnCompleted, runId: "run-b"))
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 0)
    }

    @Test("a duplicate admission does not double-count the same run")
    func duplicateAdmissionIsIdempotent() async throws {
        let root = try temporaryRoot("idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()

        await runtime.observe(turnEvent(id: "user-c", kind: .userMessageReceived, runId: "run-c"))
        await runtime.observe(turnEvent(id: "user-c", kind: .userMessageReceived, runId: "run-c"))
        #expect(await runtime.liveTurnLatchCount() == 1)
        await runtime.observe(turnEvent(id: "assistant-c", kind: .assistantTurnCompleted, runId: "run-c"))
        #expect(await runtime.liveTurnLatchCount() == 0)
    }

    @Test("a latch older than the turn wall-clock budget is not trusted")
    func staleLatchIsNotTrusted() async throws {
        let root = try temporaryRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LatchClock(Date(timeIntervalSince1970: 1_700_000_000))
        let runtime = makeRuntime(root: root, clock: clock)
        await runtime.bootstrap()

        // A terminal event that never arrives (a crashed or dropped run) must
        // not block her dream forever.
        await runtime.observe(turnEvent(id: "user-d", kind: .userMessageReceived, runId: "run-d"))
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 1)

        clock.advance(NativeCognitionRuntime.liveTurnLatchWallClockBudget + 1)
        #expect(await runtime.liveTurnLatchCount() == 0)
        #expect(await runtime.liveTurnInFlight == false)
    }

    @Test("an event without a runId cannot open the latch")
    func eventsWithoutARunIdDoNotLatch() async throws {
        let root = try temporaryRoot("norunid")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()

        await runtime.observe(CognitiveEvent(
            id: "background-signal",
            kind: .toolStarted,
            subject: CognitiveSubjectReference(type: "test", id: "background-signal"),
            sourceClass: .observed,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: "a background tool ran with no chat run behind it",
            importance: 0.4
        ))
        #expect(await runtime.liveTurnLatchCount() == 0)
    }

    /// The lane that motivated the fix: a fire-eligible sleep-pressure
    /// opportunity must be refused, without a dream attempt, while a turn is
    /// latched — even though the coalesced settlement for that turn has run.
    @Test("the pressure-dream lane refuses to fire while a turn is latched")
    func pressureDreamRefusesWhileTurnIsLatched() async throws {
        let root = try temporaryRoot("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LatchClock(Date(timeIntervalSince1970: 1_700_000_000))
        let runtime = makeRuntime(root: root, clock: clock)
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()

        await runtime.observe(turnEvent(id: "user-e", kind: .userMessageReceived, runId: "run-e"))
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.liveTurnLatchCount() == 1)

        await runtime.considerPressureDream(fireEligibleOpportunity(at: clock.now()))
        #expect(await runtime.pressureDreamAttemptCountForProof() == 0)
        try await waitForReceipt(
            in: substrate,
            kind: "dream.pressure_not_due",
            where: { payload in
                guard case .object(let fields) = payload,
                      case .string(let decision)? = fields["decision"] else { return false }
                return decision == OrganismIdentityDreamTrigger.Decision.turnInFlight.rawValue
            }
        )
    }

    // MARK: - MEDIUM: deferral receipts are change-only

    @Test("repeated identical fire-path deferrals write one receipt")
    func deferralReceiptsAreChangeOnly() async throws {
        let root = try temporaryRoot("deferral")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, clock: LatchClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await runtime.bootstrap()
        let substrate = await runtime.substrateForIntegration()

        await runtime.recordPressureDreamDeferral(reason: "organism loop budget is conserve")
        await runtime.recordPressureDreamDeferral(reason: "organism loop budget is conserve")
        await runtime.recordPressureDreamDeferral(reason: "organism loop budget is conserve")
        #expect(await deferralCount(in: substrate) == 1)

        // A CHANGE is a fact, and is recorded.
        await runtime.recordPressureDreamDeferral(reason: "dream cycle disabled")
        #expect(await deferralCount(in: substrate) == 2)
        await runtime.recordPressureDreamDeferral(reason: "dream cycle disabled")
        #expect(await deferralCount(in: substrate) == 2)
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-turnlatch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRuntime(root: URL, clock: LatchClock) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                replayEnabled: true,
                backgroundMicrocyclesEnabled: true,
                observatoryEnabled: true,
                maximumCapsuleCharacters: 4_000,
                maximumThoughtSeeds: 64
            ),
            organismConfigurationOverride: .disabled,
            now: { clock.now() },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
    }

    private func turnEvent(
        id: String,
        kind: CognitiveEventKind,
        runId: String
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "chat_turn", id: id, label: id),
            sourceClass: kind == .userMessageReceived ? .userStated : .observed,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: "\(id) for \(runId)",
            importance: 0.6,
            turnKind: .live,
            metadata: [
                "sessionId": .string("session-\(runId)"),
                "runId": .string(runId),
            ]
        )
    }

    /// The one disposition `OrganismIdentityDreamTrigger.decide` treats as
    /// eligible — every other gate is already satisfied, so only the
    /// turn-in-flight term can refuse it.
    private func fireEligibleOpportunity(at instant: Date) -> OrganismResidualRepairOpportunity {
        OrganismResidualRepairOpportunity(
            generatedAt: instant,
            pressure: 0.9,
            ready: true,
            lanes: [
                OrganismSleepLaneOpportunity(
                    lane: .identityDreamProposal,
                    threshold: 0.6,
                    quietInterval: 1_800,
                    disposition: .providerBudgetGateRequired
                )
            ]
        )
    }

    private func deferralCount(in substrate: CognitiveSubstrate) async -> Int {
        await substrate.receiptSnapshot(limit: 200).filter { $0.kind == "dream.pressure_deferred" }.count
    }

    /// Quiet-decision receipts are written from a detached task, so this polls
    /// rather than reading once.
    private func waitForReceipt(
        in substrate: CognitiveSubstrate,
        kind: String,
        where matches: @escaping (JSONValue) -> Bool,
        deadline: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: deadline)
        while clock.now < limit {
            let found = await substrate.receiptSnapshot(limit: 200)
                .contains { $0.kind == kind && matches($0.payload) }
            if found { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("no \(kind) receipt matched before the deadline")
    }
}
