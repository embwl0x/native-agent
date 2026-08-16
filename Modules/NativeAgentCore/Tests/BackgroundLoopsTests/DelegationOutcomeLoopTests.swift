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

    @Test func codexTurnResultStatusDrivesTheOutcome() {
        let job = DelegationJobSnapshot(
            id: "codex-1", source: "codex", agent: "codex",
            topicSlug: "hermes-pr", state: "watching_turn", status: nil,
            runStatus: "completed", completedAt: Self.iso(-300),
            deliveryOutcome: nil, deliveryLost: nil,
            completionTextHead: "Resolved Hermes PR #65084.")
        #expect(job.terminalOutcome == .succeeded)
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
        #expect(obj["error_signature"] == .string("claude:job-1"))
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
        #expect(result?.contains("no newly-terminal") == true)
        #expect(recorder.cards.isEmpty)
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
