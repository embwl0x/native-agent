import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import CognitiveSubstrate

// Wave B — the pump (H3, H4, M8). The only new moving part, and it does ZERO
// LLM work itself: a quiet day (nothing due) makes ZERO provider calls.
//
// On each Desk/body event or exact two-hour Workshop window the pump:
//   1. GATE (H4): run only when the organism posture is `normal` — workshop is
//      EXPENSIVE, stricter than backgroundCognitionAllowed's conserve/sleep
//      string-match. Plus enableAutonomy, low-power, and thermal checks.
//   2. SELECT one due item from a pure read of SwiftNativeDeskStore.liveState() — self-
//      pursuits (origin=agent) within budget, least-recently-worked first;
//      else owner cadence items. A real selection scorer is Wave C (seam below).
//   3. LEASE (H4): acquire the shared background-work lease for this green
//      window so reflection + replay + workshop can't all fire in one window.
//   4. RESERVE FIRST (H3): SwiftNativeDeskStore.reserveWorkSession BEFORE any session/LLM.
//      A refused reservation (cap hit, or a non-pursuit that can't reserve
//      under Wave A's store) means skip — zero LLM spend.
//   5. RUN one bounded session (WorkshopSession) with an unforgeable
//      triggerSource, then completeWorkSession + write a compact receipt (M8).

/// A due item the pump chose to work. `promptSeed` carries only bounded strings
/// (title / why / doneLooksLike) — no persona bytes.
public struct WorkshopCandidate: Sendable, Equatable {
    public let handle: String
    public let title: String
    public let promptSeed: String
    public let isPursuit: Bool
    /// The recorded volition (Wave C): why THIS pursuit was chosen over the
    /// others this tick — score + the runners-up it beat. Empty for a User
    /// cadence item (no choice was made; it was simply due). Written to the
    /// workshop receipt so the selection is auditable, never a silent queue.
    public var choiceRationale: String = ""
}

/// A pursuit's blended selection score and its components — a pure read of
/// desk-intrinsic signals (Wave C). Higher wins. Deliberately does NOT yet
/// include FELT SALIENCE (needs a cognitive-substrate read the pure pump
/// can't do here); that input lands in C2 and only RAISES a pursuit's score,
/// so adding it later cannot make today's choices wrong, only richer.
public struct PursuitChoiceScore: Sendable, Equatable {
    public let handle: String
    public let alias: String
    public let evidenceStrength: Double   // dossier breadth × source diversity
    public let momentum: Double           // completed work over the pursuit's life
    public let closureProximity: Double   // how near its doneLooksLike budget
    public let noProgressPenalty: Double  // reserved-but-never-completed drag
    public let recentAttentionPenalty: Double // worked very recently → yield, spread
    public var total: Double {
        evidenceStrength + momentum + closureProximity - noProgressPenalty - recentAttentionPenalty
    }
}

public struct WorkshopPump: Sendable {
    let dataRoot: URL
    let store: SwiftNativeDeskStore
    let lease: BackgroundWorkLease
    let receiptLog: WorkshopReceiptLog
    let sessionRunner: any WorkshopSessionRunning
    /// Organism posture (H4). nil = organism disabled → the pump stays inert
    /// (workshop is organism-gated by construction; a Wave-C toggle could relax).
    let posture: @Sendable () async -> OrganismBehaviorPosture?
    /// enableAutonomy gate — expensive autonomous work requires it, mirroring
    /// the Workshop execution executor gate.
    let isEnabled: @Sendable () async -> Bool
    let now: @Sendable () -> Date
    let flushReservationLog: @Sendable (URL) -> Bool

    public init(
        dataRoot: URL,
        store: SwiftNativeDeskStore,
        lease: BackgroundWorkLease,
        receiptLog: WorkshopReceiptLog,
        sessionRunner: any WorkshopSessionRunning,
        posture: @escaping @Sendable () async -> OrganismBehaviorPosture?,
        isEnabled: @escaping @Sendable () async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        flushReservationLog: @escaping @Sendable (URL) -> Bool = WorkshopReservationDurability.flush
    ) {
        self.dataRoot = dataRoot
        self.store = store
        self.lease = lease
        self.receiptLog = receiptLog
        self.sessionRunner = sessionRunner
        self.posture = posture
        self.isEnabled = isEnabled
        self.now = now
        self.flushReservationLog = flushReservationLog
    }

