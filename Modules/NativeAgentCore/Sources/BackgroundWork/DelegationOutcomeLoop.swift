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
    public let wake: OrganWake
    public var tickTimeoutOverride: TimeInterval? { 120 }

    private let readJobs: @Sendable () async -> DelegationJobsRead
    /// Failed publication leaves the job uncarded for the next reconciliation.
    private let fileCard: @Sendable (DelegationOutcomeCard, DelegationJobsRead) async -> Bool
    /// Records downstream transition evidence. `false` keeps the cursor
    /// unsettled so the same transition is retried on the next reconciliation.
    private let observeTransition: @Sendable (DelegationReadout) async -> Bool
    /// Reports a healthy per-tick cap remainder after the cursor is durable.
    /// The owner requests one coalesced continuation. Failed settlement or
    /// unavailable state waits for a source/repair event or the integrity pass.
    private let reportDeferral: @Sendable (Bool) async -> Void
    private let readHandledOutcomes: @Sendable () async throws -> Set<String>
    private let cursorPath: URL
    private let clock: @Sendable () -> Date

    /// Bound inbox bursts after restore or cursor loss; the tick names every capped remainder.
    public static let maxCardsPerTick = 10

    public init(
        wake: OrganWake,
        cursorPath: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        readJobsWithAvailability: @escaping @Sendable () async -> DelegationJobsRead,
        fileCard: @escaping @Sendable (DelegationOutcomeCard, DelegationJobsRead) async -> Bool,
        observeTransition: @escaping @Sendable (DelegationReadout) async -> Bool = { _ in true },
        reportDeferral: @escaping @Sendable (Bool) async -> Void = { _ in },
        readHandledOutcomes: @escaping @Sendable () async throws -> Set<String> = { throw CocoaError(.fileReadCorruptFile) }
    ) {
        self.wake = wake
        self.cursorPath = cursorPath
        self.clock = clock
        self.readJobs = readJobsWithAvailability
        self.fileCard = fileCard
        self.observeTransition = observeTransition
        self.reportDeferral = reportDeferral
        self.readHandledOutcomes = readHandledOutcomes
    }
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
        guard stampsMayAdvance else { return .failed(error: read.availabilityError ?? unreadableStoreError) }
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
                recoveryNote = """
                    corrupt delegation cursor preserved at \(backup.lastPathComponent); rebuilt from canonical notification and settlement identities; unseen \
                    outcomes remain pending
                    """
                wasSeeded = false
                seedResult = nil
            } catch {
                return .failed(error: """
                    delegation outcome cursor unavailable and preserved; restore readable cursor or canonical notifications before retrying: \
                    \(error.localizedDescription)
                    """)
            }
        }
        // Stalls are reversible warnings, never terminal outcomes.
        // The projector owns liveness; only warning settlement is tracked here.
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
                // Re-card only a proven escalation; an unrecorded prior outcome cannot prove its severity.
                guard let recorded = cursor.cardedOutcome(source: job.source, id: job.id),
                      let current = job.terminalOutcome else { return false }
                return current.alarmRank > recorded.alarmRank
            }
            return true
        }
        // Oldest-first insertion preserves completion order in the newest-last inbox.
        let ordered = pending.sorted {
            ($0.completionStamp ?? .distantPast, $0.id) < ($1.completionStamp ?? .distantPast, $1.id)
        }
        // Current stalls take priority over terminal-history bursts within the shared card budget.
        let outcomeCapacity = max(0, Self.maxCardsPerTick - livenessBatch.count)
        let batch = ordered.prefix(outcomeCapacity)
        let deferred = ordered.count - batch.count

        var filed = 0
        var failed = 0
        var receiptsRecorded = 0
        for job in batch {
            // These dispositions require cursor acknowledgement without a card or downstream settlement.
            if ["delivered", "owed", "sent_unconfirmed", "failed_before_answer", "let_go", "dry_run"].contains(job.deliveryOutcome ?? "") {
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
            // Idle ticks must not refresh successful-work age.
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
            // Cards landed without their cursor; surface the failure before a retry repeats them.
            return .failed(error: "delegation outcome cursor write failed after \(filed) card(s): \(error)")
        }
        // Publish capped work only after durable cursor progress to avoid a failed-write retry loop.
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
