import Foundation

// MARK: - DeskNotifyEvaluator — pure "which desk items should ping User now"
//
// A PULL surface that can tap User on the shoulder: a desk item the user tagged
// direct/urgent pings him when its CONTENT changes (updatedAt advances past the
// last ping) and the cooldown has elapsed. Pure + deterministic (`now` injected);
// the loop that actually fires the push lives in the app
// (BackgroundLoopsAssembly+DeskNotify) and calls SwiftNativeDeskStore.markNotified
// after each successful push.
//
// DESK-LOCAL BY DESIGN: this reads desk state and decides who to ping. It NEVER
// touches the CognitiveSubstrate — the desk reaches out to User, it does NOT live
// in Agent's cognition (User's hard line, 2026-06-29).
//
// IDEMPOTENT (Agent's requirement — one state change can't fan out into duplicate
// pings): markNotified stamps notify.lastNotifiedAt WITHOUT bumping updatedAt, so
// after a push the `updatedAt > lastNotifiedAt` gate is closed until the NEXT real
// content change. The cooldown is a second floor against rapid re-fire.
//
// v1 scope: fires on ANY content change to a direct/urgent active item. The
// notify.on event filter (blocked/unblocked/due/…) is captured on the item but
// not yet fully enforced here — a documented refinement, not a silent gap —
// with ONE enforced exception (2026-08-08, the "opened a self-pursuit" storm):
// an item whose `on` is exactly ["explicit"] is a one-time announcement. It
// pings once and never again from bare updatedAt churn — the Workshop pump's
// own work-session ops advance updatedAt every couple of hours, and before
// this rule each advance replayed the frozen open-time notifyReason at the
// user (28 pushes for 2 pursuits in 4 days). Re-pings on OTHER filters also
// stop replaying the open-time reason: a re-ping describes the change.

public enum DeskNotifyEvaluator {

    /// Everything the loop needs to fire one notification.
    public struct Decision: Sendable, Equatable {
        public let handle: String
        public let title: String
        public let body: String
        public let level: NotifyLevel   // .direct or .urgent
        /// The item's updatedAt at evaluation time — the loop stamps against THIS
        /// version (CAS) so a content change landing during the tick isn't
        /// swallowed (it pings on the next tick instead).
        public let observedUpdatedAt: String
        /// True for `on == ["explicit"]` one-time announcements. The loop
        /// stamps these UNCONDITIONALLY (no updatedAt CAS): fired is fired,
        /// and a content change landing mid-tick must not resurrect the
        /// announcement as a fresh "first ping" (gpt-5.5 review 2026-08-08).
        public let oneTimeAnnouncement: Bool

        public init(
            handle: String,
            title: String,
            body: String,
            level: NotifyLevel,
            observedUpdatedAt: String,
            oneTimeAnnouncement: Bool = false
        ) {
            self.handle = handle
            self.title = title
            self.body = body
            self.level = level
            self.observedUpdatedAt = observedUpdatedAt
            self.oneTimeAnnouncement = oneTimeAnnouncement
        }
    }

    /// Cooldown floor used when an item's notify.cooldown is unset/unparseable.
    public static let defaultCooldown: TimeInterval = 30 * 60

    /// The items that should ping User NOW, in desk (alias) order.
    public static func decisions(_ state: DeskState, now: Date) -> [Decision] {
        let inherited = inheritedNotify(state, now: now)
        return state.items.compactMap { decision(for: $0, now: now, inherited: inherited[$0.handle]) }
    }