    /// Why a tick did NOT run a session (used by tests + observability). `.ran`
    /// carries the receipt written.
    public enum TickOutcome: Sendable, Equatable {
        case disabled           // enableAutonomy off
        case postureNotNormal   // organism not in a green window (H4)
        case resourcePressure   // low power / thermal
        case quiet              // nothing due — ZERO dispatch
        case leaseHeld          // background-work lease already spent this window (H4)
        case reservationRefused // cap hit or non-pursuit — ZERO LLM (H3)
        case ran(WorkshopSessionStatus)
    }

    @discardableResult
    public func tick() async -> TickOutcome {
        // ---- 1. GATE ----
        guard await isEnabled() else { return .disabled }

        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return .resourcePressure }
        switch process.thermalState {
        case .serious, .critical: return .resourcePressure
        default: break
        }

        // H4: workshop is EXPENSIVE — only a `normal` loop budget qualifies. A
        // conserve/sleep posture, or no posture at all (organism off), defers.
        guard let posture = await posture(),
              posture.enabled,
              posture.loopBudget == .normal else {
            return .postureNotNormal
        }

        // ---- 2. SELECT (pure read — no LLM, no reservation yet) ----
        guard let state = try? await store.liveState() else {
            return .quiet
        }

        // ---- 2a. BUDGET-EXHAUSTION CLOSURE (2026-08-08) ----
        // A pursuit whose session budget is spent can never be picked again
        // (the selector filters it), but it still occupies one of the
        // maxOpenAgentPursuits cap slots — with no closer, two exhausted
        // pursuits starve the volition lane FOREVER (live case: both slots
        // heading to 12/12 with zero terminal paths). Its own written
        // abandonCondition promises "I close it with a note", so honor that
        // mechanically: receipt first, then cancel. Best-effort — a store
        // refusal (e.g. open children) logs and retries on a later tick.
        for item in state.items {
            guard item.isPursuit, item.origin == .agent, !item.status.isTerminal,
                  let p = item.pursuit, p.reservations.count >= p.maxSessions else { continue }
            do {
                // CAS close (gpt-5.5 review): re-verifies live + untouched
                // under the ops flock, so a mutation landing between our
                // state read and the close skips this sweep (retries next
                // tick) instead of being stomped.
                _ = try await store.closeItemIfUnchanged(
                    item.handle,
                    expectedUpdatedAt: item.updatedAt,
                    outcomeSummary: "abandon-condition close: session budget exhausted "
                        + "(\(p.reservations.count)/\(p.maxSessions)) with no completion — "
                        + "closed per the pursuit's own abandon condition.",
                    canceled: true
                )
            } catch {
                NSLog("[workshop] exhausted-pursuit close failed for %@: %@",
                      item.handle, String(describing: error))
            }
        }

        guard let candidate = Self.selectDueItem(from: state, now: now()) else {
            return .quiet   // quiet day → zero dispatch
        }

        // ---- 3. LEASE (H4) — one expensive background task per green window ----
        let window = Self.windowKey(now())
        guard await lease.tryAcquire(holder: "workshop", window: window) else {
            return .leaseHeld
        }

        // ---- 4. RESERVE FIRST (H3) — before any session/LLM work ----
        let day = DeskClock.dayStamp(now())
        let reservationId: String
        do {
            reservationId = try await store.reserveWorkSession(candidate.handle, day: day, slot: window)
        } catch {
            // Cap hit, or a non-pursuit that Wave A's store won't reserve. Either
            // way: skip, zero LLM spend.
            return .reservationRefused
        }
        // Desk's O_APPEND return establishes ordering but does not itself call
        // fsync. Flush the canonical op log, then re-read the reservation before
        // crossing the provider boundary. Any flush/read failure consumes the
        // slot but spends zero tokens (fail closed).
        guard flushReservationLog(store.opsPath),
              let reservedState = try? await store.liveState(),
              let reservedItem = reservedState.items.first(where: { $0.handle == candidate.handle }),
              let durableReservation = reservedItem.pursuit?.reservations.first(where: {
                  $0.reservationId == reservationId
              }),
              durableReservation.completedAt == nil else {
            return .reservationRefused
        }

        // Record the volition BEFORE running (Wave C): the choice is auditable
        // even if the session then fails. An owner cadence item has no rationale
        // (nothing was chosen — it was due), so this is pursuit-only. If the
        // write fails (IO/corruption/race) the drop is LOGGED, not silent
        // (gpt-5.5 LOW — "never a silent queue" must hold even on error).
        if candidate.isPursuit, !candidate.choiceRationale.isEmpty {
            do {
                _ = try await store.appendWorkReceipt(candidate.handle, receipt: "chose: \(candidate.choiceRationale)")
            } catch {
                NSLog("[workshop] choice rationale not recorded for %@: %@",
                      candidate.handle, String(describing: error))
            }
        }

