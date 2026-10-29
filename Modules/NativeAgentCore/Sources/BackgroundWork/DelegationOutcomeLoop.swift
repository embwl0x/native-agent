import Foundation
import NativeAgentShared
import AgentWorkspace
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DelegationOutcomeLoop.swift` | One delegation reconciliation/settlement runner; dry runs advance without a card or delegation settlement |
public struct DelegationOutcomeLoop: LoopRunner {
    public let loopId: String = "delegation_outcome"
    public static let workRemaining = Notification.Name("NativeAgent.delegation.outcomeWorkRemaining")
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 120 }

    /// Reads both wake-job stores. Injected — see the dependency note at the
    /// top of this file.
    private let readJobs: @Sendable () async -> DelegationJobsRead
    /// Upserts one inbox card. Returns whether the row actually landed; a
    /// `false` leaves the job un-carded so the next tick retries it.
    private let fileCard: @Sendable (DelegationOutcomeCard, DelegationJobsRead) async -> Bool
    /// Records downstream transition evidence. `false` keeps the cursor
    /// unsettled so the same transition is retried on the next reconciliation.
    private let observeTransition: @Sendable (DelegationReadout) async -> Bool
    /// Reports a healthy per-tick cap remainder after the cursor is durable.
    /// The owner requests one coalesced continuation. Failed settlement or
    /// unavailable state waits for a source/repair event or the integrity sweep.
    private let reportDeferral: @Sendable (Bool) async -> Void
    private let readHandledOutcomes: @Sendable () async throws -> Set<String>
    private let cursorPath: URL
    private let clock: @Sendable () -> Date

    /// Cards filed per tick. A ceiling exists so a store that suddenly reveals
    /// a hundred terminal jobs (a restored backup, a cursor reset) cannot dump
    /// a hundred rows into the inbox at once. Never silent — the tick outcome
    /// names the remainder (`no_silent_caps`).
    public static let maxCardsPerTick = 10

    public init(
        interval: TimeInterval = 5 * 60,
        cursorPath: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        readJobsWithAvailability: @escaping @Sendable () async -> DelegationJobsRead,
        fileCard: @escaping @Sendable (DelegationOutcomeCard, DelegationJobsRead) async -> Bool,
        observeTransition: @escaping @Sendable (DelegationReadout) async -> Bool = { _ in true },
        reportDeferral: @escaping @Sendable (Bool) async -> Void = { _ in },
        readHandledOutcomes: @escaping @Sendable () async throws -> Set<String> = { throw CocoaError(.fileReadCorruptFile) }
    ) {
        self.interval = interval
        self.cursorPath = cursorPath
        self.clock = clock
        self.readJobs = readJobsWithAvailability
        self.fileCard = fileCard
        self.observeTransition = observeTransition
        self.reportDeferral = reportDeferral
        self.readHandledOutcomes = readHandledOutcomes
    }
    /// Conventional cursor location under a data root.
    public static func defaultCursorPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("delegation_outcome_cursor.json")
    }
    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        let read = await readJobs()
        let jobs = read.jobs
        let stampsMayAdvance = read.allStoresReadable
        let unreadableStoreError = "a delegation store (directory, job file, or delivery "
            + "ledger line) could not be read this tick; repair its storage and retry outcome reconciliation"
        let terminal = jobs.filter { $0.isTerminal }
        let wasSeeded: Bool
        let seedResult: String?
        var recoveryNote: String?

        // Only absent storage seeds history. Corruption reconciles actual
        // notification identities and downstream settlement before replacement.
        var cursor: DelegationOutcomeCursor
        do {
            if let loaded = try DelegationOutcomeCursor.load(from: cursorPath) {
                cursor = loaded
                wasSeeded = false
                seedResult = nil
            } else {
                guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
                cursor = DelegationOutcomeCursor()
                for job in terminal {
                    cursor.record(source: job.source, id: job.id,
                                  outcome: job.terminalOutcome, deliveryReceiptVersion: job.deliveryReceiptVersion)
                }
                wasSeeded = true
                seedResult = "seeded delegation outcome cursor over \(terminal.count) pre-existing terminal job(s); no outcome cards filed"
            }
        } catch {
            guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
            do {
                let handled = try await readHandledOutcomes()
                cursor = DelegationOutcomeCursor()
                for job in terminal {
                    guard let outcome = job.terminalOutcome,
                          handled.contains("\(job.source):\(job.id):\(outcome.rawValue)") else { continue }
                    guard await observeTransition(job) else {
                        return .failed(error: "corrupt delegation cursor preserved; canonical outcome settlement failed for \(job.source):\(job.id)")
                    }
                    cursor.record(source: job.source, id: job.id, outcome: outcome)
                }
                let backup = cursorPath.appendingPathExtension("corrupt.\(UUID().uuidString)")
                try FileManager.default.copyItem(at: cursorPath, to: backup)
                recoveryNote = "corrupt delegation cursor preserved at \(backup.lastPathComponent); rebuilt from canonical notification and settlement identities; unseen outcomes remain pending"
                wasSeeded = false
                seedResult = nil
            } catch {
                return .failed(error: "delegation outcome cursor unavailable and preserved; restore readable cursor or canonical notifications before retrying: \(error.localizedDescription)")
            }
        }
        if stampsMayAdvance {
            for job in terminal {
                guard let boundary = cursor.store(job.source).legacyLastSeen,
                      let completed = job.completionStamp, completed <= boundary else { continue }
                // A reply arriving after the old completion boundary is new evidence.
                if let version = job.deliveryReceiptVersion {
                    guard let arrival = DelegationOutcomeCursor.parseISO(String(version.prefix { $0 != "|" })),
                          arrival <= boundary else { continue }
                }
                if !cursor.store(job.source).cardedIDs.contains(job.id) {
                    cursor.record(source: job.source, id: job.id, outcome: job.terminalOutcome,
                                  deliveryReceiptVersion: job.deliveryReceiptVersion)
                } else if let version = job.deliveryReceiptVersion,
                          cursor.store(job.source).deliveryReceiptVersions[job.id] == nil {
                    cursor.stores[job.source]?.deliveryReceiptVersions[job.id] = version
                }
            }
            for source in cursor.stores.keys { cursor.stores[source]?.legacyLastSeen = nil }
        }
        // Stuck liveness is not a terminal outcome. It gets its own reversible
        // cursor bit so the first real stall speaks once, recovered liveness
        // clears the warning, and a later stall can speak again. The verdict
        // itself came from DelegationStatusProjector; this loop never invents
        // another timeout or state machine.
        let newlyStalled = jobs.filter { job in
            job.stalled && !job.isTerminal
                && !cursor.store(job.source).announcedStallIDs.contains(job.id)
        }.sorted { ($0.source, $0.id) < ($1.source, $1.id) }
        let recovered = jobs.filter { job in
            !job.stalled && !job.isTerminal
                && cursor.store(job.source).announcedStallIDs.contains(job.id)
        }.sorted { ($0.source, $0.id) < ($1.source, $1.id) }

        var livenessFiled = 0
        var livenessFailed = 0
        let livenessPending = newlyStalled.map { (job: $0, stalled: true) }
            + recovered.map { (job: $0, stalled: false) }
        let livenessBatch = livenessPending.prefix(Self.maxCardsPerTick)
        for entry in livenessBatch {
            let card = entry.stalled
                ? DelegationOutcomeCard.makeStalled(from: entry.job, now: now)
                : DelegationOutcomeCard.makeStallCleared(from: entry.job, now: now)
            guard let card else { continue }
            if await fileCard(card, read), await observeTransition(entry.job) {
                if entry.stalled {
                    cursor.markStallAnnounced(source: entry.job.source, id: entry.job.id)
                } else {
                    cursor.clearStallAnnouncement(source: entry.job.source, id: entry.job.id)
                }
                livenessFiled += 1
            } else {
                livenessFailed += 1
                break
            }
        }
        let livenessDeferred = livenessPending.count - livenessBatch.count

        let pending = terminal.filter { job in
            let store = cursor.store(job.source)
            if store.cardedIDs.contains(job.id) {
                if let version = job.deliveryReceiptVersion,
                   store.deliveryReceiptVersions[job.id] != version { return true }
                // Already carded. It cards AGAIN only when the outcome it now
                // presents is more alarming than the one it was carded under
                // (finished → unconfirmed once the codex reply is preserved).
                // An id with no recorded outcome predates that field and
                // stays settled: the cursor cannot prove what its card said.
                guard let recorded = cursor.cardedOutcome(source: job.source, id: job.id),
                      let current = job.terminalOutcome else { return false }
                return current.alarmRank > recorded.alarmRank
            }
            return true
        }
        // Oldest first: the inbox reads newest-last, and a burst should land in
        // the order the work actually finished.
        let ordered = pending.sorted {
            ($0.completionStamp ?? .distantPast, $0.id) < ($1.completionStamp ?? .distantPast, $1.id)
        }
        // Liveness warnings take the shared per-tick card budget first: a job
        // that is stuck now should not sit silent behind a terminal-history
        // burst. Terminal outcomes remain ordered oldest-first in the space
        // left this tick.
        let outcomeCapacity = max(0, Self.maxCardsPerTick - livenessBatch.count)
        let batch = ordered.prefix(outcomeCapacity)
        let deferred = ordered.count - batch.count

        var filed = 0
        var failed = 0
        var receiptsRecorded = 0
        for job in batch {
            // These dispositions need only cursor acknowledgement here, without
            // an outcome card or downstream delegation settlement.
            if ["delivered", "owed", "sent_unconfirmed", "failed_before_answer", "legacy_before_receipts", "let_go", "dry_run"].contains(job.deliveryOutcome ?? "") {
                guard await observeTransition(job) else {
                    failed += 1
                    break
                }
                cursor.record(source: job.source, id: job.id, outcome: job.terminalOutcome,
                              deliveryReceiptVersion: job.deliveryReceiptVersion)
                cursor.clearStallAnnouncement(source: job.source, id: job.id)
                receiptsRecorded += 1
                continue
            }
            guard let card = DelegationOutcomeCard.make(from: job, now: now) else { continue }
            if await fileCard(card, read), await observeTransition(job) {
                cursor.record(source: job.source, id: job.id,
                              outcome: card.outcome, deliveryReceiptVersion: job.deliveryReceiptVersion)
                cursor.clearStallAnnouncement(source: job.source, id: job.id)
                filed += 1
            } else {
                // Stop on failed settlement; exact identity remains pending.
                failed += 1
                break
            }
        }
        if pending.isEmpty && livenessPending.isEmpty {
            await reportDeferral(false)
            if wasSeeded || recoveryNote != nil {
                do {
                    try cursor.write(to: cursorPath)
                } catch {
                    return .failed(error: "delegation outcome cursor seed failed: \(error)")
                }
                guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
                if let recoveryNote { return .failed(error: recoveryNote) }
                return .completed(result: seedResult)
            }
            guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
            // Nothing settled, nothing stuck, nothing filed. The cursor was not
            // even rewritten — this tick did no work, and calling it
            // `.completed` is what let a lane that files a card once a month
            // read as freshly successful every two minutes.
            return .skipped(
                reason: "no newly-terminal or stuck delegated jobs (\(terminal.count) terminal on record)")
        }
        let writeFailures = failed + livenessFailed
        let failureDeferred = max(0, batch.count - filed - failed - receiptsRecorded)
        let livenessFailureDeferred = max(0, livenessBatch.count - livenessFiled - livenessFailed)
        let totalDeferred = deferred + failureDeferred + livenessDeferred + livenessFailureDeferred
        do {
            try cursor.write(to: cursorPath)
        } catch {
            // The cards landed; the cursor did not. Report it as a failure so
            // the loop's own health surface shows it — the next tick would
            // otherwise re-file everything this tick just filed.
            return .failed(error: "delegation outcome cursor write failed after \(filed) card(s): \(error)")
        }
        // A cap leaves known, selectable work behind; a failure does not.
        // Publish only after the cursor advances, so a failed write cannot
        // turn the same unsettled batch into a self-sustaining retry loop.
        await reportDeferral(!Task.isCancelled && stampsMayAdvance && writeFailures == 0
            && recoveryNote == nil && deferred + livenessDeferred > 0
            && filed + livenessFiled + receiptsRecorded > 0)

        var result = "filed \(filed) delegation outcome card(s)"
        if let recoveryNote { result += "; \(recoveryNote)" }
        if livenessFiled > 0 { result += "; filed \(livenessFiled) delegation liveness card(s)" }
        if let seedResult { result += "; \(seedResult)" }
        if writeFailures > 0 {
            result += "; \(writeFailures) outcome settlement write(s) failed and will retry next tick"
        }
        if totalDeferred > 0 { result += "; \(totalDeferred) more deferred for contiguous settlement" }
        // Settlement write failures make the tick fail so loop health reports them.
        if writeFailures > 0 || recoveryNote != nil {
            return .failed(error: result)
        }
        if !stampsMayAdvance {
            return .failed(error: "\(result); \(unreadableStoreError)")
        }
        if filed == 0 && livenessFiled == 0 && failed == 0 && livenessFailed == 0 {
            return .skipped(reason: "no delegation outcome or liveness card could be classified")
        }
        return .completed(result: result)
    }
}
