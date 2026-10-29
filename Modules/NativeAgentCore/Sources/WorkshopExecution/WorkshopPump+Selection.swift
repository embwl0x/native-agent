import Foundation
import NativeAgentCore
import NativeAgentShared
import Desk
// Blueprint: | `WorkshopPump+Selection.swift` | `WorkshopCandidate`, `PursuitChoiceScore` and `WorkshopPump` due-item selection, choice rationale, cadence deadlines and Desk-day windows |

/// A due item the pump chose to work. `promptSeed` carries only bounded strings
/// (title / why / doneLooksLike) — no persona bytes.
public struct WorkshopCandidate: Sendable, Equatable {
    public let handle: String
    public let title: String
    public let promptSeed: String
    public let isPursuit: Bool
    /// Auditable pursuit choice and runners-up; empty for an owner cadence item.
    public var choiceRationale: String = ""
}

/// A pursuit’s blended Desk evidence, momentum and closure score, with penalties.
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

extension WorkshopPump {
    // MARK: - Selection

    /// Score eligible pursuits with an auditable rationale, then due owner items.
    public static func selectDueItem(from state: DeskState, now: Date) throws -> WorkshopCandidate? {
        let today = DeskClock.dayStamp(now)

        // Apply Desk’s global daily reservation cap before acquiring a lease.
        let globalToday = state.workSessions(on: today)
        let globalCapHit = globalToday >= SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay
        let sequencing = DeskSequencing.compute(state, now: now)

        // Self-pursuits first — eligible ones are those within budget.
        let pursuits = globalCapHit ? [] : state.items.filter { item in
            guard item.isPursuit, !item.status.isTerminal, item.status != .blocked,
                  let expiry = item.pursuitExpiresAt, now < expiry,
                  sequencing.byHandle[item.handle]?.isReady == true,
                  let p = item.pursuit else { return false }
            let usedSessions = p.sessionsUsed(in: item.workAttempts)
            let todayCount = state.workSessions(on: today, handle: item.handle)
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
            var seed = try completionPolicy("workshop-work-session", section: "pursuit", arguments: [picked.title, why])
            if !done.isEmpty { seed += try completionPolicy("workshop-work-session", section: "done", arguments: [done]) }
            // Carry the session budget and abandon condition into the prompt.
            if let p = picked.pursuit {
                seed += try completionPolicy("workshop-work-session", section: "session", arguments: [String(p.sessionsUsed(in: picked.workAttempts) + 1), String(p.maxSessions)])
                let abandon = p.abandonCondition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !abandon.isEmpty {
                    seed += try completionPolicy("workshop-work-session", section: "abandon", arguments: [abandon])
                }
                let prior = picked.workAttempts.filter { $0.lane == .pursuit && $0.completedAt != nil }.suffix(3)
                if !prior.isEmpty {
                    seed += try completionPolicy("workshop-work-session", section: "prior")
                    for reservation in prior {
                        let receipt = (reservation.receipt ?? "")
                            .unicodeScalars
                            .filter { $0.value >= 0x20 && $0.value != 0x7F }
                        seed += "\n- \(String(String.UnicodeScalarView(receipt)).prefix(300))"
                        let refs = reservation.artifactRefs
                            .filter(Self.isSafePromptArtifactRef)
                            .prefix(4)
                        if !refs.isEmpty {
                            seed += " [artifacts: \(refs.joined(separator: ", "))]"
                        }
                    }
                }
            }
            seed += try completionPolicy("workshop-work-session", section: "pursuit-step")
            return WorkshopCandidate(
                handle: picked.handle, title: picked.title, promptSeed: seed, isPursuit: true,
                choiceRationale: choiceRationale(chosen: best.score, from: scored.map(\.score)))
        }

        // Else User items with a beating cadence that is due.
        let userDue = globalCapHit ? [] : state.items.filter { item in
            guard !item.isPursuit, item.project != MyQueue.project, item.assignee != "agent",
                  !item.status.isTerminal, item.status != .blocked,
                  sequencing.byHandle[item.handle]?.isReady == true
            else { return false }
            switch item.cadence.mode {
            case .tick, .daily, .weekly: break
            default: return false
            }
            // The Desk owner permits one owner-cadence attempt per item/day.
            // Pre-filter that exact admission rule here: otherwise a short
            // cadence remains due after its first daily attempt, acquires and
            // releases the shared lease, and retries a reservation the store
            // must refuse until midnight.
            return state.workSessions(on: today, handle: item.handle) == 0
                && isDue(item.cadence.nextRefreshAt, now: now)
        }
        if let picked = userDue.min(by: { lhs, rhs in
            lessRecentlyWorked(lhs.cadence.nextRefreshAt, rhs.cadence.nextRefreshAt, tieBreak: (lhs.alias, rhs.alias))
        }) {
            var seed = try completionPolicy("workshop-work-session", section: "cadence", arguments: [picked.title])
            if let s = picked.summary, !s.isEmpty { seed += "\n\(s)" }
            // Owner cadence reports progress through workshop_progress.
            seed += try completionPolicy("workshop-work-session", section: "cadence-step")
            return WorkshopCandidate(handle: picked.handle, title: picked.title, promptSeed: seed, isPursuit: false)
        }

        return nil
    }