    // MARK: - Cascade: a quiet child under a direct parent (2026-08-18)
    //
    // THE BUG THIS FIXES (caught live on campaign 644): User marks a project
    // direct/on:[state_change,blocked,done]; Agent breaks it into sub-items so
    // his phone can watch it tick through steps; every sub-item is born
    // level=quiet, and closing one pinged NOTHING. The parent doesn't fire
    // either — a child close doesn't advance the PARENT's updatedAt — so the
    // exact use case the lane was built for (async delegation: "watch it move
    // without asking me") was silent by construction.
    //
    // SHAPE: inherit-from-nearest-direct-ancestor. The CHILD is the pinging
    // item — it keeps its own lastNotifiedAt stamp, so idempotency, the CAS,
    // and the loop are all unchanged, and two sub-items closing seconds apart
    // are two pings instead of one swallowed by the parent's cooldown.
    //
    // INHERITED PINGS ARE TRANSITION-ONLY, and that is the storm guard: a
    // delegated sub-item is exactly the row an agent touches all day (notes,
    // refs, work logs), and any-change semantics under a direct parent would
    // turn one delegation into a push firehose. An inherited item pings on the
    // two transitions this evaluator can detect from a SNAPSHOT — it closed
    // (closedAt) or it is blocked (status) — and on nothing else. Activation
    // (todo → now) is deliberately NOT inherited: without transition history
    // it is indistinguishable from a note edit, and guessing would reopen the
    // storm. An item that wants every change still says so on itself.
    struct InheritedNotify: Sendable, Equatable {
        let level: NotifyLevel
        let filters: Set<String>
        let cooldown: String?
        /// Title of the ancestor whose policy this is — named in the push so
        /// User reads "which project just ticked", not an orphan step.
        let donorTitle: String
    }

