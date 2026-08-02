import Foundation

// MARK: - DeskNagEvaluator — "stale AND something moved" (PURE, never stored)
//
// Agent's binding rule, and the reason this is a separate lane from
// DeskNotifyEvaluator: STALENESS ALONE NEVER PINGS. A card that has sat
// untouched for a week while nothing underneath it changed is not news — it is
// digest material, and it goes in a list User reads when he is already being
// spoken to. What earns an interruption is stale + a DELTA underneath: the last
// blocker closed, the defer date passed, or the item's own content advanced
// while it was already stale. Those are the moments where User's next action
// just became possible and he doesn't know it yet.
//
// THE CAP IS STRUCTURAL, not a cooldown. Each item nags at most ONCE per
// windowId (DeskNagConfig.ledger), and the window only advances when User
// unmutes or switches the lane back on. So the worst case for a desk of any
// size is one ping per item per deliberate User action — there is no timer that
// can quietly re-arm the whole desk overnight.
//
// MUTED MEANS QUIET, NOT BLIND. While muted the evaluator OBSERVES but never
// CONSUMES: it records a baseline for items it has never seen (so a card
// created during the quiet week is tracked) and leaves every existing baseline
// frozen. That freeze is what makes `digestOnUnmute` truthful — the drift is
// still measurable against the pre-mute snapshot when User comes back.
//
// Everything here is pure: `now` is injected, no wall clock is read, and the
// updated config is RETURNED for the caller to persist under the flock. Same
// contract as DeskSequencing — the evaluator and its tests are reproducible.

public enum DeskNagEvaluator {

    /// One earned interruption. Shaped like DeskNotifyEvaluator.Decision minus
    /// the CAS stamp: the nag lane's idempotency comes from the window ledger,
    /// not from a lastNotifiedAt compare-and-swap on the item.
    public struct Nag: Sendable, Equatable {
        public let handle: String
        public let title: String
        public let body: String
        /// ALWAYS `.digest`. A nag is User asking to be kept on track; it is
        /// never allowed to escalate to the urgent channel — that lane belongs
        /// to items he explicitly marked direct/urgent (DeskNotifyEvaluator).
        public let level: NotifyLevel

        public init(handle: String, title: String, body: String, level: NotifyLevel = .digest) {
            self.handle = handle
            self.title = title
            self.body = body
            self.level = level
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Items that earned a ping this tick.
        public var nags: [Nag]
        /// Stale + STATIC items, one line each ("alias · title — stale 5d").
        /// These are NEVER pushed on their own; the loop attaches them to a
        /// push that was already happening. That is Agent's rule in the
        /// delivery layer, not just in the trigger.
        public var digestLines: [String]
        /// Config with the new snapshots and ledger entries. The caller
        /// persists this under the config flock; nothing here writes.
        public var updatedConfig: DeskNagConfig

        public init(nags: [Nag] = [], digestLines: [String] = [], updatedConfig: DeskNagConfig) {
            self.nags = nags
            self.digestLines = digestLines
            self.updatedConfig = updatedConfig
        }
    }

    /// Staleness threshold when the item's cadence doesn't set one. Three days
    /// is "a working stretch went by and this didn't move".
    public static let defaultStaleAfter: TimeInterval = 72 * 60 * 60

    /// Digest lines are capped so one neglected project can't turn a single
    /// nag into a wall of text.
    public static let digestLineCap = 8

    /// The overflow line appended when the cap hid something (audit
    /// 2026-08-02, finding 3). CAPPING THE DIGEST IS FINE; CAPPING IT SILENTLY
    /// IS NOT — `consumingDrift` advances the baseline for EVERY scoped item,
    /// so anything the cap hid has its delta consumed and will never nag and
    /// never appear in a later digest. One extra line is the whole difference
    /// between "shortened" and "lost".
    static func overflowLine(hidden: Int, describing what: String = "moved") -> String {
        "+\(hidden) more \(what) — run desk to see them"
    }

    /// Cap `lines` at `digestLineCap`, appending an explicit overflow line when
    /// anything was hidden. Nothing is ever dropped without being counted.
    static func capped(_ lines: [String], describing what: String = "moved") -> [String] {
        guard lines.count > digestLineCap else { return lines }
        return Array(lines.prefix(digestLineCap))
            + [overflowLine(hidden: lines.count - digestLineCap, describing: what)]
    }

    // MARK: - Main pass