        // ---- 5. RUN one bounded session, then close it out + receipt (M8) ----
        let request = WorkshopSessionRequest(
            handle: candidate.handle,
            reservationId: reservationId,
            title: candidate.title,
            promptSeed: candidate.promptSeed
        )
        let receipt = await sessionRunner.run(request)

        // Close the reserved slot with a compact receipt on the pursuit, and
        // append the M8 per-session row. Best-effort: a store hiccup must not
        // wedge the loop.
        let receiptLine = "[\(receipt.status.rawValue)] \(receipt.summary)"
        _ = try? await store.completeWorkSession(candidate.handle, reservationId: reservationId, receipt: receiptLine)
        await receiptLog.append(receipt)

        return .ran(receipt.status)
    }

    // MARK: - Selection (pure; Wave C replaces with a real scorer)

    /// Wave C selection: self-pursuits are chosen by a BLENDED SCORE (real
    /// volition — evidence strength + momentum + closure proximity − no-progress
    /// penalty), and the choice is recorded as a rationale ("picked A over B
    /// because…") so it's auditable, not a silent queue. Owner cadence items keep
    /// simple due-ordering (no choice is made — they're due or not). Pure so
    /// both scoring and selection are trivially testable.
    ///
    /// C2 SEAM: felt salience (a substrate read) and the activeTask/goal
    /// NeedSignal wiring land in C2 — felt salience only RAISES a score, so it
    /// enriches this choice later without invalidating today's.
    public static func selectDueItem(from state: DeskState, now: Date) -> WorkshopCandidate? {
        let today = DeskClock.dayStamp(now)

        // The store also enforces a GLOBAL 6/day workshop cap counting DISTINCT
        // reservations across ALL pursuits (open + terminal). Pre-filter it here
        // (gpt-5.5 MED): otherwise a pursuit could score, acquire the green-window
        // lease, then fail reservation at the global cap — spending the lease on
        // no work, every tick, for the rest of the day.
        let globalToday = state.items.reduce(0) { acc, it in
            acc + (it.pursuit?.reservations.filter { $0.day == today }.count ?? 0)
        }
        let globalCapHit = globalToday >= SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay

        // Self-pursuits first — eligible ones are those within budget.
        let pursuits = globalCapHit ? [] : state.items.filter { item in
            guard item.isPursuit, !item.status.isTerminal, let p = item.pursuit else { return false }
            let usedSessions = p.reservations.count
            let todayCount = p.reservations.filter { $0.day == today }.count
            return usedSessions < p.maxSessions && todayCount < SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay
        }
        let scored = pursuits.compactMap { item -> (item: DeskItem, score: PursuitChoiceScore)? in
            guard let s = choiceScore(for: item, now: now) else { return nil }
            return (item, s)
        }
        // Highest total wins; ties broken deterministically by alias so a tick
        // is reproducible.
        if let best = scored.max(by: { a, b in
            a.score.total != b.score.total
                ? a.score.total < b.score.total
                : a.item.alias > b.item.alias
        }) {
            let picked = best.item
            let why = picked.pursuit?.why ?? picked.title
            let done = picked.pursuit?.doneLooksLike ?? ""
            var seed = "Work session on your pursuit \"\(picked.title)\".\nWhy: \(why)"
            if !done.isEmpty { seed += "\nDone looks like: \(done)" }
            // The session must know the budget and the exit: without these,
            // every session "makes progress" forever and the pursuit only ends
            // by mechanical exhaustion (2026-08-08 — neither live pursuit had
            // ever been told its own abandon condition).
            if let p = picked.pursuit {
                seed += "\nThis is session \(p.reservations.count + 1) of at most \(p.maxSessions)."
                let abandon = p.abandonCondition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !abandon.isEmpty {
                    seed += "\nAbandon condition (honor it honestly): \(abandon)"
                }
            }
            seed += "\nDo one bounded, honest step. Write artifacts with workshop_artifact_write; anything outward needs a desk approval."
            return WorkshopCandidate(
                handle: picked.handle, title: picked.title, promptSeed: seed, isPursuit: true,
                choiceRationale: choiceRationale(chosen: best.score, from: scored.map(\.score)))
        }

        // Else User items with a beating cadence that is due.
        let userDue = state.items.filter { item in
            guard !item.isPursuit, !item.status.isTerminal else { return false }
            switch item.cadence.mode {
            case .tick, .daily, .weekly: break
            default: return false
            }
            return isDue(item.cadence.nextRefreshAt, now: now)
        }
        if let picked = userDue.min(by: { lhs, rhs in
            lessRecentlyWorked(lhs.cadence.nextRefreshAt, rhs.cadence.nextRefreshAt, tieBreak: (lhs.alias, rhs.alias))
        }) {
            var seed = "Cadence work on \"\(picked.title)\"."
            if let s = picked.summary, !s.isEmpty { seed += "\n\(s)" }
            seed += "\nDo one bounded, honest step. Anything outward needs a desk approval."
            return WorkshopCandidate(handle: picked.handle, title: picked.title, promptSeed: seed, isPursuit: false)
        }

        return nil
    }

    /// Earliest persisted cadence/window crossing after `now`. Store changes
    /// cause an immediate event-driven reconciliation; this method exists only
    /// for time becoming meaningful without another mutation.
    public static func nextMeaningfulDeadline(from state: DeskState, after now: Date) -> Date? {
        var candidates: [Date] = []
        let today = DeskClock.dayStamp(now)
        let currentWindow = windowKey(now)
        let globalToday = state.items.reduce(0) { count, item in
            count + (item.pursuit?.reservations.filter { $0.day == today }.count ?? 0)
        }
        let openPursuits = state.items.filter { item in
            guard item.isPursuit, !item.status.isTerminal, let pursuit = item.pursuit else {
                return false
            }
            let todayCount = pursuit.reservations.filter { $0.day == today }.count
            return pursuit.reservations.count < pursuit.maxSessions
                && todayCount < SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay
        }
        if !openPursuits.isEmpty {
            let currentWindowConsumed = openPursuits.contains { pursuit in
                pursuit.pursuit?.reservations.contains {
                    $0.day == today && $0.slot == currentWindow
                } == true
            }
            if globalToday >= SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay {
                candidates.append(nextUTCDateBoundary(after: now))
            } else if currentWindowConsumed || selectDueItem(from: state, now: now) != nil {
                candidates.append(nextUTCWorkshopWindow(after: now))
            }
        }
        for item in state.items where !item.isPursuit && !item.status.isTerminal {
            guard item.cadence.mode == .tick
                    || item.cadence.mode == .daily
                    || item.cadence.mode == .weekly,
                  let raw = item.cadence.nextRefreshAt,
                  let due = DeskClock.parseISO(raw),
                  due > now
            else { continue }
            candidates.append(due)
        }
        return candidates.min()
    }

    static func nextUTCWorkshopWindow(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let hour = calendar.component(.hour, from: start)
        let hours = (hour % 2 == 0) ? 2 : 1
        return calendar.date(byAdding: .hour, value: hours, to: start)
            ?? date.addingTimeInterval(TimeInterval(hours * 3600))
    }

    static func nextUTCDateBoundary(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    /// Blended choice score for a pursuit (Wave C) — a pure read of desk state.
    /// nil for a non-pursuit. All components are normalized to roughly [0,1] so
    /// no single signal dominates; the felt-salience input (C2) will add on top.
    static func choiceScore(for item: DeskItem, now: Date = Date()) -> PursuitChoiceScore? {
        guard item.isPursuit, let p = item.pursuit else { return nil }
        let reservations = p.reservations
        let completed = reservations.filter { $0.completedAt != nil }.count
        let openReservations = reservations.count - completed

        // Evidence strength: breadth × diversity of NON-FRICTION citations only.
        // Friction can't inflate either term (gpt-5.5 MED — a pile of
        // trace_friction citations must not out-score a diverse dossier), matching
        // the store's dossier rule where friction alone is unrepresentable.
        // Saturates so a giant dossier can't run away.
        let nonFriction = p.evidence.citations.filter { !$0.isFriction }
        let nonFrictionKinds = Set(nonFriction.map { $0.token })
        let breadth = min(Double(nonFriction.count), 5) / 5.0
        let diversity = min(Double(nonFrictionKinds.count), 3) / 3.0
        let evidenceStrength = 0.6 * diversity + 0.4 * breadth

        // Momentum: completed work relative to a small rolling target — a pursuit
        // she's actively moving outranks one that's only been reserved.
        let momentum = min(Double(completed), 4) / 4.0

        // Closure proximity: nearer the doneLooksLike budget → finish it. Guard
        // against a zero/negative maxSessions (store clamps ≥1, belt-and-suspenders).
        let budget = max(p.maxSessions, 1)
        let closureProximity = min(Double(completed) / Double(budget), 1.0)

        // No-progress penalty: reservations that were opened but never completed
        // are drag — a pursuit that keeps reserving and not finishing should cede
        // its slot. Scaled gently so one open slot isn't fatal.
        let noProgressPenalty = min(Double(openReservations), 3) / 3.0 * 0.5

        // Recent-attention penalty: momentum rewards a pursuit that COMPLETES
        // work over its life, but a pursuit worked in the last day should yield
        // THIS tick so attention spreads instead of one pursuit monopolizing.
        // Decays to zero by ~24h — the counterweight the design pairs with
        // momentum. A pursuit with much stronger evidence can still win despite
        // recent work; a fresh sibling of equal evidence takes the next slot.
        let recentAttentionPenalty: Double = {
            guard let raw = p.lastWorkedAt, let last = DeskClock.parseISO(raw) else { return 0 }
            let hours = now.timeIntervalSince(last) / 3600.0
            // Older than a day → no penalty. A just-worked (or, because the
            // commit clock is Lamport-monotonic, a hair-in-the-future) stamp
            // clamps to 0h → FULL penalty. Clamping matters: without it a
            // sub-millisecond future stamp reads as "no penalty" and flips
            // selection non-deterministically.
            guard hours < 24 else { return 0 }
            let clamped = max(0, hours)
            return (1.0 - clamped / 24.0) * 0.6
        }()

        return PursuitChoiceScore(
            handle: item.handle, alias: item.alias,
            evidenceStrength: evidenceStrength, momentum: momentum,
            closureProximity: closureProximity, noProgressPenalty: noProgressPenalty,
            recentAttentionPenalty: recentAttentionPenalty)
    }

    /// The recorded volition: why the chosen pursuit beat the others this tick.
    static func choiceRationale(chosen: PursuitChoiceScore, from all: [PursuitChoiceScore]) -> String {
        func fmt(_ s: PursuitChoiceScore) -> String {
            String(format: "%@=%.2f(ev %.2f, mom %.2f, close %.2f, drag −%.2f, recent −%.2f)",
                   s.alias, s.total, s.evidenceStrength, s.momentum, s.closureProximity,
                   s.noProgressPenalty, s.recentAttentionPenalty)
        }
        let others = all.filter { $0.handle != chosen.handle }
            .sorted { $0.total > $1.total }
            .prefix(2)
        if others.isEmpty {
            return "Picked \(fmt(chosen)) — the only eligible pursuit this tick."
        }
        return "Picked \(fmt(chosen)) over " + others.map(fmt).joined(separator: ", ") + "."
    }

    /// A cadence with no `nextRefreshAt` is due now; otherwise due when the next
    /// refresh time is at or before `now`. An unparseable stamp is treated as due
    /// (fail-forward: a beating cadence shouldn't stall on a malformed date).
    static func isDue(_ nextRefreshAt: String?, now: Date) -> Bool {
        guard let raw = nextRefreshAt, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        guard let due = DeskClock.parseISO(raw) else { return true }
        return due <= now
    }

    /// Ordering helper: nil (never worked / no next time) sorts FIRST; otherwise
    /// earlier timestamp first; ties broken by alias for determinism.
    private static func lessRecentlyWorked(_ lhs: String?, _ rhs: String?, tieBreak: (String, String)) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return tieBreak.0 < tieBreak.1
        case (nil, _): return true
        case (_, nil): return false
        case (let l?, let r?):
            let dl = DeskClock.parseISO(l)
            let dr = DeskClock.parseISO(r)
            switch (dl, dr) {
            case (nil, nil): return tieBreak.0 < tieBreak.1
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?):
                if a == b { return tieBreak.0 < tieBreak.1 }
                return a < b
            }
        }
    }

    /// The green-window key: UTC day + 2h bucket. Two ticks in the same ~2h
    /// window share a key, so the lease grants at most one workshop session per
    /// window and the reservation id is idempotent within it.
    static func windowKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let hour = cal.component(.hour, from: date)
        return "\(DeskClock.dayStamp(date))-b\(hour / 2)"
    }
}

