import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Desk
import CognitiveSubstrate
// Blueprint: | `WorkshopPump.swift` | `WorkshopPump` tick and live/recovered receipt settlement through Desk’s ops lock; status changes require the latest reservation on a nonterminal item and receipt-only recovery requires its unchanged commit revision |

// Each Desk/body event or two-hour window can admit one due session after
// autonomy, organism, lease and durable reservation gates. Quiet ticks spend
// no provider calls; settlement records the session in Desk and the receipt feed.

public struct WorkshopPump: Sendable {
    let dataRoot: URL
    let store: SwiftNativeDeskStore
    let lease: BackgroundWorkLease
    let receiptLog: WorkshopReceiptLog
    let sessionRunner: WorkshopSession
    /// Missing or disabled organism posture prevents new sessions.
    let posture: @Sendable () async -> OrganismBehaviorPosture?
    /// enableAutonomy gate — expensive autonomous work requires it, mirroring
    /// the Workshop execution executor gate.
    let isEnabled: @Sendable () async -> Bool
    let now: @Sendable () -> Date

    public init(
        dataRoot: URL,
        store: SwiftNativeDeskStore,
        lease: BackgroundWorkLease,
        receiptLog: WorkshopReceiptLog,
        sessionRunner: WorkshopSession,
        posture: @escaping @Sendable () async -> OrganismBehaviorPosture?,
        isEnabled: @escaping @Sendable () async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.store = store
        self.lease = lease
        self.receiptLog = receiptLog
        self.sessionRunner = sessionRunner
        self.posture = posture
        self.isEnabled = isEnabled
        self.now = now
    }

    /// Why a tick did not run a session. `.ran`
    /// carries the receipt written.
    public enum TickOutcome: Sendable, Equatable {
        case disabled           // enableAutonomy off
        /// The organism cannot provide a posture at all. This is deliberately
        /// distinct from a conservative/disabled posture so observability can
        /// say whether the body is absent or actively withholding work.
        case organismUnavailable
        case postureNotNormal   // organism not in a green window
        case quiet              // nothing due — ZERO dispatch
        case unavailable(String) // canonical storage could not be read or settled
        case leaseHeld          // background-work lease already spent this window
        case reservationRefused // canonical reservation/durability refusal — ZERO LLM
        case ran(WorkshopSessionStatus)
    }

    /// The pass, and beside it every cadence whose timing is unknown (an
    /// unreadable next-refresh time): those items alone are left out.
    @discardableResult
    public func tick() async -> (outcome: TickOutcome, unknownTiming: [String]) {
        var unknown: [String] = []
        do {
            return (try await tickChecked(unknownTiming: &unknown), unknown)
        } catch {
            return (.unavailable(String(error.localizedDescription.prefix(600))), unknown)
        }
    }