    public static func evaluate(
        state: DeskState,
        plan: DeskSequencing.Plan,
        config: DeskNagConfig,
        now: Date
    ) -> Outcome {
        // GLOBAL OFF IS TOTAL INERTNESS: no nags, no digest, and — critically —
        // no config mutation, so a fresh install never even writes the file.
        // Zero behaviour change until User opts in.
        guard config.enabled else { return Outcome(updatedConfig: config) }

        let muted = config.isMuted(now: now)
        var next = config
        var nags: [Nag] = []
        var digest: [String] = []

        for item in state.items {
            guard !item.status.isTerminal else { continue }
            guard config.scopeEnabled(for: item) else { continue }

            let snapshot = observation(item, plan: plan)

            guard let previous = config.observed[item.handle] else {
                // First sighting. A baseline is not a delta — an item can never
                // nag on the tick it is first seen, muted or not.
                next.observed[item.handle] = snapshot
                continue
            }

            // Muted: observe, never consume. The frozen baseline is the drift
            // digest's evidence.
            if muted { continue }

            // Parked items are not stale and not next actions (design decision
            // 2). Advance the baseline so that when the park elapses, the
            // false→true deferElapsed flip reads as the delta it is.
            guard snapshot.deferElapsed else {
                next.observed[item.handle] = snapshot
                continue
            }

            let age = staleness(item, now: now)
            let isStale = age != nil
            let reasons = deltaReasons(previous: previous, current: snapshot, isStale: isStale)

            if isStale, !reasons.isEmpty {
                if config.ledger[item.handle] == config.windowId {
                    // Already nagged this window. CONSUME the delta anyway —
                    // leaving it pending would let a suppressed nag detonate on
                    // the next window bump for something User was already told
                    // about.
                    next.observed[item.handle] = snapshot
                } else {
                    nags.append(nag(for: item, reasons: reasons, age: age))
                    next.ledger[item.handle] = config.windowId
                    next.observed[item.handle] = snapshot
                }
            } else if isStale {
                // Stale + static → digest, never a ping.
                digest.append(digestLine(for: item, age: age))
                next.observed[item.handle] = snapshot
            } else {
                next.observed[item.handle] = snapshot
            }
        }

        // STATE LIFECYCLE: bounded by PRESENCE IN STATE, not by status.
        //
        // Pruning on `!isTerminal` (the original rule) made the once-per-window
        // cap defeatable by a round trip User does all the time: close an item
        // and reopen it inside the same window, and the ledger entry that says
        // "already nagged" is gone — so it nags again, and again per cycle. The
        // cap is supposed to be STRUCTURAL (see the header): one ping per item
        // per deliberate User action.
        //
        // `state.items` already excludes archived rows, so keying on presence
        // bounds both maps to the size of the VISIBLE DESK — that is the actual
        // bound, and it is the whole bound (gpt-5.5 review 2026-08-02, NIT 5).
        // An earlier version of this comment claimed terminal rows leave "on the
        // archive sweep", which overclaims: `archiveSweep` (DeskStore) refuses
        // PINNED items and `.standing` items outright, and a parent with any
        // non-terminal descendant, so those rows stay in `state.items` — and
        // therefore hold an `observed`/`ledger` entry — for as long as User keeps
        // them on the desk, sweep or no sweep. That is bounded and intended:
        // the desk is a human-sized surface, so the maps are human-sized too.
        // What is NOT true is that every terminal item's entry is guaranteed to
        // age out on its own. A reopen inheriting its pre-close baseline is the
        // POINT: the reopen's updatedAt bump reads as a delta, the ledger says
        // it was already reported this window, and the delta is consumed
        // instead of detonating.
        let known = Set(state.items.map(\.handle))
        next.observed = next.observed.filter { known.contains($0.key) }
        next.ledger = next.ledger.filter { known.contains($0.key) }

        return Outcome(
            nags: nags,
            digestLines: capped(digest, describing: "stale"),
            updatedConfig: next
        )
    }

    // MARK: - Unmute drift

    /// What moved while User was quiet. Called when `mutedUntil` transitions
    /// from future to past/nil — by the loop when it observes the expiry, and
    /// by desk_nag_control on an explicit unmute so the answer is IN the reply.
    ///
    /// Reports drift against the FROZEN baselines, which is why the muted pass
    /// refuses to advance them. Items created during the mute are reported as
    /// new — "nothing changed" must never be a side effect of not having looked.
    public static func digestOnUnmute(
        state: DeskState,
        plan: DeskSequencing.Plan,
        config: DeskNagConfig,
        now: Date
    ) -> [String] {
        guard config.enabled else { return [] }
        var lines: [String] = []
        for item in state.items {
            guard !item.status.isTerminal, config.scopeEnabled(for: item) else { continue }
            let snapshot = observation(item, plan: plan)
            guard let previous = config.observed[item.handle] else {
                lines.append("\(item.alias) \(item.title) — new since the mute")
                continue
            }
            guard previous != snapshot else { continue }
            var moved = deltaReasons(previous: previous, current: snapshot, isStale: true)
            if !previous.deferElapsed, !snapshot.deferElapsed { moved.append("still parked") }
            if moved.isEmpty { moved.append("changed") }
            lines.append("\(item.alias) \(item.title) — \(moved.joined(separator: ", "))")
        }
        // CAPPED, NEVER SILENTLY TRUNCATED (audit 2026-08-02, finding 3). The
        // caller pairs this with `consumingDrift`, which advances the baseline
        // for EVERY scoped item — so a line the cap hid is a delta User was
        // never shown AND can never be shown again: it doesn't nag (the delta
        // is consumed) and it doesn't come back in a later digest (there is no
        // drift left to report). Unlike `evaluate`'s stale+static digest, which
        // regenerates from persistent staleness every tick, this one does not
        // self-heal. The overflow line is the receipt.
        return capped(lines)
    }