    /// Per-handle inherited policy for items that carry none of their own.
    /// Cycle-safe (visited set + depth cap, same contract as DeskSequencing).
    static func inheritedNotify(_ state: DeskState, now: Date) -> [String: InheritedNotify] {
        let byHandle = Dictionary(state.items.map { ($0.handle, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: InheritedNotify] = [:]
        for item in state.items {
            // Only a DEFAULT-quiet child inherits. digest/direct/urgent are
            // deliberate choices on the item and always govern themselves —
            // which is also how a sub-item opts OUT of a loud parent.
            //
            // "DEFAULT" IS LITERAL (gpt-5.5 review, finding 3): a child that
            // states ANY policy of its own — its own `on` filter or its own
            // cooldown — is not a default row, and borrowing the ancestor's
            // policy would silently discard what it asked for. Inheriting the
            // ancestor's FILTERS over a child that set `on:["blocked"]` would
            // answer a question the child already answered. Such a child keeps
            // its own (quiet ⇒ silent) policy; to be heard it sets a level.
            guard item.notify.level == .quiet,
                  item.parent != nil,
                  item.notify.on.isEmpty,
                  trimmedNonEmpty(item.notify.cooldown) == nil
            else { continue }
            var seen: Set<String> = [item.handle]
            var current = item.parent
            var depth = 0
            while let cur = current, depth < deskMaxGraphDepth, seen.insert(cur).inserted {
                depth += 1
                guard let ancestor = byHandle[cur] else { break }
                // A PARKED ancestor silences its subtree: "not now" means the
                // same thing on every desk lane (audit 2026-08-02, finding 4),
                // and it must not be escapable by pinging through a child.
                if DeskSequencing.isDeferred(ancestor, now: now) { break }
                if ancestor.notify.level == .direct || ancestor.notify.level == .urgent {
                    // A one-time announcement is the ancestor's own single tap;
                    // it never becomes a standing subscription to its children.
                    if isExplicitOnly(ancestor) { break }
                    out[item.handle] = InheritedNotify(
                        level: ancestor.notify.level,
                        filters: normalizedFilters(ancestor),
                        cooldown: ancestor.notify.cooldown,
                        donorTitle: ancestor.title
                    )
                    break
                }
                current = ancestor.parent
            }
        }
        return out
    }

    /// Earliest future moment this lane could fire, per item:
    ///   • a PARKED item's own defer expiry — parking silences the shoulder-tap
    ///     (see `decision`), so the park ending is itself a wake-worthy moment:
    ///     an item that accumulated changes while parked must ping when it
    ///     un-parks, not whenever the next unrelated event happens to wake the
    ///     loop. Reported whether or not a cooldown is also outstanding, since
    ///     the defer gate outranks it.
    ///   • otherwise the cooldown crossing for an already-changed item.
    /// Initial notifications and already-due rows are handled by the event or
    /// startup reconciliation pass; returning only a future date prevents an
    /// exact-deadline owner from spinning on corrupt/unchanged state.
    public static func nextMeaningfulDeadline(_ state: DeskState, after now: Date) -> Date? {
        let inherited = inheritedNotify(state, now: now)
        return state.items.compactMap { item -> Date? in
            // Effective level: a quiet child under a direct ancestor schedules
            // wake-ups too, or its cooldown crossing would only be noticed the
            // next time some unrelated event happened to wake the loop.
            let level = inherited[item.handle]?.level ?? item.notify.level
            guard level == .direct || level == .urgent,
                  !item.status.isTerminal
            else { return nil }
            // A one-time announcement that already fired can never ping again,
            // so it must not generate wake deadlines either (a deadline for a
            // ping `decision` will refuse would spin the loop).
            if item.notify.lastNotifiedAt != nil, isExplicitOnly(item) { return nil }
            // Parked: the only thing that can unblock this item is the park
            // ending — but wake for it ONLY if a ping actually follows, so the
            // park end is a deadline for items with something to say, not for
            // every parked row on the desk.
            if DeskSequencing.isDeferred(item, now: now) {
                guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let until = DeskSequencing.parseDeferStamp(raw), until > now
                else { return nil }
                guard let lastRaw = item.notify.lastNotifiedAt,
                      let last = DeskClock.parseISO(lastRaw)
                else { return until }   // never pinged ⇒ eligible the moment the park lifts
                guard let updated = DeskClock.parseISO(item.updatedAt), updated > last
                else { return nil }     // nothing pending ⇒ the park end is not news
                // Inherited rows use the INHERITED cooldown here too — the
                // non-deferred branch below already does, and disagreeing
                // between the two branches schedules a wake at a time the
                // evaluator does not actually consider the row eligible
                // (gpt-5.5 review, finding 4).
                let cooldown = (inherited[item.handle]?.cooldown ?? item.notify.cooldown)
                    .flatMap(parseDuration) ?? defaultCooldown
                // Both gates must clear; the later one is the real moment.
                return max(until, last.addingTimeInterval(cooldown))
            }
            guard let lastRaw = item.notify.lastNotifiedAt,
                  let last = DeskClock.parseISO(lastRaw),
                  let updated = DeskClock.parseISO(item.updatedAt),
                  updated > last
            else { return nil }
            let cooldown = (inherited[item.handle]?.cooldown ?? item.notify.cooldown)
                .flatMap(parseDuration) ?? defaultCooldown
            let due = last.addingTimeInterval(cooldown)
            return due > now ? due : nil
        }.min()
    }

    static func decision(for item: DeskItem, now: Date, inherited: InheritedNotify? = nil) -> Decision? {
        // Only items the user explicitly asked to be tapped on the shoulder for
        // — or a default-quiet child standing under one (see inheritedNotify).
        let level = inherited?.level ?? item.notify.level
        guard level == .direct || level == .urgent else { return nil }
        // A CLOSING item is the one moment a delegated project must interrupt
        // User (desk-delegation-pushes W1): "I'll let you know when it's done"
        // becomes mechanical instead of a promise in Agent's head. A closed
        // item that already got its completion ping never fires again.
        guard !item.status.isTerminal else { return terminalDecision(for: item, now: now, inherited: inherited) }
        // PARKING SILENCES THE SHOULDER-TAP TOO (audit 2026-08-02, finding 4).
        // Both other desk lanes already honour the park — DeskSequencing drops a
        // deferred item out of `nextUp`, DeskNagEvaluator refuses to call it
        // stale — and this one didn't, so an item parked until September that
        // picked up a ref today fired a direct push. "Not now" has to mean the
        // same thing on every lane, and the loudest lane is the one where it
        // matters most. The change is NOT lost: `updatedAt` still sits past
        // `lastNotifiedAt`, so it fires on the first tick after the park ends —
        // which `nextMeaningfulDeadline` above now schedules exactly.
        guard !DeskSequencing.isDeferred(item, now: now) else { return nil }
        // INHERITED, NON-TERMINAL: the only snapshot-detectable transition left
        // is "it is blocked". Everything else on a borrowed policy stays quiet
        // (the storm guard — see inheritedNotify).
        if let inherited {
            guard item.status == .blocked,
                  inherited.filters.isEmpty
                    || inherited.filters.contains("blocked")
                    || inherited.filters.contains("state_change")
            else { return nil }
            return inheritedBlockedDecision(for: item, now: now, inherited: inherited)
        }
        // W2 (desk-delegation-pushes): a non-empty `on` filter is now ENFORCED,
        // mechanically and statelessly against the snapshot. Empty filter and
        // the live "state_change" vocabulary keep today's any-change semantics;
        // "blocked" pings while the item sits blocked; filters we cannot detect
        // without transition history (unblocked, user_next, due) do not match on
        // their own. Explicit-only items pass here — their once-only rule below
        // is the governing gate.
        guard changeFilterAllows(item) else { return nil }

        var isRePing = false
        if let lastRaw = item.notify.lastNotifiedAt, let last = DeskClock.parseISO(lastRaw) {
            // One-time announcements never re-ping: `on == ["explicit"]` means
            // the opener asked for exactly one shoulder-tap, and routine
            // machine churn (work logs, session receipts) advancing updatedAt
            // must not replay it.
            guard !isExplicitOnly(item) else { return nil }
            // Already pinged once: re-ping only on a REAL change since then
            // (markNotified doesn't bump updatedAt, so the stamp itself can't
            // re-trigger) …
            guard let updated = DeskClock.parseISO(item.updatedAt), updated > last else { return nil }
            // … and only past the cooldown floor.
            let cooldown = item.notify.cooldown.flatMap(parseDuration) ?? defaultCooldown
            guard now.timeIntervalSince(last) >= cooldown else { return nil }
            isRePing = true
        }
        // (lastNotifiedAt nil ⇒ never pinged ⇒ fire on this first eligible tick.)

        // notifyReason describes the moment the policy was SET (e.g. "opened a
        // self-pursuit"). It is first-ping copy only; a re-ping describes the
        // current state instead of replaying the stale announcement.
        var reason = isRePing
            ? "\(item.project) · \(item.title) — now \(item.status.rawValue)"
            : (trimmedNonEmpty(item.notify.notifyReason)
                ?? "\(item.project) · \(item.title) — now \(item.status.rawValue)")
        // A blocker ping answers "on WHAT?" in the push itself — User should not
        // have to open the app to learn what the project is waiting on.
        if item.status == .blocked, let waiting = trimmedNonEmpty(item.waitingOn) {
            reason += " — waiting on: \(waiting)"
        }
        return Decision(
            handle: item.handle,
            title: "Desk · \(item.project)",
            body: reason,
            level: item.notify.level,
            observedUpdatedAt: item.updatedAt,
            oneTimeAnnouncement: isExplicitOnly(item)
        )
    }

    // MARK: terminal completion ping (desk-delegation-pushes W1)

    /// Storm guard: only a close that happened RECENTLY may ping, so shipping
    /// completion pings can never replay the board's history (49 historical
    /// done items on the live board at introduction, 2026-08-17).
    public static let terminalPingWindow: TimeInterval = 48 * 3600

    /// The one final "it closed" ping for a delegated item. No cooldown gate:
    /// completion is the terminal event, and after its stamp the item is
    /// silent forever (updatedAt never advances past lastNotifiedAt again).
    static func terminalDecision(for item: DeskItem, now: Date, inherited: InheritedNotify? = nil) -> Decision? {
        // One-time announcements had their single tap; closing is not a second.
        // (An inherited policy is never explicit-only — inheritedNotify refuses
        // to hand one down — so this reads the item's own filter either way.)
        guard !isExplicitOnly(item) else { return nil }
        let filters = inherited?.filters ?? normalizedFilters(item)
        // At close, an empty filter (any-change), "done", or the live
        // "state_change" vocabulary all cover it; anything else opted out.
        guard filters.isEmpty || filters.contains("done") || filters.contains("state_change")
        else { return nil }
        guard let closedRaw = trimmedNonEmpty(item.closedAt),
              let closed = DeskClock.parseISO(closedRaw),
              now.timeIntervalSince(closed) <= terminalPingWindow
        else { return nil }
        // Already pinged at-or-after THIS close ⇒ silent forever — keyed off
        // closedAt, NOT updatedAt (gpt-5.5 HIGH: post-close churn like a note
        // or ref bumps updatedAt after the stamp and would re-send the same
        // completion). A re-open + re-close advances closedAt past the stamp
        // and legitimately earns a fresh completion ping.
        if let lastRaw = item.notify.lastNotifiedAt, let last = DeskClock.parseISO(lastRaw) {
            guard closed > last else { return nil }
        }
        let (mark, verb) = item.status == .done ? ("✓", "done") : ("✕", item.status.rawValue)
        // A step ping names its project so User reads progress, not an orphan.
        let step = inherited.map { " (step of \($0.donorTitle))" } ?? ""
        return Decision(
            handle: item.handle,
            title: "Desk · \(item.project)",
            body: "\(mark) \(item.title) — \(verb)\(step)",
            level: inherited?.level ?? item.notify.level,
            observedUpdatedAt: item.updatedAt,
            oneTimeAnnouncement: false
        )
    }

    // MARK: inherited blocked ping (cascade, 2026-08-18)

    /// A quiet sub-item that is BLOCKED under a direct/urgent ancestor. Same
    /// stamp + cooldown discipline as the item's own lane: first ping when it
    /// has never pinged, re-ping only on a real change past the cooldown —
    /// so a blocked step that keeps accruing notes taps User at most once per
    /// cooldown, and the answer to "on WHAT?" rides in the push.
    static func inheritedBlockedDecision(for item: DeskItem, now: Date, inherited: InheritedNotify) -> Decision? {
        // RECENCY BOUND (gpt-5.5 review, finding 2 — the rollout storm).
        // A never-stamped blocked child is otherwise eligible forever, so the
        // FIRST evaluator tick after this ships would fire one push for every
        // quiet child that has been sitting blocked for weeks — a burst of
        // ancient news, exactly the shape `terminalPingWindow` already bounds
        // on the close path. An inherited blocked ping is news only if the row
        // actually moved recently; a long-parked blocker is the digest's job.
        guard let updatedAt = DeskClock.parseISO(item.updatedAt),
              now.timeIntervalSince(updatedAt) <= terminalPingWindow
        else { return nil }
        if let lastRaw = item.notify.lastNotifiedAt, let last = DeskClock.parseISO(lastRaw) {
            guard let updated = DeskClock.parseISO(item.updatedAt), updated > last else { return nil }
            let cooldown = inherited.cooldown.flatMap(parseDuration) ?? defaultCooldown
            guard now.timeIntervalSince(last) >= cooldown else { return nil }
        }
        var body = "\u{26d4} \(item.title) — blocked (step of \(inherited.donorTitle))"
        if let waiting = trimmedNonEmpty(item.waitingOn) {
            body += " — waiting on: \(waiting)"
        }
        return Decision(
            handle: item.handle,
            title: "Desk · \(item.project)",
            body: body,
            level: inherited.level,
            observedUpdatedAt: item.updatedAt,
            oneTimeAnnouncement: false
        )
    }

    /// W2 change-event filter (stateless, per-snapshot). Explicit-only returns
    /// true — its once-only rule in `decision` is the governing gate.
    static func changeFilterAllows(_ item: DeskItem) -> Bool {
        let filters = normalizedFilters(item)
        if filters.isEmpty { return true }
        if filters == ["explicit"] { return true }
        if filters.contains("state_change") { return true }
        if filters.contains("blocked"), item.status == .blocked { return true }
        return false
    }

    // MARK: helpers

    static func normalizedFilters(_ item: DeskItem) -> Set<String> {
        Set(item.notify.on.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).subtracting([""])
    }

    /// True when the item's `on` filter is exactly the one-time announcement:
    /// ping once, then stay silent regardless of content churn.
    static func isExplicitOnly(_ item: DeskItem) -> Bool {
        normalizedFilters(item) == ["explicit"]
    }

    static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Parse "30m" / "2h" / "1d" / "45s" into seconds (mirrors DeskProjection).
    static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()) else { return nil }
        switch unit {
        case "s": return TimeInterval(value)
        case "m": return TimeInterval(value * 60)
        case "h": return TimeInterval(value * 3600)
        case "d": return TimeInterval(value * 86_400)
        default: return nil
        }
    }
}