    private func tickChecked(unknownTiming: inout [String]) async throws -> TickOutcome {
        // ---- 1. ZERO-EFFECT DURABLE REPAIR ----
        // Repair admitted/terminal bookkeeping even when new autonomous work
        // is disabled or the machine is conserving resources. This crosses no
        // provider/tool boundary and prevents disabled mode from preserving
        // zombie reservations forever.
        var state = try await store.liveState()

        // Finish any terminal result that was durably produced before a prior
        // process exited. A claimed attempt with no result is settled blocked:
        // replaying it could duplicate tool effects, while leaving it open
        // forever creates a zombie reservation.
        try await reconcileAttempts(from: state)
        state = try await store.liveState()

        // Exhausted/expired pursuits close under their abandon condition so
        // they release open-pursuit capacity. Refused settlement stays pending.
        for item in state.items {
            guard item.isPursuit, item.origin == .agent, !item.status.isTerminal,
                  let p = item.pursuit,
                  p.sessionsUsed(in: item.workAttempts) >= p.maxSessions || (item.pursuitExpiresAt.map { now() >= $0 } ?? false) else { continue }
            // Close only a still-live, unchanged item under the Desk ops lock.
            if let satisfied = item.workAttempts.last(where: {
                $0.lane == .pursuit && $0.disposition == .goalSatisfied && $0.completedAt != nil
            }), verifyArtifactRefs(satisfied.artifactRefs, handle: item.handle) {
                _ = try await store.closePursuitIfGoalSatisfied(
                    item.handle,
                    reservationId: satisfied.attemptId,
                    expectedUpdatedAt: item.updatedAt,
                    outcomeSummary: satisfied.receipt ?? "Pursuit goal satisfied."
                )
            } else {
                _ = try await store.closeItemIfUnchanged(
                    item.handle,
                    expectedUpdatedAt: item.updatedAt,
                    outcomeSummary: "abandon-condition close: pursuit budget exhausted "
                        + "(\(p.sessionsUsed(in: item.workAttempts))/\(p.maxSessions) sessions, \(p.maxDays) day lifetime) with no verified completion — "
                        + "closed per the pursuit's own abandon condition.",
                    canceled: true
                )
            }
        }

        state = try await store.liveState()

        // ---- 2. NEW-WORK GATES ----
        guard await isEnabled() else { return .disabled }

        guard let posture = await posture() else {
            return .organismUnavailable
        }
        guard posture.enabled else { return .postureNotNormal }

        // isDue already leaves these out of selection; the pass names them.
        unknownTiming = Self.unreadableCadences(in: state)
        guard let candidate = try Self.selectDueItem(from: state, now: now()) else {
            return .quiet   // quiet day → zero dispatch
        }

        // ---- 3. LEASE — one expensive background task per green window ----
        let window = Self.windowKey(now())
        guard await lease.tryAcquire(holder: "workshop", window: window) else {
            return .leaseHeld
        }

        // ---- 4. RESERVE FIRST — before any session/LLM work ----
        let day = DeskClock.dayStamp(now())
        let reservationId: String
        do {
            reservationId = try await store.reserveWorkAttempt(candidate.handle,
                lane: candidate.isPursuit ? .pursuit : .ownerCadence, day: day, slot: window)
        } catch {
            // A refused admission performed no work, so return this pump's own
            // lease claim. A due owner item must not burn the entire green
            // window merely because its typed attempt could not be written.
            _ = await lease.releaseUnused(holder: "workshop", window: window)
            return .reservationRefused
        }
        // Desk's O_APPEND return establishes ordering but does not itself call
        // fsync. Flush the canonical op log, then re-read the reservation before
        // crossing the provider boundary. Failure spends zero tokens; settle
        // the unclaimed reservation now if storage is readable, or on its next
        // recovery edge.
        do {
            guard WorkshopReservationDurability.flush(store.opsPath) else {
                throw WorkshopExecutionError.persistenceFailure("Desk reservation log could not be flushed; restore Desk storage before continuing work")
            }
            let reservedState = try await store.liveState()
            guard let reservedItem = reservedState.items.first(where: { $0.handle == candidate.handle }),
                  Self.hasLiveAttempt(reservationId, on: reservedItem) else {
                throw WorkshopExecutionError.persistenceFailure("Desk reservation is no longer live; inspect its saved settlement before continuing work")
            }
        } catch {
            _ = await lease.releaseUnused(holder: "workshop", window: window)
            let pending = try await store.liveState()
            try await reconcileAttempts(from: pending)
            throw error
        }

        // Record the pursuit choice before running; log any failed rationale write.
        if candidate.isPursuit, !candidate.choiceRationale.isEmpty {
            do {
                _ = try await store.appendWorkReceipt(candidate.handle, receipt: "chose: \(candidate.choiceRationale)")
            } catch {
                nativeLog("[workshop] choice rationale not recorded for %@: %@",
                      candidate.handle, String(describing: error))
            }
        }

        // ---- 5. RUN one bounded session, then close it out + receipt ----
        let request = WorkshopSessionRequest(
            handle: candidate.handle,
            reservationId: reservationId,
            promptSeed: candidate.promptSeed
        )
        let receipt = await sessionRunner.run(request)

        // Close the reserved slot with a compact receipt on the pursuit, and
        // append the per-session row. Best-effort: a store hiccup must not
        // wedge the loop.
        do {
            try await settleSessionReceipt(receipt, isPursuit: candidate.isPursuit)
        } catch {
            nativeLog("[workshop] terminal receipt settlement failed for %@/%@: %@",
                  candidate.handle, reservationId, String(describing: error))
        }

        return .ran(receipt.status)
    }

    public static func hasLiveAttempt(_ id: String, on item: DeskItem) -> Bool {
        if let attempt = item.workAttempts.first(where: { $0.attemptId == id }) {
            return attempt.completedAt == nil
        }
        return false
    }

