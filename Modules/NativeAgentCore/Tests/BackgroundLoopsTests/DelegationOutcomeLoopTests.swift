import Testing
import Foundation
import PersistenceCore
@testable import BackgroundLoops

// MARK: - DelegationOutcomeLoop tests (W2b, upgrade campaign 2026-08 Track A)
//
// Hermetic by construction: the job store is an injected closure returning
// in-memory snapshots, the cursor path is a per-test temp file, and the clock
// is injected. Nothing here reads ~/.config or the live data root, and nothing
// here can pass or fail because of the wall clock.
//
// The snapshot fixtures mirror the RECORD SHAPES READ OFF THE LIVE STORES
// (2026-08-11): a claude job carries `status: "completed"` + `bridgeStatus`
// (projected to delivery_outcome) + `completedAt`; a codex job carries only the
// turnResult status. The field asymmetry is pinned deliberately.

@Suite("DelegationOutcomeLoop")
struct DelegationOutcomeLoopTests {

    // 2026-08-11T12:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_786_449_600)

    /// The clock constant is load-bearing for every window assertion below, so
    /// pin it against its ISO rendering rather than trusting the literal.
    @Test func fixedClockIsTheInstantTheFixturesAssume() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.string(from: Self.now) == "2026-08-11T12:00:00Z")
    }

    private func cursorPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelegationOutcome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("delegation_outcome_cursor.json")
    }

    private static func iso(_ offsetSeconds: TimeInterval) -> String {
        DelegationOutcomeCursor.formatISO(now.addingTimeInterval(offsetSeconds))
    }

    /// A completed + delivered claude job.
    private static func claudeSuccess(
        id: String = "job-1",
        topic: String? = "w2b-delegation",
        completedAt: String? = iso(-600)
    ) -> DelegationJobSnapshot {
        DelegationJobSnapshot(
            id: id, source: "claude", agent: "claude",
            topicSlug: topic, state: "settled", status: "completed", runStatus: "completed",
            completedAt: completedAt, deliveryOutcome: "delivered", deliveryLost: false,
            completionTextHead: "Shipped the delegation projection."
        )
    }

    private final class CardRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _cards: [DelegationOutcomeCard] = []
        private let accept: @Sendable (DelegationOutcomeCard) -> Bool
        init(accept: @escaping @Sendable (DelegationOutcomeCard) -> Bool = { _ in true }) {
            self.accept = accept
        }
        var cards: [DelegationOutcomeCard] { lock.lock(); defer { lock.unlock() }; return _cards }
        func file(_ card: DelegationOutcomeCard) -> Bool {
            let ok = accept(card)
            if ok { lock.lock(); _cards.append(card); lock.unlock() }
            return ok
        }
    }

    private func makeLoop(
        cursor: URL,
        jobs: @escaping @Sendable () -> [DelegationJobSnapshot],
        recorder: CardRecorder,
        now: Date = DelegationOutcomeLoopTests.now
    ) -> DelegationOutcomeLoop {
        DelegationOutcomeLoop(
            cursorPath: cursor,
            clock: { now },
            readJobs: { jobs() },
            fileCard: { recorder.file($0) }
        )
    }

    // MARK: - Terminality + classification

    @Test func inFlightJobIsNotTerminal() {
        let job = DelegationJobSnapshot(
            id: "j", source: "claude", agent: "claude",
            topicSlug: "t", state: "running", status: nil, runStatus: nil, completedAt: nil)
        #expect(job.isTerminal == false)
        #expect(job.terminalOutcome == nil)
    }

    /// The projection treats `delivering` as terminal FOR STALL PURPOSES. A
    /// completion card must not: the run ended but the outcome has not landed.
    /// This is the difference the loop re-derives on purpose.
    @Test func deliveringStateIsNotACompletion() {
        let job = DelegationJobSnapshot(
            id: "j", source: "claude", agent: "claude",
            topicSlug: "t", state: "delivering", status: nil, runStatus: nil, completedAt: nil)
        #expect(job.isTerminal == false)
    }

    @Test func completedAndDeliveredIsSuccess() {
        #expect(Self.claudeSuccess().terminalOutcome == .succeeded)
        #expect(DelegationOutcome.succeeded.severity == "info")
    }

    @Test func failedRunIsActionable() {
        var job = Self.claudeSuccess()
        job.status = "failed"
        job.runStatus = "failed"
        job.deliveryOutcome = "delivered"
        #expect(job.terminalOutcome == .failed)
        #expect(job.terminalOutcome?.severity == "actionable")
    }

    @Test func provenLostDeliveryOutranksACompletedRun() {
        var job = Self.claudeSuccess()
        job.deliveryLost = true
        job.deliveryOutcome = "lost"
        #expect(job.terminalOutcome == .deliveryLost)
        #expect(job.terminalOutcome?.severity == "actionable")
    }

    /// "The bridge could not confirm" must never be graded as success. This is
    /// the exact distinction `delegation_status` refuses to collapse, and the
    /// card lane has to hold the same line.
    @Test func unconfirmedDeliveryIsNotSuccess() {
        var job = Self.claudeSuccess()
        job.deliveryOutcome = "unknown"
        job.deliveryLost = nil
        #expect(job.terminalOutcome == .unknown)
        #expect(job.terminalOutcome?.severity == "actionable")
    }

    @Test(arguments: ["completed", "failed"])
    func blockedDeliveryIsActionableWithoutClaimingWorkerOrDeliverySuccess(status: String) throws {
        for agent in ["claude", "omp"] {
            let job = DelegationJobSnapshot(
                id: "blocked-\(agent)", source: agent, agent: agent, state: "settled", status: status, runStatus: status,
                completedAt: Self.iso(-30), deliveryOutcome: "blocked", deliveryLost: false,
                completionTextHead: "retained terminal evidence"
            )
            #expect(job.isTerminal)
            #expect(job.terminalOutcome == .unknown)
            #expect(job.terminalOutcome?.severity == "actionable")
            let motor = job.motorActionReadModel()
            #expect(motor.phase == .blocked)
            #expect(motor.verification == .unknown)
            #expect(motor.domainState.contains(status))
            #expect(motor.expectedNextEvidence?.contains("Do not rerun the worker") == true)
            let card = try #require(DelegationOutcomeCard.make(from: job, now: Self.now))
            #expect(card.title.contains("delivery is blocked"))
            #expect(card.severity == "actionable")
            #expect(card.summary.contains("run \(status)"))
            #expect(card.detail.contains("retained terminal evidence"))
            #expect(card.detail.contains("original completion route"))
            #expect(card.detail.contains("Do not rerun the worker"))
        }
    }

    @Test func codexTurnResultStatusDrivesTheOutcome() {
        let job = DelegationJobSnapshot(
            id: "codex-1", source: "codex", agent: "codex",
            topicSlug: "hermes-pr", state: "watching_turn", status: nil,
            runStatus: "completed", completedAt: Self.iso(-300),
            deliveryOutcome: nil, deliveryLost: nil,
            completionTextHead: "Resolved Hermes PR #65084.")
        #expect(job.terminalOutcome == .succeeded)
    }

    @Test func motorProjectionKeepsCompletionDistinctFromTaskVerification() {
        let completed = Self.claudeSuccess(id: "bridge-action")
            .motorActionReadModel()
        #expect(completed.domain == "agent_bridge")
        #expect(completed.actionIdentity
            == CausalTransitionEvidence.opaqueIdentity("bridge-action"))
        #expect(completed.phase == .succeeded)
        #expect(completed.verification == .unverified)
        #expect(completed.expectedNextEvidence?.contains("originating request") == true)

        let waiting = DelegationJobSnapshot(
            id: "waiting", source: "codex", agent: "codex", state: "watching_turn"
        ).motorActionReadModel()
        #expect(waiting.phase == .waitingExternal)
        #expect(waiting.verification == .pending)

        let stuck = DelegationJobSnapshot(
            id: "stuck", source: "omp", agent: "omp", state: "running",
            stalled: true, stallBasis: "stall_seconds"
        ).motorActionReadModel()
        #expect(stuck.phase == .blocked)
        #expect(stuck.verification == .pending)
    }

    // MARK: - Card shape

    @Test func successCardIsInfoAndNamesTheAgentAndTopic() throws {
        let card = try #require(DelegationOutcomeCard.make(from: Self.claudeSuccess(), now: Self.now))
        #expect(card.severity == "info")
        #expect(card.summary == "Claude finished: w2b-delegation")
        #expect(card.cardId == "delegation-outcome:claude:job-1")
        #expect(card.jobKey == "claude:job-1")
        #expect(card.detail.contains("Shipped the delegation projection."))
        guard case .object(let obj) = card.toJSON() else { Issue.record("not an object"); return }
        #expect(obj["source"] == .string("delegation_outcome"))
        #expect(obj["severity"] == .string("info"))
        #expect(obj["status"] == .string("unread"))
        // The job key rides in the field the inbox already reads as a
        // sticky-card signature — that reuse IS the never-re-fire contract.
        #expect(obj["error_signature"] == .string("claude:job-1:succeeded"))
    }

    @Test func codexSuccessCardSaysCodex() throws {
        let job = DelegationJobSnapshot(
            id: "codex-1", source: "codex", agent: "codex",
            topicSlug: "hermes-pr", runStatus: "completed", completedAt: Self.iso(-300))
        let card = try #require(DelegationOutcomeCard.make(from: job, now: Self.now))
        #expect(card.summary == "Codex finished: hermes-pr")
    }

    /// An absent completion head on a delivered job is NORMAL (the runner nulls
    /// the text once delivery succeeds). The card has to say so, or it reads as
    /// "finished with nothing to show".
    @Test func successCardExplainsAnAbsentCompletionText() throws {
        var job = Self.claudeSuccess()
        job.completionTextHead = nil
        let card = try #require(DelegationOutcomeCard.make(from: job, now: Self.now))
        #expect(card.detail.contains("normal for a delivered job"))
    }

    @Test func lostDeliveryCardStatesTheReasonAndOffersArchive() throws {
        var job = Self.claudeSuccess()
        job.deliveryLost = true
        job.deliveryOutcome = "lost"
        let card = try #require(DelegationOutcomeCard.make(from: job, now: Self.now))
        #expect(card.detail.contains("LOST"))
        guard case .object(let obj) = card.toJSON(),
              case .array(let actions)? = obj["actions"] else {
            Issue.record("no actions"); return
        }
        let ids: [String] = actions.compactMap {
            guard case .object(let a) = $0, case .string(let id)? = a["id"] else { return nil }
            return id
        }
        #expect(ids.contains("archive"))
        #expect(ids.contains("dismiss"))
    }

    @Test func nonTerminalJobProducesNoCard() {
        let job = DelegationJobSnapshot(id: "j", source: "claude", agent: "claude", state: "running")
        #expect(DelegationOutcomeCard.make(from: job, now: Self.now) == nil)
    }

    // MARK: - Cursor round trip

    @Test func cursorRoundTripsThroughDisk() throws {
        let path = cursorPath()
        var cursor = DelegationOutcomeCursor()
        cursor.record(source: "claude", id: "a", stamp: Self.now)
        cursor.record(source: "codex", id: "b", stamp: nil)
        try cursor.write(to: path)
        let loaded = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(loaded.store("claude").cardedIDs == ["a"])
        #expect(loaded.store("claude").lastSeen == Self.now)
        #expect(loaded.store("codex").cardedIDs == ["b"])
        #expect(loaded.store("codex").lastSeen == nil)
    }

    @Test func cursorEvictsOldestBeyondTheLimit() {
        var cursor = DelegationOutcomeCursor()
        for i in 0..<(DelegationOutcomeCursor.cardedIDLimit + 5) {
            cursor.record(source: "claude", id: "job-\(i)", stamp: nil)
        }
        let ids = cursor.store("claude").cardedIDs
        #expect(ids.count == DelegationOutcomeCursor.cardedIDLimit)
        #expect(ids.first == "job-5")
        #expect(ids.last == "job-\(DelegationOutcomeCursor.cardedIDLimit + 4)")
    }

    @Test func cursorLastSeenNeverMovesBackwards() {
        var cursor = DelegationOutcomeCursor()
        cursor.record(source: "claude", id: "new", stamp: Self.now)
        cursor.record(source: "claude", id: "old", stamp: Self.now.addingTimeInterval(-3_600))
        #expect(cursor.store("claude").lastSeen == Self.now)
    }

    @Test func missingCursorFileLoadsAsNil() {
        #expect(DelegationOutcomeCursor.load(from: cursorPath()) == nil)
    }

    // MARK: - Loop behaviour

    /// The single most important behaviour: the first tick on a machine with a
    /// full history of terminal jobs must file NOTHING.
    @Test func firstTickSeedsTheCursorAndFilesNothing() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        let jobs = (0..<5).map { Self.claudeSuccess(id: "job-\($0)", completedAt: Self.iso(-3_600)) }
        let loop = makeLoop(cursor: path, jobs: { jobs }, recorder: recorder)

        let outcome = await loop.tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(result?.contains("seeded") == true)
        #expect(recorder.cards.isEmpty)
        let cursor = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(cursor.store("claude").cardedIDs.count == 5)
    }

    @Test func newlyTerminalJobCardsExactlyOnceAcrossTicks() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        let existing = Self.claudeSuccess(id: "old", completedAt: Self.iso(-7_200))
        let fresh = Self.claudeSuccess(id: "fresh", topic: "new-work", completedAt: Self.iso(-60))

        // Tick 1 seeds over the pre-existing job.
        var visible: [DelegationJobSnapshot] = [existing]
        let box = SnapshotBox(visible)
        let loop = makeLoop(cursor: path, jobs: { box.value }, recorder: recorder)
        _ = await loop.tickOutcome()
        #expect(recorder.cards.isEmpty)

        // Tick 2: the fresh job appears and cards.
        visible.append(fresh)
        box.value = visible
        _ = await loop.tickOutcome()
        #expect(recorder.cards.map(\.jobKey) == ["claude:fresh"])

        // Tick 3: nothing new. The same job must NOT card again.
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == 1)
    }

    @Test func recentCodexDeliveryIdentityOutranksAnAheadCrossJobTimestamp() async throws {
        let path = cursorPath()
        var cursor = DelegationOutcomeCursor()
        // Another Codex job advanced the coarse completion cursor first.
        cursor.record(source: "codex", id: "different-job", stamp: Self.now)
        try cursor.write(to: path)
        let recorder = CardRecorder()
        let receipt = DelegationJobSnapshot(
            id: "message-id",
            motorOwnerID: "message-id",
            source: "codex",
            agent: "codex",
            state: "settled",
            status: "delivered",
            runStatus: "completed",
            completedAt: Self.iso(-60),
            deliveryOutcome: "delivered"
        )

        _ = await makeLoop(cursor: path, jobs: { [receipt] }, recorder: recorder).tickOutcome()

        #expect(recorder.cards.map(\.jobKey) == ["codex:message-id"])
        let settled = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(settled.store("codex").cardedIDs.contains("message-id"))
    }

    /// A failed inbox write must leave the job un-carded so the next tick
    /// retries — otherwise a transient failure silently swallows the card.
    @Test func failedInboxWriteIsRetriedOnTheNextTick() async throws {
        let path = cursorPath()
        let failing = CardRecorder(accept: { _ in false })
        let job = Self.claudeSuccess(id: "retry-me", completedAt: Self.iso(-60))
        let seedOnly = makeLoop(cursor: path, jobs: { [] }, recorder: failing)
        _ = await seedOnly.tickOutcome()  // seed with an empty store

        let failingLoop = makeLoop(cursor: path, jobs: { [job] }, recorder: failing)
        let outcome = await failingLoop.tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(result?.contains("will retry") == true)
        #expect(failing.cards.isEmpty)
        let cursor = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(cursor.store("claude").cardedIDs.isEmpty)

        // Now the write succeeds and the card lands.
        let succeeding = CardRecorder()
        let retryLoop = makeLoop(cursor: path, jobs: { [job] }, recorder: succeeding)
        _ = await retryLoop.tickOutcome()
        #expect(succeeding.cards.map(\.jobKey) == ["claude:retry-me"])
    }

    @Test func failedTransitionReceiptKeepsTheOutcomeUnsettledForRetry() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()
        let job = Self.claudeSuccess(id: "receipt-retry", completedAt: Self.iso(-60))
        let observations = TransitionReceiptRecorder(results: [false, true])
        let loop = DelegationOutcomeLoop(
            cursorPath: path,
            clock: { Self.now },
            readJobs: { [job] },
            fileCard: { recorder.file($0) },
            observeTransition: { observations.observe($0) }
        )

        _ = await loop.tickOutcome()
        #expect(DelegationOutcomeCursor.load(from: path)?.store("claude").cardedIDs.isEmpty == true)
        _ = await loop.tickOutcome()

        #expect(observations.ids == ["receipt-retry", "receipt-retry"])
        #expect(DelegationOutcomeCursor.load(from: path)?.store("claude").cardedIDs == ["receipt-retry"])
    }

    @Test func olderFailurePreventsCursorFromSkippingItForANewerSuccess() async throws {
        let path = cursorPath()
        let attempts = AttemptRecorder()
        let recorder = CardRecorder(accept: { card in
            attempts.record(card.jobKey)
            return card.jobKey != "claude:older"
        })
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()
        let older = Self.claudeSuccess(id: "older", completedAt: Self.iso(-120))
        let newer = Self.claudeSuccess(id: "newer", completedAt: Self.iso(-60))
        _ = await makeLoop(cursor: path, jobs: { [newer, older] }, recorder: recorder).tickOutcome()
        #expect(attempts.values == ["claude:older"])
        let cursor = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(cursor.store("claude").cardedIDs.isEmpty)
        #expect(cursor.store("claude").lastSeen == nil)
    }

    @Test func perTickCapIsAnnouncedNeverSilent() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        let seeded = makeLoop(cursor: path, jobs: { [] }, recorder: recorder)
        _ = await seeded.tickOutcome()

        let many = (0..<(DelegationOutcomeLoop.maxCardsPerTick + 4)).map {
            Self.claudeSuccess(id: "burst-\($0)", completedAt: Self.iso(-Double($0 + 1)))
        }
        let loop = makeLoop(cursor: path, jobs: { many }, recorder: recorder)
        let outcome = await loop.tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(recorder.cards.count == DelegationOutcomeLoop.maxCardsPerTick)
        #expect(result?.contains("4 more deferred") == true)

        // The remainder lands on the following tick.
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == many.count)
    }

    @Test func inFlightJobsAreNeverCarded() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        let seeded = makeLoop(cursor: path, jobs: { [] }, recorder: recorder)
        _ = await seeded.tickOutcome()

        let running = DelegationJobSnapshot(
            id: "running", source: "claude", agent: "claude",
            topicSlug: "t", state: "running")
        let loop = makeLoop(cursor: path, jobs: { [running] }, recorder: recorder)
        let outcome = await loop.tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(result?.contains("no newly-terminal or stuck") == true)
        #expect(recorder.cards.isEmpty)
    }

    @Test func stalledStepSpeaksOnceAndClearsWhenLivenessReturns() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()

        let healthy = DelegationJobSnapshot(
            id: "review-1", source: "omp", agent: "omp",
            topicSlug: "review-candidate-a32e6ce6", state: "running",
            stalled: false, stallBasis: "stall_seconds",
            lastLiveness: Self.iso(-5))
        let box = SnapshotBox([healthy])
        let loop = makeLoop(cursor: path, jobs: { box.value }, recorder: recorder)

        // Persisted output more frequent than the OMP idle threshold keeps the
        // projector verdict healthy, so the outcome loop files no warning.
        _ = await loop.tickOutcome()
        #expect(recorder.cards.isEmpty)

        var stalled = healthy
        stalled.stalled = true
        stalled.lastLiveness = Self.iso(-900)
        box.value = [stalled]

        let first = await loop.tickOutcome()
        guard case .completed(let firstResult) = first else {
            Issue.record("expected completed, got \(first)"); return
        }
        #expect(firstResult?.contains("filed 1 delegation liveness card") == true)
        #expect(recorder.cards.count == 1)
        let stuck = try #require(recorder.cards.first)
        #expect(stuck.title == "OMP step is stuck")
        #expect(stuck.summary.contains("review-candidate-a32e6ce6"))
        #expect(stuck.detail.contains("recorded liveness stopped advancing"))
        #expect(stuck.detail.contains("did not replay the request or start replacement work"))
        #expect(stuck.severity == "actionable")
        #expect(stuck.resolved == false)
        #expect(try #require(DelegationOutcomeCursor.load(from: path))
            .store("omp").announcedStallIDs == ["review-1"])

        // Steady stalled state is quiet: the same liveness episode speaks once.
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == 1)

        var recovered = stalled
        recovered.stalled = false
        recovered.lastLiveness = Self.iso(-5)
        box.value = [recovered]
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == 2)
        let cleared = try #require(recorder.cards.last)
        #expect(cleared.cardId == stuck.cardId)
        #expect(cleared.title == "OMP step is moving again")
        #expect(cleared.resolved == true)
        #expect(cleared.detail.contains("proves renewed liveness, not completion"))
        #expect(try #require(DelegationOutcomeCursor.load(from: path))
            .store("omp").announcedStallIDs.isEmpty)

        // Recovery is also edge-triggered rather than a recurring heartbeat.
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == 2)
    }

    @Test func stalledStepVisibleOnTheFirstSeedTickIsNotSilenced() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        let stalled = DelegationJobSnapshot(
            id: "builder-1", source: "omp", agent: "omp",
            topicSlug: "builder-candidate", state: "running",
            stalled: true, stallBasis: "deadline", lastLiveness: Self.iso(-1_800))
        let outcome = await makeLoop(
            cursor: path, jobs: { [stalled] }, recorder: recorder
        ).tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(result?.contains("seeded delegation outcome cursor") == true)
        #expect(result?.contains("filed 1 delegation liveness card") == true)
        #expect(recorder.cards.map(\.title) == ["OMP step is stuck"])
    }

    // MARK: - Outcome upgrade re-card (the codex mid-delivery race)

    /// A codex job as the loop sees it while the POST is still in flight:
    /// `completedExecution` is written BEFORE delivery, so the record is
    /// terminal with no delivery verdict. `undelivered: true` is the same job
    /// after the bridge preserved it under `reply-jobs/undelivered/`.
    private static func codexJob(
        id: String = "cx-1", topic: String? = "mac-chat-658-16",
        completedAt: String? = iso(-600), undelivered: Bool = false
    ) -> DelegationJobSnapshot {
        DelegationJobSnapshot(
            id: id, source: "codex", agent: "codex",
            topicSlug: topic, state: "watching_turn", status: nil, runStatus: "completed",
            completedAt: completedAt, deliveryOutcome: undelivered ? "unknown" : nil,
            deliveryLost: nil, completionTextHead: "658.16 is complete on baseline f6895936."
        )
    }

    @Test func alarmRankIsOneWayAndOrdered() {
        #expect(DelegationOutcome.succeeded.alarmRank < DelegationOutcome.unknown.alarmRank)
        #expect(DelegationOutcome.unknown.alarmRank < DelegationOutcome.failed.alarmRank)
        #expect(DelegationOutcome.failed.alarmRank < DelegationOutcome.deliveryLost.alarmRank)
    }

    @Test func signatureNamesTheOutcomeButJobKeyStaysStable() throws {
        let finished = try #require(DelegationOutcomeCard.make(from: Self.codexJob(), now: Self.now))
        let preserved = try #require(DelegationOutcomeCard.make(
            from: Self.codexJob(undelivered: true), now: Self.now))
        #expect(finished.cardId == preserved.cardId)
        #expect(finished.jobKey == preserved.jobKey)
        #expect(finished.signature == "codex:cx-1:succeeded")
        #expect(preserved.signature == "codex:cx-1:unknown")
        #expect(preserved.severity == "actionable")
        // The JSON row carries the outcome-bearing signature and starts unread.
        guard case .object(let row) = preserved.toJSON() else { Issue.record("not an object"); return }
        #expect(row["error_signature"] == .string("codex:cx-1:unknown"))
        #expect(row["status"] == .string("unread"))
    }

    /// LIVE BUG PINNED (2026-08-21, 10 of 11 preserved replies): the job cards
    /// as "finished" while mid-delivery; when the 409 lands and it moves to
    /// undelivered/ it MUST card again as unconfirmed, same cardId, once.
    @Test func codexJobPreservedAfterBeingCardedFinishedIsCardedAgainAsUnconfirmed() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()  // seed

        let box = SnapshotBox([Self.codexJob(completedAt: Self.iso(-60))])
        let loop = makeLoop(cursor: path, jobs: { box.value }, recorder: recorder)
        _ = await loop.tickOutcome()
        #expect(recorder.cards.map(\.outcome) == [.succeeded])

        // The bridge preserves it: same id, now under undelivered/.
        box.value = [Self.codexJob(completedAt: Self.iso(-60), undelivered: true)]
        let outcome = await loop.tickOutcome()
        guard case .completed(let result) = outcome else { Issue.record("expected completed, got \(outcome)"); return }
        #expect(result?.contains("filed 1 delegation outcome card") == true)
        let perJob = recorder.cards.filter { $0.cardId != DelegationOutcomeCard.codexBacklogCardId }
        #expect(perJob.map(\.outcome) == [.succeeded, .unknown])
        #expect(perJob[0].cardId == perJob[1].cardId)
        #expect(perJob[1].title == "Codex outcome is unconfirmed")
        // The preserve tick also files the rolling backlog card (1 preserved).
        #expect(recorder.cards.contains { $0.cardId == DelegationOutcomeCard.codexBacklogCardId })
        let cursor = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(cursor.cardedOutcome(source: "codex", id: "cx-1") == .unknown)

        // Steady state: the same preserved job never cards a third time, and
        // the backlog card (filed on the preserve tick) does not re-file.
        let before = recorder.cards.count
        _ = await loop.tickOutcome()
        #expect(recorder.cards.count == before)
    }

    /// The rank is ONE-WAY: a job already carded under a worse outcome never
    /// downgrades to a "finished" card.
    @Test func outcomeNeverDowngradesAfterTheFact() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()
        let box = SnapshotBox([Self.codexJob(completedAt: Self.iso(-60), undelivered: true)])
        let loop = makeLoop(cursor: path, jobs: { box.value }, recorder: recorder)
        _ = await loop.tickOutcome()
        let perJob = recorder.cards.filter { $0.cardId != DelegationOutcomeCard.codexBacklogCardId }
        #expect(perJob.map(\.outcome) == [.unknown])
        box.value = [Self.codexJob(completedAt: Self.iso(-60), undelivered: false)]
        _ = await loop.tickOutcome()
        let perJobAfter = recorder.cards.filter { $0.cardId != DelegationOutcomeCard.codexBacklogCardId }
        #expect(perJobAfter.count == 1)
    }

    /// An id recorded by a pre-outcome cursor has no recorded outcome; the
    /// loop cannot prove what its card said, so it never re-cards it.
    @Test func legacyCursorIdsWithoutAnOutcomeNeverRecard() async throws {
        let path = cursorPath()
        // Hand-write a legacy cursor: carded_ids only, no carded_outcomes.
        let legacy = """
        {"version":1,"stores":{"codex":{"carded_ids":["cx-legacy"],"last_seen":"\(Self.iso(-3_600))"}}}
        """
        try legacy.write(to: path, atomically: true, encoding: .utf8)
        let recorder = CardRecorder()
        let loop = makeLoop(
            cursor: path,
            jobs: { [Self.codexJob(id: "cx-legacy", completedAt: Self.iso(-7_200), undelivered: true)] },
            recorder: recorder)
        _ = await loop.tickOutcome()
        #expect(recorder.cards.filter { $0.cardId != DelegationOutcomeCard.codexBacklogCardId }.isEmpty)
    }

    @Test func cursorRoundTripsCardedOutcomesAndBacklogKey() throws {
        let path = cursorPath()
        var cursor = DelegationOutcomeCursor()
        cursor.record(source: "codex", id: "a", stamp: Self.now, outcome: .succeeded)
        cursor.record(source: "codex", id: "a", stamp: nil, outcome: .unknown)  // upgrade overwrites
        cursor.record(source: "claude", id: "b", stamp: nil)  // no outcome recorded
        cursor.markStallAnnounced(source: "claude", id: "live-stuck")
        cursor.codexBacklogKey = "codex:undelivered-backlog:1:x"
        try cursor.write(to: path)
        let loaded = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(loaded.cardedOutcome(source: "codex", id: "a") == .unknown)
        #expect(loaded.cardedOutcome(source: "claude", id: "b") == nil)
        #expect(loaded.store("claude").announcedStallIDs == ["live-stuck"])
        #expect(loaded.codexBacklogKey == "codex:undelivered-backlog:1:x")
        #expect(loaded == cursor)
    }

    @Test func cursorEvictionDropsTheOutcomeWithTheId() {
        var cursor = DelegationOutcomeCursor()
        for i in 0..<(DelegationOutcomeCursor.cardedIDLimit + 3) {
            cursor.record(source: "codex", id: "job-\(i)", stamp: nil, outcome: .succeeded)
        }
        #expect(cursor.cardedOutcome(source: "codex", id: "job-0") == nil)
        #expect(cursor.store("codex").cardedOutcomes.count == DelegationOutcomeCursor.cardedIDLimit)
    }

    // MARK: - Codex undelivered backlog card

    @Test func backlogCardNamesCountOldestAndWhereWithoutRedelivering() throws {
        let jobs = [
            Self.codexJob(id: "new", topic: "mac-chat-658-16", completedAt: Self.iso(-3_600), undelivered: true),
            Self.codexJob(id: "old", topic: "continuum-583-takeover", completedAt: Self.iso(-9 * 86_400), undelivered: true),
            Self.codexJob(id: "in-flight", completedAt: Self.iso(-60), undelivered: false),
            Self.claudeSuccess(id: "c1"),
        ]
        let card = try #require(DelegationOutcomeCard.makeBacklog(jobs: jobs, now: Self.now))
        #expect(card.cardId == DelegationOutcomeCard.codexBacklogCardId)
        #expect(card.title == "Codex: 2 undelivered replies preserved")
        #expect(card.summary.contains("oldest 9d old"))
        #expect(card.severity == "info")
        #expect(card.jobKey.hasPrefix("codex:undelivered-backlog:2:\(Self.iso(-9 * 86_400)):"))
        // Deterministic across processes (never hashValue): same set → same key.
        #expect(DelegationOutcomeCard.makeBacklog(jobs: jobs.reversed(), now: Self.now)?.jobKey == card.jobKey)
        #expect(card.detail.contains("reply-jobs/undelivered/"))
        #expect(card.detail.contains("continuum-583-takeover"))
        #expect(card.detail.contains("mac-chat-658-16"))
        #expect(!card.detail.contains("in-flight"))
        #expect(card.detail.contains("NOTHING re-delivers"))
        // Oldest first in the listing.
        let oldIdx = try #require(card.detail.range(of: "continuum-583-takeover")?.lowerBound)
        let newIdx = try #require(card.detail.range(of: "mac-chat-658-16")?.lowerBound)
        #expect(oldIdx < newIdx)
    }

    /// Same count, same oldest, DIFFERENT membership (one reviewed reply
    /// removed, a newer one preserved) must move the key — otherwise the card's
    /// listing goes stale while claiming to track the directory (gpt-5.5 MED).
    @Test func backlogKeyMovesWhenMembershipChangesAtSameCountAndOldest() throws {
        let oldest = Self.codexJob(id: "oldest", completedAt: Self.iso(-9 * 86_400), undelivered: true)
        let a = Self.codexJob(id: "a", completedAt: Self.iso(-3_600), undelivered: true)
        let b = Self.codexJob(id: "b", completedAt: Self.iso(-1_800), undelivered: true)
        let before = try #require(DelegationOutcomeCard.makeBacklog(jobs: [oldest, a], now: Self.now))
        let after = try #require(DelegationOutcomeCard.makeBacklog(jobs: [oldest, b], now: Self.now))
        #expect(before.jobKey != after.jobKey)
        #expect(before.title == after.title)  // count and oldest unchanged — only the key moved
    }

    @Test func noBacklogMeansNoBacklogCard() {
        #expect(DelegationOutcomeCard.makeBacklog(jobs: [Self.codexJob(), Self.claudeSuccess()], now: Self.now) == nil)
    }

    @Test func backlogCardFilesOnChangeOnlyAndClearsOnceWhenEmpty() async throws {
        let path = cursorPath()
        let recorder = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: recorder).tickOutcome()  // seed
        let box = SnapshotBox([Self.codexJob(id: "p1", completedAt: Self.iso(-600), undelivered: true)])
        let loop = makeLoop(cursor: path, jobs: { box.value }, recorder: recorder)
        func backlogCards() -> [DelegationOutcomeCard] {
            recorder.cards.filter { $0.cardId == DelegationOutcomeCard.codexBacklogCardId }
        }

        _ = await loop.tickOutcome()
        #expect(backlogCards().map(\.title) == ["Codex: 1 undelivered reply preserved"])
        _ = await loop.tickOutcome()  // unchanged backlog: no re-file
        #expect(backlogCards().count == 1)

        box.value.append(Self.codexJob(id: "p2", completedAt: Self.iso(-300), undelivered: true))
        _ = await loop.tickOutcome()
        #expect(backlogCards().last?.title == "Codex: 2 undelivered replies preserved")
        #expect(backlogCards().last?.resolved == false)

        // Both reviewed and removed: ONE cleared card, already read, then quiet.
        box.value = []
        _ = await loop.tickOutcome()
        #expect(backlogCards().count == 3)
        #expect(backlogCards().last?.resolved == true)
        guard case .object(let row)? = backlogCards().last?.toJSON() else { Issue.record("no row"); return }
        #expect(row["status"] == .string("read"))
        _ = await loop.tickOutcome()
        #expect(backlogCards().count == 3)
        let cursor = try #require(DelegationOutcomeCursor.load(from: path))
        #expect(cursor.codexBacklogKey == nil)
    }

    @Test func failedBacklogCardWriteRetriesNextTick() async throws {
        let path = cursorPath()
        let failing = CardRecorder(accept: { _ in false })
        _ = await makeLoop(cursor: path, jobs: { [] }, recorder: failing).tickOutcome()
        let jobs = [Self.codexJob(id: "p1", completedAt: Self.iso(-7_200), undelivered: true)]
        // Cursor pre-seeded with the job so only the backlog card is in play.
        var cursor = try #require(DelegationOutcomeCursor.load(from: path))
        cursor.record(source: "codex", id: "p1", stamp: Self.now.addingTimeInterval(-7_200), outcome: .unknown)
        try cursor.write(to: path)
        let outcome = await makeLoop(cursor: path, jobs: { jobs }, recorder: failing).tickOutcome()
        guard case .completed(let result) = outcome else { Issue.record("expected completed, got \(outcome)"); return }
        #expect(result?.contains("backlog card write failed") == true)
        #expect(try #require(DelegationOutcomeCursor.load(from: path)).codexBacklogKey == nil)
        let succeeding = CardRecorder()
        _ = await makeLoop(cursor: path, jobs: { jobs }, recorder: succeeding).tickOutcome()
        #expect(succeeding.cards.map(\.cardId) == [DelegationOutcomeCard.codexBacklogCardId])
    }

    @Test func loopIdentityIsStable() {
        let loop = makeLoop(cursor: cursorPath(), jobs: { [] }, recorder: CardRecorder())
        #expect(loop.loopId == "delegation_outcome")
        #expect(loop.interval == 300)
    }

    @Test func defaultCursorPathLivesUnderLogs() {
        let root = URL(fileURLWithPath: "/tmp/fake-data-root")
        #expect(DelegationOutcomeLoop.defaultCursorPath(dataRoot: root).path
            == "/tmp/fake-data-root/logs/delegation_outcome_cursor.json")
    }
}

/// Mutable snapshot holder for the multi-tick tests (the loop's `readJobs` is a
/// `@Sendable` closure, so it cannot capture a `var` directly).
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [DelegationJobSnapshot]
    init(_ value: [DelegationJobSnapshot]) { self._value = value }
    var value: [DelegationJobSnapshot] {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class AttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

private final class TransitionReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var storage: [String] = []
    init(results: [Bool]) { self.results = results }
    func observe(_ job: DelegationJobSnapshot) -> Bool {
        lock.withLock {
            storage.append(job.id)
            return results.isEmpty ? true : results.removeFirst()
        }
    }
    var ids: [String] { lock.withLock { storage } }
}