    private static func isSafePromptArtifactRef(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 240,
              !raw.hasPrefix("/"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Earliest persisted cadence/window crossing after `now`. Store changes
    /// cause an immediate event-driven reconciliation; this method exists only
    /// for time becoming meaningful without another mutation.
    public static func nextMeaningfulDeadline(from state: DeskState, after now: Date) throws -> Date? {
        var candidates = state.items.compactMap { item -> Date? in
            guard !item.status.isTerminal, let expiry = item.pursuitExpiresAt, expiry > now else { return nil }
            return expiry
        }
        let today = DeskClock.dayStamp(now)
        let globalToday = state.workSessions(on: today)
        let eligiblePursuits = state.items.filter { item in
            guard item.isPursuit, !item.status.isTerminal, let pursuit = item.pursuit else {
                return false
            }
            return pursuit.sessionsUsed(in: item.workAttempts) < pursuit.maxSessions
        }
        let ownerCadenceItems = state.items.filter { item in
            guard !item.isPursuit, item.project != MyQueue.project, item.assignee != "agent",
                  !item.status.isTerminal else { return false }
            return item.cadence.mode == .tick
                || item.cadence.mode == .daily
                || item.cadence.mode == .weekly
        }
        let eligibleOwnerCadenceItems = ownerCadenceItems.filter { item in
            state.workSessions(on: today, handle: item.handle) == 0
        }
        // Ancestor deferrals also hold ready children; their exact crossing
        // must wake selection even if no Desk mutation occurs that day.
        if !eligiblePursuits.isEmpty || !ownerCadenceItems.isEmpty {
            candidates += state.items.compactMap { item in
                guard let raw = item.deferUntil,
                      let due = DeskSequencing.parseDeferStamp(raw), due > now else { return nil }
                return due
            }
        }
        if !eligiblePursuits.isEmpty || !eligibleOwnerCadenceItems.isEmpty {
            if globalToday >= SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay {
                candidates.append(deskDay(now).end)
            } else if try selectDueItem(from: state, now: now) != nil {
                // The current event has already had its chance to run. If a
                // shared lease or admission seam deferred it, retry at the next
                // exact green window without adding a polling loop.
                candidates.append(nextWorkshopWindow(after: now))
            }
        }
        let nextDay = deskDay(now).end
        for item in eligiblePursuits where
            state.workSessions(on: today, handle: item.handle) >= SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay {
            candidates.append(nextDay)
        }
        for item in ownerCadenceItems {
            let cadenceDue = item.cadence.nextRefreshAt.flatMap(DeskClock.parseISO)
            if state.workSessions(on: today, handle: item.handle) > 0 {
                // A cadence can become due again minutes after completion,
                // while its canonical one-per-day admission does not reopen
                // until the Desk day changes. Sleep until the later seam.
                candidates.append(max(cadenceDue ?? nextDay, nextDay))
            } else if let cadenceDue, cadenceDue > now {
                candidates.append(cadenceDue)
            }
        }
        return candidates.min()
    }

    /// The Desk day holding `date`, read through DeskClock's own day stamp and
    /// parser: the pump's windows, buckets and midnight reopening follow the
    /// day the Desk counts sessions in, in whatever zone the Desk keeps it.
    static func deskDay(_ date: Date) -> (start: Date, end: Date) {
        let start = DeskClock.parseDay(DeskClock.dayStamp(date)) ?? date
        // 36 hours lands inside the next day whether this one has 23, 24 or 25.
        let end = DeskClock.parseDay(DeskClock.dayStamp(start.addingTimeInterval(36 * 3600)))
            ?? start.addingTimeInterval(24 * 3600)
        return (start, end)
    }

    /// The next two-hour green window boundary within the Desk day.
    static func nextWorkshopWindow(after date: Date) -> Date {
        let day = deskDay(date)
        let bucket = (date.timeIntervalSince(day.start) / 7200).rounded(.down) + 1
        return min(day.start.addingTimeInterval(bucket * 7200), day.end)
    }

    /// Pure Desk score; normalized components keep any one signal from dominating.
    public static func choiceScore(for item: DeskItem, now: Date = Date()) -> PursuitChoiceScore? {
        guard item.isPursuit, let p = item.pursuit else { return nil }
        let reservations = item.workAttempts.filter { $0.lane == .pursuit }
        let completed = p.retiredSessions + reservations.filter { $0.completedAt != nil && $0.disposition != .unstarted }.count
        let openReservations = reservations.filter { $0.completedAt == nil }.count

        // Evidence breadth and diversity exclude friction, matching Desk’s dossier law.
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
    /// refresh time is at or before `now`. An unparseable stamp is unknown
    /// timing, never due: that item is left out and the tick names it.
    public static func isDue(_ nextRefreshAt: String?, now: Date) -> Bool {
        guard let raw = nextRefreshAt, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return DeskClock.parseISO(raw).map { $0 <= now } ?? false
    }

    /// Cadences whose saved next-refresh time cannot be read: unknown timing.
    static func unreadableCadences(in state: DeskState) -> [String] {
        state.items.compactMap { item in
            guard !item.status.isTerminal, [.tick, .daily, .weekly].contains(item.cadence.mode),
                  let raw = item.cadence.nextRefreshAt, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  DeskClock.parseISO(raw) == nil else { return nil }
            return "\(item.alias) (\"\(raw)\")"
        }
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

    /// The green-window key: Desk day + 2h bucket. Two ticks in the same ~2h
    /// window share a key, so the lease grants at most one workshop session per
    /// window and the reservation id is idempotent within it.
    public static func windowKey(_ date: Date) -> String {
        "\(DeskClock.dayStamp(date))-b\(Int(date.timeIntervalSince(deskDay(date).start) / 7200))"
    }
}