    /// Advance every candidate's baseline to the current state — the CONSUME
    /// half of an unmute. Call it with the same (state, plan, now) that
    /// produced the digest, so the drift User just read can't be re-reported as
    /// a nag on the very next tick.
    public static func consumingDrift(
        state: DeskState,
        plan: DeskSequencing.Plan,
        config: DeskNagConfig,
        now: Date
    ) -> DeskNagConfig {
        var next = config
        for item in state.items where !item.status.isTerminal {
            guard config.scopeEnabled(for: item) else { continue }
            next.observed[item.handle] = observation(item, plan: plan)
        }
        // Same presence-keyed prune as `evaluate` — an unmute must not be a
        // back door that clears the once-per-window ledger for a closed item.
        let known = Set(state.items.map(\.handle))
        next.observed = next.observed.filter { known.contains($0.key) }
        next.ledger = next.ledger.filter { known.contains($0.key) }
        return next
    }

    // MARK: - Internals

    static func observation(_ item: DeskItem, plan: DeskSequencing.Plan) -> DeskNagObservation {
        let itemPlan = plan.byHandle[item.handle]
        return DeskNagObservation(
            updatedAt: item.updatedAt,
            effectiveBlockerCount: itemPlan?.effectiveBlockers.count ?? 0,
            deferElapsed: !(itemPlan?.isDeferred ?? false)
        )
    }

    /// The item's age past its staleness threshold, or nil when it is not
    /// stale. An UNPARSEABLE updatedAt reads as not-stale: a bad stamp must not
    /// manufacture pressure.
    static func staleness(_ item: DeskItem, now: Date) -> TimeInterval? {
        guard let updated = DeskClock.parseISO(item.updatedAt) else { return nil }
        let threshold = item.cadence.staleAfter.flatMap(DeskNotifyEvaluator.parseDuration) ?? defaultStaleAfter
        let age = now.timeIntervalSince(updated)
        return age > threshold ? age : nil
    }

    /// The delta vocabulary, in the order User cares about. `isStale` gates ONLY
    /// the content-advanced reason: a fresh edit to an item that isn't stale is
    /// just work happening, not news.
    static func deltaReasons(previous: DeskNagObservation, current: DeskNagObservation, isStale: Bool) -> [String] {
        var reasons: [String] = []
        if previous.effectiveBlockerCount > 0 && current.effectiveBlockerCount == 0 {
            reasons.append("blockers cleared")
        }
        if !previous.deferElapsed && current.deferElapsed {
            reasons.append("defer elapsed")
        }
        if isStale && current.updatedAt > previous.updatedAt {
            reasons.append("moved while stale")
        }
        return reasons
    }

    static func nag(for item: DeskItem, reasons: [String], age: TimeInterval?) -> Nag {
        var body = "\(item.alias) \(item.project) · \(item.title) — \(reasons.joined(separator: ", "))"
        if let age { body += "; untouched \(humanAge(age))" }
        return Nag(handle: item.handle, title: "Desk · \(item.project)", body: body, level: .digest)
    }

    static func digestLine(for item: DeskItem, age: TimeInterval?) -> String {
        "\(item.alias) \(item.title) — stale \(age.map(humanAge) ?? "?")"
    }

    /// Coarse, readable age: days past a day, else hours, else minutes.
    static func humanAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(seconds / 60)m"
    }

    /// The next wall-clock moment this lane could produce work on its own:
    /// the mute expiring (drift digest fires then), or — unmuted — the
    /// earliest future defer date on an in-scope item (a park ending is a
    /// DELTA trigger; without a deadline it waits for the next ops-event wake
    /// or the 24h backstop, making "parked until Friday" fire sometime
    /// Saturday). Returns only strictly-future dates, same contract as
    /// DeskNotifyEvaluator.nextMeaningfulDeadline — an exact-deadline owner
    /// must never be handed a past date to spin on.
    ///
    /// While muted only the mute end matters: the loop re-derives the deadline
    /// after the unmute wake, so defers landing beyond it are not lost.
    public static func nextMeaningfulDeadline(
        state: DeskState,
        config: DeskNagConfig,
        after now: Date
    ) -> Date? {
        guard config.enabled else { return nil }
        if let raw = config.mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let muteEnd = DeskSequencing.parseDeferStamp(raw),
           muteEnd > now {
            return muteEnd
        }
        return state.items.compactMap { item -> Date? in
            guard !item.status.isTerminal, config.scopeEnabled(for: item),
                  let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let until = DeskSequencing.parseDeferStamp(raw),
                  until > now
            else { return nil }
            return until
        }.min()
    }
}