public enum WorkshopReservationDurability {
    public static func flush(_ path: URL) -> Bool {
        let fd = Darwin.open(path.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { return false }
        // The reservation is not durable if the op bytes survive but the
        // canonical feed's directory entry does not. This also fails closed on
        // a symlinked parent instead of crossing the provider boundary through
        // an attacker-controlled path.
        return flushDirectory(path.deletingLastPathComponent())
    }

    static func flushDirectory(_ path: URL) -> Bool {
        let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return Darwin.fsync(fd) == 0
    }
}

// MARK: - Shared background-work lease (H4)

/// A durable, single-slot lease that grants at most ONE background task per
/// green window. Any holder (workshop today; reflection/replay when they adopt
/// it) that acquires a window CONSUMES it for everyone — so reflection + replay
/// + workshop can't all fire in one window. Persisted so the guard survives a
/// mid-window restart. Keyed only by window: once a window is taken, a repeat
/// acquire for the SAME window fails regardless of release.
public actor BackgroundWorkLease {
    private let path: URL
    private let persistence: SwiftNativePersistenceCore

    public init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.path = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("background_lease.json")
        self.persistence = persistence
    }

    /// True iff this call is the first to claim `window`. Persists the claim
    /// under the file lock so concurrent callers can't both win.
    public func tryAcquire(holder: String, window: String) async -> Bool {
        let holder = holder.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !holder.isEmpty, !window.isEmpty else { return false }
        return (try? await persistence.withFileLock(path) { () async throws -> Bool in
            var claims: [JSONValue] = []
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                let current = try JSONValue.parse(data)
                guard case .object(let obj) = current else {
                    throw NSError(domain: "BackgroundWorkLease", code: 1)
                }
                if case .array(let rows)? = obj["claims"] {
                    guard rows.allSatisfy({ row in
                        guard case .object(let claim) = row,
                              case .string(let claimedWindow)? = claim["window"],
                              !claimedWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return false
                        }
                        return true
                    }) else {
                        throw NSError(domain: "BackgroundWorkLease", code: 3)
                    }
                    claims = rows
                } else if case .string(let legacyWindow)? = obj["window"] {
                    claims = [.object([
                        "window": .string(legacyWindow),
                        "holder": obj["holder"] ?? .string("legacy"),
                        "acquiredAt": obj["acquiredAt"] ?? .null,
                    ])]
                } else {
                    throw NSError(domain: "BackgroundWorkLease", code: 2)
                }
            }
            let alreadyClaimed = claims.contains { row in
                guard case .object(let claim) = row,
                      case .string(let claimedWindow)? = claim["window"] else { return false }
                return claimedWindow == window
            }
            if alreadyClaimed {
                return false
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let claim: JSONValue = .object([
                "window": .string(window),
                "holder": .string(holder),
                "acquiredAt": .string(stamp),
            ])
            claims.append(claim)
            claims = Array(claims.suffix(32))
            let record: JSONValue = .object([
                "window": .string(window),
                "holder": .string(holder),
                "acquiredAt": .string(stamp),
                "claims": .array(claims),
            ])
            try await persistence.writeJSON(record, to: path)
            guard WorkshopReservationDurability.flushDirectory(path.deletingLastPathComponent()) else {
                throw NSError(domain: "BackgroundWorkLease", code: 4)
            }
            return true
        }) ?? false
    }

    /// The window currently recorded as spent, if any (observability/tests).
    public func currentWindow() async -> String? {
        let current = await persistence.readJSON(path, defaultValue: .object([:]))
        if case .object(let obj) = current, case .string(let w)? = obj["window"] { return w }
        return nil
    }
}

// MARK: - Compact per-session receipt log (M8)

/// Appends one compact JSONL row per session, keyed by (handle, reservationId).
/// Deliberately NOT the weekly WorkshopOutcomeScoreboard (O(all Workshop executions) per
/// tick) — a small, append-only feed.
public actor WorkshopReceiptLog {
    private let path: URL
    private let persistence: SwiftNativePersistenceCore

    public init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.path = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        self.persistence = persistence
    }

    public var receiptsPath: URL { path }

    public func append(_ receipt: WorkshopSessionReceipt) async {
        let stamp = ISO8601DateFormatter().string(from: receipt.generatedAt)
        let row: JSONValue = .object([
            "handle": .string(receipt.handle),
            "reservationId": .string(receipt.reservationId),
            "status": .string(receipt.status.rawValue),
            "model": receipt.model.map { JSONValue.string($0) } ?? .null,
            "artifactCount": .int(Int64(receipt.artifactPaths.count)),
            "summary": .string(String(receipt.summary.prefix(600))),
            "ts": .string(stamp),
        ])
        try? await persistence.appendJSONL(row, to: path)
    }
}