    private func verifyArtifactRefs(_ refs: [String], handle: String) -> Bool {
        guard !refs.isEmpty else { return false }
        let reader = WorkshopArtifactWriter(dataRoot: dataRoot, handle: handle)
        return refs.allSatisfy { reader.isReadable(relativePath: $0) }
    }

    private func settleSessionReceipt(_ receipt: WorkshopSessionReceipt, isPursuit: Bool) async throws {
        let disposition: DeskWorkDisposition = isPursuit && receipt.disposition == .goalSatisfied &&
            !verifyArtifactRefs(receipt.artifactPaths, handle: receipt.handle) ? .progress : receipt.disposition
        // Every blocked disposition parks work, including failed/timed-out turns.
        let deskSettlement: Result<Void, Error>
        do {
            try await store.settleWorkshopSession(
                receipt.handle, reservationId: receipt.reservationId,
                receipt: "[\(receipt.status.rawValue)] \(receipt.summary)", disposition: disposition,
                artifactRefs: receipt.artifactPaths, outcomeSummary: receipt.summary,
                blockedReason: disposition == .blocked
                    ? String(receipt.summary.prefix(600)) : nil)
            deskSettlement = .success(())
        } catch {
            deskSettlement = .failure(error)
        }
        let receiptSettled = await receiptLog.append(receipt)
        try deskSettlement.get()
        guard receiptSettled else {
            throw WorkshopExecutionError.persistenceFailure("Workshop receipt \(receipt.handle)/\(receipt.reservationId) could not be persisted; restore Workshop storage before continuing work")
        }
        try await store.handOffWorkReceipt(receipt.handle, reservationId: receipt.reservationId)
        WorkshopSessionResultStore(dataRoot: dataRoot).remove(reservationId: receipt.reservationId)
    }

    private func reconcileAttempts(from state: DeskState) async throws {
        let results = WorkshopSessionResultStore(dataRoot: dataRoot)
        let claims = WorkshopReservationClaimStore(dataRoot: dataRoot)
        var loggedReservations: [String: Set<String>]?
        for item in state.items {
            let attempts = item.workAttempts.map {
                (id: $0.attemptId, ownerCadence: $0.lane == .ownerCadence,
                 completed: $0.completedAt != nil, handedOff: $0.receiptHandedOff)
            }
            for attempt in attempts {
                if !results.hasClaim(reservationId: attempt.id) {
                    if attempt.completed { continue }
                    guard claims.claim(handle: item.handle, reservationId: attempt.id, unstarted: true)
                            || results.hasClaim(reservationId: attempt.id) else {
                        throw WorkshopExecutionError.persistenceFailure("Workshop reservation \(attempt.id) could not be reconciled; restore its claim storage before continuing work")
                    }
                }
                let attemptId = attempt.id
                let unstarted = try claims.isUnstarted(reservationId: attemptId)
                let durable = results.load(reservationId: attemptId)
                if durable == nil, results.hasResult(reservationId: attemptId) {
                    throw WorkshopExecutionError.persistenceFailure("Workshop terminal result \(item.handle)/\(attemptId) is unreadable; restore it before continuing work")
                }
                if attempt.completed, durable == nil {
                    if attempt.handedOff { continue }
                    if loggedReservations == nil {
                        loggedReservations = try await receiptLog.reservationIdsByHandle()
                    }
                    if loggedReservations?[item.handle]?.contains(attemptId) == true {
                        try await store.handOffWorkReceipt(item.handle, reservationId: attemptId)
                    }
                    continue
                }
                let receipt = (unstarted ? nil : durable) ?? WorkshopSessionReceipt(
                    handle: item.handle,
                    reservationId: attemptId,
                    status: unstarted ? .refused : .blocked,
                    summary: unstarted
                        ? "reservation was interrupted before execution admission; no work ran and its budget charge was released"
                        : "execution was durably admitted but interrupted before a terminal result; not replayed to avoid duplicate effects",
                    model: nil,
                    artifactPaths: [],
                    generatedAt: now(),
                    disposition: unstarted ? .unstarted : .blocked
                )
                if !attempt.completed, unstarted || durable == nil {
                    guard results.save(receipt) else {
                        throw WorkshopExecutionError.persistenceFailure("Workshop recovery result \(attemptId) could not be persisted; restore Workshop storage before continuing work")
                    }
                }
                try await settleSessionReceipt(receipt, isPursuit: !attempt.ownerCadence)
            }
        }
    }

}
